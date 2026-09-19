# Katkı Kılavuzu

## Gereksinimler

- Docker 24+, Docker Compose v2, GNU Make, git
- (yerel geliştirme için) Lua 5.4 + LuaJIT, LuaRocks, luacheck, busted
- Node 20+ (web tarafı)

## Kurulum

```bash
make setup          # .env + git hooks (core.hooksPath .githooks → luacheck pre-commit)
make up             # postgres + mailhog + api + web
make db.migrate db.seed
```

## Dal ve commit kuralları

- `main` korumalı; çalışma dalları: `feat/…`, `fix/…`, `docs/…`
- PR zorunlu: 1 onay + yeşil CI
- Commit'ler Conventional Commits formatında: `feat(api): …`, `fix(web): …`, `docs: …`

## Kod kuralları

- Katman kuralları: [00-genel-bakis §4](docs/fazlar/00-genel-bakis.md) (handler → service → repository; ihlal review red sebebi)
- Konvansiyonlar: 00 §14 — yorumlar Türkçe, tanımlayıcılar `snake_case`, her modül `local _M = {} … return _M`
- Shared kod Lua 5.1 ∩ 5.4 ortak alt kümesinde yazılır (`//`, `goto`, `<const>` yok)

## Yeni endpoint kontrol listesi

- [ ] Route (`api/src/router.lua`) + `page_key`/auth alanı
- [ ] `authorization(page_key)` guard'ı
- [ ] Validation şeması (shared — backend ve frontend aynı şemayı kullanır)
- [ ] Service + repo katmanları; parametreli SQL (`$1`)
- [ ] Audit olayı (00 §8 listesine ekle)
- [ ] OpenAPI spec güncellemesi + `make spec.lint`
- [ ] Integration testi
- [ ] Gerekiyorsa frontend view + action sabitleri (faz-13 §4.4)

## Yeni env değişkeni

Sırayla: önce [00-genel-bakis §6](docs/fazlar/00-genel-bakis.md) tablosu → `.env.example` → `api/src/config.lua`.

## Migration kuralı

Yalnızca ileri, geriye uyumlu (expand → contract): önce sütun ekle, eski kod uyumlu kalsın; sonraki sürümde kaldır.

## Testler

```bash
make lint              # luacheck
make test.shared       # shared spec (LuaJIT + lua5.4)
make test.api          # backend birim
make test.integration  # API çalışırken
make web.test          # frontend birim (lua5.4)
make web.e2e           # Playwright (make up.e2e gerekir)
```

## İmajlar

Build context her zaman repo kökü (`shared/` gerekli):

```bash
docker build -f api/Dockerfile --target prod -t todo-api:local .   # dev compose `target: dev` kullanır
docker run --rm todo-api:local id                                  # uid != 0 olmalı
```

Yeni bir C rock'u eklenirse runtime kütüphanesini (`apk add …-libs`) `prod` aşamasına ekleyin; aksi halde
`require` yalnızca prod imajında düşer.
