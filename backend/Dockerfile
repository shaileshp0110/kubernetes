FROM node:18-alpine

WORKDIR /usr/src/app

COPY package*.json ./

# Only install prod dependencies if we want, but for now just npm install
RUN npm install

COPY . .

EXPOSE 3000

CMD [ "npm", "start" ]
