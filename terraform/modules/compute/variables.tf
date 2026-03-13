variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for Artifact Registry and NAT"
  type        = string
}

variable "zone" {
  description = "GCP zone for the Compute Engine VM"
  type        = string
}

variable "network_id" {
  description = "VPC network self-link from the networking module"
  type        = string
}

variable "subnetwork_id" {
  description = "Subnet self-link from the networking module"
  type        = string
}

variable "image_name" {
  description = "Docker image name — used as the Artifact Registry repository ID"
  type        = string
}

variable "app_version" {
  description = "Application version tag injected into the VM startup script"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in org/repo format for WIF binding"
  type        = string
}
