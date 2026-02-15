FROM node:22-slim
WORKDIR /app
COPY proxy.js .
COPY public/ public/
EXPOSE 8080 3001
CMD ["node", "proxy.js"]
