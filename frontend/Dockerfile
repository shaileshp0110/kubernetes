# Build stage
FROM node:18-alpine as build

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install

COPY . .

RUN npm run build

# Serve stage
# nginx-unprivileged runs as UID 101 and binds an unprivileged port, so the pod can run
# with runAsNonRoot + capabilities dropped. Stock nginx needs root (or NET_BIND_SERVICE)
# to bind :80, which the pod securityContext no longer permits.
FROM nginxinc/nginx-unprivileged:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /usr/src/app/dist /usr/share/nginx/html

USER 101

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
