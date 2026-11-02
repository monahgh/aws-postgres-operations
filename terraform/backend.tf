# Partial backend configuration: the bucket and key live in backend.hcl (gitignored),
# so no account-specific values are committed. Copy backend.hcl.example to start:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
