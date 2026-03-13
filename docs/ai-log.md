# AI Usage Log — DevSecOps Assignment (GCP)

**Engineer:** Sourav Chandra  
**Platform:** Google Cloud Platform  
**AI Tools Used:** Claude (Anthropic), GitHub Copilot

---

## Overview

AI was used as a force-multiplier throughout — accelerating boilerplate, validating GCP-specific patterns, and drafting documentation. Every output was reviewed, tested, and in several cases corrected before committing.

**Estimated time split:** ~55% AI-assisted, ~45% manual (architecture decisions, GCP IAM design, debugging, security review, testing)

---

## Task-by-Task AI Usage

### IaC (Terraform — GCP)

**Tool:** Claude  
**What I asked it to do:**
- Generate VPC, subnet, and firewall rules matching the assignment security requirements (SSH restricted to operator IP, egress HTTPS-only)
- Draft the GCP Service Account IAM bindings using resource-level roles instead of project-level
- Structure the `google_monitoring_dashboard` resource JSON for Cloud Monitoring
- Generate the Workload Identity Federation pool + provider resources for keyless GitHub Actions auth

**What I verified manually:**
- Confirmed IAM bindings use `google_secret_manager_secret_iam_member` (resource-scoped) instead of a project-wide `secretmanager.secretAccessor`
- Verified `google_artifact_registry_repository_iam_member` scopes to the specific repo, not registry-wide
- Checked that Shielded VM options (`enable_secure_boot`, `enable_vtpm`) are set correctly
- Confirmed `block-project-ssh-keys = "true"` metadata is set

---

### CI/CD Pipeline (GitHub Actions — GCP)

**Tool:** Claude  
**What I asked it to do:**
- Generate the 5-stage pipeline using `google-github-actions/auth@v2` with WIF — no service account keys
- Create the reusable composite action for Bandit + Semgrep + TruffleHog + Trivy
- Write the rolling-restart SSH command that pulls the new SHA-tagged image

**What I verified manually:**
- Confirmed `permissions: id-token: write` is set at the workflow level (required for WIF)
- Checked that `exit-code: "1"` is set on Trivy so it actually blocks the pipeline
- Verified PRs run stages 1–4 only; `main` push runs all 5 stages
- Checked that all sensitive values (`GCP_PROJECT_ID`, `WIF_PROVIDER`, etc.) are in GitHub Secrets — none appear in workflow YAML

---

### Security (SAST, Secrets, Container)

**Tool:** Claude  
**What I asked it to do:**
- Generate the annotated GCP IAM policy explaining each permission
- Draft the D5 Secret Manager rotation strategy for GCP
- Generate the D4 "why not Owner/Editor role" explanation for GCP context

**What I verified manually:**
- Ran Bandit locally and confirmed 0 HIGH findings in the final submitted code
- Traced each GCP SDK call in `main.py` back to its corresponding IAM permission in `iam.tf`
- Verified `google_secret_manager_secret_iam_member` correctly binds to `secretmanager.secretAccessor` (read-only) not `secretmanager.admin`

---

### Observability (Cloud Monitoring)

**Tool:** Claude  
**What I asked it to do:**
- Generate the five `google_monitoring_alert_policy` Terraform resources using MQL queries
- Draft the Cloud Monitoring uptime check Terraform resource
- Generate the dashboard JSON for `google_monitoring_dashboard`

**What I verified manually:**
- Confirmed MQL syntax for the `HighErrorRate` ratio alarm — this was the main correction (see below)
- Verified the uptime check uses `http_check` with the correct port and path
- Checked that all alert policies have `notification_channels` wired to the email channel

---

## Most Effective Prompt

**Verbatim prompt:**

> "You are a senior GCP DevSecOps engineer writing Terraform. Create the IAM bindings for a Compute Engine VM service account that needs ONLY: (1) read one specific Secret Manager secret by full resource name, (2) write custom metrics to Cloud Monitoring under the custom.googleapis.com/status_api namespace, (3) pull images from one specific Artifact Registry repository. Use resource-level IAM bindings (google_secret_manager_secret_iam_member, google_artifact_registry_repository_iam_member) not project-level roles. Add a one-line comment on each binding explaining why it is needed. Then write a comment block explaining what would break if roles/editor were used instead."

**Why it worked:**
- Specified GCP resource-level binding resources by name — this stopped the model defaulting to `google_project_iam_member` for everything
- Gave exactly three bounded permissions, preventing scope creep
- Asked for the "why not Editor" contrast section, which produced the D4 documentation content in one shot
- Naming the exact Terraform resource types (`google_secret_manager_secret_iam_member`) forced the correct pattern

---

## Where AI Got It Wrong

**The error:** The first draft of the `HighErrorRate` alert policy used `condition_threshold` with `metric.type="custom.googleapis.com/status_api/request_count"` and `threshold_value = 0.05`. This would compare the **raw count** of requests against 0.05 — which would trigger on almost every request (count 1 > 0.05) regardless of error rate.

**How I caught it:** I read the condition carefully: a threshold of `0.05` applied to a `Sum` aggregation of a counter metric makes no sense. A single request (count=1) would always exceed 0.05. The alarm would fire constantly or never, depending on the aligner. The correct approach is a `condition_monitoring_query_language` block with an MQL expression that computes `errors / total` as a ratio.

**What I fixed:** Rewrote to use `condition_monitoring_query_language` with an MQL query that filters for `status_code='500'`, computes the rate, and compares against `0.05` (5%). This is the correct GCP pattern for percentage-based alerting.

---

## One Task Where I Did NOT Use AI

**Task:** Writing the `lifespan` startup handler in `main.py` — specifically the fallback logic when Secret Manager is unreachable.

**Why I didn't use AI:** The fallback needs to: catch `google.api_core.exceptions.GoogleAPIError`, log a `WARNING` (not ERROR, so it doesn't trigger the error rate alarm during local dev), and continue with `os.environ["APP_ENV"]`. The subtlety is that a noisy ERROR log at startup would cause the `HighErrorRate` alarm to fire every time the app starts in a dev environment — which would train on-call engineers to ignore the alarm. Writing this manually meant I could reason through every failure mode and the downstream alarm implications, rather than accepting generated code that looked correct but had wrong log severity.
