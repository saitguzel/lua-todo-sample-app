# ═══ FAZ 14 — FRONTEND VIEWS (AUTH + TODOS) ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) (error kodları §5, page key'ler §7, yanıt zarfı §15).
> Store, reducer, router ve `dom.lua` API'si [faz-13-frontend-core.md](faz-13-frontend-core.md)'te tanımlanır.
> **Kanonik action listesi faz-13 §4.4'tedir.** Bu dokümandaki action adları o listeyle birebir aynıdır; yeni action gerekirse önce faz-13'e eklenir.

---

## Amaç

Kullanıcının uygulamaya giriş yapıp kendi todo'larını yönetebildiği tüm "son kullanıcı" ekranlarını üretmek:
login, şifremi unuttum, şifre sıfırlama, dashboard (istatistik kartları), todo listesi (CRUD + filtre + optimistic UI)
ve profil. Faz sonunda bir `todouser` tarayıcıdan giriş yapar, todo ekler/düzenler/tamamlar/siler, sayfayı
yenilediğinde oturumu korunur ve çıkış yapabilir.

## Önkoşullar

| Faz | Neden |
|---|---|
| F5 | `/auth/*` endpoint'leri çalışır olmalı |
| F6 | `/todos*` ve `/todos/stats` çalışır olmalı |
| F12 | `glue.js`, `index.html`, Wasmoon yükleyici |
| F13 | `dom.lua`, `fetch.lua`, `storage.lua`, `app.lua` (store), `router.lua`, `views/layout.lua` |
| F1 | `shared/src/validation.lua` + `types.lua` (form doğrulaması frontend'de de aynı şema ile) |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `web/src/views/login.lua` | E-posta + parola formu, `POST /auth/login`, token saklama, yönlendirme |
| `web/src/views/forgot_password.lua` | E-posta formu, `POST /auth/forgot-password`, her durumda aynı başarı mesajı |
| `web/src/views/reset_password.lua` | URL'deki token + yeni parola formu, `POST /auth/reset-password` |
| `web/src/views/dashboard.lua` | `GET /todos/stats` → istatistik kartları, son todo'lar |
| `web/src/views/todos.lua` | Liste, filtre, arama, sayfalama, oluştur/düzenle/sil/tamamla (optimistic) |
| `web/src/views/profile.lua` | `GET /auth/me` bilgileri, çıkış butonu, tema tercihi |
| `web/src/forms.lua` *(yalnızca gerekirse)* | Ortak form yardımcıları — 3+ view aynı kodu tekrar ederse çıkarılır, önce inline yazılır |

> `forms.lua` spekülatif; iki view'da tekrar olursa inline kalır. Üçüncüde çıkarılır (YAGNI).

---

## View Sözleşmesi (tüm view'lar için ortak)

Her view modülü faz-13'teki router'ın beklediği arayüzü uygular:

```lua
-- views/<ad>.lua — <ad> ekranı
local _M = {}

-- Router bu tabloyu okur: sayfanın auth/RBAC ihtiyacı
_M.meta = {
  title    = "Todo'lar",       -- document.title
  public   = false,            -- true ise auth gerekmez
  page_key = "todos.list",     -- RBAC guard (00 §7); public view'larda nil
}

-- Route'a girildiğinde bir kez çağrılır (coroutine içinde; fetch yield edebilir)
function _M.enter(store, params) end

-- State her değiştiğinde çağrılır; saf: state → vnode ağacı
function _M.render(state, dispatch) end

-- Route'tan çıkılırken (listener/timer temizliği)
function _M.leave(store) end

return _M
```

Kurallar:
- `render` **yan etkisizdir**: fetch yapmaz, storage'a yazmaz; yalnızca `dom.h(...)` ağacı döner.
- Yan etkiler (`fetch`) `enter` içinde veya event handler'da, `app.spawn(fn)` (faz-13: coroutine başlatıcı) ile yapılır.
- Form alan state'i store'da tutulmaz (her tuşta global render olmasın); DOM `input` değeri submit anında okunur.
  Sadece doğrulama hataları ve "gönderiliyor" durumu store'a girer.

---

## Dosya Bazlı Tasarım

### 1. `web/src/views/login.lua`

**Meta:** `public = true`, `title = "Giriş"`. Oturum varsa `enter` içinde `#/dashboard`'a yönlendirir.

**UI yapısı:**

```
<main class="auth-page">
  <form aria-labelledby="login-title" novalidate>
    <h1 id="login-title">Giriş yap</h1>
    <div role="alert" aria-live="assertive">  ← genel hata (INVALID_CREDENTIALS, RATE_LIMITED)
    <label for="email">E-posta</label>
    <input id="email" type="email" autocomplete="username" required aria-describedby="email-err">
    <p id="email-err" class="field-error">
    <label for="password">Parola</label>
    <input id="password" type="password" autocomplete="current-password" required minlength="8">
    <button type="button" aria-pressed="false" aria-label="Parolayı göster">
    <button type="submit" aria-busy="false">Giriş yap</button>
    <a href="#/forgot-password">Şifremi unuttum</a>
  </form>
</main>
```

**Akış:**

```
submit
 ├─ validation.validate(schemas.login, {email, password})   -- shared şema (F1)
 │    └─ hata → dispatch{ type="FORM_ERRORS_SET", form="login", errors=... } → ilk hatalı alana focus
 ├─ dispatch{ type="LOGIN_REQUESTED" }                      -- buton disabled + aria-busy
 ├─ res, err = fetch.post("/auth/login", body)               -- coroutine yield
 ├─ err.code == "INVALID_CREDENTIALS" → "E-posta veya parola hatalı" (ayrım YOK)
 ├─ err.code == "RATE_LIMITED"        → "Çok fazla deneme. N sn sonra tekrar deneyin" (Retry-After)
 ├─ err.code == "ACCOUNT_DISABLED"    → "Hesabınız pasif. Yöneticiye başvurun"
 └─ başarı:
      storage.set_tokens(access, refresh)
      dispatch{ type="LOGIN_SUCCEEDED", user=res.data.user, permissions=res.data.permissions }
      router.navigate(state.auth.redirect_to or "#/dashboard")
```

**Kararlar:**
- Parola alanı başarısız login'de temizlenir, e-posta korunur.
- `redirect_to`: guard tarafından yakalanan hedef URL (faz-13 router); yalnızca `#/` ile başlıyorsa kabul (open redirect önleme).
- Login yanıtının `permissions` alanı (kullanıcının rolü için `{page_key=bool}`) yoksa `GET /rbac/matrix` çağrılmaz —
  todouser bu endpoint'e erişemez. Kanonik kaynak: F5 `/auth/login` ve `/auth/me` yanıtı `permissions` içerir.

### 2. `web/src/views/forgot_password.lua`

**Meta:** `public = true`, `title = "Şifremi unuttum"`.

**UI:** tek e-posta alanı + "Sıfırlama bağlantısı gönder" butonu + `#/login` linki.

**Akış:**
1. Shared şema ile e-posta doğrula.
2. `fetch.post("/auth/forgot-password", { email })`.
3. Yanıt `202` (API her zaman 202 döner, 00 §5 `MAIL_FAILED` notu) → form yerine sabit mesaj:
   *"Bu e-posta sistemde kayıtlıysa birkaç dakika içinde sıfırlama bağlantısı gönderilecek."*
4. `RATE_LIMITED` → uyarı toast'ı. Diğer hatalar → genel hata metni (kullanıcı-numaralandırmaya izin verme).

Başarı mesajı `role="status"` bölgesinde gösterilir; focus mesaja taşınır (`tabindex="-1"` + `focus()`).

### 3. `web/src/views/reset_password.lua`

**Meta:** `public = true`, route: `#/reset-password?token=<hex>`.

**Akış:**
1. `enter`: `params.query.token` yoksa veya 64 hex karakter değilse → "Bağlantı geçersiz" ekranı + "Yeni bağlantı iste" linki.
2. Form: `new_password`, `new_password_confirm`. Frontend kontrolü: shared `schemas.password` (min 8, harf + rakam),
   iki alan eşit mi (yalnızca UI kuralı).
3. `fetch.post("/auth/reset-password", { token, new_password })`.
4. `204` → toast "Parolanız güncellendi" + `#/login`.
5. `RESET_TOKEN_INVALID` → "Bağlantının süresi dolmuş veya kullanılmış" + forgot linki.
6. `VALIDATION_FAILED` → alan hataları `details`'ten eşlenir.

**Güvenlik:** token URL'den okunduktan hemen sonra `history.replaceState` ile adres çubuğundan silinir
(glue.js'teki `js.location.replace("#/reset-password")` bridge'i — F12). Token storage'a yazılmaz.

Parola güç göstergesi: basit uzunluk/karakter-sınıfı sayacı (`aria-live="polite"`); zxcvbn gibi kütüphane eklenmez.

### 4. `web/src/views/dashboard.lua`

**Meta:** `page_key = "dashboard"`, `title = "Pano"`.

**Veri:** `GET /todos/stats` (F6). Beklenen şekil:

```json
{ "data": {
  "total": 42,
  "by_status":   { "pending": 10, "in_progress": 7, "completed": 25 },
  "by_priority": { "low": 12, "medium": 20, "high": 10 },
  "overdue": 3,
  "completed_last_7_days": 9
}}
```

**UI:**

```
<section aria-labelledby="dash-title">
  <h1 id="dash-title">Pano</h1>
  <ul class="stat-grid" role="list">
    <li class="stat-card"> Toplam | Bekleyen | Devam eden | Tamamlanan | Geciken (kırmızı) </li>
  </ul>
  <div class="progress" role="progressbar" aria-valuenow="60" aria-valuemin="0" aria-valuemax="100"
       aria-label="Tamamlanma oranı">
  <section aria-labelledby="recent-title"> Son 5 todo (GET /todos?per_page=5&sort=-updated_at) </section>
  <!-- F15: admin kartları slot'u: if state.auth.user.role == "admin" then admin_cards(state) end -->
</section>
```

**Akış:** `enter` iki isteği `app.spawn` ile başlatır (sıralı; Wasmoon'da gerçek paralellik yok, iki coroutine
iki Promise'i eşzamanlı bekler). Yüklenirken `skeleton.cards(5)` (F16) gösterilir.

**Action'lar:** `STATS_REQUESTED`, `STATS_LOADED`, `STATS_FAILED`, `RECENT_TODOS_LOADED`.

Grafik kütüphanesi yok: öncelik dağılımı CSS `width:%` barları ile.

### 5. `web/src/views/todos.lua` (fazın en büyük parçası)

**Meta:** `page_key = "todos.list"`, `title = "Todo'lar"`.
Oluştur butonu `can("todos.create")`, düzenle/sil `can("todos.edit")` ile görünür (faz-13 `app.can(page_key)`).

#### 5.1 State dilimi

```lua
state.todos = {
  items    = {},          -- dizi; sıralama sunucudan gelir
  by_id    = {},          -- id → index (hızlı optimistic güncelleme)
  meta     = { page = 1, per_page = 20, total = 0, total_pages = 0 },
  filters  = { status = nil, priority = nil, q = "", tag = nil, sort = "-created_at" },
  loading  = false,
  error    = nil,
  pending  = {},          -- temp_id/id → { op = "create"|"update"|"delete", snapshot = {...} }
  editing  = nil,         -- modal'da düzenlenen todo id'si veya "new"
}
```

#### 5.2 Filtre ve URL senkronu

Filtreler hash query'sinde tutulur: `#/todos?status=pending&priority=high&q=fatura&page=2`.
- Filtre değişince `router.replace_query(filters)` → router `enter`'ı tekrar tetiklemez, view `TODO_FILTERS_CHANGED` + reload yapar.
- Arama kutusu 300 ms debounce (`js.timer.after` bridge); Enter anında arar.
- Geri/ileri tuşu filtreleri geri getirir (URL tek doğruluk kaynağı).

İstek: `GET /todos?page=&per_page=&status=&priority=&q=&tag=&sort=` (F6'daki whitelist ile aynı alanlar).

#### 5.3 UI yapısı

```
<section aria-labelledby="todos-title">
  <header>
    <h1 id="todos-title">Todo'lar <span class="count">(42)</span></h1>
    <button data-shortcut="n" aria-keyshortcuts="n">+ Yeni todo</button>
  </header>
  <form role="search" aria-label="Todo filtreleri">
    <input type="search" id="todo-search" aria-keyshortcuts="/" placeholder="Ara… (/)">
    <select aria-label="Durum">  Tümü | Bekliyor | Devam ediyor | Tamamlandı
    <select aria-label="Öncelik"> Tümü | Düşük | Orta | Yüksek
    <select aria-label="Sıralama"> En yeni | Son tarih | Öncelik
  </form>
  <ul role="list" aria-busy="false" aria-live="polite">
    <li class="todo-item" data-id="..." tabindex="0" aria-selected="false">
      <input type="checkbox" aria-label="'Fatura öde' tamamlandı olarak işaretle">
      <div> başlık, açıklama (ilk 120 karakter), etiketler (chip), son tarih (gecikmişse kırmızı + "Gecikti") </div>
      <span class="badge priority-high">Yüksek</span>
      <button aria-label="'Fatura öde' düzenle">  <button aria-label="'Fatura öde' sil">
    </li>
  </ul>
  <nav aria-label="Sayfalama"> ‹ Önceki | Sayfa 2 / 7 | Sonraki › </nav>
</section>
```

Boş durumlar (F16 empty state bileşeni):
- Hiç todo yok → illüstrasyon + "İlk todo'nu ekle" butonu.
- Filtre sonucu boş → "Bu filtrelerle eşleşen todo yok" + "Filtreleri temizle".

#### 5.4 Oluştur / Düzenle formu (modal — F16 `components/modal.lua`)

| Alan | Kontrol | Kural (shared `schemas.todo_create` / `todo_update`) |
|---|---|---|
| `title` | text | zorunlu, 1–255 |
| `description` | textarea | opsiyonel, ≤ 10 000 |
| `status` | select | `types.TODO_STATUS` |
| `priority` | select | `types.TODO_PRIORITY`, default `medium` |
| `due_date` | `<input type="datetime-local">` | opsiyonel; ISO 8601'e çevrilir (yerel saat → UTC `Z`) |
| `tags` | text (virgülle ayrılmış) | opsiyonel, her etiket 1–32, en fazla 10 |

Native `datetime-local` kullanılır; tarih seçici kütüphanesi yok.

#### 5.5 Optimistic UI akışları

**Oluşturma:**

```
submit → validate (shared)
      → temp_id = "tmp-" .. counter
      → dispatch{ type="TODO_OPTIMISTIC_CREATE", todo={ id=temp_id, ...input, _pending=true } }   -- listenin başına
      → modal kapanır, satır yarı saydam + spinner
      → res, err = fetch.post("/todos", input)
         ├─ ok  → dispatch{ type="TODO_CREATE_CONFIRMED", temp_id=temp_id, todo=res.data }            -- temp id gerçek id ile değişir
         │        toast("Todo eklendi")
         └─ err → dispatch{ type="TODO_ROLLBACK", id=temp_id }                                  -- satır kaldırılır
                  VALIDATION_FAILED ise modal eski değerlerle tekrar açılır + alan hataları
                  diğer → toast.error(protocol.message(err.code))
```

**Güncelleme / tamamlama (checkbox):**

```
dispatch{ type="TODO_OPTIMISTIC_UPDATE", id=id, patch={ status="completed" } }   -- reducer snapshot'ı pending[id]'ye koyar
fetch.patch("/todos/"..id, patch)
 ├─ ok  → dispatch{ type="TODO_UPDATE_CONFIRMED", todo=res.data }   -- sunucu değeri (completed_at dahil) yazılır
 │        status "completed"'e geçtiyse → confetti.fire() (F16)
 └─ err → dispatch{ type="TODO_ROLLBACK", id=id }             -- snapshot geri yüklenir + toast.error
         TODO_NOT_FOUND → satırı kaldır + "Bu todo artık mevcut değil"
```

Tam form düzenlemesi `PUT /todos/:id`, tekil alan değişimi (checkbox, öncelik hızlı değişimi) `PATCH` kullanır.

**Silme:**

```
modal.confirm("'<başlık>' silinsin mi?")   -- F16; butonlar: İptal (default focus) | Sil (kırmızı)
dispatch{ type="TODO_OPTIMISTIC_DELETE", id=id }
fetch.delete("/todos/"..id)
 ├─ 204 → dispatch{ type="TODO_DELETE_CONFIRMED", id=id }
 │        toast("Todo silindi")          -- ponytail: "Geri al" yok; eklemek için soft-delete gerekir
 └─ err → dispatch{ type="TODO_ROLLBACK", id=id }   -- satır eski indeksine döner
```

**Çakışma kuralı:** Aynı id için `pending[id]` doluyken ikinci bir mutasyon başlatılırsa buton disabled'dır
(sıra/yarış durumu yok). Sayfa değiştirildiğinde bekleyen işlemler iptal edilmez; yanıt gelince `by_id` yoksa sessizce yok sayılır.

#### 5.6 Klavye (F16'da global kayıt; bu view kısayolları register eder)

| Tuş | Eylem |
|---|---|
| `n` | Yeni todo modalı (izin varsa) |
| `e` | Seçili (focus'taki) todo'yu düzenle |
| `d` | Seçili todo'yu sil (onaylı) |
| `/` | Arama kutusuna focus |
| `Esc` | Modal kapat / aramayı temizle |
| `↑` / `↓` | Liste satırları arasında focus (roving tabindex) |
| `Space` | Seçili todo'nun tamamlanma durumunu değiştir |

#### 5.7 Action listesi (bu view'ın kullandıkları)

`TODOS_REQUESTED`, `TODOS_LOADED`, `TODOS_FAILED`, `TODO_FILTERS_CHANGED`, `TODO_EDIT_OPENED`, `TODO_EDIT_CLOSED`,
`TODO_OPTIMISTIC_CREATE`, `TODO_OPTIMISTIC_UPDATE`, `TODO_OPTIMISTIC_DELETE`, `TODO_CREATE_CONFIRMED`, `TODO_UPDATE_CONFIRMED`, `TODO_DELETE_CONFIRMED`, `TODO_ROLLBACK`,
`FORM_ERRORS_SET`, `TOAST_PUSHED`.

Reducer örneği (faz-13 reducer'ına eklenecek dal):

```lua
-- Optimistic güncellemeyi uygula; geri alma için anlık görüntüyü sakla
handlers.TODO_OPTIMISTIC_UPDATE = function(s, a)
  local idx = s.todos.by_id[a.id]
  if not idx then return s end
  local old = s.todos.items[idx]
  s.todos.pending[a.id] = { op = "update", snapshot = old }
  local new = shallow_copy(old)
  for k, v in pairs(a.patch) do new[k] = v end
  new._pending = true
  s.todos.items[idx] = new
  return s
end

-- Sunucu reddetti: anlık görüntüyü geri yükle
handlers.TODO_ROLLBACK = function(s, a)
  local p = s.todos.pending[a.id]
  if not p then return s end
  s.todos.pending[a.id] = nil
  if p.op == "create" then remove_item(s.todos, a.id)
  elseif p.op == "delete" then insert_at(s.todos, p.index, p.snapshot)
  else s.todos.items[s.todos.by_id[a.id]] = p.snapshot end
  return s
end
```

### 6. `web/src/views/profile.lua`

**Meta:** `page_key = nil` (auth yeterli), `title = "Profil"`.

**İçerik:**
- `GET /auth/me` → ad, e-posta, rol (badge), son giriş (`last_login_at`, `Intl` ile yerel biçim — glue.js `js.format_date`).
- Tema seçimi: Açık / Koyu / Sistem (F16 `theme_toggle` bileşeni burada da kullanılır).
- Klavye kısayolları tablosu (yardım; `?` tuşu da bu listeyi modalda açar — F16).
- "Çıkış yap" → `POST /auth/logout` (body: `{ refresh_token }`) → yanıt ne olursa olsun `storage.clear_tokens()` +
  `dispatch{ type="LOGGED_OUT" }` + `#/login`.

Parola değiştirme endpoint'i API'de yok (00 endpoint listesi) → bu fazda eklenmez; kullanıcı forgot akışını kullanır.
Gerekirse ayrı bir `POST /auth/change-password` fazı açılır.

---

## Hata Mesajı Eşlemesi

Kullanıcıya gösterilen metinler `shared/src/protocol.lua`'daki `DEFAULT_MESSAGES[code]` tablosundan `protocol.message(code)` ile gelir (F1).
View'lar yalnızca bağlama özel override yapar (ör. login'de `INVALID_CREDENTIALS`). `TOKEN_EXPIRED` view'a
ulaşmaz: `fetch.lua` (F13) otomatik refresh yapar; refresh de başarısızsa `LOGGED_OUT` + `#/login?expired=1`
ve login ekranı "Oturumunuzun süresi doldu" bilgisi gösterir.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Form değerleri store'da değil DOM'da | Her tuşta global render + diff maliyeti yok; basit |
| Aynı shared validation şeması hem frontend hem backend | Tek kural kaynağı; frontend hatası = backend hatası |
| Optimistic UI + snapshot rollback | Prompt gereği; ağ gecikmesini gizler. Snapshot pending tablosunda, reducer saf kalır |
| Filtre URL'de | Paylaşılabilir link, geri tuşu doğal çalışır |
| Native `datetime-local`, `type="search"`, `required` | Kütüphane yok; erişilebilirlik tarayıcıdan gelir |
| "Geri al" (undo) yok | API'de soft-delete yok; eklemek için şema değişikliği gerekir |
| Hata metinleri tek tabloda | Çeviri/tutarlılık tek yerde |

## Kabul kriterleri (DoD)

- [ ] `admin@todoapp.local / Admin123!` ve `user@todoapp.local / User123!` ile giriş yapılabiliyor.
- [ ] Hatalı parola "E-posta veya parola hatalı" gösteriyor; e-postanın varlığını ifşa etmiyor.
- [ ] 6. hatalı denemede `RATE_LIMITED` mesajı ve bekleme süresi görünüyor.
- [ ] Sayfa yenilenince oturum korunuyor (storage'daki token ile `/auth/me`).
- [ ] Forgot-password kayıtlı ve kayıtsız e-posta için **aynı** mesajı gösteriyor.
- [ ] Reset linki (MailHog'dan) açılınca token URL'den siliniyor, yeni parola ile giriş yapılabiliyor; ikinci kullanımda `RESET_TOKEN_INVALID`.
- [ ] Dashboard istatistikleri `/todos/stats` ile birebir aynı; yüklenirken skeleton görünüyor.
- [ ] Todo ekle/düzenle/tamamla/sil optimistic çalışıyor; API'yi durdurunca (docker stop api) işlem geri alınıyor ve toast çıkıyor.
- [ ] Todo tamamlanınca confetti tetikleniyor (F16 sonrası).
- [ ] Filtreler URL'ye yansıyor; geri tuşu önceki filtreye dönüyor.
- [ ] `todouser` başka kullanıcının todo id'sini URL'den açarsa "bulunamadı" görüyor.
- [ ] Tüm form alanlarının `<label>`'ı var; hatalar `aria-describedby` ile bağlı; ilk hatalı alana focus gidiyor.
- [ ] `n`, `e`, `d`, `/`, `Esc` kısayolları todos sayfasında çalışıyor; input içindeyken tetiklenmiyor.
- [ ] Profilden çıkış yapınca refresh token denylist'e giriyor (tekrar kullanılamıyor).

## Doğrulama

```bash
make up                      # postgres + api + web + mailhog
make db.migrate db.seed      # SEED_DEFAULTS=true
make web.build && open http://localhost:28000
```

Manuel senaryo (E2E'si F17'de Playwright'a dönüşür):
1. `#/login` → `user@todoapp.local` / `User123!` → `#/dashboard`.
2. `#/todos` → `n` → başlık "Deneme" → Kaydet → listede anında görünür (yarı saydam) → onaylanır.
3. Checkbox → tamamlandı → confetti → DevTools Network'te `PATCH /api/v1/todos/<id>` 200.
4. `docker compose stop api` → başka todo'yu sil → satır kaybolur, ~hata sonrası geri gelir + kırmızı toast.
5. `docker compose start api` → Profil → Çıkış → `#/login`.
6. `#/forgot-password` → e-posta → http://localhost:28025 (MailHog) → link → yeni parola → giriş.

Busted birim testleri (F17): reducer `TODO_*` dalları, `redirect_to` doğrulaması, `datetime-local` → ISO dönüşümü.

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| Optimistic create'te temp id ile hemen düzenleme | `_pending` satırlarda düzenle/sil disabled |
| Saat dilimi: `datetime-local` yerel, API UTC | Dönüşüm glue.js'teki `new Date(v).toISOString()` bridge'i ile; spec ile test |
| Büyük listelerde tam re-render | Sayfalama (max 100); diff F13 `dom.patch`'te keyed (`data-id`) |
| Token'ın `localStorage`'da tutulması XSS'e açık | CSP (F12) + tüm metinler `textContent` ile (innerHTML yok). httpOnly cookie'ye geçiş F18 güvenlik listesinde not |
| Reset token referer ile sızabilir | `<meta name="referrer" content="no-referrer">` (F12 index.html) + `replaceState` |

## Tahmini Efor

**L** — ~3 gün (todos view ve optimistic akış ~1.5 gün; auth ekranları ~1 gün; dashboard + profil ~0.5 gün).
