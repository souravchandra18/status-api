# ── Networking Module ─────────────────────────────────────────────────────────
#
# AWS → GCP mapping:
#   VPC                    → google_compute_network
#   Subnet                 → google_compute_subnetwork
#   Internet Gateway       → not needed (GCP routes public IPs automatically)
#   Route table            → google_compute_router + google_compute_route (implicit)
#   Security Group (SSH)   → google_compute_firewall (ingress, target tag)
#   Security Group (app)   → google_compute_firewall (ingress, port 8080)
#   Security Group (egress)→ google_compute_firewall (egress HTTPS-only + deny-all)
#

# ── VPC ───────────────────────────────────────────────────────────────────────
# AWS equivalent: aws_vpc with enable_dns_support + enable_dns_hostnames
resource "google_compute_network" "vpc" {
  name                    = "status-api-vpc"
  auto_create_subnetworks = false # custom subnets only — equivalent to a non-default VPC
  description             = "VPC for status-api workload"
  project                 = var.project_id
}

# ── Subnet ────────────────────────────────────────────────────────────────────
# AWS equivalent: aws_subnet with a /24 CIDR in the VPC
resource "google_compute_subnetwork" "subnet" {
  name          = "status-api-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id

  # Enable VPC flow logs — equivalent to enabling flow logs on an AWS subnet
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── Cloud Router + NAT ────────────────────────────────────────────────────────
# AWS equivalent: NAT Gateway in a public subnet for private instances
# Required for the VM to pull Docker images from Artifact Registry without
# a public IP on the interface. We give the VM a public IP so NAT is not
# strictly needed, but it's included for parity with the AWS reference architecture.
resource "google_compute_router" "router" {
  name    = "status-api-router"
  region  = var.region
  network = google_compute_network.vpc.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  name                               = "status-api-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Firewall: SSH ingress (restricted) ───────────────────────────────────────
# AWS equivalent: Security Group ingress rule, port 22, source = operator IP/32
resource "google_compute_firewall" "allow_ssh" {
  name        = "status-api-allow-ssh"
  network     = google_compute_network.vpc.id
  project     = var.project_id
  description = "Allow SSH only from operator IP — equivalent to SG ingress port 22 source /32"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Only VMs tagged with this label receive SSH traffic
  target_tags   = ["status-api-vm"]
  source_ranges = ["${var.allowed_ssh_ip}/32"]
}

# ── Firewall: App port ingress ────────────────────────────────────────────────
# AWS equivalent: Security Group ingress rule, port 8080, source = 0.0.0.0/0
resource "google_compute_firewall" "allow_app" {
  name        = "status-api-allow-app"
  network     = google_compute_network.vpc.id
  project     = var.project_id
  description = "Allow inbound traffic to the FastAPI app on port 8080"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  target_tags   = ["status-api-vm"]
  source_ranges = ["0.0.0.0/0"]
}

# ── Firewall: Health check ingress ────────────────────────────────────────────
# Allow GCP uptime check probes to reach the app
# AWS equivalent: ALB health check source CIDR in the target SG
resource "google_compute_firewall" "allow_health_check" {
  name        = "status-api-allow-health-check"
  network     = google_compute_network.vpc.id
  project     = var.project_id
  description = "Allow GCP uptime check probes — equivalent to ALB health check SG rule"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  target_tags = ["status-api-vm"]
  # GCP uptime check probe IP ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

# ── Firewall: Egress HTTPS only ───────────────────────────────────────────────
# AWS equivalent: Security Group egress rule, port 443, dest = 0.0.0.0/0
resource "google_compute_firewall" "allow_egress_https" {
  name        = "status-api-allow-egress-https"
  network     = google_compute_network.vpc.id
  project     = var.project_id
  description = "Allow HTTPS egress — for Docker pulls, GCP API calls, Secret Manager"
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  target_tags        = ["status-api-vm"]
  destination_ranges = ["0.0.0.0/0"]
}

# ── Firewall: Deny all other egress ──────────────────────────────────────────
# AWS equivalent: default Security Group deny-all egress (SGs are deny-by-default
# for egress only when outbound rules are explicitly empty — this makes it explicit)
resource "google_compute_firewall" "deny_egress_all" {
  name        = "status-api-deny-egress-all"
  network     = google_compute_network.vpc.id
  project     = var.project_id
  description = "Deny all other egress — least-privilege network posture"
  direction   = "EGRESS"
  priority    = 65534 # lower priority than allow-https (1000), evaluated last

  deny {
    protocol = "all"
  }

  target_tags        = ["status-api-vm"]
  destination_ranges = ["0.0.0.0/0"]
}
