#######################################
# Machine Pools for ROSA HCP
#######################################
#
# Defines worker node machine pools for the ROSA cluster.
# Supports autoscaling for dynamic workload handling.
#
#######################################

# Extra Worker Machine Pool (optional)
# The cluster's default "workers" pool carries the baseline (sized in
# main.tf); enable this for additional autoscaled capacity. Note OCM
# only allows pool creation once the cluster is ready.
resource "rhcs_hcp_machine_pool" "worker" {
  count = var.rosa_type == "hcp" && var.enable_extra_worker_pool ? 1 : 0

  cluster   = rhcs_cluster_rosa_hcp.cluster[0].id
  name      = "platform"
  subnet_id = local.private_subnet_ids[0]

  # Instance configuration
  aws_node_pool = {
    instance_type = var.worker_instance_type
  }

  # Node auto-repair (required by rhcs >= 1.7)
  auto_repair = true

  # Autoscaling configuration
  autoscaling = var.enable_autoscaling ? {
    enabled      = true
    min_replicas = var.worker_min_replicas
    max_replicas = var.worker_max_replicas
  } : null

  # Fixed replicas if autoscaling is disabled
  replicas = var.enable_autoscaling ? null : var.worker_replicas

  # Labels for node identification
  # (node-role.kubernetes.io/* is reserved — OCM rejects it)
  labels = {
    "unique.ag/environment" = var.environment
    "unique.ag/pool"        = "platform"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Multi-AZ Worker Machine Pools (if multi_az is enabled)
resource "rhcs_hcp_machine_pool" "worker_az" {
  count = var.rosa_type == "hcp" && var.multi_az ? length(local.private_subnet_ids) - 1 : 0

  cluster   = rhcs_cluster_rosa_hcp.cluster[0].id
  name      = "worker-${local.azs[count.index + 1]}"
  subnet_id = local.private_subnet_ids[count.index + 1]

  # Instance configuration
  aws_node_pool = {
    instance_type = var.worker_instance_type
  }

  # Node auto-repair (required by rhcs >= 1.7)
  auto_repair = true

  # Autoscaling configuration
  autoscaling = var.enable_autoscaling ? {
    enabled      = true
    min_replicas = var.worker_min_replicas
    max_replicas = var.worker_max_replicas
  } : null

  # Fixed replicas if autoscaling is disabled
  replicas = var.enable_autoscaling ? null : var.worker_replicas

  # Labels for node identification
  labels = {
    "unique.ag/environment" = var.environment
    "unique.ag/pool"        = "worker-${local.azs[count.index + 1]}"
  }

  depends_on = [time_sleep.wait_for_cluster]
}
