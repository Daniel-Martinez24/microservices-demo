# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Fetch dynamic credentials for the kubernetes and helm providers
data "google_client_config" "default" {}

# Configure Kubernetes provider dynamically using the newly created GKE cluster details
provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

# Configure Helm provider dynamically using the newly created GKE cluster details
provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

# ------------------------------------------------------------------------------
# GKE CLUSTER DEFINITION
# ------------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  # Enterprise Standard: Disable default node pool to ensure we only use custom-defined pools
  remove_default_node_pool = true
  initial_node_count       = 1

  # Enterprise Standard: Enable Workload Identity for secure GCP API access
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = {
    environment = "production"
    team        = "sre"
    managed-by  = "terraform"
  }

  # Set to true for production workloads. Set to false here to allow easy teardown for the challenge.
  deletion_protection = false
}

# ------------------------------------------------------------------------------
# CUSTOM NODE POOL
# ------------------------------------------------------------------------------
resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-node-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  # Enable autoscaling (Min 1, Max 3)
  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-standard-4"

    # Principle of least privilege
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      environment = "production"
      role        = "workload"
    }

    # Enterprise Standard: Enable Shielded Nodes
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Associate GKE metadata with Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ------------------------------------------------------------------------------
# MONITORING STACK (KUBE-PROMETHEUS-STACK)
# ------------------------------------------------------------------------------

# Create the dedicated monitoring namespace
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  # Ensure the node pool is fully up before trying to create K8s resources
  depends_on = [google_container_node_pool.primary_nodes]
}

# Deploy Prometheus and Grafana using Helm
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Enterprise Standard: Pin your helm chart versions in production to avoid drift
  # version = "58.2.1"

  # Explicit dependency mapping to avoid race conditions
  depends_on = [
    google_container_node_pool.primary_nodes,
    kubernetes_namespace.monitoring
  ]

  # Expose Grafana via LoadBalancer for easy access during the challenge
  set {
    name  = "grafana.service.type"
    value = "LoadBalancer"
  }
}
