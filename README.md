# legacy-to-cloud-migration

Every company has one: the internal tool that started on someone's laptop,
moved to a VM nobody owns, and quietly became load-bearing. This repo is
the full story of taking one of those apps to AWS — containerized, on real
infrastructure, shipped through a real pipeline.

The app is a tiny inventory tracker. The point was never the app. The point
is everything around it.

This is a portfolio reference implementation I built from scratch. Not from
any employer.

## the before and after

`legacy-app/` is the "before": Flask + SQLite, config hardcoded at the top
of the file, `debug=True`, no health endpoint. It works on one server and
dies everywhere else.

`app/` is the same app after migration. Same routes, same behavior, but:

- all config comes from environment variables
- Postgres via `DATABASE_URL` (SQLite still works for local dev)
- `/healthz` endpoint so the load balancer knows it's alive
- structured JSON logs to stdout — CloudWatch picks them up, no agent
- runs behind gunicorn as a non-root user

The diff between those two folders is the whole migration in miniature.

## the infrastructure

`terraform/` builds the AWS side, split into modules with `dev` and `prod`
environments:

- VPC with public/private subnets across 2 AZs, NAT gateways
- ALB in the public subnets, health-checking `/healthz`
- ECS Fargate running the container from ECR (immutable SHA tags)
- RDS Postgres 16 in the private subnets, encrypted, password in Secrets
  Manager — never in Terraform state
- CloudWatch log group + two alarms (unhealthy ALB targets, ECS task
  count), SNS topic for notifications
- IAM roles with least privilege: the task execution role can pull the
  image, write logs, and read one secret. Nothing else.

Dev is cheap (1 task, single-AZ RDS, no deletion protection). Prod is
real (2 tasks, Multi-AZ, deletion protection on).

## the pipeline

`.github/workflows/` — see `pipeline/README.md` for the full design:

1. **CI** on every push: pytest → Docker build → Trivy scan. Fails on
   HIGH/CRITICAL vulnerabilities. CI has no AWS credentials — it can't
   deploy anything, ever.
2. **Deploy to dev**: automatic. Build, push to ECR (tag = git SHA),
   rolling ECS deploy, smoke test against the ALB.
3. **Deploy to prod**: manual. You trigger it with an image SHA, a
   required reviewer approves, Terraform pins the tag, waits for steady
   state, smoke tests.

No long-lived AWS keys anywhere — the workflows use OIDC to assume deploy
roles.

## the runbook

`docs/migration-runbook.md` is the human half: the assessment checklist I
wish someone had handed me, the strangler-fig approach for bigger
monoliths, the SQLite → RDS data migration strategy, and cutover/rollback
plans where every step is reversible.

`scripts/db-migrate.sh` does the actual data move (dump to CSV, COPY into
a staging table, idempotent insert, row-count verification).
`scripts/smoke-test.sh` is the post-deploy check the pipeline gates on.

## try it locally

You don't need AWS for most of this:

```bash
# run the tests
make test

# run the migrated app against SQLite
make smoke-local
# curl localhost:5000/healthz

# app + real Postgres, the way ECS runs it (needs Docker)
docker compose -f container/docker-compose.yml up
```

For the AWS parts:

```bash
cd terraform/envs/dev
# fill in terraform.tfvars (see the .example pattern), then:
terraform init
terraform plan
terraform apply -var "image_tag=<git-sha>"
```

## repo layout

```
legacy-app/        the "before" — Flask + SQLite, hardcoded config
app/               the "after" — env config, Postgres, /healthz, JSON logs
tests/             pytest suite for the migrated app
container/         multi-stage Dockerfile, .dockerignore, docker-compose
terraform/
  modules/         vpc, alb, ecr, ecs, rds, monitoring
  envs/dev         cheap dev stack
  envs/prod        real prod stack (Multi-AZ, deletion protection)
pipeline/          pipeline design doc (workflows live in .github/)
.github/workflows/ ci, deploy-dev, deploy-prod (manual approval gate)
scripts/           db-migrate.sh, smoke-test.sh
docs/              migration-runbook.md
```

## license

MIT.
