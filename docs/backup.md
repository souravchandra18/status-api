# Backup & Recovery Strategy — Status API (GCP)

## What Needs to Be Backed Up

### 1. Terraform State (GCS + Versioning)
- **Location:** GCS bucket `status-api-tfstate`, object `status-api/state`
- **Protection:** GCS object versioning enabled — every `terraform apply` creates a new version. Previous versions retained indefinitely.
- **Recovery:** `gsutil ls -a gs://status-api-tfstate/status-api/state` to list versions; `gsutil cp "gs://bucket/object#<generation>" ./terraform.tfstate` to restore.

### 2. Artifact Registry Images (Tagged by Git SHA)
- **Policy:** Every image tagged `sha-<git-sha>` AND `:latest`. No `:latest`-only deployments.
- **Recovery:** Any prior SHA tag can be re-pulled: `docker pull <region>-docker.pkg.dev/<project>/status-api/status-api:sha-<git-sha>`

### 3. Application Config / Secrets
- **APP_ENV:** Stored in GCP Secret Manager (`status-api-app-env`). Secret Manager retains all prior versions — previous versions remain accessible until explicitly destroyed.
- **Terraform variables:** Committed in `terraform.tfvars`. Sensitive values stored in GitHub Secrets.

---

## RTO — Recovery Time Objective

**RTO: 30 minutes**

- `terraform apply` provisions all GCP infrastructure: ~10 minutes
- Docker image pull from Artifact Registry: ~2 minutes
- Container start + health check: ~1 minute
- Total: well within 30 minutes

---

## RPO — Recovery Point Objective

**RPO: 0 minutes**

The Status API is fully stateless. No user data, no database, no persistent application state. A fresh deployment produces an identical service.

---

## Full Recovery Procedure (New GCP Project from Zero)

### Prerequisites
```bash
# gcloud CLI installed and authenticated with Owner role on new project
gcloud config set project <new-project-id>
```

### Step 1 — Bootstrap GCS state bucket (one-time)
```bash
gsutil mb -l us-central1 gs://status-api-tfstate
gsutil versioning set on gs://status-api-tfstate
gsutil ubla set on gs://status-api-tfstate   # Uniform bucket-level access
```

### Step 2 — Enable required GCP APIs
```bash
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com
```

### Step 3 — Configure GitHub Secrets
```
GCP_PROJECT_ID     = <new-project-id>
GCP_REGION         = us-central1
AR_REPO            = status-api
TF_STATE_BUCKET    = status-api-tfstate
WIF_PROVIDER       = projects/<num>/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider
WIF_SERVICE_ACCOUNT = status-api-cicd-sa@<new-project>.iam.gserviceaccount.com
ALLOWED_SSH_IP     = <your-ip>
ALERT_EMAIL        = <your-email>
SLACK_WEBHOOK_URL  = <webhook>
```

### Step 4 — Provision infrastructure
```bash
cd terraform
export TF_VAR_project_id="<new-project-id>"
export TF_VAR_allowed_ssh_ip="<your-ip>"
export TF_VAR_alert_email="<your-email>"
export TF_VAR_github_repository="<org/repo>"

terraform init -backend-config="bucket=status-api-tfstate"
terraform apply -var-file=terraform.tfvars
```

### Step 5 — Push the Docker image
```bash
# Via CI/CD: push to main branch triggers the full pipeline
# Or manually:
cd app
SHORT_SHA=$(git rev-parse --short HEAD)
REGISTRY="us-central1-docker.pkg.dev/<new-project>/status-api"
docker build . \
  --build-arg BUILD_SHA=$SHORT_SHA \
  -t $REGISTRY/status-api:sha-$SHORT_SHA \
  -t $REGISTRY/status-api:latest
gcloud auth configure-docker us-central1-docker.pkg.dev
docker push $REGISTRY/status-api:sha-$SHORT_SHA
docker push $REGISTRY/status-api:latest
```

### Step 6 — Verify recovery
```bash
IP=$(cd terraform && terraform output -raw instance_public_ip)
curl http://$IP:8080/health
# Expected: {"status":"healthy", ...}
```

---

## Terraform State Loss Scenario

**If the GCS state bucket is accidentally deleted:**

The GCP infrastructure still exists — state loss does not destroy resources.

**Option A — Import existing resources**
```bash
# 1. Recreate the bucket (Step 1)
# 2. Re-init with empty state
terraform init -backend-config="bucket=status-api-tfstate"
# 3. Import resources back
terraform import google_compute_instance.app projects/<project>/zones/us-central1-a/instances/status-api-instance
terraform import google_artifact_registry_repository.app projects/<project>/locations/us-central1/repositories/status-api
# ... continue for each resource
terraform plan  # Should show no changes when import is complete
```

**Option B — Destroy and re-create**
1. Delete GCP resources via `gcloud` CLI or console
2. Follow recovery procedure from Step 1
3. Artifact Registry images survive — re-pull immediately after Terraform apply
