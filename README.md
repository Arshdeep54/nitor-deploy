# nitor-deploy

ECS rollout and AWS operational config for [nitor](https://github.com/Arshdeep54/nitor). The app repo builds and pushes `tracker/api`, `tracker/agent`, and `tracker/migrate` to ECR on `v*` tags; this repo runs migrations and updates Fargate services.

## How deploy gets triggered (pick one or use both)

| Method | Professional pattern | Setup |
|--------|----------------------|--------|
| **ECR push → EventBridge → Lambda → GitHub** | AWS-native; no secret on the app repo | `deploy/aws/ecr-github-dispatch/bootstrap.sh` (recommended) |
| **App CI → `repository_dispatch`** | GitHub-native; fires right after CI push, not per-ECR event | `NITOR_DEPLOY_DISPATCH_TOKEN` on the nitor repo |
| **Manual** | Rollback / hotfix | Actions → **Deploy ECS** → enter tag |

**Why listen on `tracker/migrate`?** The app workflow pushes api, then agent, then **migrate** last. A successful push of `tracker/migrate:v0.1.5` means all three images for that tag are in ECR.

Deploy order: public migrations → API service → agent migrations → agent service.

## ECR → GitHub (recommended)

1. Create a fine-grained GitHub PAT with **Contents: Read and write** on **this repo only**.

2. Store it in Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name tracker/github-dispatch-token \
  --secret-string 'github_pat_...' \
  --region ap-south-1
```

3. Install the EventBridge rule and Lambda:

```bash
chmod +x deploy/aws/ecr-github-dispatch/bootstrap.sh
./deploy/aws/ecr-github-dispatch/bootstrap.sh
```

4. Tag the app repo as usual. When ECR receives `tracker/migrate:v*`, **Deploy ECS** runs here automatically.

## One-time AWS setup (ECS deploy job)

Attach ECS permissions to the GitHub OIDC role:

```bash
aws iam put-role-policy \
  --role-name github-actions-tracker-deploy \
  --policy-name github-actions-ecs-deploy \
  --policy-document file://deploy/ecs/github-actions-ecs-policy.json
```

Extend the role **trust policy** for OIDC (keep the nitor app repo entry):

- `repo:Arshdeep54/nitor-deploy:ref:refs/heads/main`

## GitHub secret (optional, app repo `nitor`)

| Secret | Purpose |
|--------|---------|
| `NITOR_DEPLOY_DISPATCH_TOKEN` | Same PAT as above; app CI calls `repository_dispatch` after ECR push instead of waiting for EventBridge |

If both ECR Lambda and app dispatch are enabled, **concurrency** on the workflow dedupes by tag (one rollout per version).

## Local rollout

```bash
cp deploy/ecs/production.env.example deploy/ecs/production.env
RELEASE_API=1 RELEASE_AGENT=1 RUN_MIGRATIONS=1 ./scripts/ecs-release.sh v0.1.5
```

## Config

Edit `deploy/ecs/production.env` or use `production.env.example` for forks.
