//! Database access: connection pool and migrations. A single Postgres instance serves all
//! modules; the module boundaries mark where storage could later be split.

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

/// Connects, then runs embedded migrations. `migrate!` embeds the SQL files at compile
/// time (no DB needed to build) and applies any pending ones at startup.
pub async fn connect(url: &str) -> Result<PgPool, Box<dyn std::error::Error>> {
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    Ok(pool)
}
