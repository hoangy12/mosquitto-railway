FROM caddy:2-alpine

COPY gateway/Caddyfile /etc/caddy/Caddyfile
COPY gateway/entrypoint.sh /railway-entrypoint.sh
RUN chmod 0755 /railway-entrypoint.sh

ENTRYPOINT ["/railway-entrypoint.sh"]
