ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/node:20-alpine
ENV NODE_ENV=production PORT=8080
WORKDIR /app
# NEXUS_URL (build-arg): packages from the company Nexus (cicd-deps.sh); empty: registry.npmjs.org
ARG NEXUS_URL
COPY cicd-deps.sh /tmp/cicd-deps.sh
COPY package*.json ./
RUN export CICD_DEPS_DIR=/tmp/cicd-deps && . /tmp/cicd-deps.sh && \
    if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi && npm cache clean --force
COPY . .
USER node
EXPOSE 8080
CMD ["node", "server.js"]
