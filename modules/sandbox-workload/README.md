# Terraform Module: AWS Nitro Sandbox Workload (`sandbox-workload`)

Reusable Terraform module to provision hardware-isolated (`isolated-sandbox`) or confidential (`confidential-sandbox`) microVM workloads on **Amazon EKS Auto Mode**.

This module automates the entire per-application lifecycle:
* **MicroVM Sandbox**: Configures the pod `runtimeClassName` to `isolated-sandbox` or `confidential-sandbox`.
* **Workload Identity**: Provisions an isolated AWS IAM role trusted *only* by EKS Pod Identity for the specific cluster, and creates the matching Kubernetes `ServiceAccount` and `aws_eks_pod_identity_association`.
* **Zero-Trust Network Perimeter**: Optionally deploys a Kubernetes `NetworkPolicy` permitting ingress only to the defined container port, adhering to the cluster's default-deny egress/ingress posture.
* **Cryptographic Attestation (Confidential Mode)**: Automatically provisions a dedicated customer-managed AWS KMS key (`alias/<cluster>-<name>`) gated by explicit `Deny` statements against Nitro Secure Module measurements (**PCR17** Cedar policy hash and **PCR8** `eks.amazonaws.com` signer).
* **Flexible Management Mode**: Deploy the full workload (Deployment + Service) through Terraform (`manage_deployment = true`), or provision only the identity slot and network policy (`manage_deployment = false`) while managing pods via Helm, Argo CD, Flux, or `kubectl`.
* **Dual Interface**: Use top-level HCL variables for native Terraform code, or pass a single `config` object when decoding YAML/JSON workload files.

---

## Architecture

```
                      ┌──────────────────────────────────────────────┐
                      │             EKS Auto Mode Cluster            │
                      │                                              │
  Incoming Traffic ──►│  [NetworkPolicy] (Ingress Port)              │
                      │         │                                    │
                      │  [ServiceAccount] ── Pod Identity Assocation │
                      │         │                    │               │
                      │  [Deployment]                ▼               │
                      │   └── MicroVM        [Workload IAM Role]     │
                      │        (isolated /           │               │
                      │       confidential)          ▼               │
                      │                      [Workload KMS Key]      │
                      │                      (Confidential PCR17/8)  │
                      └──────────────────────────────────────────────┘
```

---

## Usage

### 1. Basic Isolated Workload (Managed Deployment)

Provisions the IAM role, Pod Identity association, ServiceAccount, NetworkPolicy, Deployment, and Service.

```hcl
module "worker" {
  source = "github.com/Roslaan001/terraform-aws-eks-nitro-sandboxes//modules/sandbox-workload"

  cluster_name  = "nitro-sandbox-eks"
  namespace     = "nitro-sandboxes"
  sandbox_modes = ["isolated"]
  name          = "data-processor"
  mode          = "isolated"

  image         = "public.ecr.aws/nginx/nginx-unprivileged:alpine"
  replicas      = 2
  port          = 8080
  allow_ingress = true
  run_as_user   = 101

  # Optional IAM policies for this workload's role only
  iam_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]
}
```

### 2. Identity Slot Only (Deploy Pods via GitOps / Helm / kubectl)

When `manage_deployment = false`, Terraform creates only the IAM role, Pod Identity association, ServiceAccount, and NetworkPolicy.

```hcl
module "api_identity" {
  source = "github.com/Roslaan001/terraform-aws-eks-nitro-sandboxes//modules/sandbox-workload"

  cluster_name      = "nitro-sandbox-eks"
  namespace         = "nitro-sandboxes"
  sandbox_modes     = ["isolated"]
  name              = "api-gateway"
  mode              = "isolated"
  manage_deployment = false
  port              = 8080
  allow_ingress     = true
}
```

You can then reference the created ServiceAccount in your own manifests:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: nitro-sandboxes
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway # Matches NetworkPolicy
    spec:
      runtimeClassName: isolated-sandbox
      serviceAccountName: api-gateway # Created by module
      containers:
        - name: api
          image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/api:v1.0.0
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```

### 3. Confidential Workload (with Hardware Attestation & KMS Key)

Provisions a confidential microVM workload with an in-guest Cedar policy and a dedicated attestation-gated KMS key (`alias/<cluster>-<name>`).

```hcl
module "confidential_job" {
  source = "github.com/Roslaan001/terraform-aws-eks-nitro-sandboxes//modules/sandbox-workload"

  cluster_name  = "nitro-sandbox-eks"
  namespace     = "nitro-sandboxes"
  sandbox_modes = ["isolated", "confidential"]
  name          = "conf-job"
  mode          = "confidential"

  image               = "public.ecr.aws/nginx/nginx-unprivileged@sha256:a77f1af2603df07bbf73221721393ab5d687de83462106937143e86460514f1e"
  replicas            = 1
  port                = 8080
  allow_ingress       = true
  run_as_user         = 101
  run_as_group        = 101 # Required for confidential workloads
  cedar_policy_base64 = "H4sIAAAAAAAC/..."
  expected_pcr17      = ["b2add91a5710c770c14ebb9cf4500714b6ea3ad9fdccbd55ba509b297c77078fffd27578ee30619a9fc2343f4e0520e4"]
}
```

---

## Important Provider Requirement

> [!IMPORTANT]
> Always configure your `kubernetes` provider from a `data "aws_eks_cluster"` data source, not directly from an `aws_eks_cluster` resource in the same stack:
>
> ```hcl
> data "aws_eks_cluster" "this" {
>   name = var.cluster_name
> }
>
> provider "kubernetes" {
>   host                   = data.aws_eks_cluster.this.endpoint
>   cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
>   exec {
>     api_version = "client.authentication.k8s.io/v1beta1"
>     command     = "aws"
>     args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
>   }
> }
> ```
> Configuring the provider from an `aws_eks_cluster` resource creates a circular dependency: Cluster Resource ➔ Platform KMS Key ➔ Workload IAM Role ➔ Kubernetes Deployment. Using a data source breaks this cycle.

---

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| `cluster_name` | Name of the Amazon EKS cluster | `string` | n/a | yes |
| `namespace` | Kubernetes namespace for workload deployment | `string` | n/a | yes |
| `name` | Workload name (DNS-1123 label, max 40 chars) | `string` | n/a | yes |
| `sandbox_modes` | Sandbox modes enabled on the cluster (`isolated`, `confidential`) | `list(string)` | n/a | yes |
| `mode` | Sandbox isolation mode: `isolated` or `confidential` | `string` | `"isolated"` | no |
| `manage_deployment` | Whether Terraform manages Deployment/Service (`true`) or identity only (`false`) | `bool` | `true` | no |
| `image` | Container image. Must be `@sha256:` digest-pinned if `confidential` | `string` | `null` | no |
| `replicas` | Number of pod replicas (0-50) | `number` | `1` | no |
| `command` | Container entrypoint override | `list(string)` | `null` | no |
| `args` | Container argument list | `list(string)` | `null` | no |
| `env` | Key-value map of environment variables | `map(string)` | `{}` | no |
| `port` | Container port (creates ClusterIP Service if `manage_deployment = true`) | `number` | `null` | no |
| `allow_ingress` | Whether to create NetworkPolicy allowing ingress to `port` | `bool` | `false` | no |
| `cpu_request` | Pod CPU request | `string` | `"100m"` | no |
| `memory_request` | Pod memory request | `string` | `"128Mi"` | no |
| `cpu_limit` | Pod CPU limit | `string` | `"500m"` | no |
| `memory_limit` | Pod memory limit | `string` | `"512Mi"` | no |
| `run_as_user` | Non-root UID | `number` | `10001` | no |
| `run_as_group` | Non-root GID (required for managed confidential workloads) | `number` | `null` | no |
| `iam_policy_arns` | Managed IAM policy ARNs to attach to workload role | `list(string)` | `[]` | no |
| `iam_policy_json` | Custom inline IAM policy JSON for workload role | `string` | `null` | no |
| `kms_decrypt` | Allow role to decrypt via platform KMS key (isolated mode only) | `bool` | `false` | no |
| `cedar_policy_base64` | Base64 Cedar admission policy from `genpolicy` (confidential mode) | `string` | `null` | no |
| `expected_pcr17` | List of acceptable 96-hex PCR17 measurements for KMS attestation | `list(string)` | `[]` | no |
| `config` | Optional structured object input (preempts top-level variables if set) | `any` | `null` | no |
| `account_id` | AWS account ID (auto-discovered from caller identity if omitted) | `string` | `null` | no |
| `aws_region` | AWS region (auto-discovered from provider if omitted) | `string` | `null` | no |
| `partition` | AWS partition (`aws`, `aws-cn`, `aws-us-gov`) | `string` | `"aws"` | no |
| `kms_key_arn` | Platform KMS key ARN (required only when `kms_decrypt = true`) | `string` | `null` | no |
| `tags` | Map of tags applied to all created AWS resources | `map(string)` | `{}` | no |

---

## Outputs

| Name | Description |
|------|-------------|
| `role_arn` | ARN of the IAM role assumed by workload pods through EKS Pod Identity |
| `service_account` | Name of the Kubernetes ServiceAccount created for this workload |
| `manifest` | Rendered Kubernetes Deployment manifest object (null when `manage_deployment = false`) |
| `kms_key_arn` | ARN of dedicated KMS key created for confidential image decryption (null for isolated workloads) |

---

## License

Apache 2.0. See [LICENSE](../../LICENSE) for details.
