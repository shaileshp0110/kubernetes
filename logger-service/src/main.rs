use axum::{
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use tokio::signal::unix::{signal, SignalKind};

#[derive(Deserialize)]
struct LogRequest {
    message: String,
}

async fn log_message(Json(req): Json<LogRequest>) -> &'static str {
    println!("logger-service received message: {}", req.message);
    "logged\n"
}

async fn health() -> &'static str {
    "ok\n"
}

fn app() -> Router {
    Router::new()
        .route("/log", post(log_message))
        .route("/health", get(health))
}

#[tokio::main]
async fn main() {
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    println!("logger-service listening on :8080");

    // PID 1 in a container gets no default SIGTERM handling; without this the pod
    // waits out the full termination grace period on every rollout.
    let mut sigterm = signal(SignalKind::terminate()).unwrap();
    axum::serve(listener, app())
        .with_graceful_shutdown(async move {
            sigterm.recv().await;
        })
        .await
        .unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{header::CONTENT_TYPE, Request, StatusCode},
    };
    use tower::ServiceExt;

    fn post_log(body: &'static str) -> Request<Body> {
        Request::post("/log")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(body))
            .unwrap()
    }

    #[tokio::test]
    async fn post_log_with_message_returns_ok() {
        let res = app().oneshot(post_log(r#"{"message":"hello"}"#)).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn post_log_without_message_is_rejected() {
        let res = app().oneshot(post_log("{}")).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[tokio::test]
    async fn health_returns_ok() {
        let req = Request::get("/health").body(Body::empty()).unwrap();
        let res = app().oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }
}
