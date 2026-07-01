FROM node:22-alpine
WORKDIR /app
RUN apk add --no-cache git && \
    git clone https://github.com/michaelhart/meshcore-mqtt-broker.git . && \
    git fetch origin pull/3/head:pr3 && \
    git merge pr3 && \
    npm install && \
    npm run build
EXPOSE 8883
CMD ["npm", "start"]
