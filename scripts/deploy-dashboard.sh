#!/usr/bin/env bash
# Deploy dashboard with API credentials injected at build time.
# Usage: ./scripts/deploy-dashboard.sh
#
# Reads API_KEY, TELEMETRY_API_URL, and COMMAND_API_URL from Terraform outputs
# and injects them into demo/index.html, then uploads to S3 + invalidates CloudFront.
#
# Security: The committed index.html contains __PLACEHOLDER__ strings only.
# Real credentials are never stored in source control.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEMO_DIR="$PROJECT_DIR/demo"
INFRA_DIR="$PROJECT_DIR/infra"

echo "[1/3] Reading secrets from Terraform outputs..."
API_KEY=$(cd "$INFRA_DIR" && terraform output -raw dashboard_api_key)
API_URL=$(cd "$INFRA_DIR" && terraform output -raw telemetry_api_url)

# Derive command URL from telemetry URL (same base, /command suffix)
CMD_URL="${API_URL/%\/telemetry/\/command}"

if [[ -z "$API_KEY" || -z "$API_URL" ]]; then
  echo "ERROR: Could not read Terraform outputs. Run 'terraform apply' first."
  exit 1
fi

echo "[2/3] Injecting credentials into dashboard HTML..."
TEMPLATE="$DEMO_DIR/index.html"
OUTPUT="$DEMO_DIR/index-deploy.html"

sed \
  -e "s|__API_KEY__|${API_KEY}|g" \
  -e "s|__TELEMETRY_API_URL__|${API_URL}|g" \
  -e "s|__COMMAND_API_URL__|${CMD_URL}|g" \
  "$TEMPLATE" > "$OUTPUT"

echo "[3/3] Uploading to S3 + invalidating CloudFront..."
BUCKET=$(cd "$INFRA_DIR" && terraform output -raw dashboard_bucket)
DIST_ID=$(cd "$INFRA_DIR" && terraform output -raw dashboard_cloudfront_distribution_id)

aws s3 cp "$OUTPUT" "s3://${BUCKET}/index.html" --content-type "text/html; charset=utf-8"
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/index.html"

rm "$OUTPUT"
echo "Dashboard deployed successfully."
