#!/bin/sh
# Boot-time setup for Eclipse Mosquitto on Railway.
#
# Everything here exists because it cannot be expressed as a Railway variable:
# the password file holds argon2id hashes, the TLS material has to be minted
# against whatever host the TCP proxy hands out, and the broker config is a
# multi-line file.
set -eu

DATA=/mosquitto/data
CERTS="$DATA/certs"
PWFILE="$DATA/passwd"
CONF=/mosquitto/config/railway.conf
WWW=/mosquitto/www

MQTT_USERNAME="${MQTT_USERNAME:-admin}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
MQTT_EXTRA_USERS="${MQTT_EXTRA_USERS:-}"
# argon2id is what mosquitto_passwd documents as its default, but the official
# builds compile it out (CMakeLists.txt comments out -DWITH_ARGON2 "until separate
# password handling thread is implemented"), and the only symptom is
# "Error: Unable to hash password." So ask for what the image can actually do.
MQTT_PASSWORD_HASH="${MQTT_PASSWORD_HASH:-sha512-pbkdf2}"
MQTT_LOG_TYPE="$(printf '%s' "${MQTT_LOG_TYPE:-error,warning,notice,information}" | tr -d '[:space:]')"
MQTT_MAX_PACKET_SIZE="${MQTT_MAX_PACKET_SIZE:-2000000}"

# Named PORT_* so they cannot be shadowed by the consumer-facing MQTT_PORT
# variable services reference for the private endpoint.
PORT_MQTT=1883
PORT_MQTTS=8883
PORT_WS=9001
PORT_API=9883

# PORT is only what Railway's health check probes. It gets its own anonymous
# listener that serves nothing but /api/v1/version, so the probe never needs a
# credential and the authenticated surfaces never answer an anonymous request.
HEALTH_PORT="${PORT:-9884}"
case "$HEALTH_PORT" in
	""|*[!0-9]*|"$PORT_MQTT"|"$PORT_MQTTS"|"$PORT_WS"|"$PORT_API") HEALTH_PORT=9884 ;;
esac

log() { echo "railway-entrypoint: $*"; }
die() { echo "railway-entrypoint: ERROR: $*" >&2; exit 1; }

# 2.1 reports its compile-time options here, which is the only way to tell whether
# a feature the documentation describes is actually present in this build.
mosquitto --version 2>&1 | head -n 4

if [ -z "$MQTT_PASSWORD" ]; then
	die "MQTT_PASSWORD is empty. The broker refuses anonymous clients, so it would accept nobody."
fi
case "$MQTT_USERNAME" in
	*:*|"") die "MQTT_USERNAME must be non-empty and must not contain ':'." ;;
esac

mkdir -p "$DATA" "$CERTS"

# ---------------------------------------------------------------- credentials
# Rebuilt from the environment on every boot, so the variables stay the single
# source of truth and a password change is just a redeploy.
TMPPW="$DATA/.passwd.$$"
rm -f "$TMPPW"
if ! mosquitto_passwd -c -b -H "$MQTT_PASSWORD_HASH" "$TMPPW" "$MQTT_USERNAME" "$MQTT_PASSWORD" >/dev/null 2>&1; then
	if [ "$MQTT_PASSWORD_HASH" != "sha512-pbkdf2" ]; then
		log "WARNING: this build cannot hash with '$MQTT_PASSWORD_HASH'; falling back to sha512-pbkdf2"
		MQTT_PASSWORD_HASH=sha512-pbkdf2
		rm -f "$TMPPW"
		mosquitto_passwd -c -b -H "$MQTT_PASSWORD_HASH" "$TMPPW" "$MQTT_USERNAME" "$MQTT_PASSWORD" >/dev/null \
			|| die "mosquitto_passwd failed for '$MQTT_USERNAME'."
	else
		die "mosquitto_passwd failed for '$MQTT_USERNAME' (hash '$MQTT_PASSWORD_HASH')."
	fi
fi
users=1

# MQTT_EXTRA_USERS is "user:password,user2:password2" — one credential per device
# or per application, so a leak is scoped to one client rather than the fleet.
OLDIFS=$IFS
IFS=','
for pair in $MQTT_EXTRA_USERS; do
	[ -n "$pair" ] || continue
	u=${pair%%:*}
	p=${pair#*:}
	if [ -z "$u" ] || [ "$u" = "$pair" ] || [ -z "$p" ]; then
		IFS=$OLDIFS
		die "MQTT_EXTRA_USERS entry '$pair' is not in user:password form."
	fi
	IFS=$OLDIFS
	mosquitto_passwd -b -H "$MQTT_PASSWORD_HASH" "$TMPPW" "$u" "$p" >/dev/null \
		|| die "mosquitto_passwd failed for extra user '$u'."
	users=$((users + 1))
	IFS=','
done
IFS=$OLDIFS

mv -f "$TMPPW" "$PWFILE"
chmod 0600 "$PWFILE"
log "password file rebuilt with $users user(s), hash $MQTT_PASSWORD_HASH"

# ------------------------------------------------------------------------ TLS
# Railway's TCP proxy is raw TCP passthrough, so MQTT credentials would cross the
# internet in the clear on a plain listener. The CA is minted once and kept on the
# volume; only the leaf is reissued when the proxy hostname changes, so clients
# that already trust the CA keep working.
tls_ready=0
if [ -s "$CERTS/custom.crt" ] && [ -s "$CERTS/custom.key" ]; then
	CERTFILE="$CERTS/custom.crt"
	KEYFILE="$CERTS/custom.key"
	tls_ready=1
	log "using operator-supplied certificate at $CERTFILE"
else
	CERTFILE="$CERTS/server.crt"
	KEYFILE="$CERTS/server.key"

	san="DNS:localhost,IP:127.0.0.1"
	cn="localhost"
	if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ]; then
		cn="$RAILWAY_TCP_PROXY_DOMAIN"
		san="DNS:$RAILWAY_TCP_PROXY_DOMAIN,$san"
	fi
	if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
		san="DNS:$RAILWAY_PRIVATE_DOMAIN,$san"
	fi

	if [ ! -s "$CERTS/ca.crt" ] || [ ! -s "$CERTS/ca.key" ]; then
		log "minting broker CA"
		openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
			-keyout "$CERTS/ca.key" -out "$CERTS/ca.crt" \
			-subj "/O=Mosquitto on Railway/CN=Mosquitto on Railway CA" >/dev/null 2>&1 \
			|| log "WARNING: CA generation failed; TLS listener will be skipped"
	fi

	if [ -s "$CERTS/ca.crt" ] && [ -s "$CERTS/ca.key" ]; then
		if [ ! -s "$CERTFILE" ] || [ ! -s "$KEYFILE" ] || [ "$(cat "$CERTS/server.san" 2>/dev/null || true)" != "$san" ]; then
			log "issuing server certificate for $cn"
			printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san" > "$CERTS/server.ext"
			if openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$CERTS/server.key" \
					-out "$CERTS/server.csr" -subj "/CN=$cn" >/dev/null 2>&1 \
				&& openssl x509 -req -in "$CERTS/server.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" \
					-CAcreateserial -out "$CERTS/server.crt" -days 3650 -sha256 \
					-extfile "$CERTS/server.ext" >/dev/null 2>&1; then
				printf '%s' "$san" > "$CERTS/server.san"
			else
				log "WARNING: server certificate generation failed; TLS listener will be skipped"
			fi
			rm -f "$CERTS/server.csr" "$CERTS/server.ext"
		fi
		[ -s "$CERTFILE" ] && [ -s "$KEYFILE" ] && tls_ready=1
	fi
fi

# The CA is public material and clients need it to verify the broker, so it is
# published next to the dashboard — behind the same credentials as the dashboard.
if [ -s "$CERTS/ca.crt" ] && [ -d "$WWW" ]; then
	cp -f "$CERTS/ca.crt" "$WWW/ca.crt" 2>/dev/null || true
	chmod 0644 "$WWW/ca.crt" 2>/dev/null || true
fi

# ---------------------------------------------------------------------- config
{
	echo "# Generated by railway-entrypoint.sh. Edits are overwritten on every boot."
	echo "allow_anonymous false"
	echo "max_packet_size $MQTT_MAX_PACKET_SIZE"
	echo "log_dest stdout"
	# log_type takes one value per line; a comma-separated list is rejected.
	OLDIFS=$IFS; IFS=','
	for lt in $MQTT_LOG_TYPE; do
		if [ -n "$lt" ]; then echo "log_type $lt"; fi
	done
	IFS=$OLDIFS
	echo "connection_messages true"
	echo
	echo "# Persistence: sessions, subscriptions, queued and retained messages."
	echo "persistence_location $DATA/"
	echo "global_plugin /usr/lib/mosquitto_persist_sqlite.so"
	echo "plugin_opt_db_file $DATA/mosquitto.sqlite3"
	echo "plugin_opt_flush_period 5"
	echo "plugin_opt_page_size 4096"
	echo
	echo "# Authentication for MQTT, WebSockets and the dashboard alike."
	echo "global_plugin /usr/lib/mosquitto_password_file.so"
	echo "plugin_opt_password_file $PWFILE"
	echo
	echo "# Plain MQTT, private network only."
	echo "listener $PORT_MQTT"
	echo "protocol mqtt"
	if [ "$tls_ready" = "1" ]; then
		echo
		echo "# MQTT over TLS, published through the Railway TCP proxy."
		echo "listener $PORT_MQTTS"
		echo "protocol mqtt"
		echo "certfile $CERTFILE"
		echo "keyfile $KEYFILE"
	fi
	echo
	echo "# MQTT over WebSockets, reached as wss:// through the gateway."
	echo "listener $PORT_WS"
	echo "protocol websockets"
	echo
	echo "# Dashboard and read-only HTTP API, HTTP Basic against the same accounts."
	echo "listener $PORT_API"
	echo "protocol http_api"
	echo "http_dir $WWW"
	echo
	echo "# Anonymous health endpoint. Serves /api/v1/version and nothing else:"
	echo "# no http_dir, so no file is reachable, and it holds no public domain."
	echo "listener $HEALTH_PORT"
	echo "protocol http_api"
	echo "listener_allow_anonymous true"
} > "$CONF"

if [ "$tls_ready" != "1" ]; then
	log "WARNING: no TLS material, so port $PORT_MQTTS is not listening"
fi

# Drop the volume to the broker account before mosquitto gives up root itself.
if [ "$(id -u)" = "0" ]; then
	chown -R mosquitto:mosquitto "$DATA"
fi

/usr/sbin/mosquitto -c "$CONF" --test-config || { cat "$CONF"; die "generated config rejected by mosquitto"; }
log "config validated; listeners: $PORT_MQTT mqtt$([ "$tls_ready" = 1 ] && echo ", $PORT_MQTTS mqtts"), $PORT_WS ws, $PORT_API dashboard, $HEALTH_PORT health"

exec "$@"
