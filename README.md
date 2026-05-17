# AWS CI/CD Pipeline Demo

End-to-end demonstration of an AWS-native CI/CD pipeline that builds a
containerized Node.js app and ships it to ECS Fargate with **blue/green**
deployments — all defined in CloudFormation.

## Architecture

```
GitHub (push to main)
        │
        ▼
┌──────────────────┐    ┌───────────────┐    ┌──────────────────────┐
│   CodePipeline   │──▶ │   CodeBuild   │──▶ │   CodeDeploy (ECS)   │
│  (Source stage)  │    │  Test · Build │    │  Blue/Green via ALB  │
└──────────────────┘    │  Push to ECR  │    └──────────┬───────────┘
                        └───────────────┘               │
                                                        ▼
                                              ┌────────────────────┐
                                              │ ECS Fargate Service │
                                              │  behind ALB (TGs:  │
                                              │   blue + green)    │
                                              └────────────────────┘
```

## Layout

| Path | Purpose |
|---|---|
| [app/](app/) | Node.js + Express sample app with `/` and `/health` |
| [app/Dockerfile](app/Dockerfile) | Container image |
| [buildspec.yml](buildspec.yml) | CodeBuild: test → docker build → push → emit artifacts |
| [taskdef.json](taskdef.json) | ECS task definition template (placeholders filled at build time) |
| [appspec.yaml](appspec.yaml) | CodeDeploy ECS AppSpec |
| [infrastructure/00-bootstrap.yaml](infrastructure/00-bootstrap.yaml) | One-shot CodeBuild project that builds the **seed image in AWS** (so no local Docker is needed) |
| [infrastructure/01-ecr.yaml](infrastructure/01-ecr.yaml) | ECR repository |
| [infrastructure/02-network-ecs.yaml](infrastructure/02-network-ecs.yaml) | VPC, ALB (blue+green TGs, prod+test listeners), Fargate cluster + service |
| [infrastructure/03-pipeline.yaml](infrastructure/03-pipeline.yaml) | CodePipeline, CodeBuild, CodeDeploy app + DG |
| [scripts/deploy-infra.sh](scripts/deploy-infra.sh) | One-shot deployment of all three stacks |
| [scripts/teardown.sh](scripts/teardown.sh) | Reverse cleanup |

## Prerequisites

**No Docker required locally.** All container builds happen inside AWS CodeBuild.

1. AWS account + AWS CLI v2 configured (`aws configure`)
2. A GitHub repo containing this project
3. A **CodeStar Connections** connection to GitHub in your AWS account
   (Console → Developer Tools → Settings → Connections → Create connection → GitHub → authorize).
   Copy the resulting ARN.

## Deploy

**Windows / PowerShell:**
```powershell
$env:AWS_REGION="us-east-1"
$env:GITHUB_OWNER="your-gh-username"
$env:GITHUB_REPO="CICD-Pipeline-demo"
$env:CONNECTION_ARN="arn:aws:codestar-connections:us-east-1:123456789012:connection/abcd..."

.\scripts\deploy-infra.ps1
```

**macOS / Linux / WSL:**
```bash
export AWS_REGION=us-east-1
export GITHUB_OWNER=your-gh-username
export GITHUB_REPO=CICD-Pipeline-demo
export CONNECTION_ARN=arn:aws:codestar-connections:us-east-1:123456789012:connection/abcd...

./scripts/deploy-infra.sh
```

The script:
1. Creates the ECR repository
2. Creates a one-shot bootstrap CodeBuild project, zips `app/`, uploads to S3, runs the build → pushes seed `:latest` image to ECR **(no local Docker)**
3. Creates the VPC, ALB, ECS cluster & service
4. Creates the CodePipeline + CodeBuild + CodeDeploy resources

When it finishes it prints the ALB DNS — open `http://<dns>/` to see the app.

## Try the pipeline

Edit [app/server.js](app/server.js) — e.g. change `APP_VERSION` default to `v2`,
or tweak the JSON response — then:

```bash
git commit -am "bump version"
git push origin main
```

Watch the run in **CodePipeline → cicd-demo-pipeline**. CodeDeploy will:

1. Stand up the new task set on the **green** target group
2. Shift production traffic from blue → green
3. Terminate the old (blue) tasks after 5 minutes

You can also hit `http://<alb-dns>:8080/` during deployment to preview the
green target set before traffic shifts.

## Teardown

```bash
./scripts/teardown.sh
```

## Notes

- The pipeline source stage uses **CodeStar Connections** (the modern
  replacement for the deprecated GitHub OAuth source action).
- `DeploymentController: CODE_DEPLOY` on the ECS service is what enables
  blue/green; without it CodePipeline would do a rolling update.
- `buildspec.yml` writes `imageDetail.json`, which CodePipeline's
  `CodeDeployToECS` action uses to replace the `IMAGE_NAME` placeholder
  inside `taskdef.json`.
