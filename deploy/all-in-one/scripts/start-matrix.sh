#!/usr/bin/env bash
set -euo pipefail

MATRIX_CONFIG_PATH="${MATRIX_CONFIG_PATH:-/data/matrix/homeserver.yaml}"

exec python3 -m synapse.app.homeserver --config-path "${MATRIX_CONFIG_PATH}"
