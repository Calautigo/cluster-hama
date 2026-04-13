# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a **Talos Linux + Kubernetes homelab cluster** ("thestral") managed via **Flux GitOps**. All cluster state is declared in this repository and reconciled automatically. The task runner is `just` — run `just -l` at repo root or inside a module directory to list available commands.

## Repository Structure

```
kubernetes/
  apps/          # Application manifests, one directory per namespace
  bootstrap/     # One-time cluster bootstrap (helmfile, resources, CRDs)
  components/    # Shared Kustomize components (volsync, dragonfly, gpu, namespace)
  flux/          # Flux GitRepository, Kustomization entrypoints
  mod.just       # Kubernetes day-2 tasks
  bootstrap/mod.just  # Bootstrap tasks (run once)
talos/
  machineconfig.yaml.j2   # Base Talos config template (MinJinja)
  schematic.yaml          # Talos OS extension list (Intel GPU, ucode, thunderbolt)
  talsecret.sops.yaml     # SOPS-encrypted Talos secrets
  nodes/                  # Per-node config patches (*.yaml.j2)
  mod.just                # Talos node management tasks
.justfile                 # Root just file; imports thestral, thestral-bootstrap, thestral-talos modules
.sops.yaml                # SOPS Age encryption rules
.yamllint.yaml            # YAML lint config (via .github/lint/.yamllint.yaml)
renovate.json5            # Renovate dependency update bot config
```

## Common Commands

All `just` commands are namespaced by module. From root, use the module prefix:

| Task | Command |
|---|---|
| List all tasks | `just -l` |
| Render Talos config for a node | `just thestral-talos render-config <node>` |
| Apply Talos config to a node | `just thestral-talos apply-node <node>` |
| Apply Talos config to all nodes | `just thestral-talos apply-cluster` |
| Reboot a node | `just thestral-talos reboot-node <node>` |
| Upgrade Talos on a node | `just thestral-talos upgrade-node <node>` |
| Upgrade Kubernetes version | `just thestral-talos upgrade-k8s <version>` |
| Generate Talos schematic ID | `just thestral-talos gen-schematic-id` |
| Sync a Flux HelmRelease | `just thestral sync-hr <namespace> <name>` |
| Sync a Flux Kustomization | `just thestral sync-ks <namespace> <name>` |
| Sync an ExternalSecret | `just thestral sync-es <namespace> <name>` |
| Sync all HelmReleases | `just thestral sync-all-hr` |
| Apply local Kustomization | `just thestral apply-ks <namespace> <ks>` |
| Trigger VolSync snapshot | `just thestral snapshot <namespace> <name>` |
| Browse a PVC | `just thestral browse-pvc <namespace> <claim>` |
| Open node shell | `just thestral node-shell <node>` |
| Prune failed/pending pods | `just thestral prune-pods` |

Node names: `thestral-01`, `thestral-02`, `thestral-03` (control plane), `thestral-worker-01/02/03`.

## Linting

Pre-commit hooks validate YAML and prevent committing unencrypted secrets:

```bash
pre-commit run --all-files
```

YAML rules: double quotes required, no line-length limit, 2-space indentation. SOPS-encrypted files (`*.sops.yaml`) are excluded from linting.

## Secret Management (SOPS + Age)

Secrets are encrypted with Age. The key must be present at `~/.config/sops/age/talos-age.key` (also read from `$SOPS_AGE_KEY_FILE`).

- Encrypt a secret: `sops -e -i <file>`
- Decrypt a secret: `sops -d <file>`
- Files matching `clusters/*/talos/*.sops.yaml` and `clusters/*/bootstrap/*.sops.yaml` are auto-encrypted on commit.
- Talos configs support `sops://namespace/.path.to.key` references that are injected at render time via `just template`.

## Architecture

### GitOps Flow

1. Changes committed to `main` → Flux detects and reconciles
2. HelmReleases and Kustomizations in `kubernetes/apps/` define all workloads
3. Renovate bot opens PRs for dependency updates (auto-merge on minor/patch)

### Talos Config Rendering

Node configs are MinJinja templates (`.yaml.j2`) rendered at apply time:
- `talos/machineconfig.yaml.j2` — base config for all nodes
- `talos/nodes/<node>.yaml.j2` — per-node patches (sets `controlplane` vs `worker`)
- Secrets are injected from `talos/talsecret.sops.yaml` via `sops://` references

### Kubernetes App Layout

Each namespace under `kubernetes/apps/<namespace>/` follows the pattern:
- `ks.yaml` — Flux Kustomization(s) pointing to app subdirectories
- `<app>/helmrelease.yaml` — Helm chart config
- `<app>/externalsecret.yaml` — secrets pulled from Vault via External Secrets Operator

### Shared Components (`kubernetes/components/`)

Reusable Kustomize components included by apps:
- `volsync` / `volsync-ns` — PVC backup/restore via VolSync (Restic)
- `dragonfly` — Dragonfly (Redis-compatible) connection config
- `gpu` — Intel GPU resource limits
- `common` — common labels/annotations
- `namespace` — standard namespace setup

### Cluster Infrastructure

- **3 control-plane nodes** + **3 worker nodes** running Talos Linux
- **Cilium** CNI (bootstrapped before other apps)
- **External Secrets Operator** → HashiCorp Vault for secret injection
- **CloudNative-PG** for PostgreSQL, **Dragonfly** for Redis-compatible caching
- **VolSync** for PVC backups
- **kube-prometheus-stack** for monitoring

## Tool Requirements

Tools expected in `PATH`: `talosctl`, `kubectl`, `flux`, `helm`, `helmfile`, `just`, `sops`, `age`, `minijinja-cli`, `yq`, `jq`, `gum`, `flux-local` (pip install for `apply-ks`/`delete-ks`).
