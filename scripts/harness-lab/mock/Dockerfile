FROM node:22-slim
WORKDIR /app
COPY server.js selftest.js ./
ENV PORT=8080
EXPOSE 8080
USER node
HEALTHCHECK --interval=5s --timeout=2s --retries=6 CMD ["node", "-e", "fetch('http://127.0.0.1:8080/_health').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
CMD ["node", "server.js"]
