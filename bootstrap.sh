#!/bin/bash
# =============================================================================
# bootstrap.sh — Run this ONCE on your GCP VM (or Cloud Shell) to set up
# everything. Edit the variables at the top before running.
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
# =============================================================================

set -euo pipefail

# ──   EDIT THESE BEFORE RUNNING ────────────────────────────────────────────
PROJECT_ID="project-14f0bd11-3275-4f56-b68"       # Your GCP Project ID
REGION="us-central1"
ZONE="us-central1-a"
ALERT_EMAIL="souravchandra696@gmail.com"               # Your email for alarm notifications
GITHUB_REPO="souravchandra18/status-api"   # Your GitHub org/repo
GITHUB_USERNAME="souravchandra18"          # Your GitHub username
# ─────────────────────────────────────────────────────────────────────────────

BUCKET_NAME="status-api-tfstate-${PROJECT_ID}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Status API — GCP Bootstrap Script                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Project ID  : $PROJECT_ID"
echo "Region      : $REGION"
echo "GitHub Repo : $GITHUB_REPO"
echo "State Bucket: $BUCKET_NAME"
echo ""

# ── Step 0: Confirm before proceeding ────────────────────────────────────────
read -r -p "Proceed with these settings? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted. Edit the variables at the top of this script and retry."
  exit 1
fi

# ── Step 1: Configure gcloud ─────────────────────────────────────────────────
echo ""
echo " Step 1/7 — Configuring gcloud..."
gcloud config set project "$PROJECT_ID"
gcloud auth application-default login --quiet 2>/dev/null || true

# ── Step 2: Enable APIs ───────────────────────────────────────────────────────
echo ""
echo " Step 2/7 — Enabling GCP APIs (takes ~1 minute)..."
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID" --quiet

echo "  Waiting 20 seconds for APIs to propagate..."
sleep 20

# ── Step 3: Create Terraform state bucket ─────────────────────────────────────
echo ""
echo " Step 3/7 — Creating Terraform state bucket..."
if gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
  echo "  Bucket already exists — skipping creation."
else
  gsutil mb -l "$REGION" "gs://${BUCKET_NAME}"
  gsutil versioning set on "gs://${BUCKET_NAME}"
  gsutil ubla set on "gs://${BUCKET_NAME}"
  echo "  ✅ Bucket created: gs://${BUCKET_NAME}"
fi

# ── Step 4: Update terraform.tfvars with real bucket name ─────────────────────
echo ""
echo " Step 4/7 — Updating terraform.tfvars..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="$SCRIPT_DIR/terraform/terraform.tfvars"

if [[ -f "$TFVARS" ]]; then
  # Update the bucket name in tfvars
  sed -i "s|tfstate_bucket.*=.*|tfstate_bucket = \"${BUCKET_NAME}\"|" "$TFVARS"
  echo "  ✅ Updated tfstate_bucket in terraform.tfvars"
else
  echo "  ⚠️  terraform.tfvars not found at $TFVARS"
  echo "     Make sure you run this script from the repo root."
fi

# ── Step 5: Get public IP for SSH firewall rule ────────────────────────────────
echo ""
echo " Step 5/7 — Detecting your public IP..."
MY_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "")
if [[ -z "$MY_IP" ]]; then
  echo "  Could not auto-detect IP. Enter it manually:"
  read -r -p "  Your public IP (e.g. 103.45.67.89): " MY_IP
fi
echo "  ✅ Your IP: $MY_IP"

# ── Step 6: Run Terraform ─────────────────────────────────────────────────────
echo ""
echo " Step 6/7 — Running Terraform (init → plan → apply)..."
echo "  This creates all GCP infrastructure (~5-10 minutes)..."
echo ""

cd "$SCRIPT_DIR/terraform"

export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_allowed_ssh_ip="$MY_IP"
export TF_VAR_alert_email="$ALERT_EMAIL"
export TF_VAR_github_repository="$GITHUB_REPO"

terraform init -backend-config="bucket=${BUCKET_NAME}" -input=false

echo ""
echo "  Running terraform plan..."
terraform plan -var-file=terraform.tfvars -out=tfplan.binary -input=false

echo ""
read -r -p "  ✅ Plan complete. Apply now? (yes/no): " APPLY_CONFIRM
if [[ "$APPLY_CONFIRM" != "yes" ]]; then
  echo "  Skipping apply. Run 'terraform apply tfplan.binary' manually when ready."
else
  terraform apply tfplan.binary
  echo "  ✅ Terraform apply complete!"
fi

# ── Step 7: Print GitHub Secrets ──────────────────────────────────────────────
echo ""
echo " Step 7/7 — Collecting outputs..."
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║          ADD THESE AS GITHUB SECRETS                                 ║"
echo "║  GitHub repo → Settings → Secrets → Actions → New repository secret  ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo ""
echo "  GCP_PROJECT_ID       = $PROJECT_ID"
echo "  GCP_REGION           = $REGION"
echo "  AR_REPO              = status-api"
echo "  TF_STATE_BUCKET      = $BUCKET_NAME"
echo "  ALLOWED_SSH_IP       = $MY_IP"
echo "  ALERT_EMAIL          = $ALERT_EMAIL"
echo "  SLACK_WEBHOOK_URL    = (optional — skip for now)"
echo ""

if terraform output workload_identity_provider &>/dev/null; then
  WIF_PROVIDER=$(terraform output -raw workload_identity_provider)
  WIF_SA=$(terraform output -raw cicd_service_account_email)
  APP_IP=$(terraform output -raw instance_public_ip)

  echo "  WIF_PROVIDER         = $WIF_PROVIDER"
  echo "  WIF_SERVICE_ACCOUNT  = $WIF_SA"
  echo ""
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║          YOUR LIVE APP URL (after pipeline runs)                     ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo ""
  echo "  http://$APP_IP:8080/health"
  echo "  http://$APP_IP:8080/status"
  echo ""

  # Save outputs to a file for reference
  cat > "$SCRIPT_DIR/github-secrets.txt" <<SECRETS
# GitHub Secrets — paste each into:
# GitHub repo → Settings → Secrets and variables → Actions → New repository secret
# DELETE THIS FILE after adding secrets to GitHub

GCP_PROJECT_ID       = $PROJECT_ID
GCP_REGION           = $REGION
AR_REPO              = status-api
TF_STATE_BUCKET      = $BUCKET_NAME
WIF_PROVIDER         = $WIF_PROVIDER
WIF_SERVICE_ACCOUNT  = $WIF_SA
ALLOWED_SSH_IP       = $MY_IP
ALERT_EMAIL          = $ALERT_EMAIL
SLACK_WEBHOOK_URL    = (optional)

APP_URL              = http://$APP_IP:8080/health
SECRETS

  echo "  ✅ Secrets also saved to: github-secrets.txt"
  echo "     (Delete this file after adding secrets to GitHub!)"
fi

echo ""
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║          NEXT STEPS                                                  ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo ""
echo "  1. Add the secrets above to GitHub"
echo "  2. Push your code:  git add . && git commit -m 'init' && git push"
echo "  3. Watch pipeline:  GitHub repo → Actions tab"
echo "  4. Test live app:   curl http://$APP_IP:8080/health"
echo ""
echo "╚══════════════════════════════════════════════════════════════════════╝"
