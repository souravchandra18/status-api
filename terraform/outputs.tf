# ── Public IP / DNS ───────────────────────────────────────────────────────────
# GCP equivalent of: EC2 public IP or ECS ALB DNS name

output "instance_public_ip" {
  description = "Public IP of the Compute Engine VM. Use for curl tests and SSH."
  value       = module.compute.instance_public_ip
}

output "app_url" {
  description = "Base URL of the running status API."
  value       = "http://${module.compute.instance_public_ip}:8080"
}

output "health_check_url" {
  description = "Health check endpoint — returns 200 when app is running."
  value       = "http://${module.compute.instance_public_ip}:8080/health"
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
# GCP equivalent of: ECR registry URL

output "artifact_registry_url" {
  description = <<EOT
    Docker registry URL for the Artifact Registry repository.
    Use with: docker push ARTIFACT_REGISTRY_URL:tag
    Equivalent to the ECR registry URL in AWS.
  EOT
  value       = module.compute.artifact_registry_url
}

# ── Secret ────────────────────────────────────────────────────────────────────
# GCP equivalent of: Secrets Manager secret ARN

output "secret_name" {
  description = <<EOT
    Secret Manager secret resource name.
    Equivalent to the Secrets Manager secret ARN in AWS.
    Use with: gcloud secrets versions access latest --secret=NAME
  EOT
  value       = module.compute.secret_name
}

# ── IAM / Auth ────────────────────────────────────────────────────────────────
# GCP equivalent of: IAM role ARN + OIDC provider ARN

output "workload_identity_provider" {
  description = <<EOT
    Workload Identity Federation provider resource name.
    Paste this as the WIF_PROVIDER GitHub secret.
    Equivalent to the AWS OIDC provider ARN used in GitHub Actions.
  EOT
  value       = module.compute.workload_identity_provider
}

output "cicd_service_account_email" {
  description = <<EOT
    Email of the CI/CD service account that GitHub Actions impersonates.
    Paste this as the WIF_SERVICE_ACCOUNT GitHub secret.
    Equivalent to the IAM role ARN assumed by GitHub Actions in AWS.
  EOT
  value       = module.compute.cicd_service_account_email
}

# ── Observability ─────────────────────────────────────────────────────────────

output "monitoring_dashboard_url" {
  description = "Cloud Monitoring dashboard URL. Equivalent to a CloudWatch dashboard URL."
  value       = module.observability.dashboard_url
}

output "log_explorer_url" {
  description = "Cloud Logging log explorer URL pre-filtered to this VM."
  value       = "https://console.cloud.google.com/logs/query;query=resource.type%3D%22gce_instance%22?project=${var.project_id}"
}
