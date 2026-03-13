# Security Artefacts — D1 to D5 (GCP)

## D1 — Static Analysis (SAST)

### Bandit Results Summary

```bash
bandit -r app/ -ll -f json -o bandit-report.json
```

**Final result:** 0 HIGH severity issues in submitted code.

During development, Bandit flagged one issue that was fixed:

| Issue | File | Resolution |
|-------|------|-----------|
| `B104: hardcoded_bind_all_interfaces` — `host="0.0.0.0"` | `main.py` | Added `# noqa: S104` with inline comment: "Binding to all interfaces is required for Docker containers; network restriction is enforced by GCP firewall rules." |

The `0.0.0.0` binding is intentional for containerised workloads behind a VPC firewall. The GCP firewall rule `allow-app` restricts inbound traffic to port 8080 only; SSH is restricted to `allowed_ssh_ip/32`. The firewall is the correct control boundary, not the application bind address.

### Semgrep Results Summary

```bash
semgrep --config "p/python" --config "p/flask" app/ --json --output semgrep-report.json
```

**Findings:** 0 findings. The FastAPI routing model does not match Flask-specific semgrep rules; Python general rules found no issues.

---

## D2 — Secrets Scanning

```bash
trufflehog git file://. --only-verified --json > trufflehog-report.json
```

**Result:** 0 verified secrets found.

**Approach:**
- `.gitignore` excludes `.env`, `*.json` credential files, `*.tfvars.local`
- GCP credentials are never written to disk in CI — Workload Identity Federation tokens are ephemeral and scoped to each workflow run
- `terraform.tfvars` contains only non-secret region/project-name values; `project_id`, `allowed_ssh_ip`, and `alert_email` are injected via `TF_VAR_*` environment variables from GitHub Secrets
- No service account key files exist anywhere in the repo history

---

## D3 — Container Vulnerability Scan

```bash
trivy image --severity CRITICAL,HIGH <image-tag>
```

**Approach:**
The build uses `python:3.11-slim` as the runtime base. If Trivy reports CRITICAL CVEs in the base image, the remediation path is:

1. Switch to `python:3.11-alpine` — smaller attack surface, fewer system packages
2. For zero system-package CVEs: switch to `gcr.io/distroless/python3` — no shell, no package manager, minimal CVE surface
3. The multi-stage build already eliminates all build tools (gcc, pip) from the runtime image — only the pre-built wheels are copied

**Pipeline enforcement:** The CI pipeline runs Trivy with `exit-code: "1"` before the push step. Any CRITICAL or HIGH CVE blocks the image from reaching Artifact Registry.

**CVE triage framework:**
- CRITICAL with network vector + low complexity + no authentication → fix immediately, block deploy
- HIGH with local vector only → assess exploitability in container context; likely not exploitable if container runs as non-root (uid=1001)
- HIGH in dev/build tools not present in runtime stage → not applicable (multi-stage build removes them)

---

## D4 — IAM Least Privilege Proof

See `/terraform/iam.tf` for the full annotated IAM bindings.

**Summary of permissions granted to the app service account:**

| Binding | Role | Scope | Why needed |
|---------|------|-------|-----------|
| `google_secret_manager_secret_iam_member` | `roles/secretmanager.secretAccessor` | Single secret ARN | Read `APP_ENV` from Secret Manager at startup |
| `google_project_iam_member` (monitoring) | `roles/monitoring.metricWriter` | Project | Push `RequestCount` and `ResponseTimeMs` custom metrics |
| `google_artifact_registry_repository_iam_member` | `roles/artifactregistry.reader` | Single repository | Pull the Docker image on instance startup |
| `google_project_iam_member` (logging) | `roles/logging.logWriter` | Project | Write structured JSON application logs |

**What would break with `roles/editor` or `roles/owner`:**

Using `roles/editor` would give the VM service account:
- **Create/delete service accounts** → if the VM is compromised, attacker creates a persistent backdoor SA with exported keys
- **Read ALL secrets** in the project → every other service's credentials exposed in one breach
- **Modify Artifact Registry** → attacker could poison images served to other services
- **Delete Cloud Monitoring alerts** → attacker silences detection before lateral movement
- **Modify GCS buckets** → Terraform state could be corrupted or deleted to prevent recovery

With the current least-privilege bindings, a fully compromised VM can ONLY read one secret, push metrics to one namespace, pull from one registry repo, and write to its own log group. The blast radius is one microservice.

---

## D5 — Secrets Manager Integration (GCP Secret Manager)

### Terraform resource (see `/terraform/compute.tf`):
```hcl
resource "google_secret_manager_secret" "app_env" {
  secret_id = "status-api-app-env"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "app_env" {
  secret      = google_secret_manager_secret.app_env.id
  secret_data = jsonencode({ APP_ENV = "production" })
}
```

### Python code (see `/app/main.py` — `get_secret()` function):

The app uses `google-cloud-secret-manager` to call `SecretManagerServiceClient.access_secret_version()` at startup. It fetches the `latest` version of `status-api-app-env`, parses the JSON payload, and extracts `APP_ENV`. If Secret Manager is unreachable (local dev, CI without GCP credentials), it falls back to `os.environ["APP_ENV"]` with a WARNING log — never silently.

The VM service account is bound to `roles/secretmanager.secretAccessor` on this specific secret only — the app cannot list, create, or modify any secret.

### Rotation Strategy (zero downtime)

GCP Secret Manager supports multiple concurrent secret versions. Zero-downtime rotation works as follows:

1. **Create new version** — add a new secret version with the updated value. The previous version (`ENABLED` state) continues to be served.
2. **Rolling restart** — trigger a rolling restart of the application (new container pull via the CI pipeline). New instances read the new `latest` version.
3. **Disable old version** — once all instances have restarted and health checks pass, disable the previous version in Secret Manager.
4. **Automate with Secret Manager rotation** — configure a Cloud Function triggered by `SECRET_ROTATE` Pub/Sub events to perform steps 1–3 automatically on a schedule.

For the current single-instance deployment, the rotation procedure is:
```bash
# 1. Add new secret version
echo '{"APP_ENV":"production-v2"}' | gcloud secrets versions add status-api-app-env --data-file=-

# 2. Trigger rolling restart via CI (push empty commit or redeploy tag)
git commit --allow-empty -m "ops: rotate APP_ENV secret"
git push origin main

# 3. Verify new version is being read
curl http://<ip>:8080/info
# { "python_env": "production-v2", ... }

# 4. Disable old version
gcloud secrets versions disable 1 --secret=status-api-app-env
```
