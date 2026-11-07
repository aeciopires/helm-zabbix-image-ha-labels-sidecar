# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo builds the image `ghcr.io/zabbix-community/zabbix-server-ha-label-manager`, the "HA labels sidecar" of the Zabbix Server pods of the Zabbix Helm chart (`zabbix-community/helm-zabbix`, `charts/zabbix/templates/deployment-zabbix-server.yaml`, container `ha-labels-sidecar`) when `zabbixServer.zabbixServerHA.enabled=true`. It labels its own pod `zabbix.com/server-ha-role=active|standby`; the chart's Zabbix Server Service selects `active`. There is no release/tag process: each push to `main` publishes a `<timestamp>` tag.

## Common commands

```bash
make help            # lists all targets
make check-os / check-deps / install-deps
make lint            # shellcheck (script, test) + hadolint (Dockerfile), tools pinned in mise.toml
make build           # zabbix-server-ha-label-manager:local (IMAGE_TAG)
make kind-test       # tests/kind-test.sh: fake Zabbix Server pod in kind, checks standby → active → standby and fast SIGTERM
make kind-delete     # deletes the kind cluster of the test (KIND_CLUSTER_NAME)
make kind-load       # loads the image into a kind cluster, e.g. the chart's (KIND_CLUSTER_NAME=helm-zabbix)
```

Test with real Zabbix Server pods using the chart: `charts/zabbix/docs/example/ha/README.md` in the chart repository (`values-local-images.yaml` + `make kind-load` there).

## Architecture

- `ha-label-manager.sh` is POSIX `sh` (the image is `alpine` + `kubectl`, no bash/jq/procps). It counts processes whose `/proc/<pid>/cmdline` contains `zabbix_server` (the pod uses `shareProcessNamespace: true`; Zabbix rewrites process titles like `/usr/sbin/zabbix_server: poller #1 [...]`). More than `ACTIVE_PROCESS_THRESHOLD` (5) → `active`, else `standby` (a standby node runs only a few processes).
- The cached label value only changes after a successful `kubectl label`, so failed updates are retried. The label is re-read from the API every `LABEL_REFRESH_INTERVAL` seconds. `sleep` runs in the background + `wait`, so the `TERM` trap fires immediately (the old image ignored SIGTERM when its shell was PID 1, e.g. `docker stop` waited the whole timeout; in the chart pods PID 1 is the pause container because of `shareProcessNamespace`).
- RBAC needed: `pods` get/patch (chart: Role/RoleBinding `<fullname>-ha-helper`, bound to the Zabbix Server pods' service account).
- The `ENTRYPOINT` path `/script/ha-label-manager.sh` and user `1001` are kept for compatibility with existing chart values (`securityContext`, `extraVolumeMounts`).

## Rules

- Keep the env var interface (`LABEL_NAME`, `HOSTNAME`/`POD_NAME`) compatible with the chart; add new variables with defaults.
- After a new image is published, the chart's `zabbixServer.zabbixServerHA.haLabelsSidecar.image.tag` must be updated (the chart's CI checks the tag exists).
- Keep README.md (repository structure, Mermaid diagrams, environment variables), CONTRIBUTING.md and this file consistent when changing behavior or files.
- Tool versions live only in `mise.toml`; the base image tag (and so the kubectl version) is updated by Dependabot.
