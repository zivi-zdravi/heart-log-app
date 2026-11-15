FROM node:22-alpine
WORKDIR /app
COPY server.js .
USER node
ENV NODE_ENV=production DATA_DIR=/data PORT=8787
EXPOSE 8787
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:8787/health || exit 1
CMD ["node", "server.js"]
