#!/bin/sh
# Runs inside the confidential sandbox. /attest-test/value.txt exists only if the
# guest agent unwrapped the encrypted layers via KMS Decrypt (Recipient = NSM attestation).
F=/attest-test/value.txt
echo "attest-test: runtime uname=$(uname -r)"
if [ ! -f "$F" ]; then echo "attest-test: RESULT=FAIL test file missing"; exit 1; fi
GOT=$(sha256sum "$F" | cut -d' ' -f1)
echo "attest-test: expected_sha256=${EXPECTED_SHA256}"
echo "attest-test: actual_sha256=${GOT}"
echo "attest-test: value=$(cat "$F")"
if [ "$GOT" = "$EXPECTED_SHA256" ]; then echo "attest-test: RESULT=PASS decrypted plaintext matches"; else echo "attest-test: RESULT=FAIL mismatch"; exit 1; fi
