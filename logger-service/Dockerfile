FROM rust:1-slim-bookworm AS build

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim

COPY --from=build /app/target/release/logger-service /usr/local/bin/logger-service

# Numeric UID so runAsNonRoot can be verified.
USER 1000

EXPOSE 8080

CMD ["logger-service"]
