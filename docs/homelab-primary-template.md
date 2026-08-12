# Homelab Primary - Skeleton Template

> **How to use this template**
> This document is a skeleton for documenting the _primary_ part of the homelab:
> the Kubernetes cluster. Sections marked **`<TO FILL>`** are placeholders to
> complete; everything else is filled in from the live repo (`cluster-hama`).
> Keep this file in sync with `kubernetes/` and `talos/`; Renovate/Flux changes
> should be mirrored here. The canonical copy for the wiki lives at
> `wiki.ds47.dev` (Outline), this repo copy is the source of truth.

---

## 1. Identity & Purpose

| Field        | Value                                                 |
| ------------ | ----------------------------------------------------- |
| Cluster name | `thestral`                                            |
| Domain       | `*.ds47.dev` / `*.schwarz47.at`                       |
| Management   | GitOps via Flux CD (this repo)                        |
| Wiki         | <https://wiki.ds47.dev>                               |
| Repo         | `cluster-hama` (Git push to `main` → Flux reconciles) |
| Purpose      | `<TO FILL>`                                           |
| Location     | `<TO FILL>`                                           |
| Owner        | `<TO FILL>`                                           |

---

## 2. Physical Hardware

> One row per machine. The cluster runs Talos Linux (immutable, API-driven).

| Hostname             | Role          | OS    | Node IP (`ens18`) | Storage IP (`ens19`) | Hardware    | Notes       |
| -------------------- | ------------- | ----- | ----------------- | -------------------- | ----------- | ----------- |
| `thestral-01`        | Control Plane | Talos | `10.100.10.71`    | `10.44.0.71`         | `<TO FILL>` | `<TO FILL>` |
| `thestral-02`        | Control Plane | Talos | `10.100.10.72`    | `10.44.0.72`         | `<TO FILL>` | `<TO FILL>` |
| `thestral-03`        | Control Plane | Talos | `10.100.10.73`    | `10.44.0.73`         | `<TO FILL>` | `<TO FILL>` |
| `thestral-worker-01` | Worker        | Talos | `10.100.10.81`    | `10.44.0.81`         | `<TO FILL>` | `<TO FILL>` |
| `thestral-worker-02` | Worker        | Talos | `10.100.10.82`    | `10.44.0.82`         | `<TO FILL>` | `<TO FILL>` |
| `thestral-worker-03` | Worker        | Talos | `10.100.10.83`    | `10.44.0.83`         | `<TO FILL>` | `<TO FILL>` |

Hardware facts from the repo (see `talos/`):

- Install disk: `/dev/sda`; Talos image via factory (`talos/schematic.yaml`).
- OS extensions: `i915`, `intel-ucode`, `thunderbolt`, `qemu-guest-agent`.
- Workers carry a third NIC `ens20` with VLAN `30` (`<TO FILL>`: purpose).
- Hostnames resolve in `infra.gryffindor.schwarz47.at`.

---

## 3. Network Layout

### 3.1 Networks / VLANs

| Network          | Subnet           | Purpose                               |
| ---------------- | ---------------- | ------------------------------------- |
| Node network     | `10.100.10.0/24` | Node management + K8s API             |
| Storage network  | `10.44.0.0/16`   | Ceph/backup/storage traffic           |
| `<TO FILL>` VLAN | `<TO FILL>`      | `<TO FILL>` (worker `ens20`, VLAN 30) |

### 3.2 Kubernetes Endpoints

| Endpoint                     | Address                                                    |
| ---------------------------- | ---------------------------------------------------------- |
| Kubernetes API (VIP)         | `10.100.10.70`                                             |
| Ingress (kgateway, internal) | `*.ds47.dev` via listener `kgateway-internal`              |
| Public ingress               | Disabled by default; `gateway/external.yaml` commented out |
| Forgejo SSH                  | TCP `22` listener on kgateway                              |

### 3.3 DNS & Certificates

- `external-dns` + cert-manager: Let's Encrypt wildcard certs for `*.ds47.dev` / `*.schwarz47.at`.
- `<TO FILL>`: DNS provider, split-horizon details.

---

## 4. Kubernetes Cluster Skeleton

```
thestral (Talos Linux, Flux CD)
├── 3× control plane   (thestral-01..03)
├── 3× worker          (thestral-worker-01..03)
├── CNI: Cilium (eBPF, network policy)
├── Ingress: kgateway (Gateway API)
├── Secrets: Vault (KV-v2 `apps/`) ← external-secrets (ClusterSecretStore `vault`)
└── Storage: Ceph CSI (csi-rbd-sc) + OpenEBS + Garage S3 (backup target)
```

Flux flow: Git push → `GitRepository` → `cluster-apps` → per-namespace
`Kustomization` → per-app `Kustomization` → HelmRelease / resources.

Repo layout:

```
kubernetes/
├── apps/         # per-namespace app definitions
├── bootstrap/    # one-time bootstrap (helmfile, CRDs)
├── components/   # reusable Kustomize components (common, dragonfly, gpu, kopiur)
└── flux/         # Flux entrypoints
talos/            # MinJinja node configs, rendered at apply time
```

### 4.1 Node Roles

| Role          | Nodes                    | Responsibilities                                                            |
| ------------- | ------------------------ | --------------------------------------------------------------------------- |
| Control plane | `thestral-01..03`        | etcd, API server, scheduler, controller manager                             |
| Worker        | `thestral-worker-01..03` | Workloads, storage, GPU workloads (intel-gpu-resource-driver, gpu-operator) |

---

## 5. Storage & Data Layer

| Layer                   | Technology                                  | Purpose                                          |
| ----------------------- | ------------------------------------------- | ------------------------------------------------ |
| Block storage (default) | Ceph CSI RBD (`csi-rbd-sc`)                 | PVCs                                             |
| Snapshot                | `snapshot-controller` + `csi-rbd-snapclass` | Volume snapshots                                 |
| Backups                 | Kopiur (mover) + Kopia → Garage S3          | PVC backup/restore (VolSync)                     |
| Object storage (S3)     | Garage (in-cluster)                         | Kopia repository, app media, CNPG barman backups |

Kopiur pattern: PVC + `Repository` (Garage S3, per-app kopia prefix) +
`SnapshotPolicy` (GFS retention) + hourly `SnapshotSchedule`. Apps with
persistent data mount `existingClaim: <app>`.

---

## 6. Identity & Security

- **SSO**: Pocket-ID (OIDC) via `pocket-id-operator`; OIDC clients are
  `PocketIDOIDCClient` CRs. Groups: `hama` (admin), `media`, `services`.
- **Secrets**: SOPS + Age (`*.sops.yaml`) for Talos/bootstrap/cluster-secrets;
  app credentials in Vault (KV-v2 `apps/<ns>/<app>`), synced by
  external-secrets.
- **Network policy**: Cilium.
- **Cluster access**: `kubeconfig` / `talosconfig` via mise (`KUBECONFIG`,
  `TALOSCONFIG`), MCP viewer kubeconfig for tooling.
- **VPN**: NetBird (`network/netbird`) for remote access; `<TO FILL>` exposed routes.
- **Guardian**: `kguardian` (security) `<TO FILL>`.

---

## 7. Application Inventory

> Apps are grouped by namespace; `app.kubernetes.io/name` is set via Flux
> `commonMetadata`. Register new apps per the flow in `AGENTS.md`
> (see `kubernetes/apps/database/pgadmin/` as reference).

| Namespace          | Apps                                                                                                            |
| ------------------ | --------------------------------------------------------------------------------------------------------------- |
| `ai`               | llmkube, searxng, open-webui, n8n, hermes-agent, hermes-webui, toolhive, mcp-servers                            |
| `cert-manager`     | cert-manager                                                                                                    |
| `database`         | cloudnative-pg, dragonfly, emqx, influxdb, pgadmin                                                              |
| `dev`              | coder, forgejo                                                                                                  |
| `downloads`        | autopulse, decluttarr, deduparr, lidarr, profilarr, prowlarr, radarr, sabnzbd, slskd, soularr, sonarr, whisparr |
| `external-secrets` | external-secrets                                                                                                |
| `flux-system`      | flux-operator, flux-instance                                                                                    |
| `home-automation`  | bambuddy, esphome, evcc, frigate, glasheim-dashboard, music-assistant, netbox, nodered, unifi, zigbee2mqtt      |
| `kube-system`      | cilium, coredns, intel-gpu-resource-driver, metrics-server, node-feature-discovery, gpu-operator                |
| `matrix`           | continuwuity, element-web, mautrix-signal                                                                       |
| `media`            | jellyfin, navidrome, scrob, seerr, stash                                                                        |
| `monitoring`       | headlamp, kube-prometheus-stack                                                                                 |
| `network`          | external-dns, external-services, kgateway, multus, netbird, smtp-relay                                          |
| `renovate`         | renovate-operator                                                                                               |
| `security`         | kguardian, pocket-id-operator, pocket-id-instance                                                               |
| `services`         | bentopdf, immich, collabora, it-tools, kroki, obsidian, outline, oxicloud, paperless, redlib, termix, vikunja   |
| `storage`          | ceph-csi, garage, openebs                                                                                       |
| `system`           | descheduler, k8tz, keda, kopiur, reloader, snapshot-controller, spegel                                          |
| `vault`            | vault                                                                                                           |

---

## 8. Backup & Disaster Recovery

- **PVC backups**: Kopiur/Kopia → Garage S3, GFS retention, hourly schedule.
- **Secrets**: SOPS+Age keys stored `<TO FILL>`; Vault backup `<TO FILL>`.
- **etcd**: `<TO FILL>` (Talos `etcd` snapshots).
- **RPO / RTO**: `<TO FILL>`
- **Restore drill**: `<TO FILL>`

---

## 9. Day-2 Operations

```bash
just -l --list-submodules              # all tasks
just talos apply-cluster               # render + apply Talos to all nodes
just talos render-config <node>        # re-render one node config
just talos apply-node <node>           # apply config to one node
just talos upgrade-node <node>         # upgrade Talos on a node
just talos upgrade-k8s <version>       # upgrade Kubernetes control plane
just k8s sync-hr|sync-ks|sync-es <ns> <name>   # force-sync Flux resource
just k8s snapshot <ns> <name>          # manual Kopiur snapshot
flux get ks|hr -A                      # status
```

Recovery from scratch: bootstrap sequence is `<TO FILL>` (start: `just talos
apply-cluster`, then `just bootstrap`).

---

## 10. References

- Repo: `cluster-hama` (`AGENTS.md` for conventions and app onboarding flow)
- Wiki: <https://wiki.ds47.dev/nexus/kubernetes/overview>
- Node configs: `talos/nodes/*.yaml.j2`, `talos/machineconfig.yaml.j2`
- App reference example: `kubernetes/apps/database/pgadmin/`
