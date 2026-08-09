FROM node:18-alpine

WORKDIR /usr/src/app

COPY package*.json ./

# Only install prod dependencies if we want, but for now just npm install
RUN npm install

COPY . .

# Numeric UID (the node image's built-in "node" user). Must be numeric: kubelet cannot
# verify a named user against runAsNonRoot and refuses to start the container.
USER 1000

EXPOSE 3000

CMD [ "npm", "start" ]
