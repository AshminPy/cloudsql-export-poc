# Cloud SQL Export Modernization — Management Summary

## The problem

A common database backup path looks like this:

**on-prem VM → IAP tunnel → bastion host → Cloud SQL Auth Proxy → `pg_dump`**

Four separate pieces of infrastructure have to stay up, patched, and correctly
configured just to run a backup. `pg_dump` also runs its query load directly against
the live production database for the whole duration of the dump.

## The proposed alternative

**Cloud SQL → serverless (offloaded) export → Cloud Storage → download**

Google spins up a *temporary* Cloud SQL instance to do the actual export work, so the
production database keeps serving traffic normally the entire time. No bastion, no
tunnel, no proxy.

Two usage modes:
- **Today (manual):** trigger an export, then download it with a plain,
  already-authenticated `gcloud` command. No key files, nothing new to install.
- **Future (automated):** Cloud Scheduler triggers a small Cloud Workflows job that
  starts the export with a unique timestamped filename and waits for it to actually
  finish, then an on-prem job downloads it on its own schedule.

## What was actually tested (not just planned)

A disposable proof-of-concept was built and torn down in a test environment: a small
test database, a real export/download/restore cycle, and independent verification at
every step.

- Deployed a temporary Cloud SQL Postgres instance, storage bucket, and
  least-privilege IAM with Terraform.
- Seeded it with tables, an index, a view, functions, a trigger, and a genuine stored
  procedure — chosen because those are the object types most likely to get dropped by
  a database export tool.
- Ran the export twice and confirmed both produced distinct, non-colliding files.
- Downloaded the result with a single `gcloud storage cp` — no bastion, no tunnel, no
  proxy, no key file.
- Restored the download into a clean database and checked every table, every row, the
  view, the functions, the trigger, and explicitly **called** the stored procedure to
  confirm it still works as code, not just that its definition survived as text.
- Triggered the Scheduler → Workflow automation path and confirmed it actually waits
  for the export to finish before considering the run complete.
- Destroyed every resource afterward and independently confirmed nothing was left
  running.

## The one caveat worth flagging

Google's own documentation states that this export mode "does not contain triggers or
stored procedures." **This test found the opposite** — every object type tried
survived intact, including an explicit `CALL` of the stored procedure that correctly
updated a row. That's a genuinely useful result, but it is specific to the schema
tested here. **Before switching a real production database, the same test should be
re-run against that database's actual triggers and procedures** — the documentation
and this measurement disagree, so only a direct test on the real schema resolves it
for that database. The test takes well under an hour.

## What this gets us

- Fewer moving parts that can fail — no bastion, tunnel, or proxy process to keep
  patched and running.
- Zero backup-related load on the production database during export.
- Managed, trackable operations instead of a shell session that can silently drop
  partway through.

## What it costs

Cost is driven mainly by the **primary instance's disk size**, not by how much data is
actually exported — that's a real, documented Google Cloud billing detail worth
knowing before scheduling frequent exports on a large instance. Storage, transfer, and
operations costs scale with the real database and how often it's exported; sizing
those against the real workload is a five-minute exercise once this is adopted, not
something to estimate in the abstract.

## Recommendation

Adopt this pattern for the next backup/export redesign, with one prerequisite: run the
validation test (seed → export → download → restore → compare, including the stored
procedure check) against a copy of the real target database first, to confirm the
result holds for the actual schema.

## What's included

A reusable Terraform module that can either spin up a fresh test instance or point at
an *existing* Cloud SQL instance in read-only mode — never creating, modifying, or
deleting it — to run this same validation against a real database. Full technical
write-up, including every limitation found, is in `README.md` in the same repository.
