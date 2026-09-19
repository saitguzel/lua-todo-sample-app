# ═══ FAZ 17 — FRONTEND TEST + WASM OPTİMİZASYONU ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — özellikle §11 teknik düzeltmeler #1 (Wasmoon hazır WASM),
> #2 (shared kod 5.1 ∩ 5.4), #11 (`-O3` / `ReleaseSmall` geçersiz).
> **Kanonik action listesi faz-13 §4.4'tedir.** Bu dokümandaki action adları o listeyle birebir aynıdır; yeni action gerekirse önce faz-13'e eklenir.

---

## Amaç

Frontend'in doğruluğunu iki katmanda güvenceye almak — (1) Lua mantığı için hızlı busted birim testleri
(reducer, router guard, fetch/coroutine köprüsü, yardımcılar), (2) gerçek tarayıcıda Playwright E2E senaryoları —
ve ilk yükleme performansını optimize etmek. Faz sonunda `make web.test` ve `make web.e2e` CI'da yeşil, ilk
anlamlı boyama (LCP) 4G'de < 2.5 sn, aktarılan toplam boyut (gzip) < 450 KB.

## Önkoşullar

| Faz | Neden |
|---|---|
| F12–F16 | Test edilecek frontend kodu |
| F11 | CI pipeline (bu faz job ekler), backend test altyapısı, seed |
| F1 | Shared spec'ler — burada iki yorumlayıcıda koşturulur |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `web/spec/helper.lua` | Test ortamı: `package.path`, sahte `js` modülü (DOM/fetch/storage mock) |
| `web/spec/reducer_spec.lua` | `app.lua` reducer dalları (auth, todos optimistic, rbac, toast, modal) |
| `web/spec/router_spec.lua` | Hash parse, query parse, guard (public / auth / page_key), `redirect_to` doğrulaması |
| `web/spec/fetch_spec.lua` | Promise → coroutine köprüsü, 401 → tek-uçuş refresh, hata eşleme |
| `web/spec/dom_spec.lua` | `h()` vnode üretimi, keyed diff/patch (sahte DOM üzerinde), metin kaçışı |
| `web/spec/views_spec.lua` | Saf yardımcılar: audit `diff_fields`, tarih dönüşümü, filtre ↔ query |
| `web/spec/shortcuts_spec.lua` | Editable hedefte tek tuşların engellenmesi, scope temizliği |
| `web/e2e/playwright.config.ts` | Playwright yapılandırması (Chromium + Firefox + WebKit, mobil profil) |
| `web/e2e/*.spec.ts` | E2E senaryoları (aşağıda) |
| `web/build-wasm.sh` *(güncelleme)* | Minify, manifest, hash'li dosya adları, gzip/brotli ön sıkıştırma |
| `web/public/index.html` *(güncelleme)* | `preload`, `modulepreload`, kritik CSS |
| `web/js/glue.js` *(güncelleme)* | `WebAssembly.compileStreaming`, lazy modül yükleme |
| `.github/workflows/ci.yml` *(güncelleme)* | `web-unit`, `web-e2e` job'ları |

> Prompt'ta `web/spec/*.lua` ve "E2E (Playwright)" var ama E2E dizini belirtilmemiş; `web/e2e/` seçildi.

---

## 1. Birim Testleri (busted, Lua 5.4)

### 1.1 Yorumlayıcı

Frontend kodu Wasmoon içinde **Lua 5.4** ile çalışır; testler de yerel `lua5.4` ile koşar (WASM gerekmez —
mantık aynı VM sürümünde test edilir). Shared kütüphane spec'i (F1) ayrıca `luajit` ile de koşturulur.

```bash
luarocks --lua-version=5.4 install busted
cd web && busted --lua=lua5.4 spec/
```

`.busted` (web/):

```lua
return {
  default = {
    lua = "lua5.4",
    ROOT = { "spec" },
    lpath = "src/?.lua;src/?/init.lua;../shared/src/?.lua;spec/?.lua",
    helper = "spec/helper.lua",
    output = "utfTerminal",
  },
}
```

### 1.2 `js` mock'u (`spec/helper.lua`)

Frontend modülleri tarayıcıya yalnızca `require("js")` (glue.js'in expose ettiği köprü tablosu, F12) üzerinden
dokunur. Testte bu modül `package.loaded["js"]` ile sahte bir tabloyla değiştirilir:

```lua
-- Test yardımcısı: glue.js köprüsünün bellek içi sahtesi
local fake = { storage = {}, calls = {}, fetch_queue = {}, now = 0 }

fake.storage_get = function(k) return fake.storage[k] end
fake.storage_set = function(k, v) fake.storage[k] = v end
fake.storage_remove = function(k) fake.storage[k] = nil end

-- fetch: kuyruktaki bir sonraki yanıtı döner; gerçek glue gibi callback ile çağırır
fake.fetch = function(req, cb)
  fake.calls[#fake.calls + 1] = req
  local res = table.remove(fake.fetch_queue, 1) or { status = 599, body = "{}" }
  cb(res)
end

fake.set_timeout = function(ms, fn) fn() end          -- zamanlayıcılar senkron
fake.confetti = function() fake.calls[#fake.calls + 1] = { confetti = true } end

package.loaded["js"] = fake
_G.test_js = fake    -- spec'lerin kuyruk doldurması için
```

Sahte DOM (`dom_spec`): `create_element` / `set_attr` / `append` / `remove` çağrılarını basit bir Lua ağacına
yazan ~80 satırlık `fake_dom`. jsdom **kullanılmaz** (Lua'dan erişilemez; gerek de yok — diff mantığı test edilir,
gerçek DOM E2E'de).

### 1.3 Test kapsamı

**`reducer_spec.lua`** (en kritik — saf fonksiyon, en yüksek değer):

| Senaryo | Beklenen |
|---|---|
| `LOGIN_SUCCEEDED` | `auth.user`, `auth.permissions` set; `auth.status == "authenticated"` |
| `LOGGED_OUT` | Tüm kullanıcıya özel dilimler (todos, users, audit) başlangıç değerine döner |
| `TODO_OPTIMISTIC_CREATE` → `TODO_CREATE_CONFIRMED` | temp id gerçek id ile değişir, `by_id` güncel, `pending` boş |
| `TODO_OPTIMISTIC_CREATE` → `TODO_ROLLBACK` | Satır kaldırılır, liste eski haline eşit |
| `TODO_OPTIMISTIC_UPDATE` → `TODO_ROLLBACK` | Snapshot birebir geri gelir (deep equal) |
| `TODO_OPTIMISTIC_DELETE` → `TODO_ROLLBACK` | Satır **eski indeksine** döner |
| Bilinmeyen id ile `TODO_ROLLBACK` | State değişmez, hata fırlatmaz |
| `RBAC_CELL_TOGGLED` → `RBAC_CELL_ROLLBACK` | Hücre eski değer |
| `TOAST_PUSHED` × 6 | En fazla 5, en eski düşer |
| Aynı mesajla 2 × `TOAST_PUSHED` (1 sn içinde) | Tek toast, `count == 2` |
| Bilinmeyen action | State referansı aynı döner |

**`router_spec.lua`:**

| Senaryo | Beklenen |
|---|---|
| `#/todos?status=pending&page=2` | `{ path="/todos", query={ status="pending", page="2" } }` |
| URL-encoded query (`q=fatura%20%C3%B6de`) | `"fatura öde"` |
| Oturumsuz → `#/todos` | `#/login`'e yönlenir, `redirect_to = "#/todos"` saklanır |
| todouser → `#/rbac` | Erişim reddi view'ı / dashboard, navigasyon yapılmaz |
| Oturumlu → `#/login` | `#/dashboard` |
| `redirect_to = "https://evil.com"` veya `"//evil.com"` | Reddedilir → `#/dashboard` |
| Bilinmeyen route | 404 view'ı |

**`fetch_spec.lua`:**

| Senaryo | Beklenen |
|---|---|
| 200 JSON | `data` tablosu döner |
| 422 | `nil, { code="VALIDATION_FAILED", details=... }` |
| 401 `TOKEN_EXPIRED` → refresh 200 → tekrar 200 | Orijinal istek yeni token ile tekrarlanır; çağıran fark etmez |
| Aynı anda 3 istek 401 | **Tek** `/auth/refresh` çağrısı (tek-uçuş), 3'ü de tekrarlanır |
| Refresh 401 | `LOGGED_OUT` dispatch edilir, `nil, UNAUTHORIZED` |
| Ağ hatası (status 0) | `nil, { code = "NETWORK_ERROR" }` — **frontend'e özel** kod, API kodu değildir (00 §5'e eklenmez) |
| `Authorization` header | Token varsa ekleniyor, `/auth/login`'de eklenmiyor |

**`views_spec.lua`:** `diff_fields` (ekleme/silme/değişme/değişmeme), `datetime-local` → ISO UTC,
filtre tablosu ↔ query string gidiş-dönüş eşitliği, `redirect_to` doğrulayıcı.

**`dom_spec.lua`:** Metin her zaman `textContent` yoluyla (vnode'da `innerHTML` alanı yok — XSS regresyon testi:
`<img src=x onerror=...>` string'i text node olarak kalır), keyed listede yeniden sıralamada düğümlerin yeniden
yaratılmaması (fake_dom'daki `create_element` çağrı sayısı), event listener'ların `leave`'de temizlenmesi.

Kapsam hedefi: `app.lua` reducer ve `router.lua` için satır kapsamı ≥ %90 (`luacov`); view render fonksiyonları
birim testte hedeflenmez (E2E kapsar).

```bash
busted --coverage && luacov && tail -n 20 luacov.report.out
```

---

## 2. E2E Testleri (Playwright)

### 2.1 Ortam

- Test stack'i: `docker compose -f docker-compose.yml -f docker-compose.e2e.yml up -d`
  (postgres tmpfs, `SEED_DEFAULTS=true`, `APP_ENV=test`, MailHog).
  `docker-compose.e2e.yml` yalnızca override içerir (tmpfs volume + env); yeni servis eklemez.
- Her test dosyası öncesi DB sıfırlama: `make db.reset` yerine API'de test endpoint'i **açılmaz** (güvenlik);
  bunun yerine her test **kendi benzersiz verisini** oluşturur (`e2e-<uuid>@todoapp.local`) — testler izole ve paralel.
- Rate limit: login testleri farklı e-postalar kullanır; rate-limit testi ayrı ve seri (`test.describe.serial`).

`web/e2e/playwright.config.ts`:

```ts
import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: ".",
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  use: { baseURL: process.env.WEB_BASE_URL ?? "http://localhost:28000", trace: "retain-on-failure" },
  projects: [
    { name: "chromium", use: devices["Desktop Chrome"] },
    { name: "firefox",  use: devices["Desktop Firefox"] },
    { name: "webkit",   use: devices["Desktop Safari"] },
    { name: "mobile",   use: devices["Pixel 7"] },
  ],
});
```

Wasmoon başlatma bekleme yardımcısı: glue.js hazır olunca `document.documentElement.dataset.ready = "1"` set eder;
testler `await page.waitForSelector("html[data-ready='1']")` ile bekler (keyfi `sleep` yok).

### 2.2 Senaryolar

| Dosya | Senaryolar |
|---|---|
| `auth.spec.ts` | Başarılı login (admin, user); hatalı parola mesajı; oturumun yenilemede korunması; logout sonrası geri tuşu korumalı sayfaya girmez; süresi dolmuş token → sessiz refresh (access TTL'i kısa test env ile) |
| `password-reset.spec.ts` | Forgot → MailHog API'den (`GET :8025/api/v2/messages`) link al → reset → yeni parola ile login; aynı link ikinci kez → hata; kayıtsız e-posta aynı mesaj |
| `todos.spec.ts` | Oluştur/düzenle/tamamla/sil; filtre + URL; boş durum; `page.route` ile API'yi 500'e zorlayıp **optimistic rollback** + toast; başka kullanıcının todo id'si → bulunamadı |
| `admin-users.spec.ts` | Kullanıcı oluştur → o kullanıcıyla login; `EMAIL_TAKEN`; kendini silme butonu disabled |
| `admin-rbac.spec.ts` | todouser'a `users.list` ver → todouser oturumunda (reload) menü öğesi görünür; admin `rbac.matrix` hücresi disabled; **todouser'ın API'ye doğrudan isteği 403** (frontend gizlemesinin güvenlik olmadığının kanıtı) |
| `admin-audit.spec.ts` | Todo oluştur → audit'te `todo.create`; filtre; detay diff; CSV indirme (`page.waitForEvent("download")`, satır sayısı kontrolü) |
| `a11y.spec.ts` | `@axe-core/playwright` ile login, dashboard, todos, users, rbac, audit — 0 serious/critical ihlal; her iki tema |
| `keyboard.spec.ts` | Yalnızca klavye ile todo akışı; `n`/`e`/`d`/`/`/`Esc`; modal focus trap ve focus geri yükleme |
| `responsive.spec.ts` | `mobile` projesinde: hamburger menü, tablo → kart, yatay kaydırma yok (`scrollWidth <= clientWidth`) |

Page Object'ler **yazılmaz**; 3+ dosyada tekrar eden adımlar (`login(page, email, pw)`) tek `e2e/helpers.ts`'e
çıkarılır. Seçiciler: `getByRole` / `getByLabel` önceliklidir (ARIA doğruluğunu da test eder); `data-testid` yalnızca
rol ile ayırt edilemeyen yerlerde.

### 2.3 Çalıştırma

```bash
cd web && npm ci && npx playwright install --with-deps
make up.e2e && npx playwright test
npx playwright show-report
```

---

## 3. Yükleme Optimizasyonu

### 3.1 Neyi optimize etmiyoruz (00 §11 #1, #11)

- **Emscripten `-O3` / `ReleaseSmall` uygulanmaz.** WASM dosyası (`app.wasm`) Wasmoon'un önceden derlenmiş
  `glue.wasm`'ıdır; biz derlemiyoruz. Zaten release derlemesidir (~250 KB ham, ~100 KB brotli).
- Lua kaynakları `luac` ile bytecode'a **çevrilmez**: Wasmoon'un derlendiği 5.4 alt sürümü ile yerel `luac` sürümü
  farklıysa bytecode yüklenemez; kazanç da (parse süresi) ölçülebilir değil. Ölçüm sonrası gerekirse tekrar değerlendirilir.

### 3.2 Uygulanan optimizasyonlar

| # | Teknik | Nerede | Beklenen etki |
|---|---|---|---|
| 1 | Lua minify (yorum + gereksiz boşluk silme) | `build-wasm.sh` → `luamin` (npm) veya `luasrcdiet` | Türkçe yorumlar kaynağın ~%30'u; bundle ~%35 küçülür |
| 2 | Tek `bundle.json` manifest: `{ "modül.adı": "kaynak" }` | `build-wasm.sh` | Tek HTTP isteği; glue.js `mountFile` ile sanal FS'e yazar |
| 3 | Content hash'li dosya adları (`bundle.3f9a1c.json`, `app.8b21.wasm`) | `build-wasm.sh` + `index.html` yeniden yazımı | `Cache-Control: immutable` mümkün |
| 4 | Ön sıkıştırma `.br` + `.gz` | `build-wasm.sh` (`brotli -q 11`, `gzip -9`) | nginx `brotli_static` / `gzip_static` (F18) |
| 5 | `<link rel="preload" as="fetch" type="application/wasm" crossorigin>` | `index.html` | WASM, JS parse'ı beklemeden iner |
| 6 | `WebAssembly.compileStreaming` | `glue.js` (Wasmoon factory'ye `customWasmUri` / hazır modül) | İndirme ile derleme paralel |
| 7 | Lazy view yükleme: admin view'ları ayrı `bundle-admin.<hash>.json` | `build-wasm.sh` + router | todouser admin kodunu hiç indirmez; admin route'una ilk girişte yüklenir |
| 8 | `canvas-confetti` dinamik `import()` | `glue.js` | İlk todo tamamlanana kadar yüklenmez |
| 9 | Kritik CSS inline + Tailwind prod'da derlenmiş (F18) | `index.html` | Render-blocking CSS azalır |
| 10 | Uygulama kabuğunun (layout iskeleti) statik HTML'de olması | `index.html` | WASM yüklenirken boş beyaz ekran yerine iskelet (LCP'yi iyileştirir) |

`build-wasm.sh` bundle adımı (özet):

```bash
#!/usr/bin/env bash
# Lua kaynaklarını minify edip tek manifest'e paketler, hash'ler ve ön sıkıştırır
set -euo pipefail
OUT=public/dist; rm -rf "$OUT"; mkdir -p "$OUT"
bundle() {  # $1 = çıktı adı, $2.. = kaynak kökleri
  local name=$1; shift
  node scripts/bundle-lua.mjs --minify "$@" > "$OUT/$name.json"      # { "views.todos": "<kaynak>", ... }
  local h; h=$(sha256sum "$OUT/$name.json" | cut -c1-8)
  mv "$OUT/$name.json" "$OUT/$name.$h.json"; echo "$name=$name.$h.json" >> "$OUT/manifest.env"
}
bundle bundle       src/*.lua src/components ../shared/src   # çekirdek
bundle bundle-admin src/views/users.lua src/views/rbac_matrix.lua src/views/audit_logs.lua
cp node_modules/wasmoon/dist/glue.wasm "$OUT/app.$(sha256sum node_modules/wasmoon/dist/glue.wasm | cut -c1-8).wasm"
for f in "$OUT"/*.{json,wasm,js}; do brotli -q 11 -k "$f"; gzip -9 -k "$f"; done
node scripts/rewrite-index.mjs "$OUT/manifest.env"                 # index.html'deki yolları hash'li adlarla değiştir
```

> `scripts/bundle-lua.mjs` ve `scripts/rewrite-index.mjs` küçük (~50 satır) Node script'leri; Vite/webpack eklenmez.

### 3.3 Bütçe ve ölçüm

| Metrik | Bütçe | Ölçüm |
|---|---|---|
| Aktarılan toplam (brotli), login sayfası | < 450 KB | Lighthouse "Total byte weight" |
| `app.wasm` (br) | ~100 KB (sabit, Wasmoon) | — |
| Çekirdek Lua bundle (br) | < 40 KB | `ls -l public/dist/*.br` |
| LCP (Moto G4, 4G profili) | < 2.5 sn | Lighthouse mobile |
| TTI | < 3.5 sn | Lighthouse |
| CLS | < 0.1 | Lighthouse |
| Lua VM başlatma + ilk render | < 150 ms | glue.js `performance.mark("lua-ready")` → konsola |

Bütçe CI'da `lighthouse-ci` (`lhci autorun`) ile `web-e2e` job'unda kontrol edilir; aşım build'i kırmaz,
PR'a uyarı yorumu düşer (ilk sürüm için). Stabilleşince hataya çevrilir.

---

## 4. CI Entegrasyonu

`.github/workflows/ci.yml`'e eklenen job'lar (F11'deki pipeline'ın devamı):

```yaml
  web-unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v10
        with: { luaVersion: "5.4" }
      - uses: leafo/gh-actions-luarocks@v4
      - run: luarocks install busted && luarocks install luacov
      - run: cd web && busted --coverage spec/
      - run: cd shared && busted spec/        # shared kodun 5.4'te de geçtiğinin kanıtı (F1: luajit job'u ayrı)

  web-e2e:
    needs: [web-unit, api-integration]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm, cache-dependency-path: web/package-lock.json }
      - run: cd web && npm ci && npx playwright install --with-deps
      - run: make up.e2e
      - run: cd web && npx playwright test
      - if: failure()
        uses: actions/upload-artifact@v4
        with: { name: playwright-report, path: web/playwright-report }
      - run: cd web && npx lhci autorun || true
```

Makefile hedefleri: `web.test`, `web.e2e`, `up.e2e`, `web.build` (optimizasyonlu), `web.size` (bütçe raporu).

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Birim testleri yerel `lua5.4` ile, WASM'sız | Aynı VM sürümü; saniyeler içinde koşar; WASM katmanı E2E'de test edilir |
| `js` köprüsünün mock'lanması | Frontend'in tek dış bağımlılığı bu tablo; tasarım gereği test edilebilir |
| jsdom yok | Lua'dan kullanılamaz; diff mantığı fake DOM ile, gerçek DOM E2E ile |
| Playwright seçicilerinde rol/label önceliği | Testler ARIA'yı da doğrular |
| DB reset endpoint'i yok | Prod'a sızma riski; testler benzersiz veriyle izole |
| `-O3`/`ReleaseSmall`/`luac` yok | WASM'ı biz derlemiyoruz; bytecode taşınabilirlik riski (00 §11) |
| Bundler (Vite/webpack) yok | Lua kaynağı paketlemek için 2 küçük Node script'i yeterli |

## Kabul kriterleri (DoD)

- [ ] `make web.test` yeşil; reducer + router satır kapsamı ≥ %90.
- [ ] `shared/spec` hem `luajit` hem `lua5.4` ile yeşil.
- [ ] Tabloda listelenen tüm reducer, router ve fetch senaryoları için test var.
- [ ] `make web.e2e` Chromium, Firefox, WebKit ve mobil projede yeşil; CI'da 2 retry ile flaky oranı < %2.
- [ ] Optimistic rollback E2E'de ağ hatası simülasyonu ile doğrulanıyor.
- [ ] Todouser'ın admin API'lerine doğrudan isteği E2E'de 403 dönüyor.
- [ ] axe: 0 serious/critical ihlal (açık + koyu tema).
- [ ] `build-wasm.sh` hash'li, minify edilmiş, `.br`/`.gz` ön sıkıştırılmış çıktı üretiyor; `index.html` doğru yolları içeriyor.
- [ ] todouser oturumunda Network sekmesinde `bundle-admin.*` isteği yok.
- [ ] Bütçe tablosundaki metrikler karşılanıyor (Lighthouse raporu PR'a eklendi).
- [ ] CI'da `web-unit` ve `web-e2e` job'ları çalışıyor; başarısız E2E'de trace artifact yükleniyor.

## Doğrulama

```bash
cd web
busted --lua=lua5.4 --coverage spec/ && luacov && grep -A3 "Summary" luacov.report.out
(cd ../shared && busted --lua=luajit spec/ && busted --lua=lua5.4 spec/)
./build-wasm.sh && ls -la public/dist/ && du -ch public/dist/*.br | tail -1
make up.e2e && npx playwright test --project=chromium
npx lighthouse http://localhost:28000/#/login --preset=perf --form-factor=mobile --output=json \
  | jq '.audits["largest-contentful-paint"].displayValue, .audits["total-byte-weight"].displayValue'
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Mock ile gerçek glue.js davranışının ayrışması | E2E aynı akışları gerçek tarayıcıda koşar; glue.js API'si değişince mock aynı PR'da güncellenir (review kuralı) |
| Wasmoon başlatma süresinin CI'da değişken olması | `data-ready` bekleme; sabit sleep yok |
| Rate-limit'in paralel E2E'yi bozması | Benzersiz e-postalar; rate-limit testi seri |
| Minifier'ın Lua 5.4 sözdizimini (`<const>`, `//`) bozması | Minify sonrası `luac -p` ile sözdizim kontrolü build adımında |
| Lazy admin bundle'ın yetki değişiminde yüklenmemesi | Router guard admin route'unda bundle'ı yükler; `PERMISSIONS_LOADED` sonrası da çalışır |
| WebKit'te `<dialog>` / clipboard farkları | WebKit projesi CI'da zorunlu |

## Tahmini Efor

**M** — ~2 gün (birim testleri ~0.75, E2E ~0.75, optimizasyon + ölçüm ~0.5).
