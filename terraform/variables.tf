variable "project_id" {
  description = "GCP Project ID. Equivalent to AWS Account ID scope."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "GCP region for all resources. us-central1 is always-free tier eligible."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1", "us-west1"], var.region)
    error_message = "region must be a GCP always-free eligible region."
  }
}

variable "zone" {
  description = "GCP zone for Compute Engine VM. Must be within var.region."
  type        = string
  default     = "us-central1-a"
}

variable "allowed_ssh_ip" {
  description = <<EOT
    IP address permitted to SSH into the VM (without /32 suffix).
    Equivalent to the trusted CIDR in an AWS Security Group SSH ingress rule.
    Find yours by running: curl -s ifconfig.me
  EOT
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.allowed_ssh_ip))
    error_message = "allowed_ssh_ip must be a valid IPv4 address without /32 suffix."
  }
}

variable "alert_email" {
  description = <<EOT
    Email address for Cloud Monitoring alarm notifications.
    Equivalent to an SNS email subscription in AWS.
    GCP will send a confirmation email — you must click it before alerts are delivered.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "github_repository" {
  description = <<EOT
    GitHub repository in org/repo format.
    Used to bind Workload Identity Federation so only this repo's GitHub Actions
    can impersonate the CI/CD service account — equivalent to an AWS OIDC provider
    condition keyed on the repository claim.
    Example: "sourav-chandra/status-api"
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in org/repo format e.g. myorg/myrepo."
  }
}

variable "image_name" {
  description = <<EOT
    Docker image name (without registry prefix or tag).
    The compute module constructs the full Artifact Registry path:
      REGION-docker.pkg.dev/PROJECT_ID/IMAGE_NAME:latest
    Equivalent to the ECR repository name in AWS.
  EOT
  type        = string
  default     = "status-api"
}

variable "app_version" {
  description = "Application semantic version tag. Injected into the VM as an env var and into container labels."
  type        = string
  default     = "0.1.0"
}
