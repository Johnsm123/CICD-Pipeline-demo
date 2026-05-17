# PowerShell deployment script - no Docker required locally.
# CodeBuild builds the seed image in AWS.
#
# Usage:
#   $env:AWS_REGION="us-east-1"
#   $env:GITHUB_OWNER="your-gh-username"
#   $env:GITHUB_REPO="CICD-Pipeline-demo"
#   $env:CONNECTION_ARN="arn:aws:codestar-connections:..."
#   .\scripts\deploy-infra.ps1

$ErrorActionPreference = "Stop"

$Region        = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$EcrStack      = "cicd-demo-ecr"
$BootstrapStack= "cicd-demo-bootstrap"
$EcsStack      = "cicd-demo-ecs"
$PipelineStack = "cicd-demo-pipeline"

foreach ($v in @("GITHUB_OWNER","GITHUB_REPO","CONNECTION_ARN")) {
    if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue)) {
        throw "Environment variable $v is not set"
    }
}

function Get-StackOutput([string]$Stack, [string]$Key) {
    aws cloudformation describe-stacks --region $Region --stack-name $Stack `
        --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue" --output text
}

Write-Host "==> [1/4] Deploying ECR stack" -ForegroundColor Cyan
aws cloudformation deploy --region $Region --stack-name $EcrStack `
    --template-file infrastructure/01-ecr.yaml --capabilities CAPABILITY_NAMED_IAM
if ($LASTEXITCODE -ne 0) { throw "ECR stack deploy failed" }

$RepoUri = Get-StackOutput $EcrStack "RepositoryUri"
Write-Host "ECR repo URI: $RepoUri"

Write-Host "==> [2/4] Deploying bootstrap stack (seed CodeBuild project)" -ForegroundColor Cyan
aws cloudformation deploy --region $Region --stack-name $BootstrapStack `
    --template-file infrastructure/00-bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides EcrRepositoryUri=$RepoUri
if ($LASTEXITCODE -ne 0) { throw "Bootstrap stack deploy failed" }

$SeedBucket  = Get-StackOutput $BootstrapStack "SeedBucketName"
$SeedProject = Get-StackOutput $BootstrapStack "SeedProjectName"

Write-Host "==> Zipping app source and uploading to s3://$SeedBucket/source.zip"
$ZipPath = Join-Path $env:TEMP "cicd-demo-source.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
# Include the app/ folder (Dockerfile lives inside it) at the zip root
Compress-Archive -Path "app" -DestinationPath $ZipPath -Force
aws s3 cp $ZipPath "s3://$SeedBucket/source.zip" --region $Region
if ($LASTEXITCODE -ne 0) { throw "S3 upload failed" }

Write-Host "==> Running seed CodeBuild (builds & pushes :latest image in the cloud)"
$BuildId = aws codebuild start-build --region $Region --project-name $SeedProject `
    --query 'build.id' --output text
Write-Host "Seed build started: $BuildId"

# Poll until done
do {
    Start-Sleep -Seconds 10
    $Status = aws codebuild batch-get-builds --region $Region --ids $BuildId `
        --query 'builds[0].buildStatus' --output text
    Write-Host "  build status: $Status"
} while ($Status -eq "IN_PROGRESS")

if ($Status -ne "SUCCEEDED") {
    throw "Seed build failed with status: $Status. Check CodeBuild console for logs."
}
Write-Host "Seed image pushed to ECR." -ForegroundColor Green

Write-Host "==> [3/4] Deploying ECS stack" -ForegroundColor Cyan
aws cloudformation deploy --region $Region --stack-name $EcsStack `
    --template-file infrastructure/02-network-ecs.yaml --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides EcrRepositoryUri=$RepoUri
if ($LASTEXITCODE -ne 0) { throw "ECS stack deploy failed" }

$Cluster      = Get-StackOutput $EcsStack "ClusterName"
$Service      = Get-StackOutput $EcsStack "ServiceName"
$TgBlue       = Get-StackOutput $EcsStack "TargetGroupBlueName"
$TgGreen      = Get-StackOutput $EcsStack "TargetGroupGreenName"
$ProdListener = Get-StackOutput $EcsStack "ProdListenerArn"
$TestListener = Get-StackOutput $EcsStack "TestListenerArn"
$ExecRole     = Get-StackOutput $EcsStack "TaskExecutionRoleArn"
$TaskRole     = Get-StackOutput $EcsStack "TaskRoleArn"
$AlbDns       = Get-StackOutput $EcsStack "LoadBalancerDns"

Write-Host "==> [4/4] Deploying pipeline stack" -ForegroundColor Cyan
aws cloudformation deploy --region $Region --stack-name $PipelineStack `
    --template-file infrastructure/03-pipeline.yaml --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        GitHubOwner=$env:GITHUB_OWNER `
        GitHubRepo=$env:GITHUB_REPO `
        CodeStarConnectionArn=$env:CONNECTION_ARN `
        EcrRepositoryUri=$RepoUri `
        EcsClusterName=$Cluster `
        EcsServiceName=$Service `
        TargetGroupBlueName=$TgBlue `
        TargetGroupGreenName=$TgGreen `
        ProdListenerArn=$ProdListener `
        TestListenerArn=$TestListener `
        TaskExecutionRoleArn=$ExecRole `
        TaskRoleArn=$TaskRole
if ($LASTEXITCODE -ne 0) { throw "Pipeline stack deploy failed" }

Write-Host ""
Write-Host "Done. App URL: http://$AlbDns" -ForegroundColor Green
Write-Host "Push a commit to GitHub branch '$($env:GITHUB_BRANCH ?? 'main')' to trigger the pipeline."
