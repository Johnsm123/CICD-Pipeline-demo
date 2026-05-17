#!/usr/bin/env bash
# Deletes the demo stacks in reverse order. ECR images and S3 artifact bucket must be emptied first.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

ARTIFACT_BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name cicd-demo-pipeline \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucket'].OutputValue" --output text 2>/dev/null || true)

if [[ -n "${ARTIFACT_BUCKET:-}" ]]; then
  echo "Emptying artifact bucket $ARTIFACT_BUCKET"
  aws s3 rm "s3://$ARTIFACT_BUCKET" --recursive || true
  aws s3api delete-objects --bucket "$ARTIFACT_BUCKET" \
    --delete "$(aws s3api list-object-versions --bucket "$ARTIFACT_BUCKET" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
fi

echo "Emptying ECR repository"
aws ecr batch-delete-image --region "$REGION" --repository-name cicd-demo-app \
  --image-ids "$(aws ecr list-images --region "$REGION" --repository-name cicd-demo-app --query 'imageIds[*]' --output json)" 2>/dev/null || true

for s in cicd-demo-pipeline cicd-demo-ecs cicd-demo-ecr; do
  echo "Deleting stack $s"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$s"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$s" || true
done
