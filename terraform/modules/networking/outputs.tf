output "network_id" {
  description = "Self-link of the VPC network. Passed to compute module for VM placement."
  value       = google_compute_network.vpc.id
}

output "subnetwork_id" {
  description = "Self-link of the subnet. Passed to compute module for VM NIC config."
  value       = google_compute_subnetwork.subnet.id
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.vpc.name
}
