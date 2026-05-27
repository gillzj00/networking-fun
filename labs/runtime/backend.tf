terraform {
  # Backend config supplied per PR at init time:
  #   terraform init \
  #     -backend-config="bucket=$TFSTATE_BUCKET" \
  #     -backend-config="key=labs/<pr-number>/terraform.tfstate" \
  #     -backend-config="region=$AWS_REGION" \
  #     -backend-config="use_lockfile=true" \
  #     -backend-config="encrypt=true"
  backend "s3" {}
}
