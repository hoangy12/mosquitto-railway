FROM eclipse-mosquitto:2.1-alpine

# The base image ships libcrypto but not the openssl CLI, which the entrypoint uses
# to mint the CA and server certificate that secure MQTT over the Railway TCP proxy.
RUN apk add --no-cache openssl

# Serve the bundled dashboard from a writable directory so the entrypoint can place
# the generated CA certificate alongside it for clients that need to trust the broker.
RUN cp -r /usr/share/mosquitto/dashboard /mosquitto/www \
 && chown -R mosquitto:mosquitto /mosquitto/www

COPY broker/entrypoint.sh /railway-entrypoint.sh
RUN chmod 0755 /railway-entrypoint.sh

EXPOSE 1883 8883 9001 9883 9884

ENTRYPOINT ["/railway-entrypoint.sh"]
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/railway.conf"]
