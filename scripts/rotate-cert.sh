#!/usr/bin/env bash
# Certificate rotation script for iViewIO IoT devices
# Usage: ./rotate-cert.sh <thing-name> <output-dir>
# Example: ./rotate-cert.sh Trailer_Sim_01 ./certs
#
# Procedure (ISO 21434 Clause 8.6 — Vulnerability Management):
#   1. Generate new X.509 key pair + certificate
#   2. Attach new certificate to the IoT Thing
#   3. Attach IoT policy to new certificate
#   4. Revoke (INACTIVE) the old certificate
#   5. Detach old certificate from Thing
#
# Run this script before the old certificate expires.
# After running, restart the device simulator with the new cert files.

set -euo pipefail

THING_NAME="${1:-Trailer_Sim_01}"
OUTPUT_DIR="${2:-./certs}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
POLICY_NAME="TrailerSim01Policy"

echo "[1/5] Generating new certificate for ${THING_NAME}..."
mkdir -p "$OUTPUT_DIR"

CERT_OUTPUT=$(aws iot create-keys-and-certificate \
    --set-as-active \
    --certificate-pem-outfile "${OUTPUT_DIR}/device-new.pem.crt" \
    --public-key-outfile  "${OUTPUT_DIR}/public-new.pem.key" \
    --private-key-outfile "${OUTPUT_DIR}/private-new.pem.key" \
    --region "$REGION" \
    --output json)

NEW_CERT_ARN=$(echo "$CERT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['certificateArn'])")
NEW_CERT_ID=$(echo "$CERT_OUTPUT"  | python3 -c "import sys,json; print(json.load(sys.stdin)['certificateId'])")
echo "    New certificate ARN: ${NEW_CERT_ARN}"

echo "[2/5] Attaching new certificate to Thing ${THING_NAME}..."
aws iot attach-thing-principal \
    --thing-name "$THING_NAME" \
    --principal "$NEW_CERT_ARN" \
    --region "$REGION"

echo "[3/5] Attaching IoT policy to new certificate..."
aws iot attach-policy \
    --policy-name "$POLICY_NAME" \
    --target "$NEW_CERT_ARN" \
    --region "$REGION"

echo "[4/5] Retrieving old certificate ARN..."
OLD_CERT_ARN=$(aws iot list-thing-principals \
    --thing-name "$THING_NAME" \
    --region "$REGION" \
    --query "principals[?contains(@, 'cert') && @ != '${NEW_CERT_ARN}'] | [0]" \
    --output text)

if [ "$OLD_CERT_ARN" = "None" ] || [ -z "$OLD_CERT_ARN" ]; then
    echo "    No old certificate found. Skipping revocation."
else
    OLD_CERT_ID=$(basename "$OLD_CERT_ARN")
    echo "    Revoking old certificate: ${OLD_CERT_ID:0:16}..."
    aws iot update-certificate \
        --certificate-id "$OLD_CERT_ID" \
        --new-status INACTIVE \
        --region "$REGION"

    echo "[5/5] Detaching old certificate from Thing..."
    aws iot detach-thing-principal \
        --thing-name "$THING_NAME" \
        --principal "$OLD_CERT_ARN" \
        --region "$REGION"
    aws iot detach-policy \
        --policy-name "$POLICY_NAME" \
        --target "$OLD_CERT_ARN" \
        --region "$REGION"
fi

echo ""
echo "Certificate rotation complete."
echo "New cert files:"
echo "  ${OUTPUT_DIR}/device-new.pem.crt"
echo "  ${OUTPUT_DIR}/private-new.pem.key"
echo ""
echo "Next steps:"
echo "  1. Rename new cert files to device.pem.crt / private.pem.key"
echo "  2. Restart the device simulator"
echo "  3. Update terraform.tfvars: device_cert_arn = \"${NEW_CERT_ARN}\""
echo "  4. Run: terraform apply"
