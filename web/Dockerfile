# F17/F18: web imajı — build context repo kökü (shared/ ve deploy/ gerekir):
#   docker build -f web/Dockerfile .
# Aşama 1: Lua bundle'ları + glue.js + Tailwind CLI (MODE=production; demo hesaplar yok)
FROM node:22-alpine AS build
RUN apk add --no-cache bash lua5.4 brotli
WORKDIR /src
COPY web/package.json web/package-lock.json web/
RUN cd web && npm ci --no-audit --no-fund
COPY shared/src shared/src
COPY web/index.html web/build-wasm.sh web/tailwind.config.cjs web/
COPY web/src web/src
COPY web/js web/js
COPY web/static web/static
COPY web/scripts web/scripts
RUN cd web && CI=1 MODE=production ./build-wasm.sh

# Aşama 2: yalnızca statik çıktı + nginx (Node/kaynak yok)
FROM nginx:1.27-alpine
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/web/public/index.html /usr/share/nginx/html/index.html
COPY --from=build /src/web/public/dist /usr/share/nginx/html/dist
EXPOSE 80
