# The upstream image is `scratch` (no shell, no wget), so a Docker HEALTHCHECK cannot run in it.
# Add a single static busybox binary (used only by the healthcheck).
ARG PROXY_IMAGE=wollomatic/socket-proxy:1.13.2
FROM busybox:1.37.0-musl AS busybox
FROM ${PROXY_IMAGE}
COPY --from=busybox /bin/busybox /busybox
