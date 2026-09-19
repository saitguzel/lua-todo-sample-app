# Çok aşamalı API imajı (F18). Build context = repo kökü (shared/ gerekli).
#   dev  : docker-compose.yml (kaynaklar volume ile bağlanır, busted/luacheck dahil)
#   prod : docker build -f api/Dockerfile --target prod -t todo-api:local .

# ---- 1. aşama: LuaRocks bağımlılıkları (derleme araçları yalnızca burada) ----
FROM openresty/openresty:1.25.3.2-alpine-fat AS build
RUN apk add --no-cache build-base argon2-dev openssl-dev git
RUN luarocks install lapis 1.16.0 \
 && luarocks install pgmoon 1.16.0 \
 && luarocks install lua-resty-jwt 0.2.3 \
 && luarocks install argon2 3.0.1 \
 && luarocks install lua-resty-mail 1.1.0

# ---- dev: derleme imajı + test araçları ----
FROM build AS dev
RUN luarocks install busted && luarocks install luacheck
WORKDIR /app
EXPOSE 8080
CMD ["openresty", "-p", "/app", "-c", "conf/nginx.conf", "-g", "daemon off;"]

# ---- prod: ince runtime, non-root ----
FROM openresty/openresty:1.25.3.2-alpine AS prod
# perl: migration CLI'ı `resty` ile koşar; argon2-libs/libssl3: C rock'ları; tini: PID 1
RUN apk add --no-cache argon2-libs libssl3 libcrypto3 libgcc perl tini ca-certificates \
 && addgroup -S app && adduser -S -G app -H app
COPY --from=build /usr/local/openresty/luajit /usr/local/openresty/luajit
WORKDIR /app
COPY --chown=app:app api/conf/ conf/
COPY --chown=app:app api/src/ src/
COPY --chown=app:app api/migrations/ migrations/
COPY --chown=app:app api/seeds/ seeds/
COPY --chown=app:app api/public/ public/
COPY --chown=app:app shared/src/ lib/todo_shared/
# read_only rootfs'ta bu dizinler compose'da tmpfs olarak bağlanır
RUN mkdir -p logs temp client_body_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp \
 && chown -R app:app logs temp *_temp
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8080/api/v1/health || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["openresty", "-p", "/app", "-c", "conf/nginx.conf", "-g", "daemon off;"]
