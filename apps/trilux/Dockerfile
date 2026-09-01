# The Trilux runtime is only the Express host: the site itself is bind-mounted
# from the git checkout at /site, so this image never needs rebuilding when the
# content changes. @vercel/blob is here because api/lead.js and api/track.js
# import it and those files live outside the image.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production PORT=8080 SITE_ROOT=/site

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S trilux -G nodejs
USER trilux

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:8080/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
