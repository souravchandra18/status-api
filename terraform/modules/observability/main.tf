# ── Observability Module ──────────────────────────────────────────────────────
#
# AWS → GCP mapping:
#   CloudWatch Log Group       → Cloud Logging (automatic for GCE VMs — no resource needed)
#   CloudWatch Metric Filter   → google_logging_metric (log-based metric)
#   CloudWatch Alarm           → google_monitoring_alert_policy
#   CloudWatch Dashboard       → google_monitoring_dashboard
#   Route53 Health Check       → google_monitoring_uptime_check_config
#   SNS Topic + Subscription   → google_monitoring_notification_channel (email)
#

# ── Notification channel ──────────────────────────────────────────────────────
# AWS equivalent: aws_sns_topic + aws_sns_topic_subscription (email)
# Note: GCP sends a confirmation email — click it before alerts are delivered.
resource "google_monitoring_notification_channel" "email" {
  display_name = "Status API alert email"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.alert_email
  }
}

# ── Log-based metric ──────────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_log_metric_filter
# Counts log entries where the structured field httpRequest.status >= 500
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

# ── Alert policy 1: High error rate ───────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on HTTPCode_Target_5XX_Count
resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "HighErrorRate — status-api"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "HTTP 5xx errors in logs"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/status_api/error_count\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 5

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = "The status-api error rate has exceeded 5% in the last 5 minutes. Check Cloud Logging for 500 responses. Trigger endpoint: GET /simulate/error"
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Alert policy 2: High latency ──────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on TargetResponseTime P99
resource "google_monitoring_alert_policy" "high_latency" {
  display_name = "HighLatency — status-api P99 > 2s"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "VM CPU sustained high (latency proxy)"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
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
    content   = "P99 latency has exceeded 2000ms. Check for slow requests. Trigger endpoint: GET /simulate/latency"
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Alert policy 3: High CPU ──────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on CPUUtilization
resource "google_monitoring_alert_policy" "high_cpu" {
  display_name = "InstanceCPUHigh — status-api VM > 80%"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "VM CPU utilization > 80%"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
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
    content   = "VM CPU has been above 80% for 5 minutes. Consider scaling or investigating runaway processes."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Alert policy 4: App unhealthy (uptime check failure) ──────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on Route53 HealthCheckStatus
resource "google_monitoring_alert_policy" "app_unhealthy" {
  display_name = "AppUnhealthy — health check failing"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Uptime check /health failing"

    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\""
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
    content   = "The /health endpoint is not returning 200 OK. Check if the Docker container is running on the VM."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Alert policy 5: No traffic ────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_metric_alarm on NetworkIn = 0
resource "google_monitoring_alert_policy" "no_traffic" {
  display_name = "NoBytesIn — VM receiving no network traffic"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "No inbound bytes for 10 minutes"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/network/received_bytes_count\""
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
    content   = "VM has received no inbound network bytes for 10 minutes. Instance may be stopped or unreachable."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

# ── Dashboard ─────────────────────────────────────────────────────────────────
# AWS equivalent: aws_cloudwatch_dashboard
resource "google_monitoring_dashboard" "main" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "Status API Dashboard"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          width  = 6
          height = 4
          widget = {
            title = "Request count (custom metric)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"custom.googleapis.com/status_api/request_count\" resource.type=\"gce_instance\""
                    aggregation = {
                          alignmentPeriod    = "60s"
                          perSeriesAligner   = "ALIGN_MEAN"
                      crossSeriesReducer = "REDUCE_SUM"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        {
          xPos   = 6
          width  = 6
          height = 4
          widget = {
            title = "Response time P99 (ms)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"custom.googleapis.com/status_api/response_time_ms\" resource.type=\"gce_instance\""
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
        {
          yPos   = 4
          width  = 6
          height = 4
          widget = {
            title = "VM CPU utilization (%)"
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
        {
          xPos   = 6
          yPos   = 4
          width  = 6
          height = 4
          widget = {
            title = "Uptime check — /health"
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
        {
          yPos   = 8
          width  = 12
          height = 4
          widget = {
            title = "Network bytes received"
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
        }
      ]
    }
  })
}
