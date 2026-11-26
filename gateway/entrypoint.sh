#!/bin/sh
set -eu

# A ${{Mosquitto.RAILWAY_PRIVATE_DOMAIN}} reference renders empty until that
# service owns a deployment, and Caddy's {$VAR:default} does not rescue a variable
# that is set-but-empty — so the shape of the value is what decides here.
BROKER_HOST="${BROKER_HOST:-}"
case "$BROKER_HOST" in
	""|":"*) BROKER_HOST="mosquitto.railway.internal" ;;
esac

BROKER_WS_HOST="$BROKER_HOST:${BROKER_WS_PORT:-9001}"
BROKER_API_HOST="$BROKER_HOST:${BROKER_API_PORT:-9883}"
export BROKER_WS_HOST BROKER_API_HOST

echo "gateway: websockets -> $BROKER_WS_HOST, dashboard -> $BROKER_API_HOST"

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
