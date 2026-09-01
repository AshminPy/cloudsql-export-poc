# Cloud SQL Export Modernization POC

Replaces a `pg_dump`-over-bastion backup pipeline with a serverless, managed export
path: Cloud SQL's offloaded export straight to Cloud Storage, downloaded from there.

Terraform is reusable as-is against a new test instance or an existing Cloud SQL
instance (read-only lookup, never modified) -- see [Deployment instructions](#8-deployment-instructions).

## 1. Problem

A common Cloud SQL backup workflow looks like this:

```
on-prem VM -> IAP tunnel -> bastion host -> Cloud SQL Auth Proxy -> pg_dump
```

Every hop is infrastructure that has to stay up, patched, and correctly configured
just to run a backup: the bastion host, the IAP tunnel, the proxy process, and a
long-lived network path into the database's network. `pg_dump` also runs its query
load directly against the primary instance for the full duration of the dump.

## 2. Current architecture

```
┌──────────────┐     ┌─────┐     ┌─────────┐     ┌──────────────────┐     ┌─────────┐
│ On-prem VM   │────▶│ IAP │────▶│ Bastion │────▶│ Cloud SQL Proxy  │────▶│ pg_dump │
│              │     │     │     │  host   │     │ (local tunnel)   │     │         │
└──────────────┘     └─────┘     └─────────┘     └──────────────────┘     └─────────┘
```

Every hop is a failure surface, a patch burden, and a credential/network path.

## 3. Proposed architecture

Two modes, deliberately kept separate: what's tested and usable **today**, and what a
**future**, fully-scheduled version looks like once a real on-prem identity provider
is available.

### Mode A -- today / manual

```
Cloud SQL -> offloaded export -> GCS -> gcloud storage cp (your own gcloud login)
```

You trigger the export once (`gcloud sql export ... --offload`), then download it
yourself with a plain `gcloud storage cp` using your normal authenticated account. No
bastion, no tunnel, no proxy, no key file. See [Manual download](#manual-download--do-this-today).

### Mode B -- future / automated

```
Cloud Scheduler -> Cloud Workflows -> offloaded Cloud SQL export (timestamped GCS
object) -> on-prem systemd timer -> download via Workload Identity Federation
```

Cloud Scheduler triggers a Cloud Workflows execution, which starts the export with a
unique, timestamped object name and polls the operation until it actually finishes --
rather than guessing a fixed wait. This repo builds and tests the Scheduler ->
Workflow -> Cloud SQL -> GCS half of Mode B. The on-prem download side is documented,
not deployed here, because unattended authentication needs Workload Identity
Federation against a real identity provider this environment doesn't have -- see
[Future on-prem automation](#future-on-prem-automation).

No bastion, no IAP, no Cloud SQL Proxy, no long-running SSH tunnel, and no query load
against the primary during export -- Google spins up a **temporary** Cloud SQL
instance to run the export, per
[Google's documentation on serverless exports](https://cloud.google.com/blog/products/databases/introducing-cloud-sql-serverless-exports):
"With serverless export, Cloud SQL creates a separate, temporary instance to offload
the export operation," so you "can export data... without any impact on performance or
risk to your production workloads." Trade-off, same source: it takes longer than a
standard export, because provisioning that temporary instance takes time.

## 4. Why the proposed architecture is more reliable

- **Fewer moving parts to fail.** No bastion host, IAP tunnel, or Cloud SQL Proxy
  process to keep patched and running.
- **No credential/network surface on the database's own network.** The on-prem side
  only ever needs outbound HTTPS to `storage.googleapis.com` -- never a connection to
  the database itself.
- **Zero query load on the primary during export.** The offloaded export runs on a
  temporary instance Google provisions and tears down automatically.
- **Managed, trackable operations** instead of a shell process whose failure mode is
  "the SSH session dropped partway through."

## 5. DB performance considerations

Offloaded (`--offload`) export takes measurably longer wall-clock time than a
non-offloaded export, because Google provisions a temporary instance first
([source](https://cloud.google.com/blog/products/databases/introducing-cloud-sql-serverless-exports)).
For a scheduled batch job this is a non-issue; for a low-RTO need it's worth
benchmarking against your real database size (see [Validation evidence](#10-validation-evidence)
for this repo's own measured timings on a tiny test dataset -- not representative of
production scale).

A non-offloaded export runs against the primary directly and can compete with it for
resources during the dump -- offload exists specifically to avoid that.

## 6. Security / IAM design

Least privilege, one identity per responsibility:

| Identity | Scope | Why |
|---|---|---|
| Cloud SQL's own per-instance service agent (Google-managed) | Custom role (`storage.objects.create/get/list/delete`) bound to **this one export bucket only** | What Cloud SQL's own export/import mechanism requires -- not project-wide `storage.objectAdmin`. |
| Workflow runtime identity | Custom role with only `cloudsql.instances.export` + `cloudsql.instances.get`, IAM-**conditioned** to one instance; a second custom role for `cloudsql.operations.get` (project-wide -- see [Known limitations](#12-known-limitations)) | Only this identity talks to Cloud SQL. Cloud SQL supports IAM Conditions on the `Instance` resource type, so export/get are scoped narrower than a project-wide grant. |
| Scheduler trigger identity | `roles/workflows.invoker` only (project-wide -- see [Known limitations](#12-known-limitations)), zero Cloud SQL or GCS access | Can start the workflow execution and nothing else. |
| On-prem downloader identity | `roles/storage.objectViewer` on the export bucket only, **no key** | Represents the future on-prem client. Read-only. See [Future on-prem automation](#future-on-prem-automation) for why no key is created. |

**Network exposure:** the Cloud SQL instance has a public IP (Cloud SQL requires either
a public IP or a private IP + VPC; this repo doesn't provision a VPC + Private Service
Access it doesn't otherwise need, since nothing in this workflow ever opens a direct
SQL connection to the instance), but `authorized_networks` is empty, so the instance's
firewall accepts connections from nowhere. An environment with its own existing VPC
should use Private IP instead.

**No static credentials anywhere in this Terraform.** Short-lived credentials are
preferred throughout; see [Future on-prem automation](#future-on-prem-automation) for
the Workload Identity Federation path for unattended on-prem use.

## 7. Terraform architecture

```
terraform/
  versions.tf              provider requirements
  variables.tf              every configurable value -- the one file to edit for reuse
  apis.tf                   only the APIs this repo needs
  storage.tf                GCS export bucket (lifecycle delete rule) + its IAM bindings
  sql.tf                    new Postgres instance/user/database (manage_sql_instance=true),
                            OR a read-only lookup of an existing instance (=false) --
                            both resolve to local.instance_name / local.instance_
                            service_account / local.database_name that every other
                            file reads from
  iam.tf                    Cloud SQL IAM for the workflow runtime identity
  workflow.tf               Cloud Workflows definition + the Scheduler job that
                            triggers it
  export-workflow.yaml.tftpl  the workflow itself: start export with a timestamped
                            object name, poll until done
  outputs.tf                resource names/identities (sensitive values marked as such)
```

## 8. Deployment instructions

**All configuration lives in `terraform/variables.tf`.** Every other file reads from
these variables or from `local.*` values derived from them -- nothing else needs
editing to reuse this repo.

### Path A -- create a new test Cloud SQL instance

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id (and region/zone)
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# review the plan and cost (Section 11) before applying
terraform apply tfplan
```

### Path B -- point this at an existing Cloud SQL instance

Add to `terraform.tfvars`:

```hcl
project_id              = "your-project"
region                  = "your-instance-region"   # must match the existing instance
manage_sql_instance     = false
existing_instance_name  = "your-existing-instance-id"
existing_database_name  = "your_database_name"
```

With `manage_sql_instance = false`, Terraform **never creates, modifies, or deletes**
your instance, its users, or its databases -- it only reads it via a data source to
learn its name/region/service-account-email. It still creates the export bucket,
least-privilege IAM, and the optional Scheduler/Workflow automation around it.

## Manual download -- do this today

Once an export exists in the bucket, download it with your own authenticated account:

```bash
gcloud auth login   # once, interactively, if you haven't already

gcloud storage ls gs://<bucket>/exports/...

gcloud storage cp \
  gs://<bucket>/exports/<completed-export>.sql.gz \
  .
```

No `GOOGLE_APPLICATION_CREDENTIALS`, no service-account key file -- this uses whatever
identity `gcloud` is already logged in as. `onprem/download_export.sh` wraps this into
a script with integrity checks (file exists, non-zero size, gzip integrity) and works
the same way.

## Future on-prem automation

Mode B's full picture, once a real on-prem host and a real identity provider exist:

```
Cloud Scheduler -> Cloud Workflows -> offloaded Cloud SQL export -> GCS
    -> on-prem systemd timer -> download via Workload Identity Federation
```

The Scheduler/Workflow/export/GCS half is built and tested in this repo. The on-prem
side is a concept, documented but **not deployed**, because unattended authentication
needs Workload Identity Federation (WIF) against a real external identity provider --
this repo has no such provider to federate against, so building fake WIF
infrastructure here would demonstrate nothing real.

- `onprem/download_export.sh` -- the download + integrity-check script; already works
  with any authenticated `gcloud` identity, including a future WIF-issued one.
- `onprem/pgexport-download.service` / `.timer` (or `onprem/crontab.example`) -- runs
  the script every 10 minutes rather than assuming a fixed delay after the scheduled
  export; the script is idempotent (skips cleanly if no new export exists yet), so
  frequent runs cost nothing extra.
- `onprem/pgexport.env.example` -- configuration, with no key file referenced.
- `onprem/ANSIBLE_NOTE.md` -- where Ansible would manage this across a fleet of
  on-prem hosts, once there is more than one to manage.

**What's needed before this can run unattended in production:** a Workload Identity
Federation pool + provider configured against the organization's real identity
provider (its OIDC/SAML IdP, or a self-hosted STS), granting the on-prem downloader
identity's permissions to whatever short-lived credential that federation issues. Do
not create a long-lived service-account JSON key as a substitute -- that reintroduces
exactly the kind of standing credential this design avoids everywhere else.

## 9. Test procedure

1. **Seed** -- upload `seed/seed.sql` to the export bucket, then import it via the
   Cloud SQL Admin API (`instances.import`). The dataset has tables with FKs and a
   CHECK constraint, two indexes, a view, two functions (one a trigger handler), a
   trigger, and a genuine `CREATE PROCEDURE` -- chosen specifically because these are
   the object types a database export is most likely to drop.
2. **Export twice** -- run the offloaded export (`instances.export`, `offload: true`)
   twice in a row with the timestamped-path logic from `export-workflow.yaml.tftpl`,
   and confirm both produce distinct GCS objects with no collision.
3. **Automation path** -- trigger the Cloud Scheduler job and confirm the Workflow
   execution actually waits for the Cloud SQL operation to reach `DONE` before
   finishing (not a fixed sleep).
4. **Manual download** -- `gcloud storage cp` the completed export using a normal
   authenticated `gcloud` session (see above). Verify file exists, non-zero size, gzip
   integrity.
5. **Restore + validate** -- load the downloaded dump into a clean PostgreSQL database
   and run `seed/validate.sql`: table list, row counts, a sample record, index list,
   the view, both functions, the trigger, and an explicit `CALL` of the stored
   procedure with a before/after check that it actually changed data.
6. **Existing-instance path** -- `terraform plan` with `manage_sql_instance = false`
   against a real instance name and confirm the plan touches nothing on that instance.
7. **Cleanup** -- `terraform destroy`, then independently re-check (not just trust the
   destroy output) that every resource is actually gone.

## 10. Validation evidence

See `evidence/` (sanitized -- real project identifiers replaced with placeholders,
facts like status/timing/row counts/byte sizes preserved). Filled in after each live
test run; see that directory's own README for what each file proves.

## 11. Cost considerations

**Corrected from an earlier version of this document**, which incorrectly stated
serverless export cost scales with the size of the exported file. Verified directly
against the current pricing page (`cloud.google.com/sql/pricing`, "Serverless export
pricing" section): *"The price per GiB is calculated based on the disk size of the
offload instance, which is the same as the disk size of the primary instance. This
price isn't based on the amount of data exported."* In other words: **a serverless
export bills against your primary instance's provisioned disk size, not the size of
the SQL dump it produces.** A 500 GB instance costs roughly the same to export whether
the actual dump is 2 GB or 200 GB. The same page also notes committed use discounts do
not apply to this price, and that exporting from a read replica instead of the primary
is more cost-effective for frequent, small exports.

Inputs needed to calculate a real cost, rather than a number invented here:

| Cost driver | What determines it | Where to look |
|---|---|---|
| Cloud SQL instance (tier + disk) | Your instance's machine type and provisioned disk size -- unaffected by this change | `cloud.google.com/sql/pricing`, your region |
| Serverless export | Primary instance's **disk size** (not dump size) × how often you export | Same page, "Serverless export pricing" |
| GCS storage | Size of retained export objects × how long the lifecycle rule keeps them | `cloud.google.com/storage/pricing` |
| GCS operations | Class A (write/list) ops per export + import/restore reads | Same page |
| GCS -> on-prem transfer | Network egress, or your organization's existing interconnect/VPN pricing if that's the path (often cheaper than public internet egress) | Same page, or your network team |

This repo's own test used a small instance and a small dataset for a few hours; actual
observed spend is in `evidence/` -- not a substitute for sizing the real workload above.

## 12. Known limitations

1. **Cloud SQL's export/import identity is per-instance, not a generic per-API
   agent.** Each instance has its own uniquely-suffixed service account, exposed by
   Terraform as `service_account_email_address` on the instance resource/data source.
   Granting IAM to the wrong (generic) identity produces the same generic permission
   error as an actual missing-permission bug -- check this specific attribute first if
   export/import fails with a bucket-permission error despite IAM looking correct.
2. **Freshly-granted IAM can take several minutes to actually take effect**, even
   though a policy read already shows the binding as present. Expect this on the very
   first export/import after `terraform apply` creates a new identity.
3. **Cloud Workflows has no per-resource IAM binding today** (verified live: neither
   `gcloud workflows add-iam-policy-binding` nor a per-workflow Terraform IAM resource
   exists) -- `roles/workflows.invoker` is granted project-wide to the Scheduler
   identity. That identity has no other permission, which bounds the blast radius.
4. **Cloud SQL IAM Conditions cannot scope `cloudsql.operations.get`** to a single
   instance -- only `Instance` and `BackupRun` resource types are supported. That one
   permission stays project-wide; a genuine platform limit, not a design shortcut.
5. Cloud SQL requires either a public IP or a private IP + VPC; this repo uses a
   public IP with zero authorized networks rather than provisioning a VPC + Private
   Service Access it doesn't otherwise need. An environment with an existing VPC
   should use Private IP instead.
6. Custom IAM roles are soft-deleted for roughly a week after `terraform destroy` --
   `gcloud iam roles list --show-deleted` will still list them; `gcloud iam roles list`
   without that flag correctly shows none as active. Re-running this Terraform under
   the same `name_prefix` inside that window will hit a "role already exists (deleted)"
   error -- use a different prefix or wait it out.
7. The Cloud SQL Admin API documents both `v1` and `v1beta4` for `instances.export`/
   `instances.import` with identical method descriptions; this repo defaults to `v1`
   (see `var.sqladmin_api_version`) and documents which version was actually exercised
   in [Validation evidence](#10-validation-evidence) -- override to `v1beta4` only if
   your own testing shows `v1` failing in your environment.

## 13. pg_dump compatibility findings

**This is the section that decides whether this architecture can replace pg_dump for
a given database -- and it must be re-verified against your own schema, not assumed
from this repo's result.**

Google's documentation states (`docs.cloud.google.com/sql/docs/postgres/import-export/import-export-sql`):
*"The `export sql` command does not contain triggers or stored procedures, but does
contain views."*

**POC result:** in this repo's own test, every object type tried -- tables, an index,
a view, two functions, a trigger, and a genuine stored procedure (verified via
`pg_proc.prokind = 'p'` and an actual `CALL` that changed data, not just presence of
its definition as text) -- **survived** the export/download/restore cycle intact. See
[Validation evidence](#10-validation-evidence) for the exact commands and results.

**Official documentation:** does not guarantee triggers or stored procedures survive.

**Production requirement:** validate the real application's schema before replacing
pg_dump with this pattern. The documented behavior and this repo's measured behavior
disagree, which is exactly the situation where only a direct test on your own
triggers/procedures/functions resolves the question -- run the same seed -> export ->
download -> restore -> validate cycle (Section 9) against a copy of your real schema
first. If your real objects turn out not to survive, a hybrid approach (offloaded
export for bulk data, a small version-controlled script for the objects that don't
survive, applied after restore) is the fallback -- not all-or-nothing.

## 14. Production recommendations

1. Use Private IP once deployed into an environment with its own VPC.
2. Replace the on-prem downloader's authentication with Workload Identity Federation
   once a real identity provider is available -- see
   [Future on-prem automation](#future-on-prem-automation).
3. Decide the pg_dump-compatibility question (Section 13) against your real schema
   before switching.
4. Benchmark offloaded export duration against your real database size before
   committing to an RPO/RTO target, and size the disk-based export cost (Section 11)
   against your real instance.

## 15. Rollback / cleanup

Nothing here is destructive to a pre-existing environment -- it only adds new,
independently-destroyable resources (and in Path B, it never touches your real
instance or its data at all).

```bash
cd terraform
terraform destroy
```

Then independently verify (don't just trust the destroy output) -- see `evidence/` for
this repo's own cleanup verification:
```bash
gcloud sql instances list --project=<project> --filter="name:<name_prefix>*"
gcloud storage buckets list --project=<project> --filter="name:<name_prefix>*"
gcloud scheduler jobs list --project=<project> --location=<region> --filter="name:<name_prefix>*"
gcloud workflows list --project=<project> --location=<region> --filter="name:<name_prefix>*"
gcloud iam service-accounts list --project=<project> --filter="email:<name_prefix>*"
```
All five should return empty (custom IAM roles will still show under
`--show-deleted` -- expected, see Known Limitations #6).

## 16. How to adapt this code for your environment

- Set `project_id`/`region`/`zone` in `terraform.tfvars` to your own project.
- Set `manage_sql_instance = false` and `existing_instance_name` /
  `existing_database_name` (Section 8, Path B) to point this at a real database
  without creating anything new or touching it beyond a read-only lookup.
- Re-run the pg_dump compatibility test (Section 13) against the **real** schema --
  this repo's result is evidence for its own synthetic test case, not a guarantee.
- Wire Workload Identity Federation to your organization's real identity provider
  before deploying the on-prem download side unattended (Section 5).
