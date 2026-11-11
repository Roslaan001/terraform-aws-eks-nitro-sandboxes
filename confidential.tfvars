# Confidential Mode Preset: MicroVM Isolation with Cedar Policy & KMS Recipient Attestation
aws_region             = "us-east-1"
cluster_name           = "nitro-sandbox-eks"
kubernetes_version     = "1.36"
sandbox_modes          = ["confidential"]
deploy_sample_workload = true

# Predicted PCR17 measurement hash representing the generated Cedar policy
confidential_expected_pcr17 = "b4a3a60f9e9cf2ec0b4e2f9d6a7d5b8e9f2a4c1d3e5f7a9b0c2d4e6f8a1b3c5d"

# Base64-encoded Cedar policy generated from pod specification via eks-nitro-sandbox-genpolicy
confidential_cedar_policy_base64 = "cGVybWl0KGFjdGlvbiA9PSBTYW5kYm94QWN0aW9uOjpFeGVjdXRlLCBwcmluY2lwYWwsIHJlc291cmNlKTs="
