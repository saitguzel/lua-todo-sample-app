# ═══ FAZ 16 — FRONTEND UX POLISH ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md). Bileşenler F14/F15 view'larında kullanılır.
> **Kanonik action listesi faz-13 §4.4'tedir.** Bu dokümandaki action adları o listeyle birebir aynıdır; yeni action gerekirse önce faz-13'e eklenir.

---

## Amaç

Uygulamayı "çalışıyor"dan "kullanması keyifli ve erişilebilir"e taşımak: yeniden kullanılabilir 4 bileşen
(toast, modal, theme_toggle, skeleton), karanlık/açık tema, responsive yerleşim, ARIA/klavye erişilebilirliği,
global klavye kısayolları ve todo tamamlanınca confetti. Faz sonunda uygulama yalnızca klavye ile baştan sona
kullanılabilir, Lighthouse Accessibility ≥ 95, 360px genişlikte yatay kaydırma yoktur.

## Önkoşullar

| Faz | Neden |
|---|---|
| F12 | `styles.css` (CSS değişkenleri), `glue.js` (confetti, matchMedia, focus bridge'leri) |
| F13 | `dom.lua`, store |
| F14, F15 | Bileşenleri kullanan view'lar (bu fazda geçici basit sürümler bu bileşenlerle değiştirilir) |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `web/src/components/toast.lua` | Bildirim kuyruğu, `aria-live`, otomatik kapanma, hover'da duraklatma |
| `web/src/components/modal.lua` | Dialog, focus trap, `Esc`, focus geri yükleme, `confirm()` yardımcısı |
| `web/src/components/theme_toggle.lua` | Açık/Koyu/Sistem, `localStorage` + `prefers-color-scheme` |
| `web/src/components/skeleton.lua` | Kart/satır/metin iskeletleri, `aria-busy` |
| `web/src/shortcuts.lua` *(yeni, küçük)* | Global klavye kısayolu kaydı; view'lar `register/unregister` yapar |
| `web/public/styles.css` *(güncelleme)* | Tema token'ları, responsive kırılımlar, `prefers-reduced-motion`, focus halkası |
| `web/js/glue.js` *(güncelleme)* | `confetti`, `matchMedia` dinleyici, `focus`/`activeElement` bridge'leri |

> `shortcuts.lua` prompt ağacında yok. Alternatif: `app.lua` içine ~40 satır. Ayrı dosya tercih edildi çünkü
> view'lar `leave`'de kendi kısayollarını temizlemeli; bu API app.lua'yı şişirir. İstenirse app.lua'ya taşınabilir.

---

## Bileşen Sözleşmesi

Bileşenler view gibi saf `render(props) → vnode` fonksiyonlarıdır; state'leri store'dadır (toast, modal) veya
yoktur (skeleton). Yan etkiler (timer, focus) `dom.lua`'nın `on_mount` / `on_unmount` kancalarıyla yapılır (F13).

---

## Dosya Bazlı Tasarım

### 1. `web/src/components/toast.lua`

**Public API:**

```lua
local toast = require("components.toast")
toast.success(msg, opts)   -- opts: { timeout = 4000, action = { label = "Tekrar dene", fn = f } }
toast.error(msg, opts)     -- default timeout 7000; hata toast'ları daha uzun kalır
toast.info(msg, opts)
toast.dismiss(id)
toast.render(state)        -- layout.lua içinde bir kez çağrılır
```

`toast.success` → `app.dispatch{ type = "TOAST_PUSHED", toast = { id, kind, message, timeout, action } }`.
Kapanma → `TOAST_DISMISSED`. Store dilimi: `state.toasts = { ... }` (en fazla 5; fazlası en eskiyi düşürür).

**DOM:**

```html
<div class="toast-region" aria-live="polite" aria-relevant="additions">     <!-- success/info -->
<div class="toast-region" role="alert" aria-live="assertive">                 <!-- error -->
  <div class="toast toast-error">
    <span class="icon" aria-hidden="true">⚠</span>
    <p>Todo silinemedi</p>
    <button>Tekrar dene</button>
    <button aria-label="Bildirimi kapat">×</button>
  </div>
```

İki ayrı bölge: hata `assertive`, diğerleri `polite`. Bölgeler sayfa yüklenince **boş** olarak DOM'da bulunur
(sonradan eklenen live region'ları ekran okuyucular kaçırır).

**Davranış:**
- Otomatik kapanma `js.timer.after`; fare üstündeyken veya focus içindeyken duraklar (WCAG 2.2.1).
- Aynı mesaj 1 sn içinde tekrar gelirse yeni toast açılmaz, sayaç `(×2)` artar.
- Konum: masaüstünde sağ alt, mobilde üst tam genişlik (`env(safe-area-inset-top)`).
- `prefers-reduced-motion`: kayma animasyonu yerine yalnızca opaklık.

### 2. `web/src/components/modal.lua`

**Public API:**

```lua
local modal = require("components.modal")

-- Genel dialog: içerik bir render fonksiyonu
modal.open({ id = "todo-edit", title = "Todo düzenle", render = function(state) ... end,
             on_close = function() ... end, size = "md" })
modal.close(id)

-- Onay: coroutine içinde çağrılır, kullanıcının cevabını bekler (true/false)
local ok = modal.confirm({ title = "Silinsin mi?", message = "'Fatura öde' kalıcı olarak silinecek.",
                           confirm_label = "Sil", danger = true })
```

`modal.confirm` coroutine tabanlıdır: `coroutine.yield` ile askıya alınır, buton tıklanınca `coroutine.resume`
(F13 fetch.lua ile aynı kalıp). Böylece view kodu düz okunur:

```lua
app.spawn(function()
  if not modal.confirm{ title = "Silinsin mi?", danger = true } then return end
  -- ... optimistic silme
end)
```

**DOM ve ARIA:**

```html
<div class="modal-backdrop" data-modal-backdrop>
  <div role="dialog" aria-modal="true" aria-labelledby="m-title" aria-describedby="m-desc" tabindex="-1">
    <h2 id="m-title">Silinsin mi?</h2>
    <p id="m-desc">'Fatura öde' kalıcı olarak silinecek.</p>
    <button>İptal</button> <button class="danger">Sil</button>
  </div>
</div>
```

Tercih: native `<dialog>` + `showModal()` (focus trap, `Esc`, `inert` arka plan tarayıcıdan gelir). Bu sayede
focus trap kodunun çoğu yazılmaz. glue.js bridge: `js.dom.showModal(h)`, `js.dom.closeModal(h)`.
Yalnızca eksik kalanlar Lua'da:

| Davranış | Kaynak |
|---|---|
| Focus trap, `Esc` ile kapanma, arka planın inert olması | Native `<dialog>.showModal()` |
| Açılınca ilk focus | `autofocus` attribute: confirm'de **İptal** (yıkıcı işlemlerde güvenli default), formda ilk input |
| Kapanınca focus'u tetikleyen öğeye geri ver | Lua: açılışta `js.dom.activeElement()` sakla, kapanışta `js.dom.focus(h)` |
| Backdrop tıklaması ile kapanma | Lua: `click` target `dialog` elemanının kendisiyse kapat (form modallarında devre dışı — veri kaybı) |
| Kaydedilmemiş değişiklik uyarısı | Form modallarında `dirty` ise `Esc` → iç içe confirm |
| Arka plan kaydırma kilidi | CSS: `body:has(dialog[open]) { overflow: hidden }` |

Aynı anda tek modal + en fazla bir iç içe confirm. Store: `state.modal = { stack = { ... } }`,
action'lar `MODAL_OPENED`, `MODAL_CLOSED`.

### 3. `web/src/components/theme_toggle.lua`

**Public API:** `theme_toggle.render(state)`, `theme_toggle.init()` (main.lua'da ilk render'dan önce).

**Mantık:**

```lua
-- Tema tercihi: "light" | "dark" | "system"; storage anahtarı "theme"
local function effective(pref)
  if pref == "system" then return js.media.matches("(prefers-color-scheme: dark)") and "dark" or "light" end
  return pref
end

function _M.init()
  local pref = storage.get("theme") or "system"
  app.dispatch{ type = "THEME_SET", pref = pref }
  js.dom.setRootAttr("data-theme", effective(pref))
  -- Sistem teması değişirse ve tercih "system" ise anında uygula
  js.media.onChange("(prefers-color-scheme: dark)", function()
    if app.state().theme.pref == "system" then
      js.dom.setRootAttr("data-theme", effective("system"))
    end
  end)
end
```

**FOUC önlemi:** WASM yüklenmeden önce yanlış tema flaşı olmaması için `index.html` `<head>` içinde 3 satırlık
inline script `localStorage.theme` okuyup `data-theme`'yı set eder (F12 CSP'sinde bu script'in hash'i eklenir).

**UI:** `role="radiogroup" aria-label="Tema"` içinde 3 `role="radio"` buton (☀ Açık, ☾ Koyu, 🖥 Sistem),
`aria-checked`. Header'da kompakt sürüm: tek buton, döngüsel geçiş, `aria-label="Tema: Koyu. Değiştir"`.

**CSS token'ları (`styles.css`):**

```css
:root, [data-theme="light"] {
  --bg: #ffffff; --surface: #f6f7f9; --text: #111827; --text-muted: #4b5563;
  --primary: #2563eb; --danger: #dc2626; --success: #16a34a; --warning: #b45309;
  --border: #e5e7eb; --focus: #2563eb; --skeleton: #e5e7eb;
}
[data-theme="dark"] {
  --bg: #0b0f17; --surface: #151b26; --text: #e5e7eb; --text-muted: #9ca3af;
  --primary: #60a5fa; --danger: #f87171; --success: #4ade80; --warning: #fbbf24;
  --border: #273043; --focus: #93c5fd; --skeleton: #1f2937;
}
body { background: var(--bg); color: var(--text); color-scheme: light dark; }
```

Tailwind ile uyum: `tailwind.config = { darkMode: ['selector', '[data-theme="dark"]'] }` (CDN config script'i).
Tüm renk çiftleri WCAG AA kontrastı (≥ 4.5:1 metin, ≥ 3:1 UI) — doğrulama adımında ölçülür.

### 4. `web/src/components/skeleton.lua`

**Public API:**

```lua
skeleton.lines(n)          -- metin satırları (son satır %60 genişlik)
skeleton.cards(n)          -- dashboard stat kartları
skeleton.rows(n, cols)     -- tablo satırları (users, audit)
skeleton.todo_items(n)     -- todo listesi satırları
```

**DOM/ARIA:** kapsayıcı `aria-busy="true"` + görünmez `<span class="sr-only">Yükleniyor…</span>`;
iskelet öğeleri `aria-hidden="true"`. Veri gelince aynı kapsayıcı `aria-busy="false"` olur.

**Kurallar:**
- İskelet yalnızca istek **200 ms'den uzun** sürerse gösterilir (kısa yüklemelerde titreme yok):
  `enter`'da `js.timer.after(200, show_skeleton)`; veri önce gelirse iptal.
- Shimmer animasyonu CSS `@keyframes`; `prefers-reduced-motion`'da statik.
- İskelet boyutları gerçek içerikle aynı (layout shift yok — CLS < 0.1).

### 5. Empty State (bileşen dosyası yok)

Prompt'taki bileşen listesinde yok; tek bir fonksiyon olarak `components/skeleton.lua` yanında değil,
`views/layout.lua` içinde `layout.empty_state{ icon, title, text, action }` yardımcısı olarak yazılır
(3 view kullanır: todos, users, audit_logs). İkonlar inline SVG, `aria-hidden="true"`.

### 6. `web/src/shortcuts.lua` — Klavye Kısayolları

**API:**

```lua
shortcuts.register(scope, key, fn, description)   -- scope: view adı; "global" her yerde
shortcuts.unregister_scope(scope)                 -- view.leave içinde
shortcuts.list()                                  -- yardım modalı için
```

glue.js tek bir `keydown` dinleyicisini `document`'a bağlar ve Lua'ya `(key, ctrl, meta, alt, target_tag, is_editable)` iletir.

**Kurallar:**
- Hedef `input`, `textarea`, `select` veya `contenteditable` ise tek harfli kısayollar **tetiklenmez**
  (yalnızca `Esc` çalışır). WCAG 2.1.4 (Character Key Shortcuts): profilde "Tek tuş kısayollarını kapat" seçeneği.
- `Ctrl/Meta/Alt` ile basılan tuşlar yok sayılır (tarayıcı kısayollarıyla çakışmasın).
- Modal açıkken yalnızca `Esc` ve modal'ın kendi tuşları.

**Kısayol tablosu:**

| Tuş | Kapsam | Eylem |
|---|---|---|
| `n` | todos, users | Yeni kayıt modalı |
| `e` | todos | Focus'taki todo'yu düzenle |
| `d` | todos | Focus'taki todo'yu sil (onaylı) |
| `/` | todos, users, audit | Arama kutusuna focus (`preventDefault`) |
| `Esc` | global | Modal kapat → yoksa arama temizle → yoksa focus'u kaldır |
| `?` | global | Kısayol yardım modalı |
| `g` sonra `t` / `d` | global | Todo'lara / Panoya git (1 sn içinde ikinci tuş) — opsiyonel, zaman kalırsa |

Kısayolu olan butonlarda `aria-keyshortcuts` attribute'u ve tooltip'te tuş gösterimi (`<kbd>`).

### 7. Confetti

- `canvas-confetti` npm paketinden (F12 `package.json`), glue.js `js.confetti()` bridge'i.
- Tetik: `TODO_UPDATE_CONFIRMED` sonrası status `completed`'e geçmişse (optimistic anda değil — geri alınırsa yanıltıcı olur).
- Bir listedeki **tüm** todo'lar tamamlandıysa daha büyük patlama (`particleCount: 200`).
- `prefers-reduced-motion: reduce` → confetti hiç çalışmaz (`disableForReducedMotion: true` seçeneği).
- Canvas `aria-hidden="true"`, `pointer-events: none`.

### 8. Responsive

Kırılımlar (Tailwind default'larıyla aynı): `sm 640px`, `md 768px`, `lg 1024px`.

| Bileşen | < 640px | ≥ 1024px |
|---|---|---|
| Navigasyon | Üstte hamburger → `<nav>` çekmece (`aria-expanded`, `aria-controls`) | Sol sabit sidebar |
| Todo listesi | Tek sütun kart; işlem butonları `…` menüsünde | Satır + inline butonlar |
| Tablolar (users, audit) | Kart listesi (`display:block`, her `td` önünde `data-label` ile başlık) | Tablo |
| Modal | Tam ekran (`100dvh`) | Ortada, max 560px |
| Stat grid | 2 sütun | 5 sütun |
| Dokunma hedefi | min 44×44 px | — |

`<meta name="viewport" content="width=device-width, initial-scale=1">` (F12'de var). Yatay kaydırma yasak:
`html { overflow-x: clip }` değil, kök neden aranır (uzun e-postalar için `overflow-wrap: anywhere`).

### 9. Erişilebilirlik Kontrol Listesi (tüm uygulama)

- [ ] Her sayfada tek `<h1>`, başlık hiyerarşisi atlamasız.
- [ ] Landmark'lar: `<header>`, `<nav>`, `<main id="main">`, `<footer>`.
- [ ] "İçeriğe atla" linki (`<a class="skip-link" href="#main">`), ilk Tab'da görünür.
- [ ] Route değişiminde focus `<h1>`'e (`tabindex="-1"`) taşınır ve `document.title` güncellenir; ayrıca
      `aria-live="polite"` bölgesinde "Todo'lar sayfası yüklendi" duyurusu (SPA navigasyon duyurusu).
- [ ] Görünür focus halkası: `:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px }`.
- [ ] Sadece renkle bilgi verilmez (öncelik rozetlerinde metin, gecikmiş todo'da "Gecikti" metni).
- [ ] İkon-only butonlarda `aria-label`.
- [ ] Form hataları `aria-invalid="true"` + `aria-describedby`.
- [ ] `lang="tr"` (`index.html`).
- [ ] Yakınlaştırma %200'de içerik kaybı yok.

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Native `<dialog>` | Focus trap / Esc / inert tarayıcıdan; elle yazılan focus trap hatalara açık |
| Confirm coroutine ile | View kodu senkron okunur; F13 fetch kalıbıyla aynı mekanizma |
| Tema `data-theme` + CSS değişkenleri | Tek attribute değişimi tüm UI'ı çevirir; Tailwind `darkMode: selector` uyumlu |
| Inline tema script'i `<head>`'de | WASM yüklenmeden tema flaşını önlemenin tek yolu |
| Skeleton 200 ms gecikmeli | Hızlı yanıtlarda titreme olmaz |
| Confetti onay sonrası | Rollback olursa kutlama yanlış olurdu |
| Empty state ayrı bileşen değil | 3 kullanım, ~20 satır; layout yardımcısı yeterli |

## Kabul kriterleri (DoD)

- [ ] 4 bileşen dosyası prompt'taki yollarda; F14/F15'teki geçici sürümler kaldırıldı.
- [ ] Toast: hata toast'ı ekran okuyucuda hemen okunuyor; başarı toast'ı sırayla okunuyor; hover'da kapanmıyor.
- [ ] Modal: açılınca focus içeride, Tab dışarı çıkmıyor, Esc kapatıyor, kapanınca focus tetikleyen butona dönüyor.
- [ ] Silme onayında default focus "İptal".
- [ ] Tema: seçim yenilemede korunuyor; "Sistem" seçiliyken OS teması değişince anında değişiyor; yüklemede tema flaşı yok.
- [ ] Skeleton: yavaş ağda (DevTools "Slow 3G") görünüyor, hızlı ağda görünmüyor; CLS < 0.1.
- [ ] Kısayollar: `n`, `e`, `d`, `/`, `Esc`, `?` çalışıyor; input içinde tek harfliler tetiklenmiyor.
- [ ] Confetti todo tamamlanınca çıkıyor; `prefers-reduced-motion` açıkken çıkmıyor.
- [ ] 360px, 768px, 1280px genişliklerde yatay kaydırma yok; tüm işlemler yapılabiliyor.
- [ ] Lighthouse Accessibility ≥ 95 (login, todos, users sayfaları), axe-core 0 "serious/critical".
- [ ] Yalnızca klavye ile: giriş → todo ekle → tamamla → sil → çıkış akışı tamamlanabiliyor.
- [ ] Açık ve koyu temada tüm metin/arka plan çiftleri AA kontrastında.

## Doğrulama

```bash
make web.build && make up
# Lighthouse (headless Chrome)
npx lighthouse http://localhost:28000/#/login --only-categories=accessibility,performance --view
# axe (F17 Playwright içinde de koşar)
npx @axe-core/cli http://localhost:28000/#/login
```

Manuel:
1. DevTools → Rendering → "Emulate prefers-color-scheme: dark" ve "prefers-reduced-motion: reduce" ile dene.
2. Device toolbar: iPhone SE (375), iPad (768), 1280.
3. Orca (Linux) / NVDA (Windows) ile: login formu, toast duyurusu, modal başlığı okunuyor mu.
4. Fare kullanmadan tam akış (Tab / Shift+Tab / Enter / Space / Esc / kısayollar).

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Wasmoon'da JS callback → Lua coroutine resume hataları (confirm) | F13 fetch ile aynı resume yardımcısı; hata olursa toast + log |
| `<dialog>` eski tarayıcılar | Hedef: evergreen tarayıcılar (Safari 15.4+); README'de belirtilir |
| Tailwind CDN + custom `data-theme` çakışması | `darkMode: ['selector', ...]` config; F18'de derlenmiş CSS ile aynı config |
| Tek harf kısayolların ekran okuyucu tarama moduyla çakışması | Profilde kapatma seçeneği (WCAG 2.1.4) |
| Çok toast'ta ekran okuyucu gürültüsü | Maks 5 + tekrar birleştirme |

## Tahmini Efor

**M** — ~2 gün (bileşenler ~1 gün, responsive + a11y denetim/düzeltme ~1 gün).
