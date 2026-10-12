# Server + admin panel + web verzija aplikacije u jednoj slici (Railway ili docker compose).
FROM node:22-bookworm AS base

FROM base AS admin
WORKDIR /app/admin
COPY admin/package*.json ./
RUN npm ci
COPY admin/ ./
RUN npm run build

# Web verzija aplikacije za igrače (iPhone i računar bez instalacije), servira se na /igra
FROM ghcr.io/cirruslabs/flutter:3.24.5 AS web
WORKDIR /app/mobile
COPY mobile/pubspec.yaml mobile/pubspec.lock ./
RUN flutter pub get
COPY mobile/ ./
RUN flutter build web --release --base-href /igra/ --no-web-resources-cdn

FROM base AS backend
WORKDIR /app/backend
COPY backend/package*.json ./
COPY backend/prisma ./prisma
RUN npm ci
COPY backend/ ./
RUN npm run build

FROM base
WORKDIR /app/backend
ENV NODE_ENV=production
COPY --from=backend /app/backend ./
COPY --from=admin /app/admin/dist /app/admin/dist
COPY --from=web /app/mobile/build/web /app/web
EXPOSE 3000
# Pri svakom pokretanju: ažuriraj tabele u bazi, pa pokreni server.
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/main.js"]
