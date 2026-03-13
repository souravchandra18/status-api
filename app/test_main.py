"""
Unit tests for the Status API (GCP edition).
All GCP calls are mocked — tests run with no real credentials.
"""

import os
import sys
import time
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

# ---------------------------------------------------------------------------
# Mock GCP libraries before importing the app
# ---------------------------------------------------------------------------

# Mock google-cloud-secret-manager
mock_secret_client = MagicMock()
mock_secret_response = MagicMock()
mock_secret_response.payload.data = b'{"APP_ENV": "test"}'
mock_secret_client.access_secret_version.return_value = mock_secret_response

# Mock google-cloud-monitoring
mock_monitoring_client = MagicMock()

# Patch the google.cloud namespace
mock_secretmanager_module = MagicMock()
mock_secretmanager_module.SecretManagerServiceClient.return_value = mock_secret_client

mock_monitoring_module = MagicMock()
mock_monitoring_module.MetricServiceClient.return_value = mock_monitoring_client

sys.modules["google"] = MagicMock()
sys.modules["google.cloud"] = MagicMock()
sys.modules["google.cloud.secretmanager"] = mock_secretmanager_module
sys.modules["google.cloud.monitoring_v3"] = mock_monitoring_module
sys.modules["google.protobuf"] = MagicMock()
sys.modules["google.protobuf.timestamp_pb2"] = MagicMock()

# Set env vars before import
os.environ.setdefault("APP_ENV", "test")
os.environ.setdefault("SECRET_NAME", "status-api-app-env")
os.environ.setdefault("GCP_PROJECT_ID", "test-project")
os.environ.setdefault("BUILD_SHA", "abc1234")
os.environ.setdefault("APP_VERSION", "0.1.0")

sys.path.insert(0, os.path.dirname(__file__))

from main import app  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def client():
    with TestClient(app) as c:
        yield c


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestHealthEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_response_has_required_fields(self, client):
        data = client.get("/health").json()
        assert data["status"] == "healthy"
        assert "build_sha" in data
        assert "version" in data
        assert "uptime_seconds" in data

    def test_build_sha_injected(self, client):
        data = client.get("/health").json()
        assert data["build_sha"] == "abc1234"


class TestStatusEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/status")
        assert resp.status_code == 200

    def test_service_name(self, client):
        data = client.get("/status").json()
        assert data["service"] == "status-api"
        assert data["status"] == "running"

    def test_contains_version(self, client):
        data = client.get("/status").json()
        assert "version" in data
        assert "build_sha" in data


class TestInfoEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/info")
        assert resp.status_code == 200

    def test_uptime_is_non_negative(self, client):
        data = client.get("/info").json()
        assert data["uptime_seconds"] >= 0

    def test_build_fields_present(self, client):
        data = client.get("/info").json()
        assert "build_sha" in data
        assert "version" in data


class TestVersionEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/version")
        assert resp.status_code == 200

    def test_version_fields(self, client):
        data = client.get("/version").json()
        assert data["build_sha"] == "abc1234"
        assert data["version"] == "0.1.0"


class TestSimulateErrorEndpoint:
    def test_returns_500(self, client):
        resp = client.get("/simulate/error")
        assert resp.status_code == 500

    def test_error_body(self, client):
        data = client.get("/simulate/error").json()
        assert "error" in data


class TestSimulateLatencyEndpoint:
    def test_returns_200(self, client):
        with patch("time.sleep"):
            resp = client.get("/simulate/latency")
        assert resp.status_code == 200

    def test_latency_field(self, client):
        with patch("time.sleep"):
            data = client.get("/simulate/latency").json()
        assert data["latency_ms"] == 2500
