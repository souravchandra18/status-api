output "dashboard_url" {
  description = "Cloud Monitoring dashboard URL"
  value       = "https://console.cloud.google.com/monitoring/dashboards/custom/${google_monitoring_dashboard.main.id}?project=${var.project_id}"
}

output "notification_channel_id" {
  description = "Notification channel ID used by all alert policies"
  value       = google_monitoring_notification_channel.email.id
}

output "uptime_check_id" {
  description = "Uptime check config ID"
  value       = google_monitoring_uptime_check_config.health_endpoint.uptime_check_id
}
