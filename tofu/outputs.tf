output "vpc_name" {
  description = "The name of the dedicated Custom VPC."
  value       = google_compute_network.rke2_vpc.name
}

output "subnet_cidr" {
  description = "The CIDR block allocated for the RKE2 cluster subnetwork."
  value       = google_compute_subnetwork.rke2_subnet.ip_cidr_range
}

output "node_ips" {
  description = "Internal IP addresses allocated to each RKE2 node."
  value = {
    for instance in google_compute_instance.rke2_node :
    instance.name => instance.network_interface[0].network_ip
  }
}

output "initial_server_ip" {
  description = "Internal IP of the initial RKE2 control-plane server (rke2-node-1)."
  value       = google_compute_instance.rke2_node[0].network_interface[0].network_ip
}

output "iap_tunnel_command" {
  description = "CLI command to start the IAP port-forwarding tunnel for local kubectl access."
  value       = "gcloud compute start-iap-tunnel ${google_compute_instance.rke2_node[0].name} 6443 --local-host-port=localhost:6443 --zone=${var.zone}"
}

output "kubeconfig_fetch_command" {
  description = "CLI command to retrieve the cluster kubeconfig file securely via IAP SSH."
  value       = "gcloud compute ssh ${google_compute_instance.rke2_node[0].name} --tunnel-through-iap --zone=${var.zone} --command=\"sudo cat /etc/rancher/rke2/rke2.yaml\" > ./rke2-kubeconfig.yaml"
}

output "rke2_token" {
  description = "Shared cluster token used to join server nodes."
  value       = random_password.rke2_token.result
  sensitive   = true
}
