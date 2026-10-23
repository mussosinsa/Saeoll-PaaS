ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/node:20-alpine
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi && npm cache clean --force
COPY . .
USER node
EXPOSE 8080
CMD ["node", "server.js"]
