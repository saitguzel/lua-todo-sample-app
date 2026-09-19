# ═══ FAZ 15 — FRONTEND VIEWS (ADMIN) ═══

> Kanonik kaynak: [00-genel-bakis.md](00-genel-bakis.md) — page key'ler §7, audit olayları §8, error kodları §5, yanıt zarfı §15.
> View sözleşmesi (`meta`, `enter`, `render`, `leave`) [faz-14](faz-14-frontend-views-auth-todos.md)'te tanımlıdır.
> **Kanonik action listesi faz-13 §4.4'tedir.** Bu dokümandaki action adları o listeyle birebir aynıdır; yeni action gerekirse önce faz-13'e eklenir.

---

## Amaç

Admin rolünün yönetim ekranlarını üretmek: kullanıcı yönetimi (liste + oluştur/düzenle/sil), rol–sayfa yetki matrisi
(RBAC) ve audit log görüntüleyici (filtre, detay, istatistik, CSV indirme). Ayrıca dashboard'a admin'e özel
kartlar eklenir. Faz sonunda admin tarayıcıdan bir todouser'ı pasifleştirebilir, todouser'a `users.list` iznini
açıp kapatabilir ve bu işlemleri audit log ekranında görebilir.

## Önkoşullar

| Faz | Neden |
|---|---|
| F7 | `/users*`, `/rbac/*` endpoint'leri |
| F8 | `/audit/*` endpoint'leri (logs, detail, stats, export) |
| F13 | Router guard (`page_key` kontrolü), store |
| F14 | View sözleşmesi, form/validation kalıbı, dashboard view |
| F16 (kısmen) | `modal`, `toast`, `skeleton` — F16 bitmeden basit sürümleriyle ilerlenir, F16'da cilalanır |

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `web/src/views/users.lua` | Kullanıcı tablosu, arama/filtre, oluştur/düzenle modalı, sil onayı |
| `web/src/views/rbac_matrix.lua` | Rol × sayfa checkbox grid'i, tek hücre PATCH (optimistic), toplu kaydet (PUT) |
| `web/src/views/audit_logs.lua` | Filtrelenebilir log tablosu, detay çekmecesi (old/new diff), istatistik, CSV indir |
| `web/src/views/dashboard.lua` *(güncelleme)* | Admin kartları: kullanıcı sayısı, son 24 saat audit özeti, access.denied sayısı |
| `web/src/views/layout.lua` *(güncelleme)* | Admin menü öğeleri (`can(page_key)` ile görünür) |

---

## Ortak Kurallar

- Görünürlük **iki katmanlı**: menü/buton `app.can(page_key)` ile gizlenir **ve** router guard erişimi engeller.
  Asıl yetki API'dedir (F7 authorization middleware); frontend kontrolü yalnızca UX içindir.
- API `403 FORBIDDEN` dönerse (ör. admin başka sekmede todouser'ın iznini kaldırdı ve kendi rolünü değiştirdi):
  `app.refresh_permissions()` → `/auth/me` tekrar çekilir → `PERMISSIONS_LOADED` → router guard yeniden değerlendirilir.
- Tüm tablolar: `<table>` + `<caption>` + `<th scope="col">`; sıralanabilir sütunlarda `aria-sort`.
- Mobilde (< 640px) tablolar kart listesine döner (CSS; ayrı render yok) — F16 responsive.

---

## Dosya Bazlı Tasarım

### 1. `web/src/views/users.lua`

**Meta:** `page_key = "users.list"`, `title = "Kullanıcılar"`. Oluştur/düzenle/sil: `can("users.create")`.

**API:**

| İşlem | İstek |
|---|---|
| Liste | `GET /users?page=&per_page=&q=&role=&is_active=&sort=` |
| Detay | `GET /users/:id` |
| Oluştur | `POST /users` `{ email, full_name, password, role, is_active }` |
| Güncelle | `PUT /users/:id` `{ email, full_name, role, is_active, password? }` |
| Sil | `DELETE /users/:id` |

**State dilimi:**

```lua
state.users = {
  items = {}, by_id = {}, meta = { page = 1, per_page = 20, total = 0, total_pages = 0 },
  filters = { q = "", role = nil, is_active = nil, sort = "email" },
  loading = false, error = nil,
  editing = nil,          -- nil | "new" | user_id
  saving = false,
}
```

**UI:**

```
<section aria-labelledby="users-title">
  <header> <h1 id="users-title">Kullanıcılar</h1> <button aria-keyshortcuts="n">+ Kullanıcı ekle</button> </header>
  <form role="search"> arama (e-posta/ad) | rol select | durum select (Aktif/Pasif/Tümü) </form>
  <table>
    <caption class="sr-only">Kullanıcı listesi, 12 kayıt</caption>
    <thead> E-posta ↕ | Ad | Rol | Durum | Son giriş ↕ | Oluşturulma ↕ | İşlemler </thead>
    <tbody> ... <tr data-id> ... <td><span class="badge role-admin">admin</span></td>
            <td><span class="dot active" aria-hidden="true"></span>Aktif</td>
            <td><button aria-label="user@... düzenle"> <button aria-label="user@... sil"></td>
  </table>
  <nav aria-label="Sayfalama">
</section>
```

**Form (modal):**

| Alan | Kural (shared `schemas.user_create` / `user_update`) |
|---|---|
| `email` | zorunlu, e-posta, ≤ 255 |
| `full_name` | opsiyonel, ≤ 255 |
| `password` | oluşturmada zorunlu; düzenlemede boş bırakılırsa değişmez |
| `role` | `types.ROLES` (`admin`, `todouser`) |
| `is_active` | checkbox, default true |

"Parola oluştur" butonu: tarayıcıda `crypto.getRandomValues` ile 16 karakter (glue.js `js.random_password`), alanı doldurur
ve panoya kopyalar (`navigator.clipboard`). Parola başka hiçbir yerde saklanmaz.

**İş kuralı hataları (API'den gelir, UI'da anlamlı metne çevrilir):**

| Kod | Mesaj | UI davranışı |
|---|---|---|
| `EMAIL_TAKEN` | "Bu e-posta zaten kullanılıyor" | `email` alanı altına alan hatası |
| `LAST_ADMIN` | "Sistemdeki son aktif admin silinemez veya düşürülemez" | modal açık kalır, genel hata |
| `SELF_ACTION_FORBIDDEN` | "Kendi hesabınızı silemez veya rolünüzü düşüremezsiniz" | genel hata |
| `USER_NOT_FOUND` | "Kullanıcı artık mevcut değil" | satır kaldırılır, toast |

UI ek önlemi: kendi satırında sil butonu disabled + `title="Kendi hesabınızı silemezsiniz"`; kendi rol select'i disabled.

**Optimistic?** Hayır — kullanıcı işlemleri seyrek ve iş kuralı hataları olası (LAST_ADMIN). Kaydet butonu
`aria-busy` + spinner, yanıt sonrası liste güncellenir. Todos'tan farklı olmasının nedeni budur.

**Action'lar:** `USERS_REQUESTED`, `USERS_LOADED`, `USERS_FAILED`, `USERS_FILTERS_CHANGED`, `USER_EDIT_OPENED`,
`USER_EDIT_CLOSED`, `USER_SAVE_REQUESTED`, `USER_SAVED`, `USER_SAVE_FAILED`, `USER_REMOVED`.

### 2. `web/src/views/rbac_matrix.lua`

**Meta:** `page_key = "rbac.matrix"`, `title = "Yetki Matrisi"`.

**API:**

| İşlem | İstek | Yanıt |
|---|---|---|
| Sayfa listesi | `GET /rbac/pages` | `{ data: [ { key, label, description } ] }` |
| Matris | `GET /rbac/matrix` | `{ data: { admin: { dashboard: true, ... }, todouser: { ... } } }` |
| Toplu kaydet | `PUT /rbac/matrix` | body: tam matris |
| Tek hücre | `PATCH /rbac/matrix/:role/:page_key` | body: `{ can_access: bool }` (URL param adı `page_key` — 00 §11 #8) |

**UI:**

```
<section aria-labelledby="rbac-title">
  <h1 id="rbac-title">Rol – Sayfa Yetkileri</h1>
  <p id="rbac-help">Değişiklikler anında kaydedilir. Önbellek nedeniyle diğer oturumlara 60 sn içinde yansır.</p>
  <table aria-describedby="rbac-help">
    <caption class="sr-only">Rollerin sayfa erişim izinleri</caption>
    <thead><tr><th scope="col">Sayfa</th><th scope="col">admin</th><th scope="col">todouser</th></tr></thead>
    <tbody>
      <tr><th scope="row">todos.list <small>Todo listesi</small></th>
          <td><input type="checkbox" checked aria-label="admin rolü için todos.list erişimi"></td>
          <td><input type="checkbox" checked aria-label="todouser rolü için todos.list erişimi"></td></tr>
      <tr><th scope="row">rbac.matrix</th>
          <td><input type="checkbox" checked disabled aria-describedby="lock-note">🔒</td> ...
    </tbody>
  </table>
  <p id="lock-note">Admin'in yetki matrisi erişimi kilitlidir (kendini kilitleme önlemi).</p>
  <footer> <button>Varsayılana sıfırla</button> </footer>
</section>
```

"60 sn" metni sabit değil, `RBAC_CACHE_TTL`'den gelir: `/rbac/matrix` yanıtı `meta.cache_ttl` içerir (F7'de eklenir);
yoksa metin "kısa süre içinde" der.

**Akış — tek hücre (optimistic):**

```
change(role, page_key, checked)
 → dispatch{ type="RBAC_CELL_TOGGLED", role, page_key, value=checked }   -- snapshot pending'e
 → fetch.patch("/rbac/matrix/"..role.."/"..page_key, { can_access = checked })
    ├─ ok       → dispatch{ type="RBAC_CELL_CONFIRMED", role, page_key }
    │             toast("todouser → users.list: açık", { timeout = 2000 })
    │             role == state.auth.user.role ise app.refresh_permissions()
    └─ err      → dispatch{ type="RBAC_CELL_ROLLBACK", role, page_key }
                  CONFLICT → "Bu izin kilitli"
```

Aynı hücreye art arda tıklamada: hücre `pending` iken disabled (yarış yok).

**Varsayılana sıfırla:** `modal.confirm` → `PUT /rbac/matrix` body = `types.default_matrix()` (F1 shared'da tanımlı,
seed ile aynı kaynak) → yanıtla matris yenilenir. Optimistic değil.

**Action'lar:** `RBAC_REQUESTED`, `RBAC_LOADED`, `RBAC_FAILED`, `RBAC_CELL_TOGGLED`,
`RBAC_CELL_CONFIRMED`, `RBAC_CELL_ROLLBACK`, `RBAC_MATRIX_REPLACED`, `PERMISSIONS_LOADED`.

Klavye: grid'de `Tab` ile checkbox'lar arasında gezilir, `Space` değiştirir (native checkbox). Ok tuşu grid
navigasyonu eklenmez — tablo küçük (9 × 2), native Tab yeterli.

### 3. `web/src/views/audit_logs.lua`

**Meta:** `page_key = "audit.logs"`, `title = "Denetim Kayıtları"`.

**API:**

| İşlem | İstek |
|---|---|
| Liste | `GET /audit/logs?page=&per_page=&action=&user_id=&entity_type=&entity_id=&status=&from=&to=` |
| Detay | `GET /audit/logs/:id` |
| İstatistik | `GET /audit/stats?from=&to=` → `{ total, by_action: {...}, by_status: {...}, top_users: [...] }` |
| CSV | `GET /audit/export?<aynı filtreler>` (Content-Type `text/csv`) |

**Filtreler:**

| Filtre | Kontrol | Not |
|---|---|---|
| `action` | select | Seçenekler 00 §8 kanonik listesinden (`todo_shared.types` → `AUDIT_ACTIONS`) |
| `status` | select | `success` / `failure` |
| `entity_type` | select | `user`, `todo`, `rbac`, `page` |
| `user` | e-posta arama | `users.list` izni varsa `GET /users?q=` ile öneri listesi (`<datalist>`), yoksa serbest metin `user_email` |
| `from` / `to` | `<input type="date">` | default: son 7 gün; `to` > `from` doğrulaması |

Filtreler URL query'sinde (faz-14 todos ile aynı kalıp).

**UI:**

```
<section aria-labelledby="audit-title">
  <header> <h1 id="audit-title">Denetim Kayıtları</h1>
           <button aria-describedby="export-note">CSV indir</button> </header>
  <div class="stat-grid"> Toplam | Başarısız | access.denied | En aktif kullanıcı </div>
  <form role="search"> ...filtreler... </form>
  <table>
    <thead> Zaman | Kullanıcı | Eylem | Varlık | IP | Durum </thead>
    <tbody> <tr tabindex="0" aria-haspopup="dialog"> ... (satıra tıkla / Enter → detay) </tbody>
  </table>
  <nav aria-label="Sayfalama">
</section>
<aside role="dialog" aria-modal="true" aria-labelledby="audit-detail-title"> ← detay çekmecesi (modal bileşeni, sağdan)
  <h2 id="audit-detail-title">todo.update · #10234</h2>
  <dl> Zaman, Kullanıcı, IP, User-Agent, Durum, Hata mesajı </dl>
  <h3>Değişiklikler</h3>
  <table class="diff"> Alan | Eski | Yeni </table>   ← yalnızca değişen alanlar vurgulu
  <details><summary>Ham JSON</summary><pre>...</pre></details>
</aside>
```

**Diff hesaplama** (saf Lua, `audit_logs.lua` içinde local fonksiyon — F17'de test edilir):

```lua
-- old/new JSON nesnelerinin üst seviye alanlarını karşılaştırır; iç içe tablolar JSON string olarak gösterilir
local function diff_fields(old, new)
  old, new = old or {}, new or {}
  local keys, seen = {}, {}
  for k in pairs(old) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  for k in pairs(new) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  table.sort(keys)
  local rows = {}
  for _, k in ipairs(keys) do
    local a, b = old[k], new[k]
    rows[#rows + 1] = { field = k, old = a, new = b, changed = json.encode(a) ~= json.encode(b) }
  end
  return rows
end
```

Maskeli değerler (`"***"`) API'den öyle gelir (F8); frontend tekrar maskelemez, "***" gri italik gösterilir.

**CSV indirme:** `fetch.lua` `Authorization` header eklemek zorunda olduğundan düz `<a href>` kullanılamaz.
Akış: `api.download("/audit/export?...", "audit-2026-09-18.csv")` (F13) → glue.js `js.http.download`
(`URL.createObjectURL` + geçici `<a download>`; faz-12 glue.js'e eklenir). Büyük export'larda buton
`aria-busy` + "Hazırlanıyor…" metni; iptal yok (ponytail: 100 MB+ export'ta `AbortController` bridge'i eklenir).

**Zaman gösterimi:** API UTC ISO döner; tabloda yerel saat (`js.format_date`), `title` attribute'unda UTC.

**Action'lar:** `AUDIT_REQUESTED`, `AUDIT_LOADED`, `AUDIT_FAILED`, `AUDIT_FILTERS_CHANGED`, `AUDIT_STATS_LOADED`,
`AUDIT_SELECTED`, `AUDIT_DETAIL_LOADED`, `AUDIT_DESELECTED`, `AUDIT_EXPORT_STARTED`, `AUDIT_EXPORT_FINISHED`.

Canlı güncelleme (polling/WebSocket) yok; "Yenile" butonu yeterli.

### 4. `web/src/views/dashboard.lua` — Admin Kartları

`state.auth.user.role == "admin"` değil, **izin** bazlı gösterilir (rol adına bağlanmak RBAC'ı by-pass eder):

| Kart | Koşul | Kaynak |
|---|---|---|
| Toplam kullanıcı / aktif | `can("users.list")` | `GET /users?per_page=1` → `meta.total`; aktif için `&is_active=true` |
| Son 24 saat audit olayı | `can("audit.logs")` | `GET /audit/stats?from=<now-24h>` → `total` |
| Son 24 saat başarısız giriş | `can("audit.logs")` | aynı yanıt → `by_action["auth.login.failure"]` |
| Son 24 saat erişim reddi | `can("audit.logs")` | aynı yanıt → `by_action["access.denied"]` |
| Tüm kullanıcıların todo istatistiği | admin | `GET /todos/stats` admin için zaten tüm todo'ları kapsar (F6) — ek istek yok |

Kartlar tıklanabilir: ilgili view'a filtreli link (`#/audit-logs?action=access.denied&from=...`).
Her kart bağımsız yüklenir (ayrı `app.spawn`), biri hata verirse sadece o kart "—" gösterir.

Action'lar: `ADMIN_STATS_LOADED`, `ADMIN_STATS_FAILED`.

### 5. `web/src/views/layout.lua` — Menü

```lua
-- Menü öğeleri; görünürlük tamamen izne bağlı
local NAV = {
  { href = "#/dashboard",   label = "Pano",          page_key = "dashboard" },
  { href = "#/todos",       label = "Todo'lar",      page_key = "todos.list" },
  { href = "#/users",       label = "Kullanıcılar",  page_key = "users.list" },
  { href = "#/rbac",        label = "Yetkiler",      page_key = "rbac.matrix" },
  { href = "#/audit-logs",  label = "Denetim",       page_key = "audit.logs" },
  { href = "#/profile",     label = "Profil",        page_key = nil },
}
```

Aktif öğe `aria-current="page"`. Route tanımları faz-13 `router.lua`'daki tabloya eklenir.

---

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Users ekranında optimistic yok | İş kuralı reddi (LAST_ADMIN, EMAIL_TAKEN) olası; geri alma kafa karıştırır |
| RBAC tek hücre PATCH + optimistic | Hızlı geri bildirim; hata nadir (yalnız kilitli hücre, UI'da zaten disabled) |
| Görünürlük rol değil izin bazlı | RBAC matrisi değişince UI kendiliğinden uyum sağlar |
| Diff yalnız üst seviye alanlar | Todo/user nesneleri düz; derin diff gereksiz |
| CSV blob + `download` | Bearer header gerektiği için tek yol; ekstra kütüphane yok |
| Canlı log akışı yok | YAGNI; admin "Yenile" ile yeterli |

## Kabul kriterleri (DoD)

- [ ] Admin menüsünde Kullanıcılar/Yetkiler/Denetim görünüyor; todouser'da görünmüyor ve URL ile girince 403 ekranı / dashboard'a yönleniyor.
- [ ] Kullanıcı oluştur → listede görünüyor → yeni kullanıcı ile giriş yapılabiliyor.
- [ ] Var olan e-posta ile oluşturma `email` alanı altında "zaten kullanılıyor" gösteriyor.
- [ ] Admin kendini silemiyor (buton disabled + API `SELF_ACTION_FORBIDDEN`).
- [ ] Tek admin varken başka bir admin'in rolünü düşürmeye veya son admin'i pasifleştirmeye izin verilmiyor (`LAST_ADMIN`).
- [ ] RBAC: todouser → `users.list` açılınca, todouser oturumunda ≤ `RBAC_CACHE_TTL` sn içinde (yenileme sonrası) menüde "Kullanıcılar" çıkıyor.
- [ ] RBAC: admin → `rbac.matrix` hücresi disabled; API'ye elle PATCH `CONFLICT` dönüyor.
- [ ] RBAC hücre hatasında checkbox eski değerine dönüyor + toast.
- [ ] Audit: her filtre tek başına ve birlikte çalışıyor; URL'ye yansıyor.
- [ ] Audit detayında `todo.update` için yalnızca değişen alanlar vurgulu; `password_hash` "***".
- [ ] CSV indirme filtrelerle aynı kayıtları içeriyor; Excel'de Türkçe karakterler bozulmuyor (UTF-8 BOM — F8).
- [ ] Dashboard admin kartları doğru sayıları gösteriyor ve linkleri filtreli sayfaya gidiyor.
- [ ] Tüm tablolarda `caption`, `scope`, `aria-sort`; ekran okuyucu (Orca/NVDA) ile tablo başlıkları okunuyor.

## Doğrulama

```bash
make up && make db.migrate db.seed && make web.build
```

1. `admin@todoapp.local` ile giriş → `#/users` → "test@todoapp.local" oluştur (todouser).
2. Gizli pencerede `test@todoapp.local` ile giriş → menüde yalnızca Pano/Todo'lar/Profil.
3. Admin → `#/rbac` → todouser × users.list aç.
4. Test penceresinde 60 sn bekle / yenile → "Kullanıcılar" görünür, liste açılır.
5. Admin → `#/audit-logs?action=rbac.matrix.update` → kaydı aç → diff: `todouser.users.list: false → true`.
6. Test penceresinde `#/rbac` URL'sine git → reddedilir → admin audit'te `access.denied` kaydı.
7. "CSV indir" → dosyayı aç, satır sayısını tablo `meta.total` ile karşılaştır.

```bash
# API tarafı kilit kontrolü
curl -s -X PATCH localhost:28080/api/v1/rbac/matrix/admin/rbac.matrix \
  -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
  -d '{"can_access":false}' | jq .error.code      # "CONFLICT"
```

## Riskler / Dikkat Noktaları

| Risk | Önlem |
|---|---|
| RBAC cache: değişiklik anında yansımıyor | UI'da TTL metni; admin'in kendi rolü değişince `PERMISSIONS_LOADED` |
| Frontend izin kontrolünün güvenlik sanılması | Dokümante: asıl kontrol API; E2E'de API'ye doğrudan istek testi (F17) |
| Audit tablosu çok büyük (milyonlarca satır) | Varsayılan tarih aralığı 7 gün; API tarafında indeks (F2) ve sayfalama |
| CSV blob'un belleğe tamamen alınması | 30 günlük retention ile makul boyut; aşarsa streaming download (Service Worker) değerlendirilir |
| `user_id` filtresinde silinmiş kullanıcı | `user_email` sütunu audit'te saklanıyor (00 şema); filtre e-posta ile de çalışır |

## Tahmini Efor

**M** — ~2 gün (users ~0.75, rbac ~0.5, audit ~0.75; dashboard/menü güncellemesi dahil).
