# ── Non-secret values ─────────────────────────────────────────────────────────
# Commit this file. Sensitive values (project_id, allowed_ssh_ip, alert_email,
# github_repository) are passed as TF_VAR_* environment variables in CI/CD
# and via bootstrap.sh locally — never hardcoded here.

region      = "us-central1"
zone        = "us-central1-a"
image_name  = "status-api"
app_version = "0.1.0"
