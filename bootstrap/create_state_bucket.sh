#!/usr/bin/env bash
# Creates the S3 bucket for Terraform state: versioned, encrypted, no public access.
# Idempotent. Locking uses S3 native lock files (use_lockfile = true), so no DynamoDB table.
set -euo pipefail

AWS_REGION="eu-central-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${TF_STATE_BUCKET:-tfstate-aws-projects-${ACCOUNT_ID}}"

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws s3 mb "s3://${BUCKET_NAME}" --region "$AWS_REGION"
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled \
    --region "$AWS_REGION"
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    --region "$AWS_REGION"
else
  echo "Bucket already exists: ${BUCKET_NAME}"
fi

echo "$BUCKET_NAME"
