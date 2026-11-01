output "url" {
  description = "Public address."
  value       = "https://${var.subdomain}.${var.domain}"
}

output "load_balancer_ip" {
  description = "Public IP the DNS record points to."
  value       = module.edge.ip_address
}

output "image_repository" {
  description = "Where CI pushes images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "vpn_ip" {
  description = "Public IP of the WireGuard endpoint."
  value       = module.vpn.ip_address
}
