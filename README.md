# ECR Vanity Registry with Containerd

Use a custom registry hostname (e.g. `my-registry.lab`) in your Kubernetes manifests while pulling images from Amazon ECR under the hood.

## Problem

ECR image URIs are long and encode infrastructure details:

```
123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com/shared/nginx:latest
```

Every manifest, Helm chart, and CI pipeline that references this URI is now coupled to a specific AWS account and region. If you replicate images to another region for DR or migrate accounts, you're updating image references everywhere.

## Solution

This approach uses two node-level configurations — one for containerd and one for kubelet's credential provider — to rewrite a vanity hostname to ECR at pull time. No webhooks, no DNS tricks, no application changes.

Developers write manifests with the vanity name:

```yaml
image: my-registry.lab/shared/nginx:latest
```

When kubelet processes the pod spec, two things happen:

### 1. Authentication — kubelet + ecr-credential-provider

Kubelet sees the image reference and checks its credential provider config. A UserData script configures the credential provider with:

- **matchImages** including the vanity registry `my-registry.lab` — kubelet invokes `ecr-credential-provider` to retrieve ECR credentials for this image.
- **env `AWS_DEFAULT_REGION`** — the credential provider parses the image registry to find an AWS region. Since the vanity hostname has no region embedded, it falls back to the region defined as an environment variable.

```json
"env": [{ "name": "AWS_DEFAULT_REGION", "value": "us-east-1" }]
```

The provider calls ECR's `GetAuthorizationToken` API, pointing to the ECR API endpoint for that region (`api.ecr.<region>.amazonaws.com`), authenticated via the node's IAM role, and returns a short-lived Docker credential back to kubelet.



### 2. Image Pull — containerd host rewrite

Kubelet passes the image reference and credentials to containerd via the CRI `PullImage` RPC. Containerd reads its host configuration at `/etc/containerd/certs.d/my-registry.lab/hosts.toml`:

```toml
server = "https://123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com"
```

This tells containerd to resolve `my-registry.lab` against the ECR Docker endpoint (`<account>.dkr.ecr.<region>.amazonaws.com`). It sends the request there with the credentials kubelet provided, and the image pulls normally.

### The Full Flow

```
pod spec: image: my-registry.lab/shared/nginx:latest
    │
    ├─ kubelet checks matchImages → "my-registry.lab" matches
    │  → invokes ecr-credential-provider
    │  → provider calls api.ecr.<region>.amazonaws.com (using AWS_DEFAULT_REGION env)
    │  → returns base64(AWS:<token>)
    │
    ├─ kubelet calls containerd CRI PullImage
    │  with image ref + credentials
    │
    └─ containerd resolves my-registry.lab
       → reads /etc/containerd/certs.d/my-registry.lab/hosts.toml
       → server = "https://<account>.dkr.ecr.<region>.amazonaws.com"
       → pulls from ECR using the provided token
```

Both the auth endpoint (api.ecr) and the Docker endpoint (dkr.ecr) need a region. The credential provider config handles the first; the containerd hosts.toml handles the second. This repo bakes both from a single Terraform variable so they stay in sync.

## Architecture

```
  ┌────────────────────────────────────────────────┐
  │  EKS Cluster                                   │
  │                                                │
  │  ┌──────────────────────────────────────────┐  │
  │  │  Node (AL2023)                           │  │
  │  │                                          │  │
  │  │  ┌────────────────────────────────────┐  │  │
  │  │  │ Pod                                │  │  │
  │  │  │ image: my-registry.lab/            │  │  │
  │  │  │        shared/nginx:latest         │  │  │
  │  │  └────────────────────────────────────┘  │  │
  │  │                                          │  │
  │  │  containerd hosts.toml:                  │  │
  │  │    my-registry.lab →                     │  │
  │  │      <acct>.dkr.ecr.REGION.amazonaws.com │  │
  │  │                                          │  │
  │  │  ecr-credential-provider:                │  │
  │  │    AWS_DEFAULT_REGION = REGION           │  │
  │  └──────────────────┬───────────────────────┘  │
  └─────────────────────┼──────────────────────────┘
                        │
                        │
              ecr_pull_region = ?
                        │
            ┌───────────┴───────────┐
            │                       │
            │ (default: "")         │ ("us-west-1")
            │                       │
            ▼                       ▼
  ┌──────────────────┐    ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
  │  ECR (primary)   │      ECR (replica)
  │  us-east-1       │───▶│ us-west-1        │
  │  shared/nginx    │      shared/nginx
  └──────────────────┘    └ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
```

The Terraform configuration creates:

- **VPC** — 2 AZs, public/private subnets, single NAT gateway
- **EKS cluster** — managed control plane with coredns, kube-proxy, vpc-cni addons
- **Managed node group** — AL2023 nodes with cloud-init scripts that write the containerd and credential provider configs at boot
- **ECR repository** — `shared/nginx` with cross-region replication


## Demo

### Prerequisites

- AWS account with permissions to create VPC, EKS, ECR resources
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2
- `kubectl`
- A container runtime (docker, podman, or finch) for building/pushing images

### 1. Configure

Edit `infra-tf/terraform.tfvars`. Keep `ecr_pull_region` empty to pull images from ECR in the same cluster region.

| Variable | Description | Default |
|---|---|---|
| `aws_region` | AWS region for all resources | — |
| `cluster_name` | EKS cluster name | — |
| `custom_registry` | Vanity registry hostname | — |
| `ecr_pull_region` | Region to pull images from (empty = cluster region) | `""` |
| `ecr_replication_region` | Region to replicate ECR images to | — |
| `node_instance_type` | EC2 instance type for nodes | `t3.small` |

### 2. Deploy infrastructure

```console
$ ./scripts/create-infra.sh
```

This creates:
- EKS cluster and VPC
- Managed node group with containerd config pointing the vanity URI to ECR in the cluster region, and a node label `ecr-pull-region`
- ECR repository in the cluster region
- ECR replication to the replication region

### 3. Configure kubectl

```console
$ aws eks update-kubeconfig --name <cluster-name> --region <region>
```

Or copy the command from `terraform output configure_kubectl`.

### 4. Push an image to ECR

```console
$ ./scripts/build-push-images.sh
```

This pulls `public.ecr.aws/nginx/nginx:latest`, tags it, and pushes it to ECR in the cluster region. ECR replication triggers automatically, making the image available in the replication region as well.

### 5. Deploy with the vanity registry

```console
$ kubectl apply -f manifest/nginx-vanity-registry.yaml
```

### 6. Verify

The pod runs using the vanity image URI. Kubelet pulls from ECR transparently:

```console
$ kubectl get po -o wide
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE                        NOMINATED NODE   READINESS GATES
nginx-vanity-uri-684f854c7d-qdth4   1/1     Running   0          13m   10.0.1.203   ip-10-0-1-90.ec2.internal   <none>           <none>
```

```console
$ kubectl describe pod | tail
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  13m   default-scheduler  Successfully assigned default/nginx-vanity-uri-684f854c7d-qdth4 to ip-10-0-1-90.ec2.internal
  Normal  Pulling    13m   kubelet            Pulling image "my-registry.lab/shared/nginx:latest"
  Normal  Pulled     13m   kubelet            Successfully pulled image "my-registry.lab/shared/nginx:latest" in 124ms (124ms including waiting). Image size: 66133124 bytes.
  Normal  Created    13m   kubelet            Container created
  Normal  Started    13m   kubelet            Container started
```

The node label confirms which ECR region it pulls from:

```console
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,REGION:.metadata.labels.topology\.kubernetes\.io/region,ECR-PULL-REGION:.metadata.labels.node\.kubernetes\.io/ecr-pull-region'
NAME                        REGION      ECR-PULL-REGION
ip-10-0-1-90.ec2.internal   us-east-1   us-east-1
```

### 7. Inspect containerd logs

Containerd debug logs show how the vanity URI resolves to the ECR registry in the cluster region:

```console
$ # Get a shell on the node without SSH/SSM
$ kubectl debug node/<node-name> -it --image=ubuntu -- bash

$ # View containerd logs
$ chroot /host journalctl -u containerd --no-pager \
  | grep -A12 "RunPodSandbox" | grep -A12 "nginx-vanity-uri"
containerd: PullImage "my-registry.lab/shared/nginx:latest"
containerd: loading host directory dir=/etc/containerd/certs.d/my-registry.lab
containerd: resolving host=123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com
containerd: do request host=123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com request.method=HEAD
  url="https://123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com/v2/shared/nginx/manifests/latest?ns=my-registry.lab"
containerd: fetch response received response.status="401 Unauthorized"
containerd: do request host=123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com request.method=HEAD
  url="https://123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com/v2/shared/nginx/manifests/latest?ns=my-registry.lab"
containerd: fetch response received response.status="200 OK"
containerd: resolved desc.digest="sha256:162bf60c..." host=123456EXAMPLE.dkr.ecr.us-east-1.amazonaws.com
```

The 401 → 200 sequence is normal — it's the standard Docker Registry V2 auth challenge-response flow.

### 8. Failover to a Replica Region

Update `ecr_pull_region` in `terraform.tfvars` to point to the replication region:

```hcl
ecr_pull_region = "us-west-1"
```

Then apply:
```console
$ terraform apply
```

EKS managed node group replaces the nodes (this may take a few minutes). Once the new nodes are ready:

```console
$ kubectl get po -o wide
NAME                                READY   STATUS    RESTARTS   AGE     IP           NODE                         NOMINATED NODE   READINESS GATES
nginx-vanity-uri-684f854c7d-hxkvt   1/1     Running   0          3m28s   10.0.2.114   ip-10-0-2-137.ec2.internal   <none>           <none>
```

```console
$ kubectl describe pod | tail
Events:
  Type    Reason     Age    From               Message
  ----    ------     ----   ----               -------
  Normal  Scheduled  3m41s  default-scheduler  Successfully assigned default/nginx-vanity-uri-684f854c7d-hxkvt to ip-10-0-2-137.ec2.internal
  Normal  Pulling    3m40s  kubelet            Pulling image "my-registry.lab/shared/nginx:latest"
  Normal  Pulled     3m40s  kubelet            Successfully pulled image "my-registry.lab/shared/nginx:latest" in 442ms (442ms including waiting). Image size: 66133124 bytes.
  Normal  Created    3m40s  kubelet            Container created
  Normal  Started    3m40s  kubelet            Container started
```

The node label now shows the replica region:

```console
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,REGION:.metadata.labels.topology\.kubernetes\.io/region,ECR-PULL-REGION:.metadata.labels.node\.kubernetes\.io/ecr-pull-region'
NAME                         REGION      ECR-PULL-REGION
ip-10-0-2-137.ec2.internal   us-east-1   us-west-1
```

Containerd debug logs confirm the vanity URI now resolves to ECR in the replication region:

```console
$ kubectl debug node/<node-name> -it --image=ubuntu -- bash
$ chroot /host journalctl -u containerd --no-pager \
  | grep -A12 "RunPodSandbox" | grep -A12 "nginx-vanity-uri"
containerd: PullImage "my-registry.lab/shared/nginx:latest"
containerd: loading host directory dir=/etc/containerd/certs.d/my-registry.lab
containerd: resolving host=123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com
containerd: do request host=123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com request.method=HEAD
  url="https://123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com/v2/shared/nginx/manifests/latest?ns=my-registry.lab"
containerd: fetch response received response.status="401 Unauthorized"
containerd: do request host=123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com request.method=HEAD
  url="https://123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com/v2/shared/nginx/manifests/latest?ns=my-registry.lab"
containerd: fetch response received response.status="200 OK"
containerd: resolved desc.digest="sha256:162bf60c..." host=123456EXAMPLE.dkr.ecr.us-west-1.amazonaws.com
```

Manifests stay unchanged — only the Terraform variable controls which ECR region nodes pull from.

### Additional node inspection commands

```console
$ # Get a shell on the node
$ kubectl debug node/<node-name> -it --image=ubuntu -- bash

$ # Check containerd config
$ cat /host/etc/containerd/config.toml

$ # Check the containerd hosts mirror config
$ cat /host/etc/containerd/certs.d/my-registry.lab/hosts.toml

$ # Check credential provider config
$ cat /host/etc/eks/image-credential-provider/config.json
```

## Cleanup

```console
$ ./scripts/cleanup.sh
```
