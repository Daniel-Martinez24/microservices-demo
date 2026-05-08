output "cluster_name" {
  description = "The name of the provisioned GKE cluster"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "The IP address of the cluster control plane"
  value       = google_container_cluster.primary.endpoint
}

output "cluster_location" {
  description = "The zone or region the cluster is deployed in"
  value       = google_container_cluster.primary.location
}
