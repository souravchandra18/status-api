# Quick Reference — Status API GCP DevSecOps
# All commands you need, in order.

# ══════════════════════════════════════════════════════════
# PHASE 1 — First-time setup (run in GCP Cloud Shell)
# ══════════════════════════════════════════════════════════

# 1. Open Cloud Shell: https://console.cloud.google.com → click >_ icon

# 2. Set your project
gcloud config set project YOUR_PROJECT_ID

# 3. Enable APIs
gcloud services enable compute.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com monitoring.googleapis.com logging.googleapis.com \
  iam.googleapis.com cloudresourcemanager.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com

# 4. Create state bucket
gsutil mb -l us-central1 gs://status-api-tfstate-YOUR_PROJECT_ID
gsutil versioning set on gs://status-api-tfstate-YOUR_PROJECT_ID
gsutil ubla set on gs://status-api-tfstate-YOUR_PROJECT_ID

# 5. Create the dev VM (e2-medium for setup, e2-micro for the app)
gcloud compute instances create status-api-devvm \
  --zone=us-central1-a \
  --machine-type=e2-medium \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB \
  --scopes=cloud-platform \
  --tags=allow-ssh

# 6. Allow SSH
gcloud compute firewall-rules create allow-ssh-all \
  --network=default \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=allow-ssh


# ══════════════════════════════════════════════════════════
# PHASE 2 — Inside the VM (SSH via browser)
# Compute Engine → VM Instances → SSH button
# ══════════════════════════════════════════════════════════

# Install all tools
sudo bash vm-setup.sh

# OR manually:
sudo apt-get update && sudo apt-get install -y docker.io git curl unzip python3-pip

# ── Clone your repo ──────────────────────────────────────
git config --global user.name "Your Name"
git config --global user.email "you@gmail.com"
git clone https://github.com/YOUR_USERNAME/status-api.git
cd status-api

# Upload the zip via SSH window gear icon → Upload file
# Then extract:
unzip ~/devsecops-assignment-gcp.zip
cp -r devsecops-assignment/. .
rm -rf devsecops-assignment

# ── Run bootstrap ────────────────────────────────────────
chmod +x bootstrap.sh vm-setup.sh
# Edit bootstrap.sh first: nano bootstrap.sh  (change the 6 variables at top)
sudo bash vm-setup.sh    # install tools
./bootstrap.sh            # set up GCP + run Terraform

# ══════════════════════════════════════════════════════════
# PHASE 3 — Daily dev commands (run inside VM)
# ══════════════════════════════════════════════════════════

# Run tests
cd ~/status-api/app
APP_ENV=test BUILD_SHA=local GCP_PROJECT_ID=test-project pytest test_main.py -v

# Build Docker image
cd ~/status-api/app
docker build . --build-arg BUILD_SHA=$(git rev-parse --short HEAD) -t status-api:local

# Run app locally on VM
docker run -d --name status-api-local -p 8080:8080 \
  -e APP_ENV=development -e GCP_PROJECT_ID=YOUR_PROJECT_ID \
  status-api:local
curl http://localhost:8080/health

# Stop local test container
docker stop status-api-local && docker rm status-api-local

# Security scans
bandit -r app/ -ll -f json -o bandit-report.json
trivy image --severity CRITICAL,HIGH status-api:local
trufflehog git file://. --only-verified

# Push code → triggers full CI/CD pipeline
git add .
git commit -m "your message"
git push origin main

# ══════════════════════════════════════════════════════════
# PHASE 4 — Verify deployment
# ══════════════════════════════════════════════════════════

# Get app IP
cd ~/status-api/terraform
APP_IP=$(terraform output -raw instance_public_ip)

# Test all endpoints
curl http://$APP_IP:8080/health
curl http://$APP_IP:8080/status
curl http://$APP_IP:8080/info
curl http://$APP_IP:8080/version

# Trigger alarms (for submission screenshots)
# HighErrorRate alarm:
for i in $(seq 1 25); do curl -s http://$APP_IP:8080/simulate/error; done
echo "Wait 5 min → Cloud Monitoring → Alerting → HighErrorRate should fire"

# HighLatency alarm:
curl http://$APP_IP:8080/simulate/latency
echo "Wait 3 min → HighLatency should fire"

# ══════════════════════════════════════════════════════════
# PHASE 5 — Terraform commands
# ══════════════════════════════════════════════════════════

cd ~/status-api/terraform

# Always set these before terraform commands:
export TF_VAR_project_id="YOUR_PROJECT_ID"
export TF_VAR_allowed_ssh_ip="$(curl -s ifconfig.me)"
export TF_VAR_alert_email="you@gmail.com"
export TF_VAR_github_repository="your-username/status-api"

# Check what terraform wants to change
terraform plan -var-file=terraform.tfvars

# Apply changes
terraform apply -var-file=terraform.tfvars

# Get all outputs
terraform output

# Destroy everything (use with caution!)
# terraform destroy -var-file=terraform.tfvars

# ══════════════════════════════════════════════════════════
# PHASE 6 — Useful gcloud commands
# ══════════════════════════════════════════════════════════

# List VMs
gcloud compute instances list --project=YOUR_PROJECT_ID

# SSH into app VM
gcloud compute ssh status-api-instance --zone=us-central1-a

# Check VM logs
gcloud logging read 'resource.type="gce_instance"' \
  --project=YOUR_PROJECT_ID --freshness=10m --limit=20

# List Artifact Registry images
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/YOUR_PROJECT_ID/status-api

# List secrets
gcloud secrets list --project=YOUR_PROJECT_ID

# Read a secret value
gcloud secrets versions access latest --secret=status-api-app-env

# List active alerts
gcloud alpha monitoring policies list --project=YOUR_PROJECT_ID

# ══════════════════════════════════════════════════════════
# SUBMISSION CHECKLIST
# ══════════════════════════════════════════════════════════
# Email subject: DevSecOps Assignment — Sourav Chandra — us-central1
#
# Attach:
# 1. GitHub repo link
# 2. Live URL:   http://APP_IP:8080/health
# 3. Screenshot: GitHub Actions → successful pipeline run
# 4. Screenshot: Cloud Monitoring dashboard + 1 alarm in FIRING state
# 5. Screenshot: Artifact Registry showing :latest + :sha-xxxx tags
