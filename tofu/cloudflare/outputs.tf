output "zone_id" {
  description = "Cloudflare Zone ID resolved for the configured domain."
  value       = data.cloudflare_zone.primary.id
  sensitive   = true
}

output "tunnel_config_version" {
  description = "Current version number of the remotely managed Cloudflare Tunnel configuration."
  value       = cloudflare_zero_trust_tunnel_cloudflared_config.tunnel.version
}

output "route_hostnames" {
  description = "Map of route subdomain keys to their managed public FQDNs."
  value = {
    for k, record in cloudflare_dns_record.route : k => record.name
  }
  sensitive = true
}
