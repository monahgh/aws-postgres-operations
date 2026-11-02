#!/usr/bin/env bash
# Deletes the Terraform state bucket, including every object version and delete marker.
# Run it last, after `terraform destroy`. If the bucket is shared with other projects,
# their state is deleted too.
set -euo pipefail

AWS_REGION="eu-central-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${TF_STATE_BUCKET:-tfstate-aws-projects-${ACCOUNT_ID}}"

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Bucket not found: ${BUCKET_NAME}"
  exit 0
fi

# The CLI paginates list-object-versions automatically, so this covers every version.
aws s3api list-object-versions \
  --bucket "$BUCKET_NAME" \
  --output json --region "$AWS_REGION" | \
  jq -r '(.Versions // [])[], (.DeleteMarkers // [])[] | [.Key, .VersionId] | @tsv' | \
  while IFS=$'\t' read -r key version_id; do
    [ -n "$key" ] || continue
    aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version_id" --region "$AWS_REGION" >/dev/null
  done

aws s3 rb "s3://${BUCKET_NAME}" --force --region "$AWS_REGION"
echo "Deleted bucket: ${BUCKET_NAME}"
