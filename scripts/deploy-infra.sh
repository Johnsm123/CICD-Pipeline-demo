#!/usr/bin/env bash
# Bash deployment script - no Docker required locally.
# CodeBuild builds the seed image in AWS.
#
# Usage:
#   AWS_REGION=us-east-1 GITHUB_OWNER=me GITHUB_REPO=CICD-Pipeline-demo \
#     CONNECTION_ARN=arn:aws:codestar-connections:... ./scripts/deploy-infra.sh

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ECR_STACK="cicd-demo-ecr"
BOOTSTRAP_STACK="cicd-demo-bootstrap"
ECS_STACK="cicd-demo-ecs"
PIPELINE_STACK="cicd-demo-pipeline"

: "${GITHUB_OWNER:?Set GITHUB_OWNER}"
: "${GITHUB_REPO:?Set GITHUB_REPO}"
: "${CONNECTION_ARN:?Set CONNECTION_ARN (CodeStar Connections ARN to GitHub)}"

out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

echo "==> [1/4] Deploying ECR stack"
aws cloudformation deploy --region "$REGION" --stack-name "$ECR_STACK" \
  --template-file infrastructure/01-ecr.yaml --capabilities CAPABILITY_NAMED_IAM

REPO_URI=$(out "$ECR_STACK" RepositoryUri)
echo "ECR repo URI: $REPO_URI"

echo "==> [2/4] Deploying bootstrap stack (seed CodeBuild project)"
aws cloudformation deploy --region "$REGION" --stack-name "$BOOTSTRAP_STACK" \
  --template-file infrastructure/00-bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides EcrRepositoryUri="$REPO_URI"

SEED_BUCKET=$(out "$BOOTSTRAP_STACK" SeedBucketName)
SEED_PROJECT=$(out "$BOOTSTRAP_STACK" SeedProjectName)

echo "==> Zipping app source and uploading to s3://$SEED_BUCKET/source.zip"
ZIP_PATH="$(mktemp -d)/source.zip"
if command -v zip >/dev/null 2>&1; then
  (cd . && zip -qr "$ZIP_PATH" app)
else
  python3 -c "import shutil; shutil.make_archive('${ZIP_PATH%.zip}', 'zip', '.', 'app')"
fi
aws s3 cp "$ZIP_PATH" "s3://$SEED_BUCKET/source.zip" --region "$REGION"

echo "==> Running seed CodeBuild (builds & pushes :latest image in the cloud)"
BUILD_ID=$(aws codebuild start-build --region "$REGION" --project-name "$SEED_PROJECT" \
  --query 'build.id' --output text)
echo "Seed build started: $BUILD_ID"

while true; do
  sleep 10
  STATUS=$(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" \
    --query 'builds[0].buildStatus' --output text)
  echo "  build status: $STATUS"
  [[ "$STATUS" == "IN_PROGRESS" ]] || break
done
[[ "$STATUS" == "SUCCEEDED" ]] || { echo "Seed build failed: $STATUS"; exit 1; }
echo "Seed image pushed to ECR."

echo "==> [3/4] Deploying ECS stack"
aws cloudformation deploy --region "$REGION" --stack-name "$ECS_STACK" \
  --template-file infrastructure/02-network-ecs.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides EcrRepositoryUri="$REPO_URI"

CLUSTER=$(out "$ECS_STACK" ClusterName)
SERVICE=$(out "$ECS_STACK" ServiceName)
TG_BLUE=$(out "$ECS_STACK" TargetGroupBlueName)
TG_GREEN=$(out "$ECS_STACK" TargetGroupGreenName)
PROD_LISTENER=$(out "$ECS_STACK" ProdListenerArn)
TEST_LISTENER=$(out "$ECS_STACK" TestListenerArn)
EXEC_ROLE=$(out "$ECS_STACK" TaskExecutionRoleArn)
TASK_ROLE=$(out "$ECS_STACK" TaskRoleArn)
ALB_DNS=$(out "$ECS_STACK" LoadBalancerDns)

echo "==> [4/4] Deploying pipeline stack"
aws cloudformation deploy --region "$REGION" --stack-name "$PIPELINE_STACK" \
  --template-file infrastructure/03-pipeline.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOwner="$GITHUB_OWNER" \
      GitHubRepo="$GITHUB_REPO" \
      CodeStarConnectionArn="$CONNECTION_ARN" \
      EcrRepositoryUri="$REPO_URI" \
      EcsClusterName="$CLUSTER" \
      EcsServiceName="$SERVICE" \
      TargetGroupBlueName="$TG_BLUE" \
      TargetGroupGreenName="$TG_GREEN" \
      ProdListenerArn="$PROD_LISTENER" \
      TestListenerArn="$TEST_LISTENER" \
      TaskExecutionRoleArn="$EXEC_ROLE" \
      TaskRoleArn="$TASK_ROLE"

echo
echo "Done. App URL: http://$ALB_DNS"
echo "Push to GitHub branch to trigger the pipeline."
