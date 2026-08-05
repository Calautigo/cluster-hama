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
just k8s snapshot <ns> <name>         # Kopiur manual Snapshot; also snapshot-all, browse-pvc, node-shell, prune-pods
flux get ks|hr -A                            # Status; flux logs --kind=HelmRelease --name=<app>
```

## Architecture

Git push → Flux GitRepository → cluster-apps → per-namespace → per-app Kustomization → HelmRelease/resources.

- `kubernetes/apps/<ns>/<app>/`: `ks.yaml` (Flux Kustomization) + `app/` (kustomization.yaml, helmrelease.yaml, ocirepository.yaml, externalsecret.yaml, oidcclient.yaml).
- `kubernetes/bootstrap/`: one-time bootstrap (helmfile, CRDs). `kubernetes/components/`: reusable Kustomize components (common, dragonfly, gpu, kopiur). `kubernetes/flux/`: Flux entrypoints.
- `talos/`: MinJinja templates rendered at apply time; `machineconfig.yaml.j2` (base) + `nodes/<node>.yaml.j2` (per-node, controlplane vs worker); secrets injected from `talsecret.sops.yaml` via `sops://` refs; `schematic.yaml` lists OS extensions.

### App Pattern

`kubernetes/apps/database/pgadmin/` is a complete reference example. Conventions:

- Every manifest has a `# yaml-language-server: $schema=...` comment. ks.yaml uses YAML anchor `&app`, `commonMetadata.labels: app.kubernetes.io/name`, `prune: true`, `wait: false`, `dependsOn` for ordering. Multi-component apps: several Kustomizations in one ks.yaml.
- Most apps use the bjw-s app-template chart via `chartRef.kind: OCIRepository` (chart version pinned; Renovate bumps it). Routes via app-template `route:` values with hostname `"{{ .Release.Name }}.ds47.dev"` and parentRef `kgateway-internal` (ns `network`).
- Kopiur component (persistent data): creates PVC `${KOPIUR_CLAIM:-${APP}}`, a kopiur `Repository` (Garage S3 backend, per-app kopia prefix), an `ExternalSecret` from Vault key `volsync-garage` for AWS creds + `KOPIA_PASSWORD`, a `SnapshotPolicy` (source = PVC + GFS retention), and an hourly `SnapshotSchedule`. The app mounts `existingClaim: ${APP}`. Optional vars: `KOPIUR_` `NAME`, `CLAIM`, `CAPACITY` (5Gi), `ACCESSMODES` (ReadWriteOnce), `STORAGECLASS` (csi-rbd-sc), `SNAPSHOTCLASS` (csi-rbd-snapclass), `SCHEDULE` (hourly), `COPYMETHOD` (Snapshot), `KEEP_*` retention overrides; plus `APP_UID`/`APP_GID` (2000) for the mover.
- `${SECRET_DOMAIN}`, `${APP}`, etc. are substituted at reconcile time from `cluster-settings`/`cluster-secrets`; non-secret config only. App credentials go through Vault via ExternalSecret (ClusterSecretStore `vault`, KV-v2 mount `apps`, so `key: <ns>/<app>` resolves to `apps/<ns>/<app>`). SOPS+Age (`*.sops.yaml`) covers Talos, bootstrap, and `cluster-secrets`; `sops -e -i` / `sops -d`.

### Adding a New App

1. Create `kubernetes/apps/<ns>/<app>/` following pgadmin: `ks.yaml` plus `app/` with a kustomization.yaml listing all resources.
2. Register `./<app>/ks.yaml` in `kubernetes/apps/<ns>/kustomization.yaml` (sets the namespace).
3. New namespace: add `namespace.yaml` and a kustomization.yaml with `namespace:`, all ks.yaml entries, `./namespace.yaml`, and `../../components/common`; add `./<ns>` to `kubernetes/apps/kustomization.yaml`.
4. Secrets: Vault entry at `apps/<ns>/<app>` + `externalsecret.yaml`. Persistent data: kopiur component + dependsOn + `KOPIUR_CAPACITY`. OIDC-capable: `oidcclient.yaml` (below).
5. Validate before pushing with `flux build kustomization ... --dry-run` (see Commands). `just k8s apply-ks` deploys for real.

### SSO / Pocket-ID

`pocket-id-operator` (ns `security`) manages OIDC clients as `PocketIDOIDCClient` CRs in `app/oidcclient.yaml` (copy pgadmin's).

- `allowedUserGroups` is required; default `hama` (admin group). Omitting it lets every registered Pocket-ID user log in; widen beyond `hama` only deliberately, per app.
- Every referenced group needs a `PocketIDUserGroup` CR (`security/pocket-id-instance/app/usergroup-*.yaml`: hama, media, services) or reconcile fails.
- Group CRs manage existence, `friendlyName`, and `customClaims` only, not membership (managed in the Pocket-ID UI; `spec.users` omitted). `customClaims` must mirror the UI exactly or the operator overwrites it.
- The `secret:` block writes client ID/secret/issuer into a Kubernetes Secret for the app's env vars.

### Infrastructure Notes

- Cilium CNI; kgateway (Gateway API) ingress in `network`. Only `kgateway-internal` is live; `gateway/external.yaml` is commented out of `gateway/kustomization.yaml`. Listeners: HTTP:80 (redirect), HTTPS:443 for `*.ds47.dev` and `*.schwarz47.at`, TCP:22 for forgejo SSH.
- Kopiur (mover) + Kopia (PVC backups, on Garage S3); CSI `snapshot-controller` and the rest of `system` (`k8tz`, `descheduler`, `keda`, `reloader`, `spegel`); KEDA (`just k8s keda|keda-all`); kube-prometheus-stack.
- Renovate (`renovate.json5`, `.renovate/`) updates Flux manifests, image digests, chart versions, Talos configs; `*.sops.*` excluded.
- `app.kubernetes.io/name` from ks.yaml `commonMetadata` propagates to all resources; use `app.kubernetes.io/component` for labels that must survive the override.
- Lefthook commit hooks (auto-installed by mise): oxfmt formats YAML/JSON/Markdown (2-space indent, LF, width 100), `just --fmt`, shellcheck, and a block on unencrypted `*.sops.yaml`.

## Code Exploration Policy

Always use jCodemunch-MCP tools for code navigation. Never fall back to Read, Grep, Glob, or Bash for code exploration.
**Exception:** Use `Read` when you need to edit a file — the agent harness requires a `Read` before `Edit`/`Write` will succeed. Use jCodemunch tools to _find and understand_ code, then `Read` only the specific file you're about to modify.

**Start any session:**

1. `resolve_repo { "path": "." }` — confirm the project is indexed. If not: `index_folder { "path": "." }`
2. `suggest_queries` — when the repo is unfamiliar

**Finding code:**

- symbol by name → `search_symbols` (add `kind=`, `language=`, `file_pattern=`, `decorator=` to narrow)
- decorator-aware queries → `search_symbols(decorator="X")` to find symbols with a specific decorator (e.g. `@property`, `@route`); combine with set-difference to find symbols _lacking_ a decorator (e.g. "which endpoints lack CSRF protection?")
- string, comment, config value → `search_text` (supports regex, `context_lines`)
- database columns (dbt/SQLMesh) → `search_columns`

**Reading code:**

- before opening any file → `get_file_outline` first
- one or more symbols → `get_symbol_source` (single ID → flat object; array → batch)
- symbol + its imports → `get_context_bundle`
- specific line range only → `get_file_content` (last resort)

**Repo structure:**

- `get_repo_outline` → dirs, languages, symbol counts
- `get_file_tree` → file layout, filter with `path_prefix`

**Relationships & impact:**

- what imports this file → `find_importers`
- where is this name used → `find_references`
- is this identifier used anywhere → `check_references`
- file dependency graph → `get_dependency_graph`
- what breaks if I change X → `get_blast_radius`
- what symbols actually changed since last commit → `get_changed_symbols`
- find unreachable/dead code → `find_dead_code`
- class hierarchy → `get_class_hierarchy`

## Session-Aware Routing

**Opening move for any task:**

1. `plan_turn { "repo": "...", "query": "your task description", "model": "<your-model-id>" }` — get confidence + recommended files; the `model` parameter narrows the exposed tool list to match your capabilities at zero extra requests.
2. Obey the confidence level:
    - `high` → go directly to recommended symbols, max 2 supplementary reads
    - `medium` → explore recommended files, max 5 supplementary reads
    - `low` → the feature likely doesn't exist. Report the gap to the user. Do NOT search further hoping to find it.
3. **One-call shortcut for a concrete task** — `assemble_task_context { "repo": "...", "task": "..." }` returns a single token-budgeted, source-attributed context capsule. It auto-classifies the task (explore / debug / refactor / extend / audit / review), auto-extracts anchor symbols, and runs the intent-appropriate sequence of the tools below end-to-end — so you get the whole context in one request instead of chaining the primitives by hand. Prefer it over a manual chain when the task is well-defined; fall back to step 1's routing when you need to decide _whether_ the feature exists first.

**Interpreting search results:**

- If `search_symbols` returns `negative_evidence` with `verdict: "no_implementation_found"`:
    - Do NOT re-search with different terms hoping to find it
    - Do NOT assume a related file (e.g. auth middleware) implements the missing feature (e.g. CSRF)
    - DO report: "No existing implementation found for X. This would need to be created."
    - DO check `related_existing` files — they show what's nearby, not what exists
- If `verdict: "low_confidence_matches"`: examine the matches critically before assuming they implement the feature

**After editing files:**

- If PostToolUse hooks are installed (Claude Code only), edited files are auto-reindexed
- Otherwise, call `register_edit` with edited file paths to invalidate caches and keep the index fresh
- For bulk edits (5+ files), always use `register_edit` with all paths to batch-invalidate

**Token efficiency:**

- If `_meta` contains `budget_warning`: stop exploring and work with what you have
- If `auto_compacted: true` appears: results were automatically compressed due to turn budget
- Use `get_session_context` to check what you've already read — avoid re-reading the same files

## Model-Driven Tool Tiering

Your jcodemunch-mcp server narrows the exposed tool list based on the model you are running as. To avoid wasting requests on primitives when a composite would do, always include `model="<your-model-id>"` in your opening `plan_turn` call.

Replace `<your-model-id>` with your active model:

- Claude Opus variants → `claude-opus-4-7` (or any `claude-opus-*`)
- Claude Sonnet variants → `claude-sonnet-4-6`
- Claude Haiku variants → `claude-haiku-4-5`
- GPT-4o / GPT-5 / o1 / Llama → use the model id as printed by your runner

The `model=` parameter rides on the existing `plan_turn` call — it does **not** add a separate tool invocation. If `plan_turn` is not appropriate for a non-code task, call `announce_model(model="...")` once instead.
