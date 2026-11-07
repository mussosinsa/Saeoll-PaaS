ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/node:20-alpine AS build
WORKDIR /app
# NEXUS_URL (build-arg): packages from the company Nexus (cicd-deps.sh); empty: registry.npmjs.org
ARG NEXUS_URL
ENV CICD_DEPS_DIR=/tmp/cicd-deps
COPY cicd-deps.sh /tmp/cicd-deps.sh
COPY package*.json ./
RUN . /tmp/cicd-deps.sh && if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY . .
RUN npm run build

FROM ${BASE_REGISTRY}/nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
