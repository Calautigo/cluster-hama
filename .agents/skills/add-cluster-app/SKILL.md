---
name: add-cluster-app
description: "Adds a new application to the cluster-hama Flux GitOps repo (thestral cluster). Follows the pgadmin reference pattern: creates ks.yaml + app/ manifests, registers the app in the namespace kustomization, wires secrets through Vault ExternalSecrets, optionally adds kopiur PVC backups, Pocket-ID OIDC, and NetBird VPN exposure (public HTTPRoute or private TCPRoute), then validates with flux build --dry-run. Use when asked to add/onboard/deploy a new app or service to the cluster."
---

# Add a Cluster App

Adds an app to the Flux-managed cluster-hama repo. Every app lives in
`kubernetes/apps/<ns>/<app>/`; Flux reconciles from git push, so nothing is
applied to the cluster directly.

Reference example: `kubernetes/apps/database/pgadmin/` (persistent + OIDC),
`kubernetes/apps/services/termix/` (minimal persistent app).

## Preconditions

- Work in the repo root (`/home/maus/projects/cluster-hama`).
- `flux` CLI available; `KUBECONFIG` set by mise (check `.mise.toml`).
- Vault access to create `apps/<app>` secret entries (CLI or UI).
- `<ns>` and `<app>` chosen: `<app>` is lowercase, k8s-name-safe, used as the
  release name and hostname (`<app>.ds47.dev`).

## Conventions to Follow

- Every manifest starts with a `# yaml-language-server: $schema=...` comment
  (copy from pgadmin/termix).
- ks.yaml uses `name: &app <app>` anchor + `commonMetadata.labels:
  app.kubernetes.io/name: *app`, `prune: true`, `wait: false`, `interval: 30m`,
  `timeout: 5m`, `dependsOn` for ordering.
- Routes use app-template `route:` values with hostname
  `"{{ .Release.Name }}.ds47.dev"` (or literal `<app>.ds47.dev`) and
  `parentRefs: [{ name: kgateway-internal, namespace: network }]`.
- Substitutions (`${APP}`, `${KOPIUR_CAPACITY}`, ...) happen at reconcile time
  via ks.yaml `postBuild.substitute`; `cluster-settings`/`cluster-secrets`
  provide `TZ`/`CONFIG_TIMEZONE` etc. Only non-secret config in the repo.
- App credentials go through Vault via `ExternalSecret`
  (ClusterSecretStore `vault`, KV-v2 mount `apps`, so `key: <app>` reads
  `apps/<app>`).

## Steps

### 1. Scaffold the directory

```
kubernetes/apps/<ns>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    ├── [externalsecret.yaml]   # if app needs secrets
    ├── [oidcclient.yaml]       # if app supports OIDC via Pocket-ID
    └── [httproute.yaml|tcproute.yaml]  # NetBird routes for non app-template apps
```

Copy the closest existing app (pgadmin for persistent+OIDC, termix for a simple
persistent app, it-tools for a stateless one) and rename every occurrence.

### 2. ks.yaml

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app>
  namespace: <ns>
spec:
  targetNamespace: <ns>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: external-secrets
      namespace: external-secrets
    # add only what the app actually needs:
    - name: ceph-csi-rbd
      namespace: storage        # if it has a PVC
    - name: kopiur
      namespace: system          # if it uses the kopiur component
    - name: pocket-id-instance
      namespace: security        # if it has an oidcclient.yaml
  components:
    - ../../../../components/kopiur   # only if persistent data
  path: ./kubernetes/apps/<ns>/<app>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
  interval: 30m
  timeout: 5m
  postBuild:
    substitute:
      APP: *app
      # KOPIUR_CLAIM: <app>-data   # default is ${APP}; override for multi-PVC apps
      # KOPIUR_CAPACITY: 5Gi
```

`dependsOn` entries must reference real Kustomizations (check names with
`flux get ks -A`). External-secrets is required whenever you use an
`externalsecret.yaml`.

### 3. app/kustomization.yaml

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  # - ./externalsecret.yaml
  # - ./oidcclient.yaml
configMapGenerator: []   # only if the app ships config files (see pgadmin)
generatorOptions:
  disableNameSuffixHash: true   # if you use configMapGenerator
```

### 4. app/ocirepository.yaml

Chart from the bjw-s app-template registry, version pinned (Renovate bumps):

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: <app>
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: <app-template-chart-version>   # e.g. 5.0.1; verify against an existing app
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

If the app ships its own chart, check the upstream repo for an OCI/pull location
instead and note it.

### 5. app/helmrelease.yaml

app-template structure; key blocks: `chartRef.kind: OCIRepository`, `name: <app>`,
`controllers.<app>.containers.app.image` (pin `tag: x@sha256:...`, Renovate
bumps digests), `service`, `route`, `persistence` (PVC via `existingClaim`).
Copy the schema comment from pgadmin's helmrelease.yaml. Use `*app` anchors and
yaml anchors for repeated values (e.g. `&port` + `port: *port`) like termix.

### 6. Secrets (Vault ExternalSecret)

1. Create the secret in Vault at `apps/<app>` (KV-v2 mount `apps`).
2. Add `externalsecret.yaml` (copy pgadmin's): `secretStoreRef` →
   `ClusterSecretStore` `vault`, `target.name: <app>-secret`, and
   `dataFrom: [{ extract: { key: <app> } }]`. Use `template.data` to map Vault
   keys to env var names the app expects, and a second ExternalSecret with a
   `Password` generator (`password32`, see pgadmin-password) for generated
   credentials like DB passwords. Set `refreshInterval: "0"` for generated
   secrets so they are not regenerated.
3. Reference in the HelmRelease via `envFrom: [{ secretRef: { name: <app>-secret } }]`
   (reloader annotation `reloader.stakater.com/auto: "true"` on the controller
   picks up changes).
4. For registry credentials (imagePullSecrets), use the same pattern with a
   `dockerconfigjson` type target and reference it in the OCIRepository or pod
   spec as applicable.

### 7. Persistent data (kopiur)

Include the kopiur component in ks.yaml (step 2). It creates the PVC
`${KOPIUR_CLAIM:-${APP}}`, a kopia Repository, garage S3 backup, snapshot
policy and hourly schedule automatically. Mount it in the HelmRelease:

```yaml
persistence:
  data:
    existingClaim: ${APP}    # or the KOPIUR_CLAIM override
    globalMounts:
      - path: /app/data
```

Optional `KOPIUR_` overrides (all have sane defaults): `CLAIM`, `CAPACITY`
(5Gi), `ACCESSMODES`, `STORAGECLASS`, `SNAPSHOTCLASS`, `SCHEDULE`,
`COPYMETHOD`, `KEEP_*` retention. The app's `runAsUser`/`runAsGroup` should
match `APP_UID`/`APP_GID` (2000) for the kopiur mover; if not, override them.

### 8. OIDC via Pocket-ID (optional)

Copy pgadmin's `oidcclient.yaml`. Requirements:

- `allowedUserGroups` defaults to `[{ name: hama, namespace: security }]`; the
  group CR must exist in `security/pocket-id-instance/app/usergroup-*.yaml`
  (hama, media, services). Widen beyond hama only deliberately.
- `secret.name: <app>-oidc` + keys `clientID`/`clientSecret`/`issuerUrl` map
  into env var names; reference that secret in `envFrom`.
- Group CRs manage existence/friendlyName/customClaims only; do not set
  `spec.users`. customClaims must mirror the Pocket-ID UI or the operator
  overwrites it.
- Add `pocket-id-instance` to ks.yaml `dependsOn`.

### 9. NetBird access (optional)

NetBird exposes apps to the VPN mesh via Gateway API routes backed by the
netbird-operator (ns `network`, cluster `axon`):

- **Public**: `HTTPRoute` through the `netbird-public` Gateway
  (`gatewayClassName: netbird-public`) - reachable by VPN members at a
  `*.ds47.dev` hostname via the NetBird reverse proxy.
- **Private**: `TCPRoute` through the `netbird-private` Gateway
  (`gatewayClassName: netbird-private`) - raw TCP to VPN peers only, no public
  hostname.

Both gateways already allow routes from all namespaces
(`allowedRoutes.namespaces.from: All`), so adding a route for a new app needs
no changes under `kubernetes/apps/network/netbird/` - just declare the route.

**app-template apps** (most): add a second named block under `route:` in the
HelmRelease. Reference: immich (dual kgateway + netbird-public), jellyfin
(netbird-private TCP):

```yaml
    route:
      app:            # kgateway-internal (public internet), as usual
        hostnames:
          - "{{ .Release.Name }}.ds47.dev"
        parentRefs:
          - name: kgateway-internal
            namespace: network
      public:         # NetBird reverse proxy (VPN members)
        hostnames:
          - ${APP_SUBDOMAIN:-${APP}}.ds47.dev
        parentRefs:
          - name: netbird-public
            namespace: network
        rules:
          - backendRefs:
              - identifier: server
                port: 80
      private:        # raw TCP, peers only (see jellyfin)
        kind: TCPRoute
        parentRefs:
          - name: netbird-private
            namespace: network
```

**Non app-template apps**: add a standalone `app/httproute.yaml` or
`app/tcproute.yaml` (copy `kubernetes/apps/dev/coder/app/httproute.yaml`) with
`parentRefs: [{name: netbird-public|netbird-private, namespace: network}]` and
list it in `app/kustomization.yaml`.

Notes:

- The NetBird DNS zone is `ds47.dev` (`NetworkRouter` `axon`,
  `dnsZoneRef: ds47.dev`); public hostnames must end in `.ds47.dev`.
- Public and kgateway routes for the same hostname coexist fine (immich);
  external-dns handles the record. Use `${APP_SUBDOMAIN:-${APP}}` when the
  NetBird hostname should differ from the release name.
- Touching `kubernetes/apps/network/netbird/router/` (NetworkRouter
  `dnsZoneRef`, Gateway listener name) is for new domains/listeners only - it
  is a separate KS (`netbird-router`) that depends on `netbird`.

### 10. Register the app

Existing namespace: add `./<app>/ks.yaml` to
`kubernetes/apps/<ns>/kustomization.yaml` (alphabetical order).

New namespace:
- `kubernetes/apps/<ns>/namespace.yaml` (copy database's: `kopiur.home-operations.com/privileged-movers: "true"` annotation if persistent apps, `pod-security.kubernetes.io` labels).
- `kubernetes/apps/<ns>/kustomization.yaml` with `namespace: <ns>`,
  `./namespace.yaml`, all `./<app>/ks.yaml` entries, and
  `components: [../../components/common]`.
- Add `./<ns>` to `kubernetes/apps/kustomization.yaml`.

### 11. Validate

```bash
flux -n <ns> build kustomization <app> --path kubernetes/apps/<ns>/<app>/app \
  --kustomization-file kubernetes/apps/<ns>/<app>/ks.yaml --dry-run
```

Fix any errors before pushing. Optionally check the whole namespace:

```bash
flux -n <ns> build kustomization <app> ... --dry-run
```

### 12. Deploy and verify

Push to `main` (Flux reconciles) or force-sync:
`just k8s sync-ks <ns> <app>` (KS) / `just k8s sync-hr <ns> <app>` (HR).
**Do not use `just k8s apply-ks <ns> <app>` unless asked: it applies to the
live cluster directly.**

Monitor: `flux get ks <app> -n <ns>`, `flux get hr <app> -n <ns>`,
`flux logs --kind=HelmRelease --name=<app>`. If OIDC was added, log in via
Pocket-ID and confirm the user is in the `hama` group.

## Pitfalls

- Missing `# yaml-language-server` schema comments or non-2-space indent break
  oxfmt/lefthook on commit; run `just --fmt` before committing.
- `components` paths are relative to the KS (ks.yaml sits in
  `kubernetes/apps/<ns>/<app>/`, so kopiur is `../../../../components/kopiur`).
- A `dependsOn` referencing a nonexistent Kustomization stalls reconcile; verify
  names with `flux get ks -A`.
- Never put secrets (passwords, tokens) in repo YAML; only Vault keys via
  ExternalSecret. Keep `*.sops.yaml` files encrypted; lefthook blocks
  unencrypted ones.
- `app.kubernetes.io/name` is overridden by ks.yaml `commonMetadata`; use
  `app.kubernetes.io/component` for labels that must survive.
- PV-backed apps: PVC comes from the kopiur component; do not also declare one
  in the HelmRelease or app manifests (oxicloud declares its PVC inline in
  `app/pvc.yaml`; new apps should use the kopiur component instead).
