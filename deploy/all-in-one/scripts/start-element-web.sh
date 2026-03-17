#!/usr/bin/env bash
set -euo pipefail

ELEMENT_WEB_PORT="${ELEMENT_WEB_PORT:-8081}"
ELEMENT_DEFAULT_HOMESERVER_URL="${ELEMENT_DEFAULT_HOMESERVER_URL:-http://localhost:${MATRIX_PORT:-8008}}"
ELEMENT_DEFAULT_SERVER_NAME="${ELEMENT_DEFAULT_SERVER_NAME:-${MATRIX_HOMESERVER_DOMAIN:-localhost}}"

cat > /opt/element-web/config.json <<EOF
{
  "default_server_name": "${ELEMENT_DEFAULT_SERVER_NAME}",
  "default_server_config": {
    "m.homeserver": {
      "base_url": "${ELEMENT_DEFAULT_HOMESERVER_URL}",
      "server_name": "${ELEMENT_DEFAULT_SERVER_NAME}"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": false,
  "show_labs_settings": true,
  "brand": "SentientWave Element"
}
EOF

exec python3 -m http.server "${ELEMENT_WEB_PORT}" --directory /opt/element-web
