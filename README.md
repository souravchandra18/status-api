# Status API — DevSecOps Assignment (GCP)

> **Sourav Chandra** | Senior CI/CD & Cloud Operations Engineer Assessment  
> Platform: **Google Cloud Platform** | Region: `us-central1`

---

## Repository Structure

```
.
├── app/
│   ├── main.py              # FastAPI app — reads APP_ENV from GCP Secret Manager
│   ├── test_main.py         # pytest unit tests (15 tests, all GCP calls mocked)
│   ├── Dockerfile           # Multi-stage build (builder + non-root runtime uid=1001)
│   ├── requirements.txt     # Runtime: fastapi, uvicorn, google-cloud-secret-manager, google-cloud-monitoring
│   └── requirements-dev.txt # Test: pytest, httpx, pytest-cov
│
terraform/
├── main.tf          ← root module — provider config + calls all 3 modules
├── variables.tf     ← all input variables with descriptions + type constraints + validations
├── outputs.tf       ← public IP, Artifact Registry URL, secret name, WIF details
├── backend.tf       ← GCS remote state config (GCP equivalent of S3 backend)
├── terraform.tfvars ← non-secret defaults only
│
└── modules/
    ├── networking/  ← VPC, subnet, NAT, firewall rules (≡ VPC+IGW+routes+SGs)
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── compute/     ← VM, Artifact Registry, Secret Manager, IAM, WIF (≡ EC2+ECR+IAM)
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    └── observability/ ← Monitoring alarms, uptime check, dashboard, log metric (≡ CloudWatch)
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
│
├── .github/
│   ├── workflows/
│   │   └── ci-cd.yml        # 5-stage pipeline — WIF auth, no service account keys
│   └── actions/
│       └── security-scan/
│           └── action.yml   # Reusable: Bandit + Semgrep + TruffleHog + Trivy
│
└── docs/
    ├── slo.md               # SLI/SLO + error budget (E4)
    ├── backup.md            # Backup & Recovery — RTO 30min / RPO 0 (F1)
    ├── runbook.md           # Incident runbook — 4 scenarios with gcloud commands (F2)
    ├── ai-log.md            # AI usage log with honest error correction (Section 8)
    └── security-artefacts.md # D1–D5 findings, analysis, rotation strategy
```

---

## GCP Free Tier — What's Used

| Resource | Free Tier |
|----------|-----------|
| Compute Engine `e2-micro` | 1 instance free in `us-central1` / `us-east1` / `us-west1` |
| Cloud Monitoring | First 150 MB ingestion free / month |
| Cloud Logging | First 50 GB ingestion free / month |
| Secret Manager | First 6 secret versions free / month |
| Artifact Registry | First 0.5 GB storage free / month |
| GCS (state bucket) | First 5 GB storage free / month |
| Cloud Build (not used) | N/A — CI runs on GitHub-hosted runners |

> **Note:** Workload Identity Federation, VPC, IAM, and API enablement are free.

---

## Quick Start — Local Development

```bash
# 1. Clone
git clone https://github.com/<your-org>/status-api.git && cd status-api

# 2. Install dependencies
pip install -r app/requirements.txt -r app/requirements-dev.txt

# 3. Run tests (no GCP credentials needed — all mocked)
cd app
APP_ENV=test BUILD_SHA=local GCP_PROJECT_ID=test-project \
  pytest test_main.py -v

# 4. Run locally (falls back to APP_ENV env var)
APP_ENV=development uvicorn main:app --host 0.0.0.0 --port 8080 --reload
```

---

## Deploy to GCP

### Step 1 — Bootstrap GCS state bucket (one-time)
```bash
export PROJECT_ID="your-gcp-project-id"
gsutil mb -l us-central1 gs://status-api-tfstate
gsutil versioning set on gs://status-api-tfstate
gsutil ubla set on gs://status-api-tfstate
```

### Step 2 — Enable GCP APIs
```bash
gcloud services enable \
  compute.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com monitoring.googleapis.com \
  logging.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=$PROJECT_ID
```

### Step 3 — First Terraform apply (bootstraps WIF)
```bash
cd terraform
export TF_VAR_project_id=$PROJECT_ID
export TF_VAR_allowed_ssh_ip="$(curl -s ifconfig.me)"
export TF_VAR_alert_email="you@example.com"
export TF_VAR_github_repository="your-org/status-api"

terraform init -backend-config="bucket=status-api-tfstate"
terraform apply -var-file=terraform.tfvars
```

### Step 4 — Configure GitHub Secrets
After step 3, run:
```bash
terraform output workload_identity_provider   # → WIF_PROVIDER value
terraform output cicd_service_account_email   # → WIF_SERVICE_ACCOUNT value
terraform output instance_public_ip           # → for verification
```

Set these GitHub Secrets:
```
GCP_PROJECT_ID       = <project-id>
GCP_REGION           = us-central1
AR_REPO              = status-api
TF_STATE_BUCKET      = status-api-tfstate
WIF_PROVIDER         = projects/<num>/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider
WIF_SERVICE_ACCOUNT  = status-api-cicd-sa@<project>.iam.gserviceaccount.com
ALLOWED_SSH_IP       = <your-ip>
ALERT_EMAIL          = <your-email>
SLACK_WEBHOOK_URL    = https://hooks.slack.com/...
```

### Step 5 — Push to main → full pipeline runs
```bash
git push origin main
```

---

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check — `200 OK` + uptime |
| GET | `/status` | Service status + environment |
| GET | `/info` | Build SHA + version |
| GET | `/version` | Version (minimal) |
| GET | `/simulate/error` | Returns `500` — triggers `HighErrorRate` alarm |
| GET | `/simulate/latency` | Sleeps 2.5s — triggers `HighLatency` alarm |

---

## Cloud Monitoring Alarms

| Alarm | Condition | Trigger endpoint |
|-------|-----------|-----------------|
| `HighErrorRate` | Error rate > 5% over 5 min | `GET /simulate/error` |
| `HighLatency` | P99 > 2000ms over 3 min | `GET /simulate/latency` |
| `InstanceCPUHigh` | VM CPU > 80% for 5 min | Stress test |
| `AppUnhealthy` | Uptime check fails 2× | Stop the container |
| `NoBytesIn` | No network bytes in for 10 min | Stop the VM |

**Test an alarm:**
```bash
IP=$(cd terraform && terraform output -raw instance_public_ip)
# Trigger HighErrorRate:
for i in $(seq 1 20); do curl -s http://$IP:8080/simulate/error; done
# Watch alarm fire in Cloud Monitoring → Alerting
```

---

## Submission Checklist

- [x] `/terraform` — complete GCP IaC, `fmt`/`validate` pass, no hardcoded values
- [x] `/app` — FastAPI + multi-stage Dockerfile + 15 unit tests (all pass)
- [x] `/docs/slo.md` — SLI/SLO + error budget calculation
- [x] `/docs/backup.md` — RTO 30 min / RPO 0 + full recovery procedure
- [x] `/docs/runbook.md` — 4 incident scenarios with copy-pasteable `gcloud` commands
- [x] `/docs/ai-log.md` — honest AI log including one error found and fixed
- [x] `/docs/security-artefacts.md` — D1–D5 analysis
- [x] `.github/workflows/ci-cd.yml` — 5-stage pipeline, WIF auth, Slack notifications
- [x] `.github/actions/security-scan/action.yml` — reusable composite action (DRY)
- [x] No hardcoded credentials, project IDs, or secrets anywhere in the repo
