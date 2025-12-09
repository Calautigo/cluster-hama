set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir() + '/clusters/thestral'
bootstrap_dir := kubernetes_dir + '/bootstrap'

[private]
default: apps



[doc('Apply Helmfile Apps')]
apps:
  just log info "Running stage..." "stage" "$0"
  if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/01-apps.yaml" sync --hide-notes; then \
    just log fatal "Failed to sync helmfile" "stage" "$0"; \
  fi