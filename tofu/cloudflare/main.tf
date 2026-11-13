locals {
  raw_routes = yamldecode(file("${path.module}/${var.routes_file}")).routes

  routes = [
    for r in local.raw_routes : {
      subdomain              = r.subdomain
      fqdn                   = "${r.subdomain}.${var.domain}"
      path                   = try(r.path, null)
      service                = r.service
      origin_tls_verify_host = try(r.origin_tls_verify_host, false)
      origin_server_name     = try(r.origin_server_name, null)
      no_tls_verify          = try(r.no_tls_verify, null)
      http2_origin           = try(r.http2_origin, null)
    }
  ]

  # Deduplicate by subdomain so multiple path-based rules on the same hostname
  # produce a single Cloudflare DNS CNAME record. Kept free of sensitive values
  # so OpenTofu can evaluate for_each keys and metadata cleanly during plan.
  dns_routes = {
    for r in local.raw_routes : r.subdomain => {
      proxied = try(r.proxied, true)
      comment = try(r.comment, "Managed by OpenTofu (Cloudflare Tunnel route)")
    }...
  }

  ingress_rules = concat(
    [
      for r in local.routes : {
        hostname = r.fqdn
        path     = r.path
        service  = r.service
        origin_request = (
          r.origin_tls_verify_host || r.origin_server_name != null || r.no_tls_verify != null || r.http2_origin != null
          ) ? {
          origin_server_name = r.origin_server_name != null ? r.origin_server_name : (r.origin_tls_verify_host ? r.fqdn : null)
          no_tls_verify      = r.no_tls_verify
          http2_origin       = r.http2_origin
        } : null
      }
    ],
    [
      {
        hostname       = null
        path           = null
        service        = "http_status:404"
        origin_request = null
      }
    ]
  )
}

data "cloudflare_zone" "primary" {
  filter = {
    name = var.domain
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "tunnel" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id
  source     = "cloudflare"

  config = {
    ingress = local.ingress_rules
  }
}

resource "cloudflare_dns_record" "route" {
  for_each = local.dns_routes

  zone_id = data.cloudflare_zone.primary.id
  name    = "${each.key}.${var.domain}"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = each.value[0].proxied
  ttl     = 1
  comment = each.value[0].comment
}
