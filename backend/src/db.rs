//! Database access: the pool and the migrations. In the MVP one Postgres serves all
//! modules; the module seams (auth/wallet/tx/notify) are where reads/writes split later.

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

/// Connect, then run embedded migrations. `migrate!` embeds the SQL files at compile
/// time (no DB needed to build) and applies any pending ones at startup.
pub async fn connect(url: &str) -> Result<PgPool, Box<dyn std::error::Error>> {
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    Ok(pool)
}
