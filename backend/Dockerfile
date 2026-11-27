# Build the release binary, then copy it into a small runtime image.
FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
RUN cargo build --release --bin xend-backend

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/xend-backend /usr/local/bin/xend-backend
ENV RUST_LOG=info
EXPOSE 8080
CMD ["xend-backend"]
