#!/usr/bin/env bash
# Deploy the SPA outside Terraform: sync app/frontend to the S3 bucket and invalidate
# the CloudFront cache. Run in CloudShell from a clone of the repo:
#   bash scripts/deploy_frontend.sh [bucket] [distribution-id]
# Without arguments, the bucket and distribution are found by the project name.
# Note: the next `terraform apply` re-uploads the files Terraform manages if they differ.
set -euo pipefail

PROJECT="${PROJECT_NAME:-three-tier-lab}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/../app/frontend"

BUCKET="${1:-$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '${PROJECT}-frontend-')].Name | [0]" --output text)}"
DIST_ID="${2:-$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PROJECT}'].Id | [0]" --output text)}"

if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then echo "Frontend bucket not found"; exit 1; fi
if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then echo "CloudFront distribution not found"; exit 1; fi

echo "Syncing $SRC -> s3://$BUCKET"
aws s3 sync "$SRC" "s3://$BUCKET" --delete

echo "Invalidating CloudFront cache on $DIST_ID"
INVALIDATION_ID=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
  --query 'Invalidation.Id' --output text)
aws cloudfront wait invalidation-completed --distribution-id "$DIST_ID" --id "$INVALIDATION_ID"
echo "Done: https://$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"
