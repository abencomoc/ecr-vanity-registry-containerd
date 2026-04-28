# ──────────────────────────────────────────────────────────────
# terraform.tfvars — override default variable values here
# ──────────────────────────────────────────────────────────────

aws_region         = "us-east-1"
cluster_name       = "ecr-vanity-registry"
cluster_version    = "1.35"
node_instance_type = "t3.small"

# Vanity registry hostname that containerd redirects to ECR
custom_registry = "my-registry.lab"

# ECR cross-region replication target (DR / failover)
ecr_replication_region = "us-west-1"

# Leave empty to pull from the cluster region, or set to
# ecr_replication_region value for failover pulls
ecr_pull_region = ""
