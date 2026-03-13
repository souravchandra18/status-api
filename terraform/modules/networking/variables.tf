variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the subnet and NAT"
  type        = string
}

variable "allowed_ssh_ip" {
  description = "IP address permitted to SSH into the VM (without /32 suffix)"
  type        = string
}
