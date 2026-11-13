variable "account_id" {
  description = "Cloudflare Account ID owning the Zero Trust tunnel."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.account_id)) > 0
    error_message = "account_id must not be empty."
  }
}

variable "tunnel_id" {
  description = "UUID of the existing Cloudflare Zero Trust tunnel."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.tunnel_id)) > 0
    error_message = "tunnel_id must not be empty."
  }
}

variable "domain" {
  description = "Root Cloudflare zone domain name (kept out of Git, e.g. example.com)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.domain)) > 0
    error_message = "domain must not be empty."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (optional; defaults to the CLOUDFLARE_API_TOKEN environment variable)."
  type        = string
  default     = null
  sensitive   = true
}

variable "routes_file" {
  description = "Path (relative to this module) to the YAML file declaring Cloudflare Tunnel routes."
  type        = string
  default     = "routes.yaml"
}
