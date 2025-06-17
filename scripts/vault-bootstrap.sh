#!/bin/bash
set -euo pipefail

echo "[+] Enabling Kubernetes Auth Backend..."
curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST $VAULT_ADDR/v1/sys/auth/kubernetes \
  --data '{"type": "kubernetes"}' || true

echo "[+] Configuring Kubernetes Auth Backend..."
curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST $VAULT_ADDR/v1/auth/kubernetes/config \
  --data @- <<EOF
{
  "kubernetes_host": "https://kubernetes.default.svc",
  "kubernetes_ca_cert": "$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt | awk '{printf "%s\\n", $0}')",
  "token_reviewer_jwt": "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
}
EOF

echo "[+] Writing ESO Policy..."
curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
  --request PUT $VAULT_ADDR/v1/sys/policy/eso-policy \
  --data '{"policy":"path \"secret/data/*\" { capabilities = [\"read\"] }"}'

echo "[+] Creating Kubernetes Role for ESO..."
curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST $VAULT_ADDR/v1/auth/kubernetes/role/eso-role \
  --data '{
    "bound_service_account_names": "eso-sa",
    "bound_service_account_namespaces": "default",
    "policies": "eso-policy",
    "ttl": "1h"
}'
