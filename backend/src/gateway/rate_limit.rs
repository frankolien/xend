//! A fixed-window in-memory rate limiter and the middleware that enforces it. This suits a
//! single instance; a horizontally-scaled deployment would back the counters with a shared
//! store such as Redis.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;

use crate::error::AppError;

/// Counts requests per caller within a fixed window, allowing at most `max` per `window`.
pub struct RateLimiter {
    max: u32,
    window: Duration,
    windows: Mutex<HashMap<String, Window>>,
}

struct Window {
    started: Instant,
    count: u32,
}

impl RateLimiter {
    pub fn new(max: u32, window: Duration) -> Self {
        Self {
            max,
            window,
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Records a request for `caller`. Returns `Ok(())` when within the limit, or the
    /// number of seconds to wait once the window is exhausted.
    fn record(&self, caller: &str) -> Result<(), u64> {
        let now = Instant::now();
        let mut windows = self.windows.lock().expect("rate limiter mutex poisoned");
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
}

/// Middleware that rejects a caller exceeding the limit with `429 Too Many Requests`.
/// Callers are keyed by their API key when present, otherwise a shared anonymous bucket.
pub async fn enforce(
    State(limiter): State<Arc<RateLimiter>>,
    request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let caller = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("anonymous");

    match limiter.record(caller) {
        Ok(()) => Ok(next.run(request).await),
        Err(retry_after_secs) => Err(AppError::RateLimited { retry_after_secs }),
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
}
