# Where Ansible fits (not built here, deliberately)

This POC does not manage the on-prem host with Terraform or Ansible — for one throwaway
test, hand-copying `download_export.sh` + the systemd unit files is simpler and there's
no real host to manage repeatedly. That changes once this is a real fleet of on-prem
backup hosts.

At that point, Ansible is the right tool for the on-prem side specifically because it
needs no agent on hosts that may not have outbound access to a control plane beyond
SSH — unlike Terraform, which is provisioning-focused and awkward for "keep this file
and this systemd unit in a known state on N existing servers."

A minimal role would look like:

```
roles/pgexport_download/
  tasks/main.yml       # copy download_export.sh, pgexport.env, systemd unit + timer;
                        # create the pgexport system user; enable+start the timer
  templates/
    pgexport.env.j2     # renders GCS_BUCKET etc. from group_vars, not hardcoded
    pgexport-download.service.j2
    pgexport-download.timer.j2
  handlers/main.yml     # reload systemd, restart timer on template change
  defaults/main.yml     # RETAIN_DAYS, schedule, dest dir defaults
```

The service account key (`GOOGLE_APPLICATION_CREDENTIALS`) would be delivered via
Ansible Vault or, better, pulled at runtime from the org's existing secrets manager
rather than templated into a file Ansible itself carries — see README "Production
recommendations" for the Workload Identity Federation alternative that removes the key
entirely.
