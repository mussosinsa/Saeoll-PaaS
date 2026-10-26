ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY . .
RUN npm run build

FROM ${BASE_REGISTRY}/nginx:1.27-alpine
# /api/ backend: Service name in the same namespace (or set API_UPSTREAM to a full URL)
ENV API_SERVICE=node-board NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY nginx/05-api-upstream.envsh /docker-entrypoint.d/05-api-upstream.envsh
RUN chmod 755 /docker-entrypoint.d/05-api-upstream.envsh
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
