# mosquitto-railway

Deployment sources for running [Eclipse Mosquitto](https://mosquitto.org/) 2.1 on
[Railway](https://railway.com) as an authenticated MQTT broker.

Two images are built from this repository:

| Directory | Service | Purpose |
|---|---|---|
| `broker/` | Mosquitto | The broker, plus a boot script that derives credentials, TLS material and the config file |
| `gateway/` | Gateway | A Caddy reverse proxy that owns the public domain and splits WebSocket traffic from dashboard traffic |

## Broker

`broker/Dockerfile` starts from `eclipse-mosquitto:2.1-alpine` and adds the openssl CLI and
a writable copy of the bundled dashboard. `broker/entrypoint.sh` runs before the
broker and handles the three things a Railway variable cannot express:

- **Credentials.** `mosquitto_passwd` hashes `MQTT_USERNAME`/`MQTT_PASSWORD` (and any
  `MQTT_EXTRA_USERS`) into the password file on every boot, so the variables stay the
  source of truth.
- **TLS.** Railway's TCP proxy is raw passthrough, so a CA is minted once onto the
  volume and a leaf certificate is issued for `RAILWAY_TCP_PROXY_DOMAIN`. The leaf is
  reissued when that hostname changes; the CA is not, so clients keep trusting it.
  Drop `custom.crt`/`custom.key` into `certs/` on the volume to use your own instead.
- **Config.** Mosquitto is configured by a multi-line file, written here as
  `/mosquitto/config/railway.conf` and validated with `mosquitto --test-config`
  before the broker starts.

Listeners: `1883` plain MQTT (private network), `8883` MQTT over TLS (TCP proxy),
`9001` MQTT over WebSockets, `9883` dashboard and read-only HTTP API behind HTTP
Basic, and `PORT` (`9884`) an anonymous listener serving only `/api/v1/version` for
Railway's health check.

## Gateway

Caddy holds the single public domain. A request carrying `Upgrade: websocket` is
proxied to the broker's WebSocket listener, everything else to the dashboard, and
`/healthz` is answered locally so the health check tests the gateway itself. The
`Authorization` header is forwarded untouched — Mosquitto checks HTTP Basic against
the same accounts that authenticate MQTT clients.

## Variables

| Variable | Service | Default | Notes |
|---|---|---|---|
| `MQTT_USERNAME` | Mosquitto | `admin` | May not contain `:` |
| `MQTT_PASSWORD` | Mosquitto | — | Required; the broker refuses anonymous clients |
| `MQTT_EXTRA_USERS` | Mosquitto | empty | `user:password,user2:password2` |
| `MQTT_PASSWORD_HASH` | Mosquitto | `sha512-pbkdf2` | `argon2id` is documented as the default but compiled out of the official builds |
| `MQTT_LOG_TYPE` | Mosquitto | `error,warning,notice,information` | Adding `debug` is noisy enough to be rate limited |
| `MQTT_MAX_PACKET_SIZE` | Mosquitto | `2000000` | Bytes |
| `BROKER_HOST` | Gateway | `mosquitto.railway.internal` | Private hostname of the broker |

## Licence

Eclipse Mosquitto is EPL-2.0 / EDL-1.0. The files in this repository are provided
under the same terms as the upstream project they configure.

## Building

Both Dockerfiles expect the **repository root** as their build context, because a
Railway template carries `RAILWAY_DOCKERFILE_PATH` as an environment variable but
drops the `dockerfilePath` service field. Set `RAILWAY_DOCKERFILE_PATH` to
`broker/Dockerfile` or `gateway/Dockerfile` on the matching service; locally, use
`docker build -f broker/Dockerfile .` from the repository root.
