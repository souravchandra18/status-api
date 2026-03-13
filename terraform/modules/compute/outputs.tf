output "instance_public_ip" {
  description = "External IP of the Compute Engine VM"
  value       = google_compute_instance.app.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "Unique instance ID — used by the observability module for metric filters"
  value       = google_compute_instance.app.instance_id
}

output "instance_name" {
  description = "VM instance name — used by the observability module for uptime check"
  value       = google_compute_instance.app.name
}

output "artifact_registry_url" {
  description = "Full Docker registry URL for the Artifact Registry repository"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.image_name}"
}

output "secret_name" {
  description = "Secret Manager secret resource name"
  value       = google_secret_manager_secret.app_env.name
}

output "workload_identity_provider" {
  description = "Full WIF provider resource name — paste as WIF_PROVIDER GitHub secret"
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "cicd_service_account_email" {
  description = "CI/CD service account email — paste as WIF_SERVICE_ACCOUNT GitHub secret"
  value       = google_service_account.cicd_sa.email
}

output "app_service_account_email" {
  description = "App VM service account email"
  value       = google_service_account.app_sa.email
}
