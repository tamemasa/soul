FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --production 2>/dev/null || npm install --production

COPY . .

EXPOSE 3000

USER node

CMD ["node", "server.js"]
