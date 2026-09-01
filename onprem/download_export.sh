#!/usr/bin/env bash
# On-prem download script.
#
# Replaces: on-prem VM -> IAP tunnel -> bastion -> Cloud SQL Proxy -> pg_dump
# With:     gcloud storage cp gs://<export-bucket>/... -> local filesystem
#
# No IAP, no bastion, no Cloud SQL Proxy, no SSH tunnel. This host only ever needs
# outbound HTTPS to storage.googleapis.com -- it never talks to Cloud SQL directly.
#
# Identity: this script does NOT require GOOGLE_APPLICATION_CREDENTIALS or a service
# account key file. It uses whatever identity `gcloud` is already authenticated as --
# today that is your own user account (`gcloud auth login`, run once, interactively).
# For future unattended/scheduled use on a real on-prem host, the identity should come
# from Workload Identity Federation against your organization's real identity provider
# (no key file there either) -- see README "Future on-prem automation". If
# GOOGLE_APPLICATION_CREDENTIALS happens to already be set in the environment (e.g. a
# WIF-issued credential file), this script uses it automatically; it just never
# requires one.
#
# Exit codes: 0 = success, non-zero = failure (safe to alert on in cron/systemd).

set -euo pipefail

# --- Configuration (override via environment or a sourced .env file) ---
GCS_BUCKET="${GCS_BUCKET:?set GCS_BUCKET, e.g. example-export-bucket}"
GCS_PREFIX="${GCS_PREFIX:-exports/}"
DEST_DIR="${DEST_DIR:-./downloads}"
LOG_FILE="${LOG_FILE:-./pgexport-download.log}"
RETAIN_DAYS="${RETAIN_DAYS:-14}"

log() {
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "$LOG_FILE"
}

# Fail early and clearly if gcloud has no active credentials at all, rather than
# letting `gcloud storage ls` fail later with a less obvious error.
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    log "ERROR: no active gcloud credentials. Run: gcloud auth login"
    exit 1
fi

mkdir -p "$DEST_DIR"

log "starting export download from gs://${GCS_BUCKET}/${GCS_PREFIX}"

# Find the newest object under the prefix -- works whether objects are laid out under
# a flat prefix or the timestamped exports/YYYY/MM/DD/ path this repo's export
# workflow produces.
LATEST_OBJECT=$(gcloud storage ls "gs://${GCS_BUCKET}/${GCS_PREFIX}**" 2>/dev/null \
    | grep -E '\.(sql|sql\.gz)$' \
    | sort \
    | tail -n1) || true

if [ -z "${LATEST_OBJECT:-}" ]; then
    log "ERROR: no export object found under gs://${GCS_BUCKET}/${GCS_PREFIX}"
    exit 1
fi

# Idempotent, no fixed-wait guess: this script can be run on any schedule (a tight
# poll loop, a periodic timer, or by hand) because it always downloads only the
# latest object and skips cleanly if that object is the same one already downloaded
# last time -- so it's always safe to run again before the next export exists yet.
MARKER_FILE="${DEST_DIR}/.last_downloaded_object"
if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE")" = "$LATEST_OBJECT" ]; then
    log "no new export since last run (latest is still ${LATEST_OBJECT}) -- nothing to do"
    exit 0
fi

FILENAME=$(basename "$LATEST_OBJECT")
DEST_PATH="${DEST_DIR}/${FILENAME}"

log "downloading ${LATEST_OBJECT} -> ${DEST_PATH}"
gcloud storage cp "$LATEST_OBJECT" "$DEST_PATH"

# --- Validation: fail loudly rather than silently keeping a bad file ---
if [ ! -s "$DEST_PATH" ]; then
    log "ERROR: downloaded file is missing or zero bytes: ${DEST_PATH}"
    exit 1
fi

if [[ "$DEST_PATH" == *.gz ]]; then
    if ! gzip -t "$DEST_PATH"; then
        log "ERROR: gzip integrity check failed for ${DEST_PATH}"
        exit 1
    fi
fi

SIZE_BYTES=$(stat -f%z "$DEST_PATH" 2>/dev/null || stat -c%s "$DEST_PATH")
log "OK: downloaded and verified ${DEST_PATH} (${SIZE_BYTES} bytes)"
echo "$LATEST_OBJECT" > "$MARKER_FILE"

# --- Local retention cleanup: don't let old dumps accumulate forever on the host ---
find "$DEST_DIR" -type f -mtime "+${RETAIN_DAYS}" -name '*.sql*' -print -delete | while read -r removed; do
    log "removed old local copy past ${RETAIN_DAYS}d retention: ${removed}"
done

log "done"
