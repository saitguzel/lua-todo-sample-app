-- F13: Hash router + auth/RBAC guard. parse ve guard saf fonksiyonlardır (F17'de tablo-bazlı test edilir).

local router = {}

-- Route tablosu (kanonik, faz-13 §4.5). Sıra önemli: sabit segmentler parametreliden önce.
-- layout = false: layout'suz tam sayfa (auth ekranları). bundle = "admin": view ayrı bundle-admin.<hash>.json'da
-- (F17 #7), ilk girişte yüklenir.
local ROUTES = {
  { hash = "#/login", name = "login", view = "views.login", auth = "guest-only", layout = false },
  { hash = "#/forgot-password", name = "forgot_password", view = "views.forgot_password", auth = "guest-only",
    layout = false },
  { hash = "#/reset-password", name = "reset_password", view = "views.reset_password", auth = false, layout = false },
  { hash = "#/", name = "dashboard", view = "views.dashboard", auth = true, page_key = "dashboard" },
  { hash = "#/dashboard", name = "dashboard", view = "views.dashboard", auth = true, page_key = "dashboard" },
  { hash = "#/todos/new", name = "todos_new", view = "views.todos", auth = true, page_key = "todos.create" },
  { hash = "#/todos/:id", name = "todo_edit", view = "views.todos", auth = true, page_key = "todos.edit" },
  { hash = "#/todos", name = "todos", view = "views.todos", auth = true, page_key = "todos.list" },
  { hash = "#/users", name = "users", view = "views.users", auth = true, page_key = "users.list", bundle = "admin" },
  { hash = "#/rbac", name = "rbac", view = "views.rbac_matrix", auth = true, page_key = "rbac.matrix",
    bundle = "admin" },
  { hash = "#/audit-logs", name = "audit", view = "views.audit_logs", auth = true, page_key = "audit.logs",
    bundle = "admin" },
  { hash = "#/profile", name = "profile", view = "views.profile", auth = true }, -- page_key yok: her oturum
}

router.ROUTES = ROUTES

-- --- url codec ----------------------------------------------------------------

function router.urlencode(s)
  return (tostring(s):gsub("[^%w%-._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function router.urldecode(s)
  s = tostring(s):gsub("%+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- "#/todos/abc" → { "#", "todos", "abc" }
local function segments(s)
  local out = {}
  for seg in (s .. "/"):gmatch("([^/]*)/") do out[#out + 1] = seg end
  return out
end

-- Segment bazlı eşleşme (Lua pattern'i kullanılmaz: "-" gibi büyü karakterleri sorun çıkarır)
local function match_route(r, full)
  local rs, ps = segments(r.hash), segments(full)
  if #rs ~= #ps then return nil end
  local params = {}
  for i, seg in ipairs(rs) do
    if seg:sub(1, 1) == ":" then
      if ps[i] == "" then return nil end
      params[seg:sub(2)] = router.urldecode(ps[i])
    elseif seg ~= ps[i] then
      return nil
    end
  end
  return params
end

function router.encode_query(query)
  local parts = {}
  for k, v in pairs(query or {}) do
    if v ~= nil and v ~= "" and v ~= false then
      parts[#parts + 1] = router.urlencode(k) .. "=" .. router.urlencode(v)
    end
  end
  if #parts == 0 then return "" end
  table.sort(parts)
  return "?" .. table.concat(parts, "&")
end

-- Saf: "#/todos/abc?x=1&y=iki%20kelime" → { path, name, params, query, raw, route }
function router.parse(hash)
  hash = hash or ""
  local path = hash:match("^#([^?]*)") or "/"
  if path == "" then path = "/" end
  local query_str = hash:match("%?(.*)$") or ""
  local query = {}
  for pair in query_str:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      query[router.urldecode(k)] = router.urldecode(v)
    end
  end
  local matched, params = nil, {}
  for _, r in ipairs(ROUTES) do
    local p = match_route(r, "#" .. path)
    if p then
      matched, params = r, p
      break
    end
  end
  return {
    path = path,
    name = matched and matched.name or "not_found",
    params = params,
    query = query,
    raw = hash ~= "" and hash or "#/",
    route = matched,
  }
end

-- --- guard ----------------------------------------------------------------------

-- Saf: → nil (geç) | "#/login?next=..." | "#/" | "forbidden"
function router.guard(route, auth)
  if auth.status == "unknown" then return nil end
  local r = route.route or {}
  if r.auth == "guest-only" and auth.status == "authenticated" then
    return "#/"
  end
  if r.auth == true and auth.status ~= "authenticated" then
    return "#/login?next=" .. router.urlencode(route.raw or "#/")
  end
  if r.page_key and not (auth.permissions and auth.permissions[r.page_key]) then
    return "forbidden"
  end
  return nil
end

-- next yalnızca "#/" ile başlıyorsa kabul (open redirect koruması)
function router.safe_next(next_hash)
  if type(next_hash) ~= "string" then return nil end
  if next_hash:sub(1, 2) == "#/" and not next_hash:find("^#//") then return next_hash end
  return nil
end

-- --- çalışma zamanı ---------------------------------------------------------------

local on_change_cb = nil
local current = nil

function router.start(on_change)
  on_change_cb = on_change
  js.location.onHashChange(function(h)
    current = router.parse(h)
    if on_change_cb then on_change_cb(current) end
  end)
  current = router.parse(js.location.hash() or "#/")
  if on_change_cb then on_change_cb(current) end
end

-- navigate: varsayılan push (hashchange → on_change);
-- opts.replace → history'ye ekleme, on_change hemen çalışır;
-- opts.silent  → yalnızca adres çubuğu değişir (route yeniden işlenmez; reset token silme)
function router.navigate(hash, opts)
  opts = opts or {}
  if opts.silent then
    js.location.replace(hash)
    return
  end
  if opts.replace then
    js.location.replace(hash)
    current = router.parse(hash)
    if on_change_cb then on_change_cb(current) end
  elseif current and current.raw == hash then
    -- aynı hash'e push hashchange tetiklemez; yine de yeniden işle
    if on_change_cb then on_change_cb(current) end
  else
    js.location.setHash(hash) -- hashchange tetikler
  end
end

-- Mevcut path'i koruyup query'yi günceller (filtreler URL'de, geri tuşu çalışır — F14/F15)
function router.replace_query(patch, opts)
  local cur = current or router.parse("#/")
  local q = {}
  for k, v in pairs(cur.query or {}) do q[k] = v end
  for k, v in pairs(patch or {}) do
    if v == "" or v == false then q[k] = nil else q[k] = v end
  end
  router.navigate("#" .. cur.path .. router.encode_query(q), opts)
end

-- Ayrı bundle'daki view'lar yüklenmeden require edilemez
local loaded_bundles = {}
function router.bundle_ready(r)
  return not (r and r.bundle) or loaded_bundles[r.bundle] == true
end

-- Coroutine içinde çağrılır: bundle'ı JS'ten yükletir, bitene kadar yield eder
function router.load_bundle(name)
  if loaded_bundles[name] then return true end
  local co, is_main = coroutine.running()
  assert(not is_main, "router.load_bundle bir coroutine içinde çağrılmalı")
  local done, result, waiting = false, nil, false
  js.loadBundle(name, function(err)
    done, result = true, err
    if waiting then
      local ok, e = coroutine.resume(co)
      if not ok then js.log("error", "bundle coroutine hatası: " .. tostring(e)) end
    end
  end)
  if not done then
    waiting = true
    coroutine.yield()
  end
  if result then return nil, result end
  loaded_bundles[name] = true
  return true
end

-- view modülünü lazy require eder; route bilinmiyorsa / bundle yüklenmediyse nil
function router.resolve(route)
  local r = route and route.route
  if not r or not router.bundle_ready(r) then return nil end
  local ok, view = pcall(require, r.view)
  if not ok then
    js.log("error", "view yüklenemedi: " .. r.view .. " — " .. tostring(view))
    return nil
  end
  return view
end

function router.href(name, params, query)
  for _, r in ipairs(ROUTES) do
    if r.name == name then
      local hash = r.hash
      for k, v in pairs(params or {}) do hash = hash:gsub(":" .. k, router.urlencode(v)) end
      return hash .. router.encode_query(query)
    end
  end
  return "#/"
end

-- menü/buton gizleme: state.auth.permissions[page_key]
function router.can(auth, page_key)
  if not page_key then return true end
  return auth.status == "authenticated" and (auth.permissions or {})[page_key] == true
end

function router.current()
  return current
end

return router
