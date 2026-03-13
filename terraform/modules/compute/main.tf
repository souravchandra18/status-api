# ── Compute Module ────────────────────────────────────────────────────────────
#
# AWS → GCP mapping:
#   ECR repository         → google_artifact_registry_repository
#   Secrets Manager secret → google_secret_manager_secret + secret_version
#   IAM Role               → google_service_account (app)
#   IAM Role               → google_service_account (CI/CD)
#   Instance profile       → service_account block on google_compute_instance
#   EC2 / ECS task         → google_compute_instance (e2-micro, always-free)
#   OIDC provider + role   → google_iam_workload_identity_pool + provider
#

# ── Artifact Registry ─────────────────────────────────────────────────────────
# AWS equivalent: aws_ecr_repository
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = var.image_name
  description   = "Docker images for status-api — equivalent to an ECR repository"
  format        = "DOCKER"
  project       = var.project_id

  # Cleanup policy: keep last 10 tagged images, delete untagged after 7 days
  # AWS equivalent: ECR lifecycle policy
  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }
}

# ── Secret Manager ────────────────────────────────────────────────────────────
# AWS equivalent: aws_secretsmanager_secret + aws_secretsmanager_secret_version
resource "google_secret_manager_secret" "app_env" {
  secret_id = "status-api-app-env"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    app = "status-api"
    env = "production"
  }
}

resource "google_secret_manager_secret_version" "app_env" {
  secret = google_secret_manager_secret.app_env.id
  # JSON payload mirrors what the Python app expects
  secret_data = jsonencode({ APP_ENV = "production" })
}

# ── App service account ───────────────────────────────────────────────────────
# AWS equivalent: IAM role with trust policy for EC2 service principal
resource "google_service_account" "app_sa" {
  account_id   = "status-api-app-sa"
  display_name = "Status API — app VM service account"
  description  = "Runtime identity for the Compute Engine VM. Least-privilege."
  project      = var.project_id
}

# Secret access — resource-scoped (not project-wide)
# AWS equivalent: IAM policy statement allowing secretsmanager:GetSecretValue on one secret ARN
resource "google_secret_manager_secret_iam_member" "app_secret_access" {
  secret_id = google_secret_manager_secret.app_env.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_sa.email}"
  project   = var.project_id
}

# Metrics write — project-scoped (no resource-level binding for monitoring)
# AWS equivalent: IAM policy statement allowing cloudwatch:PutMetricData
resource "google_project_iam_member" "app_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

# Artifact Registry read — repository-scoped
# AWS equivalent: ECR policy allowing ecr:GetDownloadUrlForLayer etc. on one repo
resource "google_artifact_registry_repository_iam_member" "app_ar_reader" {
  location   = var.region
  repository = google_artifact_registry_repository.repo.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.app_sa.email}"
  project    = var.project_id
}

# Log write
# AWS equivalent: IAM policy statement allowing logs:CreateLogStream, logs:PutLogEvents
resource "google_project_iam_member" "app_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

# ── CI/CD service account ─────────────────────────────────────────────────────
# AWS equivalent: IAM role assumed by GitHub Actions via OIDC
resource "google_service_account" "cicd_sa" {
  account_id   = "status-api-cicd-sa"
  display_name = "Status API — CI/CD service account"
  description  = "Impersonated by GitHub Actions via WIF. Least-privilege for pipeline."
  project      = var.project_id
}

# Push images to Artifact Registry
# AWS equivalent: ecr:BatchCheckLayerAvailability, ecr:PutImage, ecr:InitiateLayerUpload
resource "google_artifact_registry_repository_iam_member" "cicd_ar_writer" {
  location   = var.region
  repository = google_artifact_registry_repository.repo.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cicd_sa.email}"
  project    = var.project_id
}

# Compute admin — for rolling restart via gcloud compute ssh
# AWS equivalent: ec2:RebootInstances on the specific instance
resource "google_project_iam_member" "cicd_compute" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Allow CI/CD SA to use the app SA (needed for ssh-in-browser / OS Login deploy)
resource "google_service_account_iam_member" "cicd_acts_as_app" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Terraform state bucket access
# AWS equivalent: S3:GetObject, S3:PutObject, S3:ListBucket on the tfstate bucket
resource "google_project_iam_member" "cicd_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# ── Workload Identity Federation ──────────────────────────────────────────────
# AWS equivalent: aws_iam_openid_connect_provider + trust policy condition on
#                 token.actions.githubusercontent.com with repo condition

resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions pool"
  description               = "WIF pool for GitHub Actions. Equivalent to an AWS OIDC provider."
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC provider"
  project                            = var.project_id

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # Attribute mapping: translate GitHub OIDC claims to Google attributes
  # AWS equivalent: the condition in the IAM role trust policy checking
  # token.actions.githubusercontent.com:sub == "repo:org/repo:ref:refs/heads/main"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only tokens from this specific repository are accepted
  attribute_condition = "assertion.repository == \"${var.github_repository}\""
}

# Allow GitHub Actions tokens to impersonate the CI/CD SA
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.cicd_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repository}"
}

# ── Compute Engine VM ─────────────────────────────────────────────────────────
# AWS equivalent: aws_instance (t2.micro) or aws_ecs_task_definition
resource "google_compute_instance" "app" {
  name         = "status-api-instance"
  machine_type = "e2-micro" # always-free tier in us-central1/us-east1/us-west1
  zone         = var.zone
  project      = var.project_id

  tags = ["status-api-vm"] # selects firewall rules from networking module

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10 # GB — plenty for the OS + Docker
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.network_id
    subnetwork = var.subnetwork_id

    # Public IP — equivalent to associating an EIP or putting EC2 in a public subnet
    access_config {}
  }

  # Attach the app service account — equivalent to EC2 instance profile
  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }

  # Shielded VM — equivalent to EC2 Nitro with secure boot
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    # Block project-wide SSH keys — only operator key applies
    block-project-ssh-keys = "true"
    enable-oslogin         = "true"

    # Startup script: install Docker, pull latest image, run the container
    # AWS equivalent: EC2 user-data script or ECS task definition with image pull
    startup-script = <<-STARTUP
      #!/bin/bash
      set -euo pipefail

      # Install Docker if not already present
      if ! command -v docker &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
        curl -fsSL https://download.docker.com/linux/debian/gpg \
          | gpg --dearmor -o /usr/share/keyrings/docker.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] \
          https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -y -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io
      fi

      # Authenticate Docker to Artifact Registry using the VM's service account
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet

      # Pull and run the latest image
      IMAGE="${var.region}-docker.pkg.dev/${var.project_id}/${var.image_name}:latest"
      docker pull "$IMAGE" || echo "Image not yet available — will retry on next deploy"

      # Stop any existing container
      docker stop status-api 2>/dev/null || true
      docker rm   status-api 2>/dev/null || true

      # Run the container
      docker run -d \
        --name status-api \
        --restart unless-stopped \
        -p 8080:8080 \
        -e GCP_PROJECT_ID="${var.project_id}" \
        -e APP_VERSION="${var.app_version}" \
        "$IMAGE" || echo "Container start skipped — image not yet pushed"
    STARTUP
  }

  labels = {
    app = "status-api"
    env = "production"
  }

  # Allow Terraform to replace the instance if the startup-script changes
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_service_account.app_sa,
    google_artifact_registry_repository.repo,
    google_secret_manager_secret_version.app_env,
  ]
}
