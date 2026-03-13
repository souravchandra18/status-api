"""
Status API — Production-grade FastAPI application
GCP edition: reads APP_ENV from Secret Manager, pushes metrics to Cloud Monitoring
"""

import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any

import structlog
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
)

log = structlog.get_logger(__name__)

# ---------------------------------------------------------------------------
# Build metadata (injected at build time via --build-arg)
# ---------------------------------------------------------------------------
BUILD_SHA = os.environ.get("BUILD_SHA", "unknown")
APP_VERSION = os.environ.get("APP_VERSION", "0.1.0")
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")


# ---------------------------------------------------------------------------
# GCP helpers
# ---------------------------------------------------------------------------

def get_secret(secret_name: str, project_id: str = None) -> str:
    """Fetch a secret from GCP Secret Manager."""
    # Import here so tests can mock without google-cloud installed
    from google.cloud import secretmanager  # noqa: PLC0415

    project = project_id or GCP_PROJECT_ID
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project}/secrets/{secret_name}/versions/latest"
    try:
        response = client.access_secret_version(request={"name": name})
        payload = response.payload.data.decode("utf-8")
        # Support both plain string and JSON {"APP_ENV": "production"}
        try:
            data = json.loads(payload)
            return data.get("APP_ENV", payload)
        except json.JSONDecodeError:
            return payload
    except Exception as exc:  # noqa: BLE001
        log.error("secret_manager_error", error=str(exc), secret=secret_name)
        raise


def push_metric(metric_type: str, value: float, labels: dict) -> None:
    """Push a custom metric to GCP Cloud Monitoring."""
    try:
        from google.cloud import monitoring_v3  # noqa: PLC0415
        from google.protobuf import timestamp_pb2  # noqa: PLC0415

        project = GCP_PROJECT_ID
        if not project:
            return

        client = monitoring_v3.MetricServiceClient()
        project_name = f"projects/{project}"

        series = monitoring_v3.TimeSeries()
        series.metric.type = f"custom.googleapis.com/status_api/{metric_type}"
        for k, v in labels.items():
            series.metric.labels[k] = str(v)

        series.resource.type = "gce_instance"
        series.resource.labels["project_id"] = project

        now = time.time()
        seconds = int(now)
        nanos = int((now - seconds) * 10**9)
        interval = monitoring_v3.TimeInterval(
            {"end_time": {"seconds": seconds, "nanos": nanos}}
        )
        point = monitoring_v3.Point(
            {"interval": interval, "value": {"double_value": value}}
        )
        series.points = [point]

        client.create_time_series(
            request={"name": project_name, "time_series": [series]}
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("cloud_monitoring_push_failed", metric=metric_type, error=str(exc))


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------
app_state: dict[str, Any] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown lifecycle."""
    secret_name = os.environ.get("SECRET_NAME", "status-api-app-env")
    try:
        app_env = get_secret(secret_name)
        log.info("secret_loaded", secret_name=secret_name, app_env=app_env)
    except Exception:  # noqa: BLE001
        # Fallback to env var for local dev / CI (no GCP credentials)
        app_env = os.environ.get("APP_ENV", "development")
        log.warning("secret_fallback", app_env=app_env)

    app_state["app_env"] = app_env
    app_state["start_time"] = time.time()
    log.info("application_started", build_sha=BUILD_SHA, version=APP_VERSION, env=app_env)

    yield

    log.info("application_shutdown")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Status API",
    version=APP_VERSION,
    description="Production-grade status API — GCP DevSecOps assignment",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Middleware — metrics + request logging
# ---------------------------------------------------------------------------

@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    request_id = str(uuid.uuid4())
    response: Response = await call_next(request)
    duration_ms = (time.time() - start) * 1000

    endpoint = request.url.path
    status_code = str(response.status_code)

    log.info(
        "request",
        request_id=request_id,
        method=request.method,
        path=endpoint,
        status_code=status_code,
        duration_ms=round(duration_ms, 2),
    )

    # Push custom metrics to Cloud Monitoring
    push_metric("request_count", 1, {"endpoint": endpoint, "status_code": status_code})
    push_metric("response_time_ms", duration_ms, {"endpoint": endpoint})

    return response


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    uptime_seconds = int(time.time() - app_state.get("start_time", time.time()))
    return {
        "status": "healthy",
        "build_sha": BUILD_SHA,
        "version": APP_VERSION,
        "env": app_state.get("app_env", "unknown"),
        "uptime_seconds": uptime_seconds,
    }


@app.get("/status")
async def status():
    return {
        "service": "status-api",
        "status": "running",
        "build_sha": BUILD_SHA,
        "version": APP_VERSION,
        "environment": app_state.get("app_env", "unknown"),
    }


@app.get("/info")
async def info():
    return {
        "build_sha": BUILD_SHA,
        "version": APP_VERSION,
        "python_env": app_state.get("app_env", "unknown"),
        "uptime_seconds": int(time.time() - app_state.get("start_time", time.time())),
    }


@app.get("/simulate/error")
async def simulate_error():
    log.error("simulated_error_triggered")
    return JSONResponse(status_code=500, content={"error": "simulated internal server error"})


@app.get("/simulate/latency")
async def simulate_latency():
    log.info("simulated_latency_triggered", sleep_ms=2500)
    time.sleep(2.5)
    return {"message": "slow response completed", "latency_ms": 2500}


@app.get("/version")
async def version():
    return {"version": APP_VERSION, "build_sha": BUILD_SHA}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)  # noqa: S104
