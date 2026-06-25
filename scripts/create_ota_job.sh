#!/usr/bin/env bash
# Usage: ./scripts/create_ota_job.sh <firmware-file> <version>
# Example: ./scripts/create_ota_job.sh firmware-1.1.0.bin 1.1.0
# Security: Validates firmware file path to prevent directory traversal.

set -euo pipefail

FIRMWARE_FILE="${1:?Usage: $0 <firmware-file> <version>}"
VERSION="${2:?Usage: $0 <firmware-file> <version>}"
DEVICE_ID="Trailer_Sim_01"
REGION="${AWS_REGION:-us-east-1}"

# Path traversal protection: resolve to absolute, verify under working directory.
FIRMWARE_REAL=$(realpath "$FIRMWARE_FILE" 2>/dev/null || echo "")
WORK_DIR=$(realpath "$(pwd)")
if [[ -z "$FIRMWARE_REAL" || "$FIRMWARE_REAL" != "$WORK_DIR"/* ]]; then
  echo "ERROR: Firmware file must be within the project directory."
  echo "  Provided: $FIRMWARE_FILE"
  echo "  Resolved: $FIRMWARE_REAL"
  exit 1
fi

BUCKET=$(cd infra && terraform output -raw firmware_bucket)
S3_KEY="$(basename "$FIRMWARE_FILE")"
SHA256=$(shasum -a 256 "$FIRMWARE_REAL" | awk '{print $1}')

echo "Uploading $FIRMWARE_FILE to s3://$BUCKET/$S3_KEY ..."
aws s3 cp "$FIRMWARE_FILE" "s3://$BUCKET/$S3_KEY" --region "$REGION"

PRESIGNED_URL=$(aws s3 presign "s3://$BUCKET/$S3_KEY" \
  --expires-in 3600 \
  --region "$REGION")

JOB_ID="ota-v${VERSION}-$(date +%s)"

JOB_DOCUMENT=$(jq -n \
  --arg url "$PRESIGNED_URL" \
  --arg sha "$SHA256" \
  --arg ver "$VERSION" \
  '{firmwareUrl: $url, sha256: $sha, version: $ver}')

echo "Creating IoT Job $JOB_ID ..."
aws iot create-job \
  --job-id "$JOB_ID" \
  --targets "arn:aws:iot:${REGION}:$(aws sts get-caller-identity --query Account --output text):thing/${DEVICE_ID}" \
  --document "$JOB_DOCUMENT" \
  --region "$REGION"

echo "OTA Job created: $JOB_ID"
echo "SHA256: $SHA256"
