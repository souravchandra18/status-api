# Service Level Objective (SLO) — Status API (GCP)

## Service Overview

**Service:** Status API  
**Platform:** Google Cloud Platform (GCP)  
**Owner:** Sourav Chandra

The Status API is a Python/FastAPI microservice deployed on GCP Compute Engine (e2-micro, always-free tier). It exposes health, version, and status endpoints. Downstream systems and Cloud Monitoring uptime checks depend on `/health` returning `200 OK` to determine availability.

---

## SLI 1 — Availability

**Definition:** Percentage of `/health` requests returning HTTP `200 OK` in a rolling 30-day window.

**Measurement source:** GCP Cloud Monitoring uptime check (`google_monitoring_uptime_check_config.health`) + custom metric `custom.googleapis.com/status_api/request_count` filtered by `status_code=200`.

**MQL query:**
```
fetch generic_task
| metric 'custom.googleapis.com/status_api/request_count'
| filter metric.labels.endpoint = '/health'
| group_by [metric.labels.status_code], [sum: sum(value.request_count)]
```

**Target SLO: 99.5% availability over 30 days**

### Error Budget Calculation

| Period | Total minutes | Allowed downtime at 99.5% |
|--------|--------------|---------------------------|
| 30 days | 43,200 min | **216 minutes** (~3h 36m) |

---

## SLI 2 — Latency

**Definition:** Percentage of all API requests completing in under 500 ms.

**Measurement source:** Custom metric `custom.googleapis.com/status_api/response_time_ms`.

**MQL query:**
```
fetch generic_task
| metric 'custom.googleapis.com/status_api/response_time_ms'
| align delta(1m)
| every 1m
| group_by [], [p95: percentile(value.response_time_ms, 95)]
```

**Target SLO: 95th percentile of requests < 500 ms**

---

## Error Budget Policy

When the availability error budget falls below 50% (< 108 minutes remaining):

1. **Freeze** all non-reliability feature work on `main`
2. **Declare incident** — on-call engineer leads triage using [runbook.md](runbook.md)
3. **Post-mortem** within 24 hours
4. Feature work **resumes** only after budget recovery above 50%

---

## How Each SLI Is Measured

| SLI | Source | Alert |
|-----|--------|-------|
| Availability | Cloud Monitoring uptime check (60s interval) + `request_count` custom metric | `AppUnhealthy` policy |
| Latency | `response_time_ms` custom metric pushed by app via Cloud Monitoring API | `HighLatency` policy |
