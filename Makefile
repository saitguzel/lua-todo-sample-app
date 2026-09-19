-include .env
export

# Lua araçları (luacheck, busted, resty) host'ta kurulu olmak zorunda değil: dev api imajında koşar.
# TOOLS_IMAGE dev imajıdır (busted + luacheck içerir); `make up` onu üretir.
TOOLS_IMAGE ?= todo-lua-api:latest
TOOLS = docker run --rm -v "$(CURDIR)":/w -w /w $(TOOLS_IMAGE)
# Entegrasyon testleri host ağından koşar: API :28080, PG 127.0.0.1:25432, MailHog :28025
IT = docker run --rm --network host --env-file .env -e APP_ENV=test -v "$(CURDIR)":/w -w /w/api $(TOOLS_IMAGE)
LUA54_IMAGE ?= nickblah/lua:5.4-luarocks
# busted'ın C bağımlılıkları (luasystem) için derleyici gerekir
LUA54_BUSTED = apt-get update -qq && apt-get install -y -qq gcc libc6-dev >/dev/null && luarocks install busted >/dev/null
LINT_PATHS = api/src shared/src web/src api/spec shared/spec api/bench api/bin/busted.lua

.PHONY: setup hooks ports.check up down logs db.psql lint test test.unit test.shared test.api test.integration \
	test.web test.e2e web.test web.e2e bench spec.lint openapi.dump openapi.lint web.build web.dev web.size \
	db.migrate db.rollback db.status db.seed db.reset api.dev api.reload conf.env job.cleanup up.e2e backup.verify \
	rockspecs

setup:
	cp -n .env.example .env || true
	$(MAKE) hooks
	@echo "Kurulum tamam: .env oluşturuldu (varsa üzerine yazılmadı), hook ayarlandı"

hooks:
	@git rev-parse --git-dir >/dev/null 2>&1 || { echo "HATA: git reposu değil; önce 'git init'" >&2; exit 1; }
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

ports.check:
	@bash scripts/check-ports.sh

up: ports.check
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f api

db.psql:
	docker compose exec postgres psql -U $${DB_USER:-todo} $${DB_NAME:-todo}

# ---- Lint ve testler (F11 §9) ----
lint:
	$(TOOLS) luacheck $(LINT_PATHS)

test: lint test.unit test.integration

test.unit: test.shared test.api

test.shared:
	$(TOOLS) busted shared/spec
	docker run --rm -v "$(CURDIR)":/w -w /w $(LUA54_IMAGE) sh -c '$(LUA54_BUSTED) && busted shared/spec'

test.api:
	$(TOOLS) sh -c 'cd api && ./bin/busted --run=unit'

test.integration:
	$(IT) busted --run=integration

test.web web.test:
	docker run --rm -v "$(CURDIR)":/w -w /w/web $(LUA54_IMAGE) sh -c '$(LUA54_BUSTED) && busted spec'

test.e2e web.e2e:
	cd web && npx playwright test

bench:
	bash api/bench/run.sh

# ---- OpenAPI (F9) ----
openapi.dump:
	docker compose exec -T api resty -I /app/src -I /app/lib -e ' \
	  local config = require("config"); config.current = config.load(); \
	  print(require("cjson").encode(require("openapi.spec").build()))' > api/public/swagger.json

openapi.lint spec.lint: openapi.dump
	npx --yes @redocly/cli@1 lint api/public/swagger.json --config redocly.yaml

# ---- Web (F12/F17) ----
web.build:
	cd web && ./build-wasm.sh

web.dev:
	cd web && npm run dev

web.size:
	@if [ -x web/scripts/size.sh ]; then web/scripts/size.sh; else \
	  test -d web/public || { echo "HATA: web/public yok; önce make web.build" >&2; exit 1; }; \
	  find web/public -type f \( -name '*.js' -o -name '*.json' -o -name '*.wasm' -o -name '*.css' -o -name '*.html' \) \
	    ! -name '*.gz' ! -name '*.br' | sort | while read -r f; do \
	    printf '%-60s %8s B  gzip %8s B\n' "$$f" "$$(wc -c < "$$f")" "$$(gzip -9c "$$f" | wc -c)"; done; fi

# ---- Veritabanı (F2) ----
MIGRATE = docker compose exec -T api resty -I /app/src -I /app/lib /app/src/db/migrations.lua
db.migrate:
	$(MIGRATE) up
db.rollback:
	$(MIGRATE) down $(or $(STEPS),1)
db.status:
	$(MIGRATE) status
db.seed:
	$(MIGRATE) seed
db.reset:
	docker compose down -v && docker compose up -d --wait postgres api
	$(MAKE) db.migrate db.seed

# ---- API (F3/F10) ----
api.dev:
	docker compose up api postgres mailhog

api.reload:
	docker compose exec api openresty -p /app -c conf/nginx.conf -s reload

# config.lua SPEC anahtarlarından nginx `env X;` satırları (F3 §env) — üretilen dosya commit edilir
conf.env:
	docker compose exec -T api resty -I /app/src -I /app/lib \
	  -e 'for _, k in ipairs((require("config").spec_keys())) do print("env " .. k .. ";") end' > api/conf/env.conf.tmp
	mv api/conf/env.conf.tmp api/conf/env.conf

# Log temizleme işini anında çalıştır (F10): config + pool + job_locks dict ile
job.cleanup:
	docker compose exec -T api resty -I /app/src -I /app/lib --shdict 'job_locks 1m' -e ' \
	  local config = require("config"); config.current = config.load(); \
	  require("db.pool").configure(config.current.db); \
	  local r, e = require("jobs.log_cleanup").run_once(); \
	  print(require("cjson").encode(r or { error = e })); if not r then os.exit(1) end'

# ---- E2E / yedek / paket ----
up.e2e:
	@test -f docker-compose.e2e.yml || { echo "HATA: docker-compose.e2e.yml yok (F17)" >&2; exit 1; }
	docker compose -f docker-compose.yml -f docker-compose.e2e.yml up -d --build --wait

backup.verify:
	sh deploy/backup/verify.sh

rockspecs:
	$(TOOLS) luarocks make rockspecs/todo-shared-0.1.0-1.rockspec --tree /tmp/rocks
