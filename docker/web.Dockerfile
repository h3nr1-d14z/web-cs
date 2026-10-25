# Build the browser client, then ship it from the Node server that also owns
# the WebSocket <-> UDP tunnel.
FROM node:22-alpine AS client-build
WORKDIR /build

COPY client/package.json client/package-lock.json ./
RUN npm ci --no-audit --no-fund

# `client/vendor` holds the pinned engine + CS client side modules. It is part
# of the repo on purpose: every upstream distribution channel for them has
# already been unpublished once.
COPY client/ .
RUN test -f vendor/client_emscripten_wasm32.wasm || \
    (echo "client/vendor thiáº¿u file .wasm â€” cháº¡y: node scripts/vendor-engine.mjs" && exit 1)
RUN npm run build

FROM node:22-alpine AS runtime
# 7zz dùng d? gi?i nén .rar khi cài map t? URL
RUN apk add --no-cache 7zip
ENV NODE_ENV=production
WORKDIR /app

COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY server/src ./src
COPY config/presets.json ./config/presets.json
COPY --from=client-build /build/dist ./public

USER node
EXPOSE 8080
CMD ["node", "src/index.js"]
