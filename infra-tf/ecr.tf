data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# ECR Repository
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "global_nginx" {
  name                 = "global/nginx"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# -----------------------------------------------------------------------------
# ECR Replication — replicate global/* to a secondary region
# -----------------------------------------------------------------------------

resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination {
        region      = var.ecr_replication_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = "global"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

