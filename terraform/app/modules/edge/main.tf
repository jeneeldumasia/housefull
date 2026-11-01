variable "region" {
  type = string
}

variable "domain" {
  type = string
}

variable "subdomain" {
  type = string
}

variable "api_service_name" {
  type = string
}

locals {
  hostname = "${var.subdomain}.${var.domain}"
}

resource "google_compute_global_address" "public" {
  name = "housefull-public"
}

resource "google_compute_region_network_endpoint_group" "api" {
  name                  = "housefull-api"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.api_service_name
  }
}

resource "google_compute_backend_service" "api" {
  name                  = "housefull-api"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  # The load balancer sets this itself, and Cloud Run only accepts traffic from
  # the load balancer, so the app can trust it for login limits.
  custom_request_headers = ["X-Client-IP: {client_ip}"]

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }
}

resource "google_compute_url_map" "https" {
  name            = "housefull-https"
  default_service = google_compute_backend_service.api.id
}

resource "google_compute_managed_ssl_certificate" "main" {
  name = "housefull"

  managed {
    domains = [local.hostname]
  }
}

resource "google_compute_target_https_proxy" "main" {
  name             = "housefull"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.main.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "housefull-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.public.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.main.id
}

resource "google_compute_url_map" "http_redirect" {
  name = "housefull-http-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "housefull-http-redirect"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "housefull-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.public.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

data "cloudflare_zone" "main" {
  name = var.domain
}

# DNS only. A second proxy in front would complicate the certificate and hide
# the real client address.
resource "cloudflare_record" "app" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.subdomain
  type    = "A"
  content = google_compute_global_address.public.address
  proxied = false
  ttl     = 300
}

output "ip_address" {
  value = google_compute_global_address.public.address
}
