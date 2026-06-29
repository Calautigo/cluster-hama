# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps homelab repository managing a Talos Linux Kubernetes cluster ("thestral") via Flux CD. All changes are deployed by pushing to `main` — Flux reconciles the Git state to the cluster. The task runner is `just` — run `just -l` at repo root or inside a module directory to list available commands.

## Common Commands

```bash
just -l                                          # List all tasks
just thestral-talos render-config <node>         # Render Talos config for a node
just thestral-talos apply-node <node>            # Apply Talos config to a node
just thestral-talos apply-cluster                # Apply Talos config to all nodes
just thestral-talos reboot-node <node>           # Reboot a node
just thestral-talos upgrade-node <node>          # Upgrade Talos on a node
just thestral-talos upgrade-k8s <version>        # Upgrade Kubernetes version
just thestral-talos gen-schematic-id             # Generate Talos schematic ID
just thestral sync-hr <namespace> <name>         # Sync a Flux HelmRelease
just thestral sync-ks <namespace> <name>         # Sync a Flux Kustomization
just thestral sync-es <namespace> <name>         # Sync an ExternalSecret
just thestral sync-all-hr                        # Sync all HelmReleases
just thestral apply-ks <namespace> <ks>          # Apply local Kustomization
just thestral snapshot <namespace> <name>        # Trigger VolSync snapshot
just thestral browse-pvc <namespace> <claim>     # Browse a PVC
just thestral node-shell <node>                  # Open node shell
just thestral prune-pods                         # Prune failed/pending pods

flux get ks -A                                   # List all Flux Kustomizations and status
flux get hr -A                                   # List all HelmReleases and status
flux logs --kind=HelmRelease --name=<app>        # Flux logs for a specific app
kubectl get hr -A                                # Quick HelmRelease status check
```

Node names: `thestral-01`, `thestral-02`, `thestral-03` (control plane), `thestral-worker-01`, `thestral-worker-02`, `thestral-worker-03` (worker plane).

## Architecture

### Deployment Flow

```
Git push → Flux GitRepository → cluster-apps Kustomization → per-namespace Kustomization → per-app Kustomization → HelmRelease/resources
```

### Directory Layout

```
kubernetes/
├── apps/<namespace>/<app>/        # Application deployments
│   ├── ks.yaml                    # Flux Kustomization (metadata, deps, components)
│   └── app/
│       ├── kustomization.yaml     # Kustomize resource list
│       ├── helmrelease.yaml       # Helm chart values
│       ├── ocirepository.yaml     # OCI chart source (if not shared)
│       └── externalsecret.yaml    # Secret injection (if needed)
├── bootstrap/                     # One-time cluster bootstrap (helmfile, CRDs)
├── components/                    # Reusable Kustomize components
│   ├── common/                    # Common labels/annotations
│   ├── dragonfly/                 # Dragonfly (Redis-compatible) connection config
│   ├── gpu/                       # Intel GPU resource limits
│   └── volsync/                   # PVC backup component
└── flux/                          # Flux config (GitRepository, Kustomization entrypoints)
talos/
├── machineconfig.yaml.j2          # Base Talos config template (MinJinja)
├── schematic.yaml                 # Talos OS extension list
├── talsecret.sops.yaml            # SOPS-encrypted Talos secrets
├── nodes/                         # Per-node config patches (*.yaml.j2)
└── mod.just                       # Talos node management tasks
.justfile                          # Root just file; imports thestral, thestral-bootstrap, thestral-talos modules
.sops.yaml                         # SOPS Age encryption rules
renovate.json5                     # Renovate dependency update bot config
```

### App Structure Pattern

**ks.yaml** (Flux Kustomization): defines app name, namespace, path, dependencies, components, and `postBuild.substitute` vars. Uses YAML anchors (`&app`, `&namespace`) for DRY naming.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app myapp
  namespace: mynamespace
spec:
  targetNamespace: mynamespace
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/mynamespace/myapp/app
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 1Gi
```

**helmrelease.yaml**: most apps use the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart via OCI (`chartRef.kind: OCIRepository`).

**Variable substitution**: `${SECRET_DOMAIN}`, `${APP}`, etc. in manifests are replaced at reconciliation time from `cluster-settings`/`cluster-secrets` ConfigMaps/Secrets. Use Flux substitution only for non-secret configuration. App credentials must go through Vault via ExternalSecret.

**Multi-component apps**: split into multiple Flux Kustomizations in the same `ks.yaml` (separated by `---`). Use `dependsOn` for ordering. Each component with the VolSync component gets its own PVC named `${APP}`.

### Secrets

- **HashiCorp Vault** (preferred for app secrets): `ExternalSecret` resources pull from the `hashicorp-vault` ClusterSecretStore. Vault path convention: `apps/<namespace>/<app-name>`.
- **SOPS + Age**: files matching `*.sops.yaml` are encrypted. Flux decrypts automatically via the `sops-age` secret. Used for Talos secrets and cluster-level bootstrap secrets, not app credentials.
- Key at `~/.config/sops/age/talos-age.key` (also `$SOPS_AGE_KEY_FILE`).
- Encrypt: `sops -e -i <file>` — Decrypt: `sops -d <file>`

### Talos Config Rendering

Node configs are MinJinja templates (`.yaml.j2`) rendered at apply time:
- `talos/machineconfig.yaml.j2` — base config for all nodes
- `talos/nodes/<node>.yaml.j2` — per-node patches (sets `controlplane` vs `worker`)
- Secrets are injected from `talos/talsecret.sops.yaml` via `sops://namespace/.path.to.key` references at render time

### Networking

- **kgateway**: Gateway API-based ingress in the `network` namespace.
- Apps expose routes via HTTPRoute resources referencing the gateway.

### Renovate

Automated dependency updates via Renovate. Config in `renovate.json5` with presets in `.renovate/`. Handles Flux manifests, Docker image digests, Helm chart versions, and Talos configs. Files matching `*.sops.*` are excluded.

### Label Convention

`app.kubernetes.io/name` is set via `commonMetadata.labels` in `ks.yaml` and propagates to all resources. Use `app.kubernetes.io/component` for labels that must survive Flux's `commonMetadata` override.

### Key Infrastructure

- **3 control-plane nodes** + **3 worker nodes** running Talos Linux
- **Cilium** CNI (bootstrapped before other apps)
- **External Secrets Operator** → HashiCorp Vault for secret injection
- **CloudNative-PG** for PostgreSQL, **Dragonfly** for Redis-compatible caching
- **VolSync** for PVC backups (Restic)
- **kube-prometheus-stack** for monitoring

## Linting

Git hooks are managed by [Lefthook](https://github.com/evilmartians/lefthook). Install hooks once after cloning:

```bash
lefthook install
```

On each commit, Lefthook runs:
- **yamlfmt** — formats all staged YAML files in-place and re-stages them (config: `.yamlfmt.yaml`)
- **forbid-unencrypted-sops** — blocks commits of `*.sops.yaml` files that are not SOPS-encrypted

YAML rules (enforced by yamlfmt): 2-space indentation, LF line endings. SOPS-encrypted files are excluded from formatting.

## Tool Requirements

`talosctl`, `kubectl`, `flux`, `helm`, `helmfile`, `just`, `sops`, `age`, `minijinja-cli`, `yq`, `jq`, `gum`, `flux-local` (pip install for `apply-ks`/`delete-ks`).
