variable "project_id" {
  description = "The GCP Project ID where resources will be provisioned."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "me-west1"
}

variable "zone" {
  description = "The GCP zone to deploy compute instances in."
  type        = string
  default     = "me-west1-a"
}

variable "vpc_name" {
  description = "Name of the dedicated Custom VPC."
  type        = string
  default     = "rke2-vpc"
}

variable "subnet_cidr" {
  description = "IPv4 CIDR block for the RKE2 cluster subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "node_count" {
  description = "Number of RKE2 control-plane server nodes in the HA cluster."
  type        = number
  default     = 3
}

variable "machine_type" {
  description = "GCP compute machine type for RKE2 nodes."
  type        = string
  default     = "e2-standard-2"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB for each node (root / partition)."
  type        = number
  default     = 10
}

variable "var_disk_size" {
  description = "Dedicated /var persistent disk size in GB for each node."
  type        = number
  default     = 50
}

variable "boot_disk_image" {
  description = "OS boot image for the nodes."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "rke2_version" {
  description = "RKE2 version string to install."
  type        = string
  # renovate: datasource=github-releases depName=rancher/rke2
  default = "v1.37.2+rke2r1"
}
