<div align="center">

## cluster-hama

### Homelab GitOps repository

_... managed with Flux and Renovate_ 🤖

</div>

---

## Overview

This repository declares the full state of my Kubernetes homelab cluster **thestral**, running on Talos Linux and managed via Flux CD. Push to `main` and Flux reconciles the cluster. Renovate runs in-cluster via `renovate-operator` and keeps image tags, chart versions and Talos versions up to date automatically.

Full documentation lives in the wiki: <https://wiki.ds47.dev/nexus/kubernetes/overview>.

## Bootstrap

```sh
# Render and apply Talos config to all nodes
just talos apply-cluster

# Bootstrap Flux
just bootstrap
```

## Talos & Kubernetes Maintenance

### Update Talos node configuration

```sh
# Re-render and apply config to a single node
just talos render-config thestral-01
just talos apply-node thestral-01
```

### Upgrade Talos / Kubernetes

```sh
# Upgrade a node to a newer Talos version
just talos upgrade-node thestral-01

# Upgrade the Kubernetes control-plane version
just talos upgrade-k8s <version>
```

## Nodes

| Name               | Role          | OS    | Node IP (`ens18`) | Storage IP (`ens19`) |
| ------------------ | ------------- | ----- | ----------------- | -------------------- |
| thestral-01        | Control Plane | Talos | 10.100.10.71      | 10.44.0.71           |
| thestral-02        | Control Plane | Talos | 10.100.10.72      | 10.44.0.72           |
| thestral-03        | Control Plane | Talos | 10.100.10.73      | 10.44.0.73           |
| thestral-worker-01 | Worker        | Talos | 10.100.10.81      | 10.44.0.81           |
| thestral-worker-02 | Worker        | Talos | 10.100.10.82      | 10.44.0.82           |
| thestral-worker-03 | Worker        | Talos | 10.100.10.83      | 10.44.0.83           |

The Kubernetes API is served on the Talos VIP `10.100.10.70`.

## Tech Stack

| Name                                                                         | Description                                       |
| ---------------------------------------------------------------------------- | ------------------------------------------------- |
| [Talos Linux](https://www.talos.dev/)                                        | Immutable, API-driven OS for Kubernetes nodes     |
| [Kubernetes](https://kubernetes.io/)                                         | Container orchestration                           |
| [Flux CD](https://fluxcd.io/)                                                | GitOps continuous delivery                        |
| [Cilium](https://cilium.io/)                                                 | CNI with eBPF-based networking and network policy |
| [kgateway](https://kgateway.dev/)                                            | Gateway API-based ingress controller              |
| [cert-manager](https://cert-manager.io/)                                     | Let's Encrypt wildcard certificates               |
| [HashiCorp Vault](https://www.vaultproject.io/)                              | Secret backend for application credentials        |
| [external-secrets](https://external-secrets.io/)                             | Sync secrets from HashiCorp Vault                 |
| [Pocket-ID](https://pocket-id.org/)                                          | OIDC provider for single sign-on                  |
| [CloudNative-PG](https://cloudnative-pg.io/)                                 | PostgreSQL operator                               |
| [Dragonfly](https://www.dragonflydb.io/)                                     | Redis-compatible in-memory store                  |
| [Ceph CSI](https://github.com/ceph/ceph-csi)                                 | RBD block storage (`csi-rbd-sc`, the default)     |
| [VolSync](https://volsync.readthedocs.io/)                                   | PVC backup and restore via the Kopia mover        |
| [Spegel](https://spegel.dev/)                                                | Peer-to-peer container image mirror               |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Monitoring (Prometheus + Grafana + Alertmanager)  |
| [Renovate](https://docs.renovatebot.com/)                                    | Automated dependency updates                      |
| [SOPS + Age](https://github.com/getsops/sops)                                | Secret encryption for Git                         |
