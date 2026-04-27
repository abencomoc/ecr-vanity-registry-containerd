data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# ECR Repository
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "shared_nginx" {
  name                 = "shared/nginx"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# -----------------------------------------------------------------------------
# ECR Replication — replicate shared/* to a secondary region
# -----------------------------------------------------------------------------

resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination {
        region      = var.ecr_replication_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = "shared"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

