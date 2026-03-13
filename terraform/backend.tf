# ── Remote State Backend ──────────────────────────────────────────────────────
#
# GCP equivalent of AWS S3 backend:
#
#   AWS                          GCP
#   ─────────────────────────    ──────────────────────────────
#   backend "s3" {}          →   backend "gcs" {}
#   S3 bucket + versioning   →   GCS bucket + versioning
#   DynamoDB state lock      →   GCS object locking (built-in)
#
# The bucket name is passed at init time so this file stays committed safely:
#
#   terraform init -backend-config="bucket=status-api-tfstate-YOUR_PROJECT_ID"
#
# bootstrap.sh runs this command automatically.
#
# To create the bucket manually (one-time, before first init):
#   gsutil mb -l us-central1 gs://status-api-tfstate-YOUR_PROJECT_ID
#   gsutil versioning set on gs://status-api-tfstate-YOUR_PROJECT_ID
#   gsutil ubla set on gs://status-api-tfstate-YOUR_PROJECT_ID
#
# Note: Unlike S3+DynamoDB, GCS provides native object locking for state
# without a separate lock table. The backend handles this automatically.

# The actual backend block is intentionally empty here.
# Bucket is injected via -backend-config at init time (never hardcoded).
# See main.tf for the backend "gcs" {} block.
