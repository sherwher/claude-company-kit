#!/usr/bin/env bash
set -euo pipefail

write_session_env_loader() {
  local project_root="$1"
  local session_id="$2"
  local loader_path="${project_root}/.company-runtime/sessions/${session_id}/load-env.sh"

  mkdir -p "$(dirname "${loader_path}")"

  cat > "${loader_path}" <<'EOF'
#!/usr/bin/env bash
set -a
SHARED_PREFIX="."
if [[ -d ./.company-shared/.company-project ]]; then
  SHARED_PREFIX="./.company-shared"
fi

for env_file in "${SHARED_PREFIX}"/.company-project/integrations/*.env; do
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
  fi
done

if [[ -f "${SHARED_PREFIX}"/.company-local.env ]]; then
  # shellcheck disable=SC1091
  source "${SHARED_PREFIX}"/.company-local.env
fi
set +a
EOF

  chmod +x "${loader_path}"
}
