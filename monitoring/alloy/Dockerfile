# The official Alloy image has no wget, so a Docker HEALTHCHECK cannot run in it. Add a single
# static busybox binary (used only by the healthcheck).
ARG ALLOY_IMAGE=grafana/alloy:v1.22.0
FROM busybox:1.37.0-musl AS busybox
FROM ${ALLOY_IMAGE}
COPY --from=busybox /bin/busybox /busybox
