# Migration runbook: legacy inventory app → AWS

This is the human half of the migration. The code shows the "after";
this doc covers the decisions that got it there. Written as a checklist
you could actually run through on a real project.

## 1. Assessment — inventory before you touch anything

Before writing a line of Terraform, answer these:

- [ ] **What does the app actually do?** List every route/endpoint and who
      calls it. (Here: 5 routes, one internal consumer. Took 20 minutes.)
- [ ] **Where does state live?** Files on disk? A local database? Ours was
      SQLite in the app directory — the single biggest migration risk.
- [ ] **What config is hardcoded?** Ports, paths, credentials, feature
      flags. Every hardcoded value becomes an environment variable.
- [ ] **What are the dependencies?** `pip freeze` the world. Ours was just
      Flask — easy. Yours might have a library from 2016 with no wheels.
- [ ] **How is it deployed today?** `python app.py` on a VM? systemd?
      A cron job that restarts it when it dies? Write it down.
- [ ] **What's the blast radius?** Who notices if it's down for an hour?
      This sets your cutover strategy (big bang vs. gradual).
- [ ] **Are there secrets in the repo?** Check now, rotate them regardless.

Rule of thumb: if the assessment takes less than a day for a small app,
you're probably missing something. Ask where the backups are.

## 2. Containerize first, cloud second

Don't change the app and the infrastructure in the same step.

1. Write the Dockerfile for the app **as-is** (the legacy version).
   Get it running locally with `docker build` + `docker run`.
2. Add docker-compose with Postgres. The app still talks to SQLite here —
   the point is proving the container works, not changing behavior.
3. Only then refactor the app to read `DATABASE_URL` and expose `/healthz`
   (that's `app/` in this repo). Run the test suite after every change.

Each step is independently verifiable. If step 3 breaks, steps 1–2 still work.

## 3. The strangler-fig approach (for when the monolith grows)

This app is small enough to lift whole. When it isn't, don't rewrite it —
strangle it:

1. Put the ALB (or API Gateway) in front of the monolith first.
2. Build the new service for ONE route (say, `POST /items`).
3. Route just that path to the new service at the load balancer.
4. Repeat route by route until the monolith serves nothing.
5. Delete the monolith. Have a small celebration.

The monolith never goes down during this. Each route migration is
independently deployable and rollback-able.

## 4. Data migration: SQLite → RDS

For this app's size, the honest approach is dump-and-load —
`scripts/db-migrate.sh` does exactly this:

1. Export SQLite → CSV, `COPY` into a Postgres staging table.
2. `INSERT ... ON CONFLICT DO NOTHING` into the real table (re-runnable).
3. Fix the sequence (`setval`) so new inserts don't collide.
4. **Verify row counts match** before cutover. The script exits non-zero
   on mismatch and the pipeline gates on it.

For anything bigger or live during migration:
- Use AWS DMS with ongoing replication instead of a one-shot dump.
- Plan a write-freeze window: stop writes to the old DB, run the final
  sync, flip `DATABASE_URL`, verify, reopen writes.
- Keep the old database read-only (not deleted) for one full business
  cycle as a fallback.

## 5. Cutover plan

1. Deploy the full stack to **dev** via the pipeline. Run the smoke test.
2. Run `db-migrate.sh` against the dev RDS. Verify counts.
3. Deploy to **prod** (manual approval gate). Point DNS at the new ALB
   with a short TTL — 60 seconds, set it a day early.
4. Watch the two CloudWatch alarms for 30 minutes: unhealthy targets
   and ECS task count. If either fires, see rollback.
5. After 24h clean, raise the DNS TTL back up.

## 6. Rollback plan

Every change here is reversible, and that's deliberate:

- **Bad deploy:** redeploy the previous image SHA (ECR tags are immutable,
  the old image is still there). One pipeline run, ~3 minutes.
- **Bad data migration:** the old SQLite file is untouched — the app can
  run against it again while you investigate. (For prod: restore the RDS
  snapshot taken before cutover.)
- **Bad DNS cutover:** flip the DNS record back. With a 60s TTL, traffic
  moves back within minutes.
- **Bad Terraform change:** `terraform apply` the previous committed
  state. Infra code is versioned like app code for exactly this reason.

The theme: never destroy the old thing until the new thing has proven
itself. The legacy VM stays up (stopped, snapshotted) for 30 days after
cutover, then it gets deleted and nobody misses it.
