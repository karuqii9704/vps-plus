# NALAR has no Dockerfile of its own and no `output: "standalone"` in
# next.config.ts, so this cannot use the slim standalone trick the plus. site
# uses. It ships the built app with production dependencies instead — a larger
# image, but it needs no change to the NALAR repo.
#
# Build context is the NALAR checkout; this file is passed with -f from
# /srv/vps-plus/apps/nalar/Dockerfile.

FROM node:22-alpine AS builder
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# NEXT_PUBLIC_* is baked into the browser bundle here. The service-role key and
# the committee Postgres credentials are read at request time and must NOT be
# build args — they would end up in the image history.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_MAPS_KEY
ARG NEXT_PUBLIC_GOOGLE_MAPS_API_KEY
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_MAPS_KEY=$NEXT_PUBLIC_MAPS_KEY \
    NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=$NEXT_PUBLIC_GOOGLE_MAPS_API_KEY

RUN npm run build

# --- runner -----------------------------------------------------------------
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0

RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S nextjs -G nodejs

COPY --from=builder --chown=nextjs:nodejs /app/package.json /app/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=builder --chown=nextjs:nodejs /app/.next        ./.next
COPY --from=builder --chown=nextjs:nodejs /app/public       ./public
COPY --from=builder --chown=nextjs:nodejs /app/next.config.ts ./

# The tracer can drag a stray env file into the image; make sure it cannot.
RUN rm -f .env .env.local .env.production

USER nextjs
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"

CMD ["npx", "next", "start"]
