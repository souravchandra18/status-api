# Incident Response Runbook — Status API (GCP)

> Follow this runbook at 2 AM with no prior context. Every command is copy-pasteable.

Set these shell variables first for all commands below:
```bash
export PROJECT_ID="<your-gcp-project-id>"
export ZONE="us-central1-a"
export INSTANCE_NAME="status-api-instance"
export APP_PORT="8080"
```

---

## Incident 1 — API Returning 5xx Errors

**Detection:** `HighErrorRate` Cloud Monitoring alert fires → email notification  
**Indicator:** `custom.googleapis.com/status_api/request_count{status_code=500}` > 5% of total

### Triage Steps

**Step 1 — Check if simulation endpoint was triggered**
```bash
gcloud logging read \
  'resource.type="gce_instance" AND jsonPayload.message="simulated_error_triggered"' \
  --project=$PROJECT_ID \
  --freshness=15m \
  --format="value(jsonPayload)"
```
If output is non-empty — this is a test, not a real incident. Confirm with team.

**Step 2 — Test live health endpoint**
```bash
IP=$(gcloud compute instances describe $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
curl -s http://$IP:$APP_PORT/health | python3 -m json.tool
```

**Step 3 — Read last 50 error logs**
```bash
gcloud logging read \
  'resource.type="gce_instance" AND severity=ERROR' \
  --project=$PROJECT_ID \
  --freshness=15m \
  --limit=50 \
  --format="value(timestamp, jsonPayload)"
```

**Step 4 — Check container status on instance**
```bash
gcloud compute ssh $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --command="docker ps -a && docker logs status-api --tail 50"
```

**Step 5 — Restart container**
```bash
gcloud compute ssh $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --command="docker restart status-api && sleep 10 && curl -s http://localhost:$APP_PORT/health"
```

### Escalation Criteria
- Container restarts but 500s continue after 2 restarts → code bug, need hotfix deploy
- Errors started immediately after a deploy → rollback to previous SHA

### Rollback Command
```bash
PREV_SHA="<previous-git-sha>"
REGISTRY="us-central1-docker.pkg.dev/$PROJECT_ID/status-api"
gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --command="
  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
  docker pull $REGISTRY/status-api:sha-$PREV_SHA
  docker stop status-api && docker rm status-api
  docker run -d --name status-api --restart unless-stopped \
    -p $APP_PORT:8080 \
    -e GCP_PROJECT_ID=$PROJECT_ID \
    -e SECRET_NAME=status-api-app-env \
    $REGISTRY/status-api:sha-$PREV_SHA
"
```

### Post-Incident Actions
1. Write post-mortem in `/docs/postmortems/YYYY-MM-DD-5xx.md`
2. Check error budget consumption in Cloud Monitoring
3. Add regression test for root cause

---

## Incident 2 — VM Instance Unreachable (No SSH, No HTTP)

**Detection:** `NoBytesIn` + `AppUnhealthy` both fire  
**Symptoms:** `curl http://$IP:8080/health` times out; SSH refused

### Triage Steps

**Step 1 — Check VM status**
```bash
gcloud compute instances describe $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --format="table(status, statusMessage)"
```

**Step 2 — Check serial console for kernel panic / OOM**
```bash
gcloud compute instances get-serial-port-output $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID | tail -100
```

**Step 3 — Reboot the instance (via gcloud, not console)**
```bash
gcloud compute instances reset $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID
echo "Waiting 90 seconds..."
sleep 90
```

**Step 4 — Verify recovery**
```bash
IP=$(gcloud compute instances describe $INSTANCE_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$IP:$APP_PORT/health || echo "000")
  echo "Attempt $i: $STATUS"
  [ "$STATUS" = "200" ] && echo "RECOVERED" && break
  sleep 15
done
```

### Remediation — Stop/Start (clears hardware faults)
```bash
gcloud compute instances stop $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID
gcloud compute instances start $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID
```

### Escalation Criteria
- Unreachable 10+ minutes after reset → provision new instance via `terraform apply`
- Serial console shows persistent hardware error → file GCP support ticket

### Post-Incident Actions
1. Check Cloud Monitoring VM metrics (CPU, memory, disk) in the 30 min before incident
2. Verify startup script re-ran and container is healthy after reboot

---

## Incident 3 — High Latency (P99 > 2 s)

**Detection:** `HighLatency` alert fires  
**Indicator:** `response_time_ms` P99 > 2000ms over 3 minutes

### Triage Steps

**Step 1 — Confirm it's not a simulation**
```bash
gcloud logging read \
  'jsonPayload.message="simulated_latency_triggered"' \
  --project=$PROJECT_ID --freshness=10m \
  --format="value(jsonPayload)"
```

**Step 2 — Check which endpoints are slow**
Open Cloud Monitoring → Dashboards → Status API Dashboard → Response Time P50/P90/P99 widget.

**Step 3 — Check VM CPU**
```bash
gcloud monitoring time-series list \
  --filter='metric.type="compute.googleapis.com/instance/cpu/utilization"' \
  --project=$PROJECT_ID \
  --format=json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d:
  pts = s.get('points',[])[:3]
  for p in pts:
    print(p['interval']['endTime'], p['value']['doubleValue'])
"
```

**Step 4 — Check memory and container stats**
```bash
gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID \
  --command="free -m && docker stats status-api --no-stream"
```

**Step 5 — Check Secret Manager / GCP API latency**
```bash
# If all endpoints are slow equally, the issue may be GCP API calls in the middleware
# Check Cloud Monitoring for Secret Manager API latency
gcloud logging read \
  'resource.type="audited_resource" AND protoPayload.serviceName="secretmanager.googleapis.com"' \
  --project=$PROJECT_ID --freshness=10m
```

### Remediation
```bash
# Restart container to clear any thread/connection leak
gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID \
  --command="docker restart status-api"
```

### Escalation Criteria
- All endpoints slow + CPU < 50% + no Secret Manager errors → investigate GCP region incident at `https://status.cloud.google.com`
- CPU consistently > 80% → upgrade machine type via Terraform (`e2-small` is next tier, ~$13/month)

---

## Incident 4 — Pipeline Broken (Deploy Failing)

**Detection:** GitHub Actions Slack notification: `❌ status-api GCP deploy FAILED`

### Triage Steps

**Step 1 — Identify the failing stage**
```
GitHub → Actions → most recent failed run → check which job failed:
  test / security-scan / terraform-plan / build-and-scan / deploy
```

**Step 2a — `test` failed**
```bash
cd app
pip install -r requirements.txt -r requirements-dev.txt
APP_ENV=test BUILD_SHA=local GCP_PROJECT_ID=test pytest test_main.py -v
```

**Step 2b — `security-scan` failed**
```bash
# Bandit
bandit -r app/ -ll -f json | python3 -m json.tool

# TruffleHog
trufflehog git file://. --only-verified

# Fix the issue — DO NOT add bypass flags to the pipeline
```

**Step 2c — `terraform-plan` failed**
```bash
cd terraform
export TF_VAR_project_id="<project>"
export TF_VAR_allowed_ssh_ip="<ip>"
export TF_VAR_alert_email="<email>"
export TF_VAR_github_repository="<org/repo>"
terraform fmt -recursive
terraform validate
terraform plan -var-file=terraform.tfvars
```
Common causes: missing GitHub Secret, WIF binding expired, GCP quota exceeded.

**Step 2d — `build-and-scan` failed (Trivy)**
```bash
# Build locally and scan
docker build app/ -t status-api:test
trivy image --severity CRITICAL,HIGH status-api:test
# Fix CVEs by updating the base image or dependency version
```

**Step 2e — `deploy` failed (health check)**
```bash
# Check if the VM received the SSH command
gcloud compute operations list \
  --filter="operationType=compute.instances.setMetadata" \
  --project=$PROJECT_ID
# Check instance startup logs
gcloud logging read 'resource.type="gce_instance"' \
  --project=$PROJECT_ID --freshness=10m --limit=30
```

### Remediation
```bash
# Re-trigger pipeline after fix
git commit --allow-empty -m "ci: re-trigger pipeline"
git push origin main
```

### Escalation Criteria
- Security gate (Bandit/Trivy) blocks a time-sensitive hotfix → escalate to team lead to jointly assess finding exploitability; NEVER add `--exit-code 0` bypass
- WIF authentication fails → check GCP IAM → Workload Identity Pool is still configured correctly
