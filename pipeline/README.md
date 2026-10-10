# Pipeline

How code gets from a commit to prod. The workflow files live in
`.github/workflows/` at the repo root (that's where GitHub Actions
actually runs them); this doc explains the design.

## The flow

```
push to main
    │
    ▼
┌─────────┐
│   CI    │  build → pytest → Trivy scan (HIGH/CRITICAL fails the build)
└────┬────┘  nothing is pushed to ECR here — CI only proves it's safe
     │
     ▼
┌──────────────┐
│ deploy → dev │  automatic: build, push to ECR (tag = git SHA),
└──────┬───────┘  ECS rolling deploy, smoke test against the ALB
       │
       │  manual gate: GitHub `prod` environment, required reviewer
       ▼
┌───────────────┐
│ deploy → prod │  triggered by hand with an image SHA, terraform pins
└───────────────┘  the tag, waits for steady state, smoke tests
```

## Design decisions

- **Immutable tags.** Every image is tagged with the git SHA, ECR is set to
  `IMMUTABLE`, and old tags are never overwritten. A deploy is just naming
  a SHA. Rollback is naming the previous SHA.
- **CI doesn't deploy.** The build/test/scan workflow has no AWS
  credentials at all. You can't accidentally ship from a test run.
- **No long-lived AWS keys.** All three workflows use OIDC
  (`id-token: write`) to assume a deploy role. There are no access keys in
  GitHub Secrets to leak.
- **Prod needs a human.** The `prod` environment has required reviewers.
  The workflow can't run without an approval, and the approval names the
  exact image SHA being shipped.
- **Rolling deploys by default.** ECS replaces tasks gradually behind the
  ALB. See the blue/green note in `deploy-prod.yml` for when to upgrade
  to CodeDeploy traffic shifting.

## What you'd add next (not included, on purpose)

- `terraform plan` as a PR check on the infra code
- Slack notification on deploy success/failure
- A staging environment between dev and prod
