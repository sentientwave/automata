#!/usr/bin/env bash
set -euo pipefail

MATRIX_CONFIG_DIR="${MATRIX_CONFIG_DIR:-/data/matrix}"
MATRIX_CONFIG_PATH="${MATRIX_CONFIG_PATH:-${MATRIX_CONFIG_DIR}/homeserver.yaml}"
MATRIX_DATA_DIR="${MATRIX_DATA_DIR:-${MATRIX_CONFIG_DIR}/data}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-localhost}"
MATRIX_REPORT_STATS="${MATRIX_REPORT_STATS:-no}"
MATRIX_PORT="${MATRIX_PORT:-8008}"
MATRIX_DISABLE_RATE_LIMITS="${MATRIX_DISABLE_RATE_LIMITS:-true}"

mkdir -p "${MATRIX_CONFIG_DIR}" "${MATRIX_DATA_DIR}"

if [ ! -f "${MATRIX_CONFIG_PATH}" ]; then
  echo "[bootstrap-matrix] generating homeserver config"
  python3 -m synapse.app.homeserver \
    --server-name "${MATRIX_SERVER_NAME}" \
    --config-path "${MATRIX_CONFIG_PATH}" \
    --data-directory "${MATRIX_DATA_DIR}" \
    --generate-config \
    --report-stats "${MATRIX_REPORT_STATS}"

  cat >> "${MATRIX_CONFIG_PATH}" <<EOCFG

# all-in-one overrides (safe to edit)
listeners:
  - port: ${MATRIX_PORT}
    tls: false
    type: http
    x_forwarded: false
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

enable_registration: true
enable_registration_without_verification: true
EOCFG
fi

if ! grep -q "^registration_shared_secret:" "${MATRIX_CONFIG_PATH}"; then
  echo "registration_shared_secret: $(openssl rand -hex 32)" >> "${MATRIX_CONFIG_PATH}"
fi

if [ "${MATRIX_DISABLE_RATE_LIMITS}" = "true" ] && ! grep -q "^# all-in-one rate-limit overrides" "${MATRIX_CONFIG_PATH}"; then
  cat >> "${MATRIX_CONFIG_PATH}" <<'EORATE'

# all-in-one rate-limit overrides
# Keep local/dev and demo environments responsive under automation load.
rc_message:
  per_second: 1000
  burst_count: 10000

rc_registration:
  per_second: 1000
  burst_count: 10000

rc_login:
  address:
    per_second: 1000
    burst_count: 10000
  account:
    per_second: 1000
    burst_count: 10000
  failed_attempts:
    per_second: 1000
    burst_count: 10000

rc_admin_redaction:
  per_second: 1000
  burst_count: 10000

rc_joins:
  local:
    per_second: 1000
    burst_count: 10000
  remote:
    per_second: 1000
    burst_count: 10000
EORATE
fi
