//! Fixed-window in-memory rate limiter and the middleware that enforces it. Suits a single
//! instance; a horizontally-scaled deployment would back the counters with a shared store
//! such as Redis.
//!
//! The middleware runs after authentication and keys callers by validated identity: the
//! API key that passed auth, or the peer IP when auth is disabled. Raw header values are
//! never used as keys, so an unauthenticated client cannot grow the table by sending random
//! tokens. The table is also capped: when full, stale windows are dropped first, then the
//! oldest one.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, Request, State};
use axum::middleware::Next;
use axum::response::Response;

use super::auth::ApiKeyIdentity;
use crate::error::AppError;

/// Default cap on tracked callers. Each entry is small, so this bounds the table to a few
/// megabytes at most.
pub const DEFAULT_MAX_TRACKED: usize = 10_000;

/// Counts requests per caller, allowing at most `max` per `window`.
pub struct RateLimiter {
    max: u32,
    window: Duration,
    max_tracked: usize,
    windows: Mutex<HashMap<String, Window>>,
}

struct Window {
    started: Instant,
    count: u32,
}

impl RateLimiter {
    pub fn new(max: u32, window: Duration) -> Self {
        Self::with_capacity(max, window, DEFAULT_MAX_TRACKED)
    }

    /// Like [`RateLimiter::new`] with an explicit cap on how many callers are tracked.
    pub fn with_capacity(max: u32, window: Duration, max_tracked: usize) -> Self {
        Self {
            max,
            window,
            max_tracked: max_tracked.max(1),
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Records a request for `caller`. Returns `Ok(())` when within the limit, otherwise
    /// `Err` with the number of seconds to wait until the window resets.
    pub fn record(&self, caller: &str) -> Result<(), u64> {
        let now = Instant::now();
        let mut windows = self.windows.lock().expect("rate limiter mutex poisoned");

        if !windows.contains_key(caller) && windows.len() >= self.max_tracked {
            self.make_room(&mut windows, now);
        }

        let window = windows
            .entry(caller.to_owned())
            .or_insert(Window { started: now, count: 0 });

        if now.duration_since(window.started) >= self.window {
            window.started = now;
            window.count = 0;
        }
        if window.count >= self.max {
            let remaining = self.window.saturating_sub(now.duration_since(window.started));
            return Err(remaining.as_secs() + 1);
        }
        window.count += 1;
        Ok(())
    }

    /// Frees at least one slot: drops every expired window, and if none had expired, the
    /// one that started earliest.
    fn make_room(&self, windows: &mut HashMap<String, Window>, now: Instant) {
        windows.retain(|_, w| now.duration_since(w.started) < self.window);
        if windows.len() >= self.max_tracked {
            let oldest = windows
                .iter()
                .min_by_key(|(_, w)| w.started)
                .map(|(k, _)| k.clone());
            if let Some(key) = oldest {
                windows.remove(&key);
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn tracked(&self) -> usize {
        self.windows.lock().unwrap().len()
    }
}

/// Rejects a caller over the limit with `429 Too Many Requests`. Must sit inside the auth
/// layer so [`ApiKeyIdentity`] is already attached. Without it (auth disabled) the caller
/// is keyed by peer IP. Behind a reverse proxy that is the proxy's address; trusting a
/// forwarded header would need a known proxy list, which v0.2 does not have.
pub async fn enforce(
    State(limiter): State<Arc<RateLimiter>>,
    request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let caller = caller_key(&request);
    match limiter.record(&caller) {
        Ok(()) => Ok(next.run(request).await),
        Err(retry_after_secs) => Err(AppError::RateLimited { retry_after_secs }),
    }
}

fn caller_key(request: &Request) -> String {
    if let Some(identity) = request.extensions().get::<ApiKeyIdentity>() {
        return format!("key:{}", identity.0);
    }
    match request.extensions().get::<ConnectInfo<SocketAddr>>() {
        Some(ConnectInfo(addr)) => format!("ip:{}", addr.ip()),
        None => "anonymous".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_up_to_the_limit_then_blocks() {
        let limiter = RateLimiter::new(3, Duration::from_secs(60));
        assert!(limiter.record("k").is_ok());
        assert!(limiter.record("k").is_ok());
        assert!(limiter.record("k").is_ok());
        assert!(limiter.record("k").is_err(), "the fourth request is blocked");
        // A different caller has an independent budget.
        assert!(limiter.record("other").is_ok());
    }

    #[test]
    fn tracked_callers_are_capped() {
        let limiter = RateLimiter::with_capacity(5, Duration::from_secs(60), 100);
        for i in 0..10_000 {
            let _ = limiter.record(&format!("random-{i}"));
        }
        assert!(limiter.tracked() <= 100, "table must not grow past its cap");
    }

    #[test]
    fn expired_windows_are_evicted_first() {
        let limiter = RateLimiter::with_capacity(1, Duration::from_millis(20), 2);
        limiter.record("a").unwrap();
        limiter.record("b").unwrap();
        std::thread::sleep(Duration::from_millis(30));
        limiter.record("c").unwrap();
        // Both stale windows were dropped to make room, not just one.
        assert_eq!(limiter.tracked(), 1);
    }

    #[test]
    fn keys_by_identity_then_ip_never_raw_header() {
        let mut req = Request::builder()
            .header("authorization", "Bearer random-garbage")
            .body(axum::body::Body::empty())
            .unwrap();
        assert_eq!(caller_key(&req), "anonymous");

        req.extensions_mut()
            .insert(ConnectInfo(SocketAddr::from(([10, 0, 0, 7], 4000))));
        assert_eq!(caller_key(&req), "ip:10.0.0.7");

        req.extensions_mut()
            .insert(ApiKeyIdentity("valid-key".to_string()));
        assert_eq!(caller_key(&req), "key:valid-key");
    }
}
