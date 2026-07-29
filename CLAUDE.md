# Agent Instructions

Bias toward caution over speed; use judgment on trivial tasks.

## Working Style

- Be concise; skip preamble. When asked a question, answer it instead of jumping to edits.
- Ambiguous request: present the interpretations. Simpler approach: say so; push back when warranted.
- Never state versions, API shapes, or flags from memory; verify against docs or code.
- No em dashes in prose; use a hyphen, semicolon, or colon.
- Just do reversible actions; ask first only for destructive or hard-to-undo actions, or scope changes.
- Verify changes by running the code or tests before claiming they work.
- Write the minimum code that solves the problem; touch only what the request requires; match existing style. Remove what your change orphaned; leave pre-existing dead code but mention it.
- Comments explain non-obvious constraints only.
- Never edit secrets or gitignored files (`*.key`, `*.crt`, `.private/`, `keys.txt`).
- The user's shell is `fish`: commands intended for the user must be fish-compatible. Shell scripts can use bash/sh.

## Overview

GitOps homelab repo: a Talos Linux Kubernetes cluster ("thestral") managed by Flux CD; push to `main` and Flux reconciles. Task runner is `just` with modules `k8s`, `talos`, `bootstrap`. Nodes: `thestral-01..03` (control plane), `thestral-worker-01..03` (workers).

mise (`.mise.toml`) sets `KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE=./keys.txt`, `MINIJINJA_CONFIG_FILE` (all gitignored) and installs lefthook git hooks. Tools via `Brewfile`, plus `sops`, `age`, `gum`, `oxfmt`, and the `flux` CLI.

## Commands

```bash
just -l --list-submodules                    # List all tasks
just talos render-config|apply-node|reboot-node|upgrade-node <node>  # Also: apply-cluster, upgrade-k8s <ver>
just k8s sync-hr|sync-ks|sync-es <ns> <name> # Force-sync (sync-all-* for all)
just k8s apply-ks <ns> <app>                 # WARNING: applies to the live cluster, not a dry run
flux -n <ns> build kustomization <app> --path kubernetes/apps/<ns>/<app>/app \
  --kustomization-file kubernetes/apps/<ns>/<app>/ks.yaml --dry-run  # Validate without touching the cluster
just k8s snapshot|backup <ns> <name>         # VolSync; also volsync suspend|resume, browse-pvc, node-shell, prune-pods
flux get ks|hr -A                            # Status; flux logs --kind=HelmRelease --name=<app>
```

## Architecture

Git push → Flux GitRepository → cluster-apps → per-namespace → per-app Kustomization → HelmRelease/resources.

- `kubernetes/apps/<ns>/<app>/`: `ks.yaml` (Flux Kustomization) + `app/` (kustomization.yaml, helmrelease.yaml, ocirepository.yaml, externalsecret.yaml, oidcclient.yaml).
- `kubernetes/bootstrap/`: one-time bootstrap (helmfile, CRDs). `kubernetes/components/`: reusable Kustomize components (common, dragonfly, gpu, volsync). `kubernetes/flux/`: Flux entrypoints.
- `talos/`: MinJinja templates rendered at apply time; `machineconfig.yaml.j2` (base) + `nodes/<node>.yaml.j2` (per-node, controlplane vs worker); secrets injected from `talsecret.sops.yaml` via `sops://` refs; `schematic.yaml` lists OS extensions.

### App Pattern

`kubernetes/apps/database/pgadmin/` is a complete reference example. Conventions:

- Every manifest has a `# yaml-language-server: $schema=...` comment. ks.yaml uses YAML anchor `&app`, `commonMetadata.labels: app.kubernetes.io/name`, `prune: true`, `wait: false`, `dependsOn` for ordering. Multi-component apps: several Kustomizations in one ks.yaml.
- Most apps use the bjw-s app-template chart via `chartRef.kind: OCIRepository` (chart version pinned; Renovate bumps it). Routes via app-template `route:` values with hostname `"{{ .Release.Name }}.ds47.dev"` and parentRef `kgateway-internal` (ns `network`).
- VolSync component (persistent data): creates PVC `${VOLSYNC_CLAIM:-${APP}}` plus a NAS and an offsite-S3 Kopia `ReplicationSource`; the app mounts `existingClaim: ${APP}`. Optional vars: `VOLSYNC_` `NAME`, `CLAIM`, `CAPACITY` (5Gi), `ACCESSMODES` (ReadWriteOnce), `STORAGECLASS` (csi-rbd-sc), `SNAPSHOTCLASS` (csi-rbd-snapclass), `KOPIA_SCHEDULE` (hourly), `OFFSITE_SCHEDULE` (02:30 daily); plus `APP_UID`/`APP_GID` (2000) for the mover.
- `${SECRET_DOMAIN}`, `${APP}`, etc. are substituted at reconcile time from `cluster-settings`/`cluster-secrets`; non-secret config only. App credentials go through Vault via ExternalSecret (ClusterSecretStore `vault`, KV-v2 mount `apps`, so `key: <app>` resolves to `apps/<app>`). A second store `vault-secret-store` points at the legacy external Vault (`10.100.0.100:8200`, mount `k8s/gryffindor-prod`). SOPS+Age (`*.sops.yaml`) covers Talos, bootstrap, and `cluster-secrets`; `sops -e -i` / `sops -d`.

### Adding a New App

1. Create `kubernetes/apps/<ns>/<app>/` following pgadmin: `ks.yaml` plus `app/` with a kustomization.yaml listing all resources.
2. Register `./<app>/ks.yaml` in `kubernetes/apps/<ns>/kustomization.yaml` (sets the namespace).
3. New namespace: add `namespace.yaml` and a kustomization.yaml with `namespace:`, all ks.yaml entries, `./namespace.yaml`, and `../../components/common`; add `./<ns>` to `kubernetes/apps/kustomization.yaml`.
4. Secrets: Vault entry at `apps/<app>` + `externalsecret.yaml`. Persistent data: volsync component + dependsOn + `VOLSYNC_CAPACITY`. OIDC-capable: `oidcclient.yaml` (below).
5. Validate before pushing with `flux build kustomization ... --dry-run` (see Commands). `just k8s apply-ks` deploys for real.

### SSO / Pocket-ID

`pocket-id-operator` (ns `security`) manages OIDC clients as `PocketIDOIDCClient` CRs in `app/oidcclient.yaml` (copy pgadmin's).

- `allowedUserGroups` is required; default `hama` (admin group). Omitting it lets every registered Pocket-ID user log in; widen beyond `hama` only deliberately, per app.
- Every referenced group needs a `PocketIDUserGroup` CR (`security/pocket-id-instance/app/usergroup-*.yaml`: hama, media, services) or reconcile fails.
- Group CRs manage existence, `friendlyName`, and `customClaims` only, not membership (managed in the Pocket-ID UI; `spec.users` omitted). `customClaims` must mirror the UI exactly or the operator overwrites it.
- The `secret:` block writes client ID/secret/issuer into a Kubernetes Secret for the app's env vars.

### Infrastructure Notes

- Cilium CNI; kgateway (Gateway API) ingress in `network`. Only `kgateway-internal` is live; `gateway/external.yaml` is commented out of `gateway/kustomization.yaml`. Listeners: HTTP:80 (redirect), HTTPS:443 for `*.ds47.dev` and `*.schwarz47.at`, TCP:22 for forgejo SSH.
- CloudNative-PG (PostgreSQL), Dragonfly (Redis-compatible), MariaDB (being retired in favour of Postgres), InfluxDB, EMQX (MQTT), VolSync + Kopia mover (PVC backups), KEDA (`just k8s keda|keda-all`), kube-prometheus-stack.
- Renovate (`renovate.json5`, `.renovate/`) updates Flux manifests, image digests, chart versions, Talos configs; `*.sops.*` excluded.
- `app.kubernetes.io/name` from ks.yaml `commonMetadata` propagates to all resources; use `app.kubernetes.io/component` for labels that must survive the override.
- Lefthook commit hooks (auto-installed by mise): oxfmt formats YAML/JSON/Markdown (2-space indent, LF, width 100), `just --fmt`, shellcheck, and a block on unencrypted `*.sops.yaml`.
