variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = ""
}

variable "cluster_version" {
  description = "Kubernetes version for EKS (>= 1.34 required for KEP 4412 Beta)"
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS managed node groups"
  type        = string
  default     = "t3.small"
}

variable "custom_registry" {
  description = "Vanity registry hostname that containerd will redirect to ECR (e.g. my-registry.lab)"
  type        = string
  default     = ""
}

variable "ecr_replication_region" {
  description = "AWS region to replicate ECR images to (DR/failover copy)"
  type        = string
  default     = ""
}

variable "ecr_pull_region" {
  description = "ECR region nodes pull images from — defaults to the cluster region, switch to ecr_replication_region for failover"
  type        = string
  default     = ""
}
