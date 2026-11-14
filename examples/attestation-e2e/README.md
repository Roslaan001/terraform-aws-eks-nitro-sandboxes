# End-to-end KMS recipient-attestation test (confidential sandbox)

A manual, disposable test showing that a real `confidential-sandbox` pod completes
AWS KMS recipient-attestation decryption *inside the guest*. It is deliberately not part of
`scripts/verify_sandbox.sh`: it needs the AWS Nitro Sandboxes binaries, `skopeo`, an ECR
repository and a disposable KMS key, which would make an automated check brittle.

## What performs the attested decrypt

Containers in a confidential sandbox cannot open the Nitro Secure Module. The generated
admission policy pins `linux_devices.isEmpty()` and mounts `/dev` as tmpfs, and the AWS docs
expose no attestation interface to workloads. The supported in-guest path is
**encrypted container images**: the AWS `nitro-sandbox-agent` inside the confidential VM
1. reads `/dev/nsm`,
2. calls `kms:Decrypt` with `Recipient` (`RSAES_OAEP_SHA_256`), using the pod's
   Pod Identity credentials,
3. unwraps `CiphertextForRecipient` (CMS EnvelopedData) in the guest,
4. then decrypts each image layer.

If KMS refuses, the layers never decrypt and the container never starts.
The test container (`check.sh`) then compares the sha256 of a known, non-sensitive file
from the encrypted layer with `EXPECTED_SHA256` and logs `RESULT=PASS|FAIL`.

The ephemeral key pair, the `Recipient` call and the unwrap are performed by the AWS guest
agent, not by code in this directory.

## Procedure

Prerequisites: `podman`, `skopeo`, and the AWS Nitro Sandboxes runtime archive
(`https://d1uvmbvklg8rt.cloudfront.net/latest/x86_64/nitro-sandboxes-runtime.tar.gz`).
Verify the archive before use:
1. Check `SHA256SUM.sig` with `openssl dgst -sha384 -verify` against the public key on the
   EKS "download binaries" page.
2. Run `sha256sum -c SHA256SUM`.

1. **Disposable key.** Create a symmetric KMS key. Its key policy is the production key
   policy with **only** the PCR17 value replaced (set in step 4). Never point this test at
   the production key or edit `platform/kms.tf`.
2. **Build and encrypt.** Every layer must be encrypted. Stage the image as a gzip OCI
   layout first. Encrypting straight from `containers-storage:` records the uncompressed
   digest, and the agent rejects it with `blob digest mismatch`.
   ```sh
   podman build --platform linux/amd64 -t localhost/attest-test:v1 -f Containerfile .
   skopeo copy --dest-compress --dest-compress-format gzip --format oci \
     containers-storage:localhost/attest-test:v1 oci:./oci-plain:v1
   # ocicrypt.json: {"key-providers":{"awskms":{"cmd":{"path":"<abs>/nitro-sandbox-keyprovider","args":[]}}}}
   OCICRYPT_KEYPROVIDER_CONFIG=./ocicrypt.json skopeo copy \
     --encryption-key provider:awskms:<TEST_KEY_ARN> oci:./oci-plain:v1 docker://<ECR_REPO>:encrypted
   ```
   The keyprovider's Rust SDK cannot use an `aws login` profile session. Export short-lived
   credentials into the environment of that one command
   (`eval "$(aws configure export-credentials --format env)"`).
3. **Manifest.** Substitute `${ENCRYPTED_IMAGE}` in `pod.yaml.tmpl` with
   `<ECR_REPO>@<digest of the encrypted image>`.
4. **Policy and PCR17.** Run
   `eks-nitro-sandbox-genpolicy --profile confidential --with-pod-identity --output-file-b64 policy.b64 pod.yaml`.
   genpolicy reads registry credentials from `$HOME/.docker/config.json`.
   - Put the predicted PCR17 into the test key policy.
   - Put `policy.b64` into the `sandbox.amazonaws.com/policy` annotation.
   - The runtime policy must still deny Exec.
5. **Run.** `kubectl apply`, then wait for `Succeeded` and read `kubectl logs`.
6. **Evidence.** Look up the CloudTrail `Decrypt` events on the test key. KMS records the
   claims from the verified attestation document under `additionalEventData.recipient`:
   `attestationDocumentEnclavePCR17` (base64; decode to hex) and
   `attestationDocumentEnclavePCR8ServiceName`.
7. **Cleanup.**
   - Delete the pod and the ECR repository.
   - `aws kms schedule-key-deletion --pending-window-in-days 7`.
   - Remove the local images and temporary files.

## Negative tests

| Test | How | Expected |
|---|---|---|
| Missing attestation | Workload-role pod calls `kms:Decrypt` without `Recipient` | `AccessDeniedException ... explicit deny in a resource-based policy` |
| Mismatched PCR17 (genuine) | Same image plus one extra env var. The Cedar policy, and so the attested PCR17, changes; the key policy is unchanged | KMS denies; pod fails `StartError` (`prepare_image: KMS Decrypt failed: AccessDeniedException`) |
| Mismatched PCR8 | Requires a guest image not signed by Amazon EKS | **Not live-testable**: no genuine non-EKS-signed sandbox guest is available, and forging documents is out of scope. Covered only by key-policy structure checks (simulation) |

## What each kind of evidence proves

| Evidence | Proves |
|---|---|
| Policy structure verification (`verify_sandbox.sh` Check 6/7) | The Deny/Allow statements and conditions are present and exact. Proves nothing about runtime behaviour. |
| Missing-attestation rejection | An unattested request by the workload role is denied. Does not show an attested request can succeed. |
| Successful recipient-attestation decryption (this test) | A genuine confidential guest's attestation (PCR17 + `PCR8:ServiceName`) satisfied the policy, KMS returned `CiphertextForRecipient`, the guest unwrapped it, and the plaintext matched. |
