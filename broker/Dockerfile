FROM node:22-alpine
WORKDIR /app
COPY subscriber-regions.patch /tmp/subscriber-regions.patch
# Upstream main and PR #3 are pinned so a rebuild can't pull in unreviewed
# changes; bump these deliberately when syncing upstream.
RUN apk add --no-cache git && \
    git config --global user.email "deploy@meshtexas.org" && \
    git config --global user.name "MeshTexas Deploy" && \
    git clone https://github.com/michaelhart/meshcore-mqtt-broker.git . && \
    git checkout 4c0496b15a0473045d289527f2ffbe39f73271c5 && \
    git fetch origin pull/3/head:pr3 && \
    git merge --no-edit 98384ab5b662240d47cab94bd2d074b89a69fa75 && \
    git fetch origin pull/10/head:pr10 && \
    git cherry-pick aebe5fcadf31aba2af55e5afa486a9d96016b731 && \
    git apply /tmp/subscriber-regions.patch && \
    npm install && \
    npm run build
EXPOSE 8883
CMD ["npm", "start"]
