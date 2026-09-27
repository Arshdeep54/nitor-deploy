#!/usr/bin/env bash
set -euo pipefail

region="${AWS_REGION:-ap-south-1}"
account_id="${AWS_ACCOUNT_ID:-546702454248}"
function_name="${ECR_DISPATCH_LAMBDA_NAME:-tracker-ecr-github-dispatch}"
rule_name="${ECR_DISPATCH_RULE_NAME:-tracker-ecr-migrate-push}"
role_name="${ECR_DISPATCH_ROLE_NAME:-tracker-ecr-github-dispatch}"
secret_name="${GITHUB_TOKEN_SECRET_NAME:-tracker/github-dispatch-token}"
migrate_repo="${ECR_MIGRATE_REPOSITORY:-tracker/migrate}"
github_repo="${GITHUB_DISPATCH_REPO:-Arshdeep54/nitor-deploy}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
zip_path="/tmp/${function_name}.zip"
role_arn="arn:aws:iam::${account_id}:role/${role_name}"

if ! aws secretsmanager describe-secret --secret-id "$secret_name" --region "$region" >/dev/null 2>&1; then
  echo "create Secrets Manager secret ${secret_name} with a GitHub PAT (repo scope: ${github_repo} contents write)" >&2
  echo "  aws secretsmanager create-secret --name ${secret_name} --secret-string 'ghp_...' --region ${region}" >&2
  exit 1
fi

trust='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
  aws iam create-role --role-name "$role_name" --assume-role-policy-document "$trust" >/dev/null
fi

policy="$(jq -n --arg secret "arn:aws:secretsmanager:${region}:${account_id}:secret:${secret_name}*" '
{
  Version: "2012-10-17",
  Statement: [
    {
      Effect: "Allow",
      Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      Resource: "arn:aws:logs:*:*:*"
    },
    {
      Effect: "Allow",
      Action: ["secretsmanager:GetSecretValue"],
      Resource: $secret
    }
  ]
}')"

aws iam put-role-policy \
  --role-name "$role_name" \
  --policy-name "${role_name}-policy" \
  --policy-document "$policy" >/dev/null

(cd "$script_dir/lambda" && zip -q -j "$zip_path" handler.py)

env_vars="Variables={GITHUB_TOKEN_SECRET_ID=${secret_name},GITHUB_DISPATCH_REPO=${github_repo},ECR_MIGRATE_REPOSITORY=${migrate_repo}}"

if aws lambda get-function --function-name "$function_name" --region "$region" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$function_name" --zip-file "fileb://${zip_path}" --region "$region" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$function_name" --region "$region"
  aws lambda update-function-configuration \
    --function-name "$function_name" \
    --role "$role_arn" \
    --runtime python3.12 \
    --handler handler.handler \
    --timeout 30 \
    --environment "$env_vars" \
    --region "$region" >/dev/null
else
  aws lambda create-function \
    --function-name "$function_name" \
    --runtime python3.12 \
    --role "$role_arn" \
    --handler handler.handler \
    --timeout 30 \
    --zip-file "fileb://${zip_path}" \
    --environment "$env_vars" \
    --region "$region" >/dev/null
fi

lambda_arn="$(aws lambda get-function --function-name "$function_name" --region "$region" --query 'Configuration.FunctionArn' --output text)"

event_pattern="$(jq -n --arg repo "$migrate_repo" '
{
  source: ["aws.ecr"],
  "detail-type": ["ECR Image Action"],
  detail: {
    "action-type": ["PUSH"],
    result: ["SUCCESS"],
    "repository-name": [$repo]
  }
}')"

rule_arn="$(aws events put-rule \
  --name "$rule_name" \
  --event-pattern "$event_pattern" \
  --state ENABLED \
  --region "$region" \
  --query RuleArn --output text)"

aws events put-targets \
  --rule "$rule_name" \
  --region "$region" \
  --targets "Id"="1","Arn"="$lambda_arn" >/dev/null

aws lambda add-permission \
  --function-name "$function_name" \
  --region "$region" \
  --statement-id "${rule_name}-invoke" \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$rule_arn" \
  2>/dev/null || true

echo "ECR push on ${migrate_repo} (tags v*) will dispatch ${github_repo} via Lambda ${function_name}"
