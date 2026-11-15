# The official Loki image has no shell and no wget, so a Docker HEALTHCHECK cannot run in it.
# Add a single static busybox binary (used only by the healthcheck); nothing else changes.
ARG LOKI_IMAGE=grafana/loki:3.7.10
FROM busybox:1.37.0-musl AS busybox
FROM ${LOKI_IMAGE}
COPY --from=busybox /bin/busybox /busybox
