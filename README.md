# nitor-deploy

ECS rollout and AWS operational config for [nitor](https://github.com/Arshdeep54/nitor). Application images are built in the app repo and pushed to ECR on `v*` tags; this repo runs migrations and updates Fargate services.

## Flow

1. Tag the app repo (`git tag v0.1.5 && git push origin v0.1.5`) — CI builds and pushes `tracker/api`, `tracker/agent`, and `tracker/migrate` to ECR.
2. Either wait for **repository_dispatch** (if `NITOR_DEPLOY_DISPATCH_TOKEN` is set on the app repo) or run **Deploy ECS** here manually with the same tag.

Order: public migrations → API service → agent migrations → agent service.

## One-time AWS setup

Attach ECS permissions to the GitHub OIDC role (if not already):

```bash
aws iam put-role-policy \
  --role-name github-actions-tracker-deploy \
  --policy-name github-actions-ecs-deploy \
  --policy-document file://deploy/ecs/github-actions-ecs-policy.json
```

Extend the role **trust policy** so OIDC allows this repository (keep the existing `nitor` app repo entry):

```json
"token.actions.githubusercontent.com:sub": "repo:Arshdeep54/nitor-deploy:ref:refs/heads/main"
```

Use a separate environment or branch condition for `workflow_dispatch` if you prefer.

## GitHub secrets (app repo `nitor`)

| Secret | Purpose |
|--------|---------|
| `NITOR_DEPLOY_DISPATCH_TOKEN` | Fine-grained PAT with **Contents: Read and write** on `nitor-deploy` only; triggers deploy after ECR push |

Without this secret, deploy still works via **Actions → Deploy ECS → Run workflow** on this repo.

## Local rollout

```bash
cp deploy/ecs/production.env.example deploy/ecs/production.env
# edit production.env
RELEASE_API=1 RELEASE_AGENT=1 RUN_MIGRATIONS=1 ./scripts/ecs-release.sh v0.1.5
```

## Config

Edit `deploy/ecs/production.env` (committed for this private/single-tenant setup) or use `production.env.example` as a template for forks.
