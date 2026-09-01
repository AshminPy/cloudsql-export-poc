# Evidence (sanitized)

Every file in this directory is **sanitized POC evidence**: real project IDs, project
numbers, bucket names, service account emails, and operation IDs from the actual test
run have been replaced with generic placeholders (`example-project`,
`example-export-bucket`, `example-instance`, etc.). The facts that matter --
operation status, timing, byte sizes, row counts, and command output shape -- are
preserved exactly as observed.

- `01-seed-import.txt` -- seeding the test database via the Cloud SQL Admin API
- `02-export-offloaded.txt` -- the offloaded export, timed
- `03-export-nonoffloaded.txt` -- the non-offloaded export, timed, for comparison
- `04-gcs-objects.txt` -- confirming exported objects exist in GCS
- `05-scheduler-workflow-run.txt` -- Cloud Scheduler -> Cloud Workflows automation,
  proving it waits for real completion and produces unique timestamped filenames
- `06-manual-download.txt` -- the manual `gcloud storage cp` download, no key file
- `07-restore-output.txt` -- restoring the dump into a clean local PostgreSQL database
- `08-validation-results.txt` -- the full validation suite, including the stored
  procedure `CALL` test
- `09-cleanup-verification.txt` -- post-`terraform destroy` independent re-check
