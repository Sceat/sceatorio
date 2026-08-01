# Build the companion's HTTP entry point. Nothing but this directory is needed,
# so the image is reproducible from the repo alone.
FROM node:22-slim AS build
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
RUN npm run build

FROM node:22-slim AS runtime
ENV NODE_ENV=production \
    SCEATORIO_HTTP_BIND=127.0.0.1 \
    SCEATORIO_HTTP_PORT=34200
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /build/dist ./dist
USER node
EXPOSE 34200
CMD ["node", "dist/src/http.js"]
