<div align="center">

## cluster-hama

### Homelab GitOps repository

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>

---

## Overview

This repository declares the full state of my Kubernetes homelab cluster **thestral**, running on Talos Linux and managed via Flux CD. Renovate keeps dependencies up to date automatically.

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

## Hardware

| Name               | Role          | OS    |
| ------------------ | ------------- | ----- |
| thestral-01        | Control Plane | Talos |
| thestral-02        | Control Plane | Talos |
| thestral-03        | Control Plane | Talos |
| thestral-worker-01 | Worker        | Talos |
| thestral-worker-02 | Worker        | Talos |
| thestral-worker-03 | Worker        | Talos |

## Tech Stack

| Name                                                                         | Description                                       |
| ---------------------------------------------------------------------------- | ------------------------------------------------- |
| [Talos Linux](https://www.talos.dev/)                                        | Immutable, API-driven OS for Kubernetes nodes     |
| [Kubernetes](https://kubernetes.io/)                                         | Container orchestration                           |
| [Flux CD](https://fluxcd.io/)                                                | GitOps continuous delivery                        |
| [Cilium](https://cilium.io/)                                                 | CNI with eBPF-based networking and network policy |
| [kgateway](https://kgateway.dev/)                                            | Gateway API-based ingress controller              |
| [external-secrets](https://external-secrets.io/)                             | Sync secrets from HashiCorp Vault                 |
| [CloudNative-PG](https://cloudnative-pg.io/)                                 | PostgreSQL operator                               |
| [Dragonfly](https://www.dragonflydb.io/)                                     | Redis-compatible in-memory store                  |
| [VolSync](https://volsync.readthedocs.io/)                                   | PVC backup and restore via Restic                 |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Monitoring (Prometheus + Grafana + Alertmanager)  |
| [Renovate](https://docs.renovatebot.com/)                                    | Automated dependency updates                      |
| [SOPS + Age](https://github.com/mozilla/sops)                                | Secret encryption for Git                         |
