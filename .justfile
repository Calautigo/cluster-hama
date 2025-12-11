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
  minijinja-cli "{{ file }}" {{ args }} | just sops-inject "{{ secrets_file }}"

[private]
sops-inject secrets_file:
  #!/usr/bin/env bash
  set -euo pipefail
  
  SECRETS=$(sops -d "{{ secrets_file }}")
  
  while IFS= read -r line; do
    if [[ "$line" =~ sops://([^/]+)/\.(.+) ]]; then
      KEY=".${BASH_REMATCH[2]}"
      VALUE=$(echo "$SECRETS" | yq -e "$KEY")
      line="${line//sops:\/\/${BASH_REMATCH[1]}\/${BASH_REMATCH[2]}/$VALUE}"
    fi
    echo "$line"
  done