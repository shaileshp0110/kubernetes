FROM node:18-slim

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY index.js ./

# Numeric UID (the node image's built-in "node" user) so runAsNonRoot can be verified.
USER 1000

EXPOSE 3000

CMD ["node", "index.js"]
