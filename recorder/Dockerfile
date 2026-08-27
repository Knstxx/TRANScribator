FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY index.js .

CMD ["node", "index.js"]
