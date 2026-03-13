terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    # Configured via -backend-config at init time (see backend.tf comment)
    # terraform init -backend-config="bucket=status-api-tfstate-YOUR_PROJECT_ID"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── Enable required GCP APIs ────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ── Networking module ────────────────────────────────────────────────────────
# GCP equivalent of: VPC + subnet + IGW + routes + security groups
module "networking" {
  source = "./modules/networking"

  project_id      = var.project_id
  region          = var.region
  allowed_ssh_ip  = var.allowed_ssh_ip

  depends_on = [google_project_service.apis]
}

# ── Compute module ───────────────────────────────────────────────────────────
# GCP equivalent of: EC2/ECS task + IAM role + instance profile
module "compute" {
  source = "./modules/compute"

  project_id         = var.project_id
  region             = var.region
  zone               = var.zone
  network_id         = module.networking.network_id
  subnetwork_id      = module.networking.subnetwork_id
  image_name         = var.image_name
  app_version        = var.app_version
  github_repository  = var.github_repository

  depends_on = [module.networking, google_project_service.apis]
}

# ── Observability module ─────────────────────────────────────────────────────
# GCP equivalent of: CloudWatch log group + metric alarms + dashboard
module "observability" {
  source = "./modules/observability"

  project_id          = var.project_id
  region              = var.region
  alert_email         = var.alert_email
  instance_id         = module.compute.instance_id
  instance_zone       = var.zone

  depends_on = [module.compute, google_project_service.apis]
}
