# External Secrets with HashiCorp Vault Integration

Complete guide for integrating External Secrets Operator with HashiCorp Vault using Kubernetes Authentication.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ K3s Cluster (Gryffindor-Prod)                               │
│                                                             │
│  ┌──────────────────────────────────────┐                  │
│  │ External Secrets Operator            │                  │
│  │ Namespace: external-secrets          │                  │
│  │ ServiceAccount: external-secrets     │─────┐            │
│  └──────────────────────────────────────┘     │            │
│                                                │            │
│  ┌──────────────────────────────────────┐     │            │
│  │ Vault Auth Helper                    │     │            │
│  │ Namespace: kube-system               │     │            │
│  │ ServiceAccount: vault-auth           │     │            │
│  └──────────────────────────────────────┘     │            │
│                                                │            │
└────────────────────────────────────────────────┼────────────┘
                                                 │
                                                 │ Kubernetes Auth
                                                 │
                                        ┌────────▼────────┐
                                        │  Vault Server   │
                                        │  External VPS   │
                                        │                 │
                                        │  vault.infra... │
                                        └─────────────────┘
```

## Prerequisites

- K3s cluster is running
- HashiCorp Vault is installed and accessible
- `kubectl` is configured
- `vault` CLI is installed
- Flux is installed (for GitOps deployment)

## Bootstrap Process

### 1. Prepare Vault Configuration

#### 1.1 Extract CA Certificate

```bash
# Extract the CA certificate from your K3s kubeconfig
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > k3s-ca.crt

# Verify the certificate
openssl x509 -in k3s-ca.crt -text -noout
```

#### 1.2 Create Service Account for Vault

```bash
# Service Account in kube-system namespace
kubectl create sa vault-auth -n kube-system

# ClusterRoleBinding for TokenReview API
kubectl create clusterrolebinding vault-tokenreview-binding \
    --clusterrole=system:auth-delegator \
    --serviceaccount=kube-system:vault-auth

# Create Secret for Service Account Token (for long-lived token)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF

# Extract token
kubectl get secret vault-auth-token -n kube-system -o jsonpath='{.data.token}' | base64 -d > vault-token.txt
```

#### 1.3 Determine Kubernetes API Endpoint

```bash
# Display API Server URL
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'
```

### 2. Configure Vault

#### 2.1 Enable Kubernetes Auth Method

```bash
# On the Vault server
vault auth enable kubernetes
```

#### 2.2 Configure Kubernetes Auth

```bash
# Connect Vault with K3s
vault write auth/kubernetes/config \
    kubernetes_host="https://10.100.10.70:6443" \
    kubernetes_ca_cert=@k3s-ca.crt \
    token_reviewer_jwt=$(cat vault-token.txt)

# Verify configuration
vault read auth/kubernetes/config
```

#### 2.3 Create Policy

```bash
# Policy for External Secrets
vault policy write external-secrets-policy - <<EOF
# Allow reading all secrets under k8s/gryffindor-prod
path "secret/data/k8s/gryffindor-prod/*" {
  capabilities = ["read"]
}

# Allow listing secret metadata
path "secret/metadata/k8s/gryffindor-prod/*" {
  capabilities = ["list"]
}
EOF

# Display policy
vault policy read external-secrets-policy
```

#### 2.4 Create Kubernetes Role

```bash
# Role for External Secrets Operator
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-policy \
    ttl=24h

# Verify role
vault read auth/kubernetes/role/external-secrets
```

### 3. Create Test Secret in Vault

```bash
# KV v2 Secret Engine should already exist under 'secret'
# If not:
# vault secrets enable -path=secret kv-v2

# Create test secret
vault kv put secret/k8s/gryffindor-prod/test \
    password="my-test-password" \
    username="testuser"

# Verify secret
vault kv get secret/k8s/gryffindor-prod/test
```

### 4. Deploy Kubernetes Resources (via Flux)

#### 4.1 Directory Structure

```
kubernetes/
└── apps/
    └── security/
        └── external-secrets/
            ├── app/
            │   ├── helmrelease.yaml
            │   └── kustomization.yaml
            ├── ks.yaml
            └── namespace.yaml
```

#### 4.2 Create Namespace

**`kubernetes/apps/security/external-secrets/namespace.yaml`**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

#### 4.3 Kustomization for Flux

**`kubernetes/apps/security/external-secrets/ks.yaml`**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/apps/security/external-secrets/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
  wait: true
  dependsOn:
    - name: external-secrets-operator
```

#### 4.4 HelmRelease

**`kubernetes/apps/security/external-secrets/app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-secrets
  namespace: external-secrets
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: external-secrets
  values:
    image:
      repository: ghcr.io/external-secrets/external-secrets
    
    installCRDs: true
    
    # Service Account is created by the chart
    serviceAccount:
      create: true
      name: external-secrets
    
    # Prometheus Monitoring
    serviceMonitor:
      enabled: true
      interval: 1m
    
    certController:
      image:
        repository: ghcr.io/external-secrets/external-secrets
      serviceMonitor:
        enabled: true
        interval: 1m
    
    webhook:
      image:
        repository: ghcr.io/external-secrets/external-secrets
      serviceMonitor:
        enabled: true
        interval: 1m
---
# ClusterSecretStore for Vault
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-secret-store
spec:
  provider:
    vault:
      server: "https://vault.infra.gryffindor.schwarz47.at"
      path: "secret"  # KV v2 Engine Name
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

**`kubernetes/apps/security/external-secrets/app/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
```

### 5. Deployment and Validation

#### 5.1 Flux Reconciliation

```bash
# Trigger flux reconciliation
flux reconcile source git home-kubernetes
flux reconcile kustomization external-secrets

# Check deployment status
kubectl get helmrelease -n external-secrets
kubectl get pods -n external-secrets
```

#### 5.2 Check ClusterSecretStore Status

```bash
# ClusterSecretStore status
kubectl get clustersecretstore vault-secret-store

# Show details
kubectl describe clustersecretstore vault-secret-store

# Should have "Ready" status
```

### 6. Create Test ExternalSecret

**`test-external-secret.yaml`**

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-test-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secret-store
    kind: ClusterSecretStore
  target:
    name: vault-test-secret
    creationPolicy: Owner
  data:
  - secretKey: password
    remoteRef:
      key: k8s/gryffindor-prod/test
      property: password
  - secretKey: username
    remoteRef:
      key: k8s/gryffindor-prod/test
      property: username
```

```bash
# Deploy ExternalSecret
kubectl apply -f test-external-secret.yaml

# Check status
kubectl get externalsecret vault-test-secret -n default
kubectl describe externalsecret vault-test-secret -n default

# Check generated secret
kubectl get secret vault-test-secret -n default
kubectl get secret vault-test-secret -n default -o yaml
```

## Usage in Applications

### Example: Database Credentials

**1. Create secret in Vault:**

```bash
vault kv put secret/k8s/gryffindor-prod/postgres \
    username="postgres_user" \
    password="super-secret-password" \
    host="postgres.database.svc.cluster.local" \
    port="5432"
```

**2. Create ExternalSecret:**

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: my-app
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-secret-store
    kind: ClusterSecretStore
  target:
    name: postgres-credentials
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        # Standard Kubernetes Secret Format
        POSTGRES_USER: "{{ .username }}"
        POSTGRES_PASSWORD: "{{ .password }}"
        # Connection String Template
        DATABASE_URL: "postgresql://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/mydb"
  data:
  - secretKey: username
    remoteRef:
      key: k8s/gryffindor-prod/postgres
      property: username
  - secretKey: password
    remoteRef:
      key: k8s/gryffindor-prod/postgres
      property: password
  - secretKey: host
    remoteRef:
      key: k8s/gryffindor-prod/postgres
      property: host
  - secretKey: port
    remoteRef:
      key: k8s/gryffindor-prod/postgres
      property: port
```

**3. Use in Deployment:**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        envFrom:
        - secretRef:
            name: postgres-credentials
```

## Troubleshooting

### External Secret shows "SecretSyncedError"

```bash
# Logs from External Secrets Operator
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# Common causes:
# - Vault server not reachable
# - Wrong path in secret
# - Policy does not allow access
# - Service Account Token expired
```

### ClusterSecretStore not "Ready"

```bash
# Status details
kubectl describe clustersecretstore vault-secret-store

# Test Vault Auth (from a pod)
kubectl run vault-test --rm -it --image=vault:latest -- sh
# In the pod:
export VAULT_ADDR="https://vault.infra.gryffindor.schwarz47.at"
vault login -method=kubernetes role=external-secrets
```

### Vault Authentication fails

```bash
# On Vault server: Check audit log
vault audit enable file file_path=/var/log/vault/audit.log
tail -f /var/log/vault/audit.log

# Common problems:
# - token_reviewer_jwt expired
# - CA certificate doesn't match
# - Kubernetes API not reachable from Vault
```

### Renew Service Account Token

```bash
# Generate new token
kubectl get secret vault-auth-token -n kube-system -o jsonpath='{.data.token}' | base64 -d > new-vault-token.txt

# Update in Vault
vault write auth/kubernetes/config \
    kubernetes_host="https://10.100.10.70:6443" \
    kubernetes_ca_cert=@k3s-ca.crt \
    token_reviewer_jwt=$(cat new-vault-token.txt)
```

## Best Practices

### 1. Secret Organization in Vault

```
secret/
└── k8s/
    ├── gryffindor-prod/
    │   ├── common/           # Cluster-wide secrets
    │   ├── databases/        # Database credentials
    │   ├── certificates/     # TLS certificates
    │   └── apps/
    │       ├── app1/
    │       └── app2/
    └── ravenclaw-prod/       # Vacation house cluster
```

### 2. Namespaced SecretStores

For better isolation per namespace:

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: my-app
spec:
  provider:
    vault:
      server: "https://vault.infra.gryffindor.schwarz47.at"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "my-app"  # Specific role
          serviceAccountRef:
            name: "my-app-sa"
```

With corresponding Vault role:

```bash
vault write auth/kubernetes/role/my-app \
    bound_service_account_names=my-app-sa \
    bound_service_account_namespaces=my-app \
    policies=my-app-policy \
    ttl=24h
```

### 3. Refresh Intervals

```yaml
spec:
  refreshInterval: 5m  # Frequent rotation: 5-15 minutes
  # or
  refreshInterval: 1h  # Normal secrets: 1-24 hours
```

### 4. Backup Strategy

```bash
# Regularly backup Vault secrets
vault kv get -format=json secret/k8s/gryffindor-prod/ > backup.json

# Or with Vault snapshots
vault operator raft snapshot save backup.snap
```

### 5. GitOps-friendly Secrets

Use templates for standardized formats:

```yaml
spec:
  target:
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "{{ .registry }}": {
                "username": "{{ .username }}",
                "password": "{{ .password }}",
                "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
              }
            }
          }
```

## Monitoring and Alerting

### Prometheus Metrics

```yaml
# ServiceMonitor already enabled in HelmRelease
serviceMonitor:
  enabled: true
  interval: 1m
```

Important metrics:

- `externalsecret_sync_calls_total` - Number of sync attempts
- `externalsecret_sync_calls_error` - Failed syncs
- `externalsecret_status_condition` - Secret status

### Grafana Dashboard

Import Dashboard ID: `14837` for External Secrets Monitoring

## Maintenance

### Vault Token Rotation

```bash
# Every 6-12 months
# 1. Generate new token (see above)
# 2. Update in Vault
# 3. No cluster-side changes needed!
```

### CRD Updates

```bash
# For External Secrets updates
helm list -n external-secrets
helm upgrade external-secrets external-secrets/external-secrets -n external-secrets
```

## Security Notes

1. **Never** commit Vault tokens to Git
2. **Always** use TLS for Vault server
3. **Regularly** check Vault audit logs
4. **Minimal** policies - only necessary permissions
5. **Separate** roles per namespace/application
6. **Monitor** ExternalSecret sync errors
7. **Backup** Vault secrets regularly

## Additional Resources

- [External Secrets Documentation](https://external-secrets.io/)
- [Vault Kubernetes Auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault KV Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)

## Support

For issues:
1. Check logs: `kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets`
2. Check status: `kubectl describe externalsecret <name>`
3. Vault audit log: `/var/log/vault/audit.log`