# syntax=docker/dockerfile:1
# Release 42: the website as a Node server for the company's server (docs/hosting/off-cloudflare.md).
# Build context: the repository's web/ folder.
#   docker build -f infra/vps/web/Dockerfile --build-arg DEPLOY_VERSION=<commit> \
#     --secret id=buildenv,src=<file of NAME=value lines the build reads, e.g. SUPABASE_SERVICE_ROLE_KEY> web
# Run `node web/scripts/guide-assets.mjs` first: the user guides' images are copied from docs/ into web/public.
# The public settings come from web/.env.production (written by the deploy job, as for the Worker build). The secret
# file is only read while the pages are built; it is never in a layer of the image.
FROM node:22-bookworm-slim AS build
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1 HOSTING_TARGET=node
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN --mount=type=secret,id=buildenv,required=false \
    set -a; if [ -f /run/secrets/buildenv ]; then . /run/secrets/buildenv; fi; set +a; \
    npm run -s build:node

FROM node:22-bookworm-slim
ARG DEPLOY_VERSION=dev
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 HOSTING_TARGET=node NEXT_STANDALONE_DIR=/app PORT=3000 DEPLOY_VERSION=$DEPLOY_VERSION
WORKDIR /app
COPY --from=build --chown=node:node /src/.next/standalone ./
COPY --from=build --chown=node:node /src/.next/static ./.next/static
COPY --from=build --chown=node:node /src/public ./public
# the entry and the modules it shares with the Worker entry (loaded as TypeScript by Node itself)
COPY --from=build --chown=node:node /src/scripts/vps-server.mjs ./scripts/vps-server.mjs
COPY --from=build --chown=node:node /src/src/lib ./src/lib
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=4 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "--no-warnings", "scripts/vps-server.mjs"]
