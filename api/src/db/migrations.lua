-- Migration runner: dosyaları sırayla uygular, advisory lock ile korunur
-- CLI: resty -I /app/src -I /app/lib migrations.lua <up|down|status|seed>
local _M = {}

local ADVISORY_LOCK = 727001

-- pgmoon başarıda (res, num_queries) döner; hata yalnızca res == nil iken ikinci değerdir
local function run(pg, sql, ...)
  local res, err = pg:query(sql, ...)
  if res == nil then return nil, err or "bilinmeyen sorgu hatasi" end
  return res
end

-- lfs yok, io.popen ile liste al
local function load_all(dir)
  local list = {}
  local cmd = "ls -1 " .. dir .. " 2>/dev/null"
  local fh = io.popen(cmd)
  if not fh then return nil, "dizin okunamadi: " .. dir end
  for fname in fh:lines() do
    local ver = fname:match("^(%d+)_[%w_]+%.lua$")
    if ver then
      local path = dir .. "/" .. fname
      local chunk, lerr = loadfile(path)
      if not chunk then
        fh:close()
        return nil, "migration yuklenemedi " .. fname .. ": " .. tostring(lerr)
      end
      local ok, mod = pcall(chunk)
      if not ok then
        fh:close()
        return nil, "migration calistirilamadi " .. fname .. ": " .. tostring(mod)
      end
      if type(mod.version) ~= "number" or type(mod.name) ~= "string" then
        fh:close()
        return nil, fname .. ": version/name eksik"
      end
      if tonumber(ver) ~= mod.version then
        fh:close()
        return nil, fname .. ": dosyadaki version (" .. mod.version .. ") dosya adiyla uyusmuyor"
      end
      list[#list + 1] = {
        version = mod.version,
        name = mod.name,
        up = mod.up,
        down = mod.down,
        fname = fname,
      }
    end
  end
  fh:close()
  table.sort(list, function(a, b) return a.version < b.version end)
  -- ardışıklık kontrolü
  for i = 2, #list do
    if list[i].version ~= list[i - 1].version + 1 then
      return nil, "version boslugu: " .. list[i - 1].version .. " -> " .. list[i].version
    end
  end
  return list
end

local function ensure_version_table(pg)
  return run(pg, [[
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  ]])
end

local function applied_versions(pg)
  local rows, err = pg:query("SELECT version FROM schema_migrations ORDER BY version")
  if not rows then return nil, err end
  local set = {}
  for _, r in ipairs(rows) do set[tonumber(r.version)] = true end
  return set
end

local function lock(pg)
  -- pgmoon LuaJIT'te 727001'i double/numeric gönderir; pg_advisory_lock(bigint) yok
  -- sayıyı metne çevirip bigint'e cast ederiz
  local rows, err = pg:query("SELECT pg_advisory_lock($1::bigint)", tostring(ADVISORY_LOCK))
  if not rows then return nil, err end
  return true
end

local function unlock(pg)
  local rows, err = pg:query("SELECT pg_advisory_unlock($1::bigint)", tostring(ADVISORY_LOCK))
  if not rows then return nil, err end
  return true
end

function _M.up(pg, dir)
  dir = dir or "/app/migrations"
  local migrations, err = load_all(dir)
  if not migrations then return nil, err end
  local ok, lerr = lock(pg)
  if not ok then return nil, lerr end
  local res, uerr = pcall(function()
    local _, e1 = ensure_version_table(pg)
    if e1 then error(e1, 0) end
    local applied, e2 = applied_versions(pg)
    if not applied then error(e2, 0) end
    local count = 0
    for _, m in ipairs(migrations) do
      if not applied[m.version] then
        local t0 = ngx and ngx.now() or os.time()
        local _, berr = run(pg, "BEGIN")
        if berr then error("BEGIN hatasi: " .. tostring(berr), 0) end
        local success = true
        local serr
        for _, stmt in ipairs(m.up) do
          local _, qerr = run(pg, stmt)
          if qerr then success = false; serr = qerr; break end
        end
        if not success then
          pg:query("ROLLBACK")
          error(m.fname .. ": " .. tostring(serr), 0)
        end
        local _, ierr = run(pg,
          "INSERT INTO schema_migrations(version, name) VALUES ($1, $2)", m.version, m.name
        )
        if ierr then
          pg:query("ROLLBACK")
          error(m.fname .. " insert: " .. tostring(ierr), 0)
        end
        local _, cerr = run(pg, "COMMIT")
        if cerr then error("COMMIT: " .. tostring(cerr), 0) end
        count = count + 1
        local dt = ""
        if ngx and ngx.now then
          dt = string.format(" (%.0f ms)", (ngx.now() - t0) * 1000)
        end
        ngx.log(ngx.NOTICE, "up " .. m.fname .. dt)
        print("applied " .. m.fname .. dt)
      end
    end
    return count
  end)
  unlock(pg)
  if not res then return nil, uerr end
  return uerr or 0
end

function _M.down(pg, dir, steps)
  dir = dir or "/app/migrations"
  steps = steps or 1
  local migrations, err = load_all(dir)
  if not migrations then return nil, err end
  local ok, lerr = lock(pg)
  if not ok then return nil, lerr end
  local res, uerr = pcall(function()
    local _, e1 = ensure_version_table(pg)
    if e1 then error(e1, 0) end
    local rows, e2 = pg:query("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT $1", steps)
    if not rows then error(e2, 0) end
    if #rows == 0 then return 0 end
    local map = {}
    for _, m in ipairs(migrations) do map[m.version] = m end
    for _, r in ipairs(rows) do
      local ver = tonumber(r.version)
      local m = map[ver]
      if not m then error("migration dosyasi yok: " .. ver, 0) end
      local _, berr = run(pg, "BEGIN")
      if berr then error(berr, 0) end
      for _, stmt in ipairs(m.down) do
        local _, qerr = run(pg, stmt)
        if qerr then pg:query("ROLLBACK"); error(m.fname .. ": " .. tostring(qerr), 0) end
      end
      local _, derr = run(pg, "DELETE FROM schema_migrations WHERE version = $1", ver)
      if derr then pg:query("ROLLBACK"); error(derr, 0) end
      local _, cerr = run(pg, "COMMIT")
      if cerr then error(cerr, 0) end
      print("rolled back " .. m.fname)
    end
    return #rows
  end)
  unlock(pg)
  if not res then return nil, uerr end
  return uerr
end

function _M.status(pg, dir)
  dir = dir or "/app/migrations"
  local migrations, err = load_all(dir)
  if not migrations then return nil, err end
  ensure_version_table(pg)
  local rows, qerr = pg:query("SELECT version, name, applied_at FROM schema_migrations ORDER BY version")
  if not rows then return nil, qerr end
  local amap = {}
  for _, r in ipairs(rows) do amap[tonumber(r.version)] = r end
  local out = {}
  for _, m in ipairs(migrations) do
    local a = amap[m.version]
    out[#out + 1] = {
      version = m.version,
      name = m.name,
      fname = m.fname,
      applied_at = a and a.applied_at or nil,
      applied = a ~= nil,
    }
  end
  return out
end

function _M.seed(pg, seeds_dir, opts)
  seeds_dir = seeds_dir or "/app/seeds"
  opts = opts or {}
  local env = opts.env or {}
  -- env yoksa os.getenv ile doldur
  if not next(env) then
    for _, k in ipairs({ "SEED_DEFAULTS", "APP_ENV" }) do env[k] = os.getenv(k) end
  end
  -- helper q fonksiyonu
  local function q(sql, ...)
    local res, err = run(pg, sql, ...)
    if res == nil then error(err, 0) end
    return res
  end
  -- rbac_defaults her zaman
  local rbac_path = seeds_dir .. "/rbac_defaults.lua"
  local chunk = loadfile(rbac_path)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and mod and mod.run then
      local s, serr = pcall(mod.run, q)
      if not s then return nil, "rbac_defaults: " .. tostring(serr) end
      print("seeded rbac_defaults")
    end
  end
  -- default_users kosullu
  local users_path = seeds_dir .. "/default_users.lua"
  local chunk2 = loadfile(users_path)
  if chunk2 then
    local ok, mod = pcall(chunk2)
    if ok and mod and mod.run then
      local enabled = true
      if mod.enabled then enabled = mod.enabled(env) end
      if enabled then
        if env.APP_ENV == "production" and env.SEED_DEFAULTS == "true" then
          ngx.log(ngx.WARN, "SEED_DEFAULTS=true production ortaminda")
        end
        local s, serr = pcall(mod.run, q)
        if not s then return nil, "default_users: " .. tostring(serr) end
        print("seeded default_users")
      else
        print("seed skipped default_users (SEED_DEFAULTS false)")
      end
    end
  end
  return true
end

-- CLI giris: resty ile calistirilirsa
if arg and arg[0] and arg[0]:match("migrations%.lua$") then
  local cmd = arg[1]
  if not cmd then
    io.stderr:write("kullanim: migrations.lua <up|down|status|seed> [steps]\n")
    os.exit(1)
  end
  -- env'den pool configure
  local pool = require("db.pool")
  local host = os.getenv("DB_HOST") or "postgres"
  local port = tonumber(os.getenv("DB_PORT") or "5432")
  local db = os.getenv("DB_NAME") or "todo"
  local user = os.getenv("DB_USER") or "todo"
  local pw = os.getenv("DB_PASSWORD") or "change-me-dev-only"
  local pw_file = os.getenv("DB_PASSWORD_FILE")
  if pw_file then
    local fh = io.open(pw_file, "r")
    if fh then pw = fh:read("*a"):gsub("\r?\n$", ""); fh:close() end
  end
  pool.configure({
    host = host, port = port, database = db, user = user, password = pw,
    ssl = os.getenv("DB_SSL") == "true",
    pool_size = tonumber(os.getenv("DB_POOL_SIZE") or "20"),
    idle_timeout_ms = tonumber(os.getenv("DB_POOL_IDLE_TIMEOUT_MS") or "60000"),
    connect_timeout_ms = tonumber(os.getenv("DB_CONNECT_TIMEOUT_MS") or "3000"),
    query_timeout_ms = tonumber(os.getenv("DB_QUERY_TIMEOUT_MS") or "10000"),
  })
  local pg, err = pool.acquire()
  if not pg then
    io.stderr:write("DB baglanti hatasi: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  if cmd == "up" then
    local n, e = _M.up(pg)
    pool.release(pg)
    if not n then io.stderr:write(e .. "\n"); os.exit(1) end
    print("migrations up: " .. n .. " uygulandi")
  elseif cmd == "down" then
    local steps = tonumber(arg[2] or "1")
    local n, e = _M.down(pg, nil, steps)
    pool.release(pg)
    if not n then io.stderr:write(e .. "\n"); os.exit(1) end
    print("migrations down: " .. n .. " geri alindi")
  elseif cmd == "status" then
    local st, e = _M.status(pg)
    pool.release(pg)
    if not st then io.stderr:write(e .. "\n"); os.exit(1) end
    for _, r in ipairs(st) do
      print(string.format("%03d %-20s %s", r.version, r.name, r.applied and tostring(r.applied_at) or "pending"))
    end
  elseif cmd == "seed" then
    local ok2, e2 = _M.seed(pg)
    pool.release(pg)
    if not ok2 then io.stderr:write(e2 .. "\n"); os.exit(1) end
    print("seed tamamlandi")
  else
    io.stderr:write("bilinmeyen komut: " .. cmd .. "\n")
    os.exit(1)
  end
end

return _M
