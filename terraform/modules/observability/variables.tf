variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "alert_email" {
  description = "Email address for alarm notifications"
  type        = string
}

variable "instance_id" {
  description = "Compute Engine instance ID — used for metric filters"
  type        = string
}

variable "instance_zone" {
  description = "Zone of the Compute Engine instance — used for uptime check"
  type        = string
}
