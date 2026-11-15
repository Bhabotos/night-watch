# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:22.23.5-alpine3.24
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.31.7-alpine3.24

# ---- dependencies (cached until package*.json change) --------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# ---- test: type-check + unit tests (docker build --target test) ------------------------
FROM deps AS test
COPY . .
RUN npm run typecheck && npm run test

# ---- build -----------------------------------------------------------------------------
FROM deps AS build
COPY . .
RUN npm run build

# ---- runtime: unprivileged nginx (uid 101, listens on 8080) ----------------------------
FROM ${NGINX_IMAGE} AS runtime
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
# Graceful shutdown: SIGQUIT lets nginx finish in-flight requests.
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
