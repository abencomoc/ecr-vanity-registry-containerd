locals {
  # Defaults to the cluster region; operator can override to pull from the replica
  ecr_pull_region = coalesce(var.ecr_pull_region, var.aws_region)
}

# -----------------------------------------------------------------------------
# EKS Cluster — Managed Node Group with per-pod ECR credential provider
# Uses terraform-aws-modules/eks/aws v21.x
# The ecr-credential-provider uses IRSA (AssumeRoleWithWebIdentity) for
# per-pod image pull credentials — not EKS Pod Identity.
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  # Addons — no pod-identity-agent needed, using IRSA for image pulls
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = { before_compute = true }
  }

  # Cluster access
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # Networking
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Managed Node Groups
  eks_managed_node_groups = {

    # -----------------------------------------------------------------
    # Default node group — containerd redirects vanity registry to ECR
    # UserScript defines AWS region for both ECR endpoint: docker ecr.dkr and auth ecr.api
    # Docker endpoint
    #   devs use vanity image URI: my-registry.lab/default/nginx-default:latest
    #   containerd reads certs.d/my-registry.lab/hosts.toml and forwards to ecr registry
    # Auth endpoint:
    #   ecr-credential-provider matchImages images for my-registry.lab
    #   ecr-credential-provider defines AWS region for ECR authentication
    # -----------------------------------------------------------------
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = 0
      max_size       = 1
      desired_size   = 1

      update_config = {
        max_unavailable_percentage = 100
      }
      force_update_version = true

      labels = {
        "node.kubernetes.io/ecr-pull-region" = local.ecr_pull_region
      }

      # Supply NodeConfig (endpoint, CA, CIDR) in user data so nodes
      # don't call DescribeCluster at boot — avoids API throttling.
      enable_bootstrap_user_data = true

      # Pre-bootstrap: containerd mirror + kubelet region env + credential provider
      # Region + account baked from Terraform — no IMDS dependency
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript; charset=\"us-ascii\""
          content      = <<-EOT
            #!/bin/bash
            set -ex

            # ── Region + account baked from Terraform ──
            REGION="${local.ecr_pull_region}"
            ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"

            ECR_ENDPOINT="$${ACCOUNT_ID}.dkr.ecr.$${REGION}.amazonaws.com"
            CUSTOM_REGISTRY="${var.custom_registry}"

            echo "Mirror: $${CUSTOM_REGISTRY} → $${ECR_ENDPOINT}"

            # ── Write containerd mirror config ───────────────────────
            # Set ECR as the server so containerd resolves directly against ECR.
            mkdir -p "/etc/containerd/certs.d/$${CUSTOM_REGISTRY}"
            cat > "/etc/containerd/certs.d/$${CUSTOM_REGISTRY}/hosts.toml" <<TOML
            server = "https://$${ECR_ENDPOINT}"
            TOML

            # ── Update credential provider config with custom registry and AWS region ────
            # Built on top of EKS default values, adding the custom
            # registry so kubelet supplies ECR credentials for it.
            # env passes AWS_DEFAULT_REGION directly to the provider
            # process — needed because the vanity hostname has no region.
            cat > /etc/eks/image-credential-provider/config.json <<CONFIG
            {
              "kind": "CredentialProviderConfig",
              "apiVersion": "kubelet.config.k8s.io/v1",
              "providers": [
                {
                  "name": "ecr-credential-provider",
                  "matchImages": [
                    "$${CUSTOM_REGISTRY}",
                    "*.dkr.ecr.*.amazonaws.com",
                    "*.dkr-ecr.*.on.aws",
                    "*.dkr.ecr.*.amazonaws.com.cn",
                    "*.dkr-ecr.*.on.amazonwebservices.com.cn",
                    "*.dkr.ecr-fips.*.amazonaws.com",
                    "*.dkr-ecr-fips.*.on.aws",
                    "*.dkr.ecr.*.c2s.ic.gov",
                    "*.dkr.ecr.*.sc2s.sgov.gov",
                    "*.dkr.ecr.*.cloud.adc-e.uk",
                    "*.dkr.ecr.*.csp.hci.ic.gov",
                    "*.dkr.ecr.*.amazonaws.eu",
                    "public.ecr.aws",
                    "ecr-public.aws.com"
                  ],
                  "defaultCacheDuration": "12h0m0s",
                  "apiVersion": "credentialprovider.kubelet.k8s.io/v1",
                  "env": [
                    {
                      "name": "AWS_DEFAULT_REGION",
                      "value": "$${REGION}"
                    }
                  ]
                }
              ]
            }
            CONFIG
          EOT
        }
      ]
      cloudinit_post_nodeadm = [
        {
          content_type = "text/x-shellscript; charset=\"us-ascii\""
          content      = <<-EOT
            #!/bin/bash
            set -ex

            # ── Enable containerd debug logging ──
            # Append debug config if not already present
            if ! grep -q '\[debug\]' /etc/containerd/config.toml; then
              cat >> /etc/containerd/config.toml <<TOML

            [debug]
            level = "debug"
            TOML
              systemctl restart containerd
            fi
          EOT
        }
      ]

    }

    # -----------------------------------------------------------------
    # Default node group — no taints, catches system pods and anything
    # without explicit tolerations (CoreDNS, kube-proxy daemonsets, etc.)
    # -----------------------------------------------------------------
    // default = {
    //   ami_type       = "AL2023_x86_64_STANDARD"
    //   instance_types = [var.node_instance_type]
    //   min_size       = 1
    //   max_size       = 3
    //   desired_size   = 1

    //   update_config = {
    //     max_unavailable_percentage = 100
    //   }
    //   force_update_version = true
    // }
  }
}


