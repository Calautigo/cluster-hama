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
- Never edit secrets or gitignored files (`*.key`, `*.crt`, `.private/`, `age.key`).
- The user's shell is `fish`: commands intended for the user must be fish-compatible. Shell scripts can use bash/sh.

## Overview

GitOps homelab repo: a Talos Linux Kubernetes cluster ("thestral") managed by Flux CD; push to `main` and Flux reconciles. Task runner is `just` with modules `k8s`, `talos`, `bootstrap`. Nodes: `thestral-01..03` (control plane), `thestral-worker-01..03` (workers).

mise (`.mise.toml`) sets `KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE=./age.key`, `MINIJINJA_CONFIG_FILE` (all gitignored) and installs lefthook git hooks. Tools via `Brewfile`, plus `sops`, `age`, `gum`, `oxfmt`, and the `flux` CLI.

## Commands

```bash
just -l --list-submodules                    # List all tasks
just talos render-config|apply-node|reboot-node|upgrade-node <node>  # Also: apply-cluster, upgrade-k8s <ver>
just k8s sync-hr|sync-ks|sync-es <ns> <name> # Force-sync (sync-all-* for all)
just k8s apply-ks <ns> <app>                 # Render + apply locally to validate before push
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
- VolSync component (persistent data): creates PVC `${VOLSYNC_CLAIM:-${APP}}` plus backups; the app mounts `existingClaim: ${APP}`. Optional vars: `VOLSYNC_` `CLAIM`, `CAPACITY` (5Gi), `ACCESSMODES` (ReadWriteOnce), `STORAGECLASS` (csi-rbd-sc), `SNAPSHOTCLASS`, `KOPIA_SCHEDULE`.
- `${SECRET_DOMAIN}`, `${APP}`, etc. are substituted at reconcile time from `cluster-settings`/`cluster-secrets`; non-secret config only. App credentials go through Vault via ExternalSecret (ClusterSecretStore `hashicorp-vault`, path `apps/<ns>/<app>`). SOPS+Age (`*.sops.yaml`) is for Talos/bootstrap secrets only; `sops -e -i` / `sops -d`.

### Adding a New App

1. Create `kubernetes/apps/<ns>/<app>/` following pgadmin: `ks.yaml` plus `app/` with a kustomization.yaml listing all resources.
2. Register `./<app>/ks.yaml` in `kubernetes/apps/<ns>/kustomization.yaml` (sets the namespace).
3. New namespace: add `namespace.yaml` and a kustomization.yaml with `namespace:`, all ks.yaml entries, `./namespace.yaml`, and `../../components/common`; add `./<ns>` to `kubernetes/apps/kustomization.yaml`.
4. Secrets: Vault entry at `apps/<ns>/<app>` + `externalsecret.yaml`. Persistent data: volsync component + dependsOn + `VOLSYNC_CAPACITY`. OIDC-capable: `oidcclient.yaml` (below).
5. Validate before pushing: `just k8s apply-ks <ns> <app>`.

### SSO / Pocket-ID

`pocket-id-operator` (ns `security`) manages OIDC clients as `PocketIDOIDCClient` CRs in `app/oidcclient.yaml` (copy pgadmin's).

- `allowedUserGroups` is required; default `hama` (admin group). Omitting it lets every registered Pocket-ID user log in; widen beyond `hama` only deliberately, per app.
- Every referenced group needs a `PocketIDUserGroup` CR (`security/pocket-id-instance/app/usergroup-*.yaml`: hama, mimler, schwarz) or reconcile fails.
- Group CRs manage existence, `friendlyName`, and `customClaims` only, not membership (managed in the Pocket-ID UI; `spec.users` omitted). `customClaims` must mirror the UI exactly or the operator overwrites it.
- The `secret:` block writes client ID/secret/issuer into a Kubernetes Secret for the app's env vars.

### Infrastructure Notes

- Cilium CNI; kgateway (Gateway API) ingress in `network` (gateways `kgateway-internal` and external).
- CloudNative-PG (PostgreSQL), Dragonfly (Redis-compatible), MariaDB, InfluxDB, EMQX (MQTT), VolSync (PVC backups), KEDA (`just k8s keda|keda-all`), kube-prometheus-stack.
- Renovate (`renovate.json5`, `.renovate/`) updates Flux manifests, image digests, chart versions, Talos configs; `*.sops.*` excluded.
- `app.kubernetes.io/name` from ks.yaml `commonMetadata` propagates to all resources; use `app.kubernetes.io/component` for labels that must survive the override.
- Lefthook commit hooks (auto-installed by mise): oxfmt formats YAML/JSON/Markdown (2-space indent, LF, width 100), `just --fmt`, shellcheck, and a block on unencrypted `*.sops.yaml`.

## Code Exploration (jCodemunch MCP)

Use jCodemunch-MCP tools for code navigation, never Read/Grep/Glob/Bash. Exception: `Read` a file right before editing it (the harness requires it for Edit/Write).

- Open with `plan_turn { repo, query, model: "<your-model-id>" }` (for non-code tasks call `announce_model` once instead). Obey the confidence: `high` → recommended symbols, max 2 extra reads; `medium` → recommended files, max 5; `low` → the feature likely doesn't exist: report the gap and stop searching.
- For a well-defined task, `assemble_task_context { repo, task }` returns the whole context capsule in one call; prefer it over chaining primitives.
- A `negative_evidence` result with `no_implementation_found` is final: report it instead of re-searching with new terms.
- The find/read/impact primitives are self-describing; `get_file_outline` before opening any file; `get_file_content` only as last resort.
- After edits (unless PostToolUse hooks reindex): `register_edit` with the edited paths; batch for 5+ files. If `_meta` shows `budget_warning` or `auto_compacted`, stop exploring and work with what you have.
