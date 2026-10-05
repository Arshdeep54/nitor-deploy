#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: ecs-release.sh <git-tag e.g. v0.1.5>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
set -a && source "$repo_root/deploy/ecs/production.env" && set +a

release_api="${RELEASE_API:-1}"
release_agent="${RELEASE_AGENT:-1}"
run_migrations="${RUN_MIGRATIONS:-1}"

registry="${ECR_REGISTRY}"
cluster="${ECS_CLUSTER}"

strip_task_def() {
  jq 'del(
    .taskDefinitionArn,
    .revision,
    .status,
    .requiresAttributes,
    .compatibilities,
    .registeredAt,
    .registeredBy
  )'
}

register_migrate_task() {
  local image="${registry}/tracker/migrate:${tag}"
  aws ecs describe-task-definition --task-definition "${ECS_MIGRATE_TASK_FAMILY}" --region "$AWS_REGION" \
    --query taskDefinition | strip_task_def | jq \
    --arg image "$image" \
    --arg host "$RDS_HOST" \
    --arg user "$RDS_USER" \
    --arg db "$RDS_DATABASE" \
    '
      .containerDefinitions[0].image = $image
      | .containerDefinitions[0].environment = [
          {name: "PGHOST", value: $host},
          {name: "PGUSER", value: $user},
          {name: "PGDATABASE", value: $db}
        ]
      # the image's own entrypoint (/run.sh) runs the migrations and reads MIGRATE_TARGET; an entryPoint/command override copied forward from an
      # older revision ("/bin/sh" with the script text and no -c) made the task fail with "can't open 'set -eu; ...'"
      | del(.containerDefinitions[0].entryPoint, .containerDefinitions[0].command)
    ' > /tmp/migrate-task.json
  aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json file:///tmp/migrate-task.json \
    --query 'taskDefinition.taskDefinitionArn' --output text
}

run_migrate_task() {
  local task_def_arn="$1"
  local migrate_target="$2"
  local subnet_csv="${ECS_SUBNETS}"
  local sg_csv="${ECS_SECURITY_GROUPS}"
  IFS=',' read -r -a subnets <<< "$subnet_csv"
  IFS=',' read -r -a security_groups <<< "$sg_csv"
  local subnet_json
  subnet_json="$(printf '%s\n' "${subnets[@]}" | jq -R . | jq -s .)"
  local sg_json
  sg_json="$(printf '%s\n' "${security_groups[@]}" | jq -R . | jq -s .)"
  local network
  network="$(jq -n \
    --argjson subnets "$subnet_json" \
    --argjson securityGroups "$sg_json" \
    --arg assignPublicIp "$ECS_ASSIGN_PUBLIC_IP" \
    '{awsvpcConfiguration: {subnets: $subnets, securityGroups: $securityGroups, assignPublicIp: $assignPublicIp}}')"
  local overrides
  overrides="$(jq -n --arg target "$migrate_target" \
    '{containerOverrides: [{name: "migrate", environment: [{name: "MIGRATE_TARGET", value: $target}]}]}')"
  local task_arn
  task_arn="$(aws ecs run-task --region "$AWS_REGION" \
    --cluster "$cluster" \
    --launch-type FARGATE \
    --task-definition "$task_def_arn" \
    --network-configuration "$network" \
    --overrides "$overrides" \
    --query 'tasks[0].taskArn' --output text)"
  if [ -z "$task_arn" ] || [ "$task_arn" = "None" ]; then
    echo "ecs run-task did not return a task arn" >&2
    exit 1
  fi
  echo "migrate ${migrate_target}: ${task_arn}"
  aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$cluster" --tasks "$task_arn"
  local exit_code
  exit_code="$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$cluster" --tasks "$task_arn" \
    --query 'tasks[0].containers[0].exitCode' --output text)"
  if [ "$exit_code" != "0" ]; then
    echo "migrate ${migrate_target} failed with exit code ${exit_code}" >&2
    exit 1
  fi
}

roll_service() {
  local family="$1"
  local service="$2"
  local container_name="$3"
  local image_name="$4"
  local image="${registry}/${image_name}:${tag}"
  aws ecs describe-task-definition --task-definition "$family" --region "$AWS_REGION" \
    --query taskDefinition | strip_task_def | jq \
    --arg image "$image" \
    --arg container "$container_name" \
    '
      .containerDefinitions |= map(
        if .name == $container then .image = $image else . end
      )
    ' > /tmp/service-task.json
  local new_arn
  new_arn="$(aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json file:///tmp/service-task.json \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
  aws ecs update-service --region "$AWS_REGION" \
    --cluster "$cluster" \
    --service "$service" \
    --task-definition "$new_arn" \
    --force-new-deployment \
    --query 'service.serviceName' --output text
  aws ecs wait services-stable --region "$AWS_REGION" --cluster "$cluster" --services "$service"
}

migrate_task_def=""
if [ "$run_migrations" = "1" ]; then
  migrate_task_def="$(register_migrate_task)"
  run_migrate_task "$migrate_task_def" public
fi

if [ "$release_api" = "1" ]; then
  roll_service "${ECS_API_TASK_FAMILY}" "${ECS_API_SERVICE}" api tracker/api
fi

if [ "$run_migrations" = "1" ]; then
  if [ -z "$migrate_task_def" ]; then
    migrate_task_def="$(register_migrate_task)"
  fi
  run_migrate_task "$migrate_task_def" agent
fi

if [ "$release_agent" = "1" ]; then
  roll_service "${ECS_AGENT_TASK_FAMILY}" "${ECS_AGENT_SERVICE}" agent tracker/agent
fi

echo "release ${tag} complete"
