# ── Observability Module ──────────────────────────────────────────────────────
#
# AWS → GCP mapping:
#   CloudWatch Log Group       → Cloud Logging (automatic for GCE VMs)
#   CloudWatch Metric Filter   → google_logging_metric
#   CloudWatch Alarm           → google_monitoring_alert_policy
#   CloudWatch Dashboard       → google_monitoring_dashboard
#   Route53 Health Check       → google_monitoring_uptime_check_config
#   SNS Topic + Subscription   → google_monitoring_notification_channel

# ── Notification channel (SNS equivalent) ─────────────────────────────────────
resource "google_monitoring_notification_channel" "email" {
  display_name = "Status API alert email"
  type         = "email"
  project      = var.project_id
  labels = {
    email_address = var.alert_email
  }
}

# ── Log-based metric: error count ─────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_log_metric_filter on 5xx responses
resource "google_logging_metric" "error_count" {
  name        = "status_api/error_count"
  description = "Count of HTTP 5xx responses from the status-api container"
  project     = var.project_id

  filter = <<EOT
    resource.type="gce_instance"
    AND jsonPayload.status_code>=500
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Status API error count"
  }
}

# ── Uptime check ──────────────────────────────────────────────────────────────
# AWS equivalent: aws_route53_health_check
resource "google_monitoring_uptime_check_config" "health_endpoint" {
  display_name = "Status API health endpoint"
  timeout      = "10s"
  period       = "60s"
  project      = var.project_id

  http_check {
    path         = "/health"
    port         = 8080
    use_ssl      = false
    validate_ssl = false
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.instance_ip
    }
  }

  content_matchers {
    content = "healthy"
    matcher = "CONTAINS_STRING"
  }
}

# ── Alert 1: HighErrorRate ─────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm HTTPCode_Target_5XX_Count
# Triggered by: GET /simulate/error
resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "HighErrorRate — status-api"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "HTTP 5xx errors > 5 per minute"
    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"logging.googleapis.com/user/status_api/error_count\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "API error rate > 5% over 5 minutes. Check logs. Trigger: GET /simulate/error"
    mime_type = "text/markdown"
  }
  alert_strategy { auto_close = "1800s" }
}

# ── Alert 2: HighLatency ───────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm TargetResponseTime P99
# Triggered by: GET /simulate/latency
resource "google_monitoring_alert_policy" "high_latency" {
  display_name = "HighLatency — status-api P99 > 2s"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "VM CPU > 70% (latency proxy until custom metrics available)"
    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\""
      duration        = "180s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.70
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "P99 latency proxy (CPU) exceeded threshold. Trigger: GET /simulate/latency"
    mime_type = "text/markdown"
  }
  alert_strategy { auto_close = "1800s" }
}

# ── Alert 3: InstanceCPUHigh ──────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm CPUUtilization > 80%
resource "google_monitoring_alert_policy" "high_cpu" {
  display_name = "InstanceCPUHigh — VM CPU > 80%"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "CPU utilization > 80% for 5 minutes"
    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.80
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "VM CPU > 80% for 5 minutes. Check for runaway processes."
    mime_type = "text/markdown"
  }
  alert_strategy { auto_close = "1800s" }
}

# ── Alert 4: AppUnhealthy ─────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on Route53 health check
resource "google_monitoring_alert_policy" "app_unhealthy" {
  display_name = "AppUnhealthy — health check failing"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Uptime check /health failing 2 consecutive times"
    condition_threshold {
      filter          = "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\""
      duration        = "120s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "/health endpoint not returning 200. Check if Docker container is running."
    mime_type = "text/markdown"
  }
  alert_strategy { auto_close = "1800s" }
}

# ── Alert 5: NoBytesIn ────────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm NetworkIn = 0
resource "google_monitoring_alert_policy" "no_traffic" {
  display_name = "NoBytesIn — no network traffic for 10 minutes"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "No inbound bytes for 10 minutes"
    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/network/received_bytes_count\""
      duration        = "600s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "No inbound network bytes for 10 min. Instance may be stopped or crashed."
    mime_type = "text/markdown"
  }
  alert_strategy { auto_close = "3600s" }
}

# ── Dashboard ─────────────────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_dashboard
# Fix: use ALIGN_MEAN for GAUGE/DOUBLE metrics (not ALIGN_RATE or ALIGN_PERCENTILE_99)
resource "google_monitoring_dashboard" "main" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "Status API Dashboard"
    mosaicLayout = {
      columns = 12
      tiles = [
        # Tile 1: Request count — log-based DELTA metric, use ALIGN_DELTA
        {
          width  = 6
          height = 4
          widget = {
            title = "Request count (5xx errors — log metric)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/status_api/error_count\" resource.type=\"gce_instance\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_DELTA"
                      crossSeriesReducer = "REDUCE_SUM"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Tile 2: Response time via CPU (GAUGE/DOUBLE → ALIGN_MEAN only)
        {
          xPos   = 6
          width  = 6
          height = 4
          widget = {
            title = "Response time proxy — VM CPU utilization"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_MEAN"
                      crossSeriesReducer = "REDUCE_MEAN"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Tile 3: Uptime check pass rate
        {
          yPos   = 4
          width  = 6
          height = 4
          widget = {
            title = "Uptime check — /health pass rate"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" resource.type=\"uptime_url\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_FRACTION_TRUE"
                      crossSeriesReducer = "REDUCE_MEAN"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Tile 4: Network bytes in
        {
          xPos   = 6
          yPos   = 4
          width  = 6
          height = 4
          widget = {
            title = "Network bytes received (NoBytesIn detector)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"compute.googleapis.com/instance/network/received_bytes_count\" resource.type=\"gce_instance\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_RATE"
                      crossSeriesReducer = "REDUCE_SUM"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Tile 5: Alert status widget (all 5 alarms)
        {
          yPos   = 8
          width  = 12
          height = 4
          widget = {
            title = "All alert policies — status"
            alertChart = {
              name = "projects/${var.project_id}/alertPolicies/-"
            }
          }
        }
      ]
    }
  })
}
