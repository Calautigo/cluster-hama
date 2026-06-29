#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod thestral "clusters/thestral"
mod thestral-bootstrap "clusters/thestral/bootstrap"
mod thestral-talos "clusters/thestral/talos"

[private]
default:
    just -l

[private]
log lvl msg *args:
  gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file secrets_file *args:
  minijinja-cli --env "{{ file }}" {{ args }} | just sops-inject "{{ secrets_file }}"

[private]
sops-inject secrets_file:
  #!/usr/bin/env bash
  set -euo pipefail

  export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/age.key}"

  if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
    echo "ERROR: SOPS age key not found at $SOPS_AGE_KEY_FILE" >&2
    exit 1
  fi

  # Decrypt secrets to temp file for faster lookups
  SECRETS_YAML=$(mktemp)
  sops -d "{{ secrets_file }}" > "$SECRETS_YAML"

  # Read stdin line by line
  while IFS= read -r line; do
    # Match sops://namespace/.path.to.key
    if [[ "$line" =~ sops://([^/]+)/(\.[^[:space:]\"\']+) ]]; then
      NAMESPACE="${BASH_REMATCH[1]}"
      KEYPATH="${BASH_REMATCH[2]}"

      # Get value from secrets
      VALUE=$(yq -e "$KEYPATH" "$SECRETS_YAML" 2>/dev/null || echo "")

      if [[ -n "$VALUE" ]]; then
        # Replace the sops:// reference with the actual value
        line="${line//sops:\/\/${NAMESPACE}\/${KEYPATH}/$VALUE}"
      else
        echo "WARNING: Could not find key $KEYPATH in secrets" >&2
      fi
    fi
    echo "$line"
  done

  rm -f "$SECRETS_YAML"
