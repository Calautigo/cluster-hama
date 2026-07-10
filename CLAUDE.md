# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps homelab repository managing a Talos Linux Kubernetes cluster ("thestral") via Flux CD. All changes are deployed by pushing to `main` — Flux reconciles the Git state to the cluster. The task runner is `just` with three modules: `k8s` (Flux/cluster operations), `talos` (node management), and `bootstrap` (one-time cluster bootstrap).

## Environment

[mise](https://mise.jdx.dev) (`.mise.toml`) sets the required environment variables relative to the repo root:

- `KUBECONFIG` → `./kubeconfig`
- `TALOSCONFIG` → `./talos/clusterconfig/talosconfig`
- `SOPS_AGE_KEY_FILE` → `./age.key`
- `MINIJINJA_CONFIG_FILE` → `./.minjinja.toml`

All of these files are gitignored. mise's postinstall hook runs `lefthook install`, so git hooks are set up automatically.

Tools are installed via Homebrew (`Brewfile`). Additionally required: `sops`, `age`, `gum`, `oxfmt`, and `flux-local` (pip, for `just k8s apply-ks`/`delete-ks`).

## Common Commands

```bash
just -l --list-submodules            # List all tasks in all modules

just talos render-config <node>      # Render Talos config for a node
just talos apply-node <node>         # Apply Talos config to a node
just talos apply-cluster             # Apply Talos config to all nodes
just talos reboot-node <node>        # Reboot a node
just talos upgrade-node <node>       # Upgrade Talos on a node
just talos upgrade-k8s <version>     # Upgrade Kubernetes version
just talos gen-schematic-id          # Generate Talos schematic ID

just k8s sync-hr <namespace> <name>  # Sync a Flux HelmRelease
just k8s sync-ks <namespace> <name>  # Sync a Flux Kustomization
just k8s sync-es <namespace> <name>  # Sync an ExternalSecret
just k8s sync-all-hr                 # Sync all HelmReleases (also: sync-all-ks, sync-all-es)
just k8s apply-ks <namespace> <ks>   # Apply local Kustomization (requires flux-local)
just k8s snapshot <namespace> <name> # Trigger VolSync snapshot
just k8s backup <namespace> <name>   # Force VolSync backup and wait for completion
just k8s volsync <suspend|resume>    # Suspend/resume VolSync
just k8s browse-pvc <namespace> <claim>  # Browse a PVC
just k8s node-shell <node>           # Open node shell
just k8s prune-pods                  # Prune failed/pending pods

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
├── mod.just                       # just module `k8s`: Flux/cluster operations
├── apps/<namespace>/<app>/        # Application deployments
│   ├── ks.yaml                    # Flux Kustomization (metadata, deps, components)
│   └── app/
│       ├── kustomization.yaml     # Kustomize resource list
│       ├── helmrelease.yaml       # Helm chart values
│       ├── ocirepository.yaml     # OCI chart source (if not shared)
│       └── externalsecret.yaml    # Secret injection (if needed)
├── bootstrap/                     # just module `bootstrap`: one-time cluster bootstrap (helmfile, CRDs)
├── components/                    # Reusable Kustomize components
│   ├── common/                    # Common labels/annotations
│   ├── dragonfly/                 # Dragonfly (Redis-compatible) connection config
│   ├── gpu/                       # Intel GPU resource limits
│   └── volsync/                   # PVC backup component
└── flux/                          # Flux config (GitRepository, Kustomization entrypoints)
talos/
├── mod.just                       # just module `talos`: node management tasks
├── machineconfig.yaml.j2          # Base Talos config template (MinJinja)
├── schematic.yaml                 # Talos OS extension list
├── talsecret.sops.yaml            # SOPS-encrypted Talos secrets
└── nodes/                         # Per-node config patches (*.yaml.j2)
.justfile                          # Root just file; imports the k8s, bootstrap, talos modules
.mise.toml                         # Env vars (KUBECONFIG, TALOSCONFIG, SOPS_AGE_KEY_FILE) + postinstall hook
.sops.yaml                         # SOPS Age encryption rules
lefthook.toml                      # Git hooks (pulls shared config from home-operations/.github)
oxfmtrc.json                       # oxfmt formatter config (YAML/JSON/Markdown)
Brewfile                           # Tool installation via Homebrew
renovate.json5                     # Renovate dependency update bot config
```

### App Structure Pattern

**ks.yaml** (Flux Kustomization): defines app name, namespace, path, dependencies, components, and `postBuild.substitute` vars. Uses YAML anchors (`&app`, `&namespace`) for DRY naming.

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app myapp
spec:
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    interval: 30m
    timeout: 5m
    path: ./kubernetes/apps/mynamespace/myapp/app
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
    targetNamespace: mynamespace
    wait: false
    # Only for apps with persistent data:
    dependsOn:
        - name: volsync
          namespace: volsync-system
    components:
        - ../../../../components/volsync
    postBuild:
        substitute:
            APP: *app
            VOLSYNC_CAPACITY: 1Gi
```

The VolSync component creates a PVC named `${VOLSYNC_CLAIM:-${APP}}` and sets up backups. Substitution vars (all optional): `VOLSYNC_CLAIM`, `VOLSYNC_CAPACITY` (default `5Gi`), `VOLSYNC_ACCESSMODES` (`ReadWriteOnce`), `VOLSYNC_STORAGECLASS` (`csi-rbd-sc`), `VOLSYNC_SNAPSHOTCLASS`, `VOLSYNC_KOPIA_SCHEDULE`.

**helmrelease.yaml**: most apps use the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart via OCI (`chartRef.kind: OCIRepository`).

**Variable substitution**: `${SECRET_DOMAIN}`, `${APP}`, etc. in manifests are replaced at reconciliation time from `cluster-settings`/`cluster-secrets` ConfigMaps/Secrets. Use Flux substitution only for non-secret configuration. App credentials must go through Vault via ExternalSecret.

**Multi-component apps**: split into multiple Flux Kustomizations in the same `ks.yaml` (separated by `---`). Use `dependsOn` for ordering. Each component with the VolSync component gets its own PVC named `${APP}`.

### Adding a New App

1. Create `kubernetes/apps/<namespace>/<app>/` with `ks.yaml` (see pattern above) and `app/` containing:

    **kustomization.yaml** — list all resources in `app/`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://json.schemastore.org/kustomization
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
        - ./ocirepository.yaml
        - ./helmrelease.yaml
    ```

    **ocirepository.yaml** — chart source (app-template shown; pin the chart version, Renovate updates it):

    ```yaml
    ---
    # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
        name: myapp
    spec:
        interval: 15m
        layerSelector:
            mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
            operation: copy
        ref:
            tag: 5.0.1
        url: oci://ghcr.io/bjw-s-labs/helm/app-template
    ```

    **helmrelease.yaml** — skeleton for the app-template chart:

    ```yaml
    ---
    # yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
        name: &app myapp
    spec:
        chartRef:
            kind: OCIRepository
            name: myapp
        interval: 30m
        values:
            controllers:
                myapp:
                    containers:
                        app:
                            image:
                                repository: ghcr.io/example/myapp
                                tag: 1.0.0
                            env:
                                TZ: ${CONFIG_TIMEZONE}
            service:
                app:
                    controller: myapp
                    ports:
                        http:
                            port: 8080
            route:
                app:
                    hostnames:
                        - "{{ .Release.Name }}.ds47.dev"
                    parentRefs:
                        - name: kgateway-internal
                          namespace: network
            persistence:
                config:
                    existingClaim: ${APP} # PVC created by the volsync component
    ```

2. Register `./<app>/ks.yaml` in `kubernetes/apps/<namespace>/kustomization.yaml` (this sets the Kustomization's namespace).
3. New namespace: create `kubernetes/apps/<namespace>/` with `namespace.yaml` and a `kustomization.yaml` that includes `namespace: <namespace>`, all `./<app>/ks.yaml` entries, `./namespace.yaml`, and the `../../components/common` component; then add `./<namespace>` to `kubernetes/apps/kustomization.yaml`.
4. Secrets: create the Vault entry at `apps/<namespace>/<app>`, pull it via `externalsecret.yaml` (ClusterSecretStore `hashicorp-vault`), and add it to `app/kustomization.yaml`.
5. Persistent data: add the `volsync` component, `dependsOn` volsync, and `VOLSYNC_CAPACITY` in `ks.yaml` (see pattern above).
6. SSO: if the app supports OIDC, add `oidcclient.yaml` (see [SSO / Pocket-ID](#sso--pocket-id)) and register it in `app/kustomization.yaml`.
7. Validate before pushing: `just k8s apply-ks <namespace> <app>` renders and applies the Kustomization locally via flux.

### SSO / Pocket-ID

App SSO is managed by the `pocket-id-operator` (`kubernetes/apps/security/pocket-id-operator`) against the `pocket-id` instance (`kubernetes/apps/security/pocket-id-instance`). Each app that supports OIDC gets a `PocketIDOIDCClient` resource (`app/oidcclient.yaml`):

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/aclerici38/pocket-id-operator/main/dist/schemas/pocketidoidcclient_v1alpha1.json
apiVersion: pocketid.internal/v1alpha1
kind: PocketIDOIDCClient
metadata:
    name: myapp
spec:
    name: MyApp
    allowedUserGroups:
        - name: hama
          namespace: security
    launchUrl: https://myapp.ds47.dev
    callbackUrls:
        - https://myapp.ds47.dev/oauth/callback
    secret:
        name: myapp-oidc
        keys:
            clientID: OIDC_CLIENT_ID
            clientSecret: OIDC_CLIENT_SECRET
            issuerUrl: OIDC_ISSUER_URL
```

- **`allowedUserGroups` is required and defaults to `hama`** (the admin/owner `PocketIDUserGroup`, defined in `kubernetes/apps/security/pocket-id-instance/app/usergroup-hama.yaml`, adopting the pre-existing Pocket-ID group of the same name). Omitting `allowedUserGroups` leaves the client **unrestricted** — every registered Pocket-ID user (including other household/family groups) can log in. Only widen access beyond `hama` to another group deliberately, per app.
- **A referenced group must have a `PocketIDUserGroup` CR** — the operator resolves `allowedUserGroups` refs to CRs, and reconcile fails if the CR is missing or not Ready. All existing groups are modeled under `kubernetes/apps/security/pocket-id-instance/app/usergroup-*.yaml` (`hama`, `mimler`, `schwarz`).
- **The CRs manage group existence, `friendlyName`, and `customClaims` only — not membership.** `spec.users` is intentionally omitted, so who belongs to each group is managed in the Pocket-ID UI and preserved across reconciles. Note `customClaims` _is_ operator-managed: it must mirror the UI exactly or the operator will overwrite it.
- The `secret` block causes the operator to write the client ID/secret/issuer (and other OIDC endpoints, depending on keys requested) into a Kubernetes Secret consumed by the app's `helmrelease.yaml` env vars.

### Secrets

- **HashiCorp Vault** (preferred for app secrets): `ExternalSecret` resources pull from the `hashicorp-vault` ClusterSecretStore. Vault path convention: `apps/<namespace>/<app-name>`.
- **SOPS + Age**: files matching `*.sops.yaml` are encrypted. Flux decrypts automatically via the `sops-age` secret. Used for Talos secrets and cluster-level bootstrap secrets, not app credentials.
- The Age key is expected at `./age.key` (gitignored; `SOPS_AGE_KEY_FILE` set by mise).
- Encrypt: `sops -e -i <file>` — Decrypt: `sops -d <file>`

### Talos Config Rendering

Node configs are MinJinja templates (`.yaml.j2`) rendered at apply time:

- `talos/machineconfig.yaml.j2` — base config for all nodes
- `talos/nodes/<node>.yaml.j2` — per-node patches (sets `controlplane` vs `worker`)
- Secrets are injected from `talos/talsecret.sops.yaml` via `sops://namespace/.path.to.key` references at render time

### Networking

- **kgateway**: Gateway API-based ingress in the `network` namespace (gateways: `kgateway-internal`, external).
- Apps expose routes via the app-template `route:` values (rendered as HTTPRoute) or standalone HTTPRoute resources referencing the gateway.

### Renovate

Automated dependency updates via Renovate. Config in `renovate.json5` with presets in `.renovate/`. Handles Flux manifests, Docker image digests, Helm chart versions, and Talos configs. Files matching `*.sops.*` are excluded.

### Label Convention

`app.kubernetes.io/name` is set via `commonMetadata.labels` in `ks.yaml` and propagates to all resources. Use `app.kubernetes.io/component` for labels that must survive Flux's `commonMetadata` override.

### Key Infrastructure

- **3 control-plane nodes** + **3 worker nodes** running Talos Linux
- **Cilium** CNI (bootstrapped before other apps)
- **External Secrets Operator** → HashiCorp Vault for secret injection
- **CloudNative-PG** for PostgreSQL, **Dragonfly** for Redis-compatible caching, **MariaDB**, **InfluxDB**, **EMQX** (MQTT)
- **VolSync** for PVC backups
- **KEDA** for autoscaling (`just k8s keda`/`keda-all` to suspend/resume)
- **kube-prometheus-stack** for monitoring

## Linting

Git hooks are managed by [Lefthook](https://github.com/evilmartians/lefthook) (`lefthook.toml`) and installed automatically via mise's postinstall hook (`lefthook install` to do it manually).

On each commit:

- Shared jobs from [home-operations/.github](https://github.com/home-operations/.github) (`lefthook.common.toml`): **oxfmt** formats staged YAML/JSON/Markdown files in-place (config: `oxfmtrc.json`), `just --fmt` formats justfiles, **shellcheck** lints shell scripts.
- Local job **forbid-unencrypted-sops**: blocks commits of `*.sops.yaml` files that are not SOPS-encrypted.

YAML rules: 2-space indentation, LF line endings, print width 100.
