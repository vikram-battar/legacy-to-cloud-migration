#!/usr/bin/env bash
# rollback.sh — roll an ECS service back to its previous task definition.
#
# Usage: ./scripts/rollback.sh <cluster> <service>
#
# How it works: reads the service's current task definition, subtracts one
# from the revision number, and updates the service to that revision. Then
# waits for the rollout to settle. This is the "oh no" button for a bad
# deploy — the pipeline calls the deploy path, humans call this one.
#
# Needs: aws CLI with ecs:DescribeServices, ecs:DescribeTaskDefinition,
# ecs:UpdateService.
set -euo pipefail

CLUSTER="${1:?usage: rollback.sh <cluster> <service>}"
SERVICE="${2:?usage: rollback.sh <cluster> <service>}"

echo "==> reading current task definition for $SERVICE"
CURRENT_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)
echo "    current: $CURRENT_ARN"

# arn:aws:ecs:region:acct:task-definition/family:revision
FAMILY=$(echo "$CURRENT_ARN" | sed 's|.*/||; s|:.*||')
REVISION=$(echo "$CURRENT_ARN" | sed 's|.*:||')

if ! [[ "$REVISION" =~ ^[0-9]+$ ]] || [ "$REVISION" -le 1 ]; then
  echo "cannot roll back: current revision is $REVISION (nothing older to go to)" >&2
  exit 1
fi

PREV_ARN="${CURRENT_ARN%:*}:$((REVISION - 1))"
echo "==> checking previous revision exists: $PREV_ARN"
aws ecs describe-task-definition --task-definition "$PREV_ARN" --query 'taskDefinition.revision' --output text >/dev/null

echo "==> updating $SERVICE to $PREV_ARN"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$PREV_ARN" --output text >/dev/null

echo "==> waiting for rollout to settle"
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
echo "OK — $SERVICE is on $PREV_ARN"
