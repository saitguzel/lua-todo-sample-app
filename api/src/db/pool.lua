-- pgmoon bağlantı havuzu: cosocket keepalive (worker başına)
-- Konfigürasyon F3 config.lua üzerinden verilir; min/max yerine keepalive.
local pgmoon = require("pgmoon")

local _M = {}
local cfg

-- String ve sayı parametreleri OID 0 (untyped) gönderilir: Postgres tipi bağlamdan çıkarır.
-- pgmoon varsayılanı string → 25 (text); bu, `uuid = text` ve `enum = text` hatalarına yol açar.
-- Tamsayılar %d ile yazılır: tostring(2^63-1) "9.22e+18" üretir, bigint'e cast edilemez.
local function untyped(_, v)
  if type(v) == "number" and v == math.floor(v) and v > -2^63 and v < 2^63 then
    return 0, string.format("%d", v)
  end
  return 0, tostring(v)
end
local SERIALIZERS = setmetatable({ string = untyped, number = untyped }, { __index = pgmoon.Postgres.type_serializers })

-- pgmoon hata metnini döndürür, SQLSTATE/constraint alanlarını ise atar (parse_error'un 2. dönüşü).
-- Hata tablosu tostring/concat ile eski string gibi davranır, ayrıca code/constraint taşır.
local PgError = {
  __tostring = function(e) return e.message end,
  __concat = function(a, b) return tostring(a) .. tostring(b) end,
}
local function parse_error(self, err_msg)
  local msg, data = pgmoon.Postgres.parse_error(self, err_msg)
  data = data or {}
  return setmetatable({ message = msg, code = data.code, constraint = data.constraint,
                        detail = data.detail, table = data.table }, PgError)
end
_M.PgError = PgError

-- timestamptz (OID 1184) → ISO-8601 Z; oturum saat dilimi UTC olduğundan PG "+00" döner
local base = pgmoon.Postgres
local PG_TYPES = setmetatable({ [1184] = "timestamptz" }, { __index = base.PG_TYPES })
local DESERIALIZERS = setmetatable({
  timestamptz = function(_, val)
    return (val:gsub(" ", "T", 1):gsub("%+00$", "Z"))
  end,
}, { __index = base.type_deserializers })

function _M.configure(opts)
  cfg = opts
end

function _M.get_config()
  return cfg
end

-- Havuzdan veya yeni bağlantı al
function _M.acquire()
  if not cfg then
    return nil, "poolconfigure edilmemis"
  end
  local pg = pgmoon.new({
    host = cfg.host,
    port = cfg.port,
    database = cfg.database,
    user = cfg.user,
    password = cfg.password,
    ssl = cfg.ssl,
    pool = "todo:" .. cfg.database,
  })
  pg.type_serializers = SERIALIZERS
  pg.PG_TYPES = PG_TYPES
  pg.type_deserializers = DESERIALIZERS
  pg.parse_error = parse_error
  -- pgmoon 1.16'da settimeouts yok; cosocket'e doğrudan: connect, send, read
  if pg.sock and pg.sock.settimeouts then
    pg.sock:settimeouts(cfg.connect_timeout_ms or 3000, cfg.query_timeout_ms or 10000, cfg.query_timeout_ms or 10000)
  end
  local ok, err = pg:connect()
  if not ok then
    return nil, err
  end
  -- pgmoon connect içinde sock:getreusedtimes() == 0 kontrolü yapar; burada doğrudan sock'tan okunur
  local reused = 0
  if pg.sock and pg.sock.getreusedtimes then
    reused = pg.sock:getreusedtimes()
  end
  if reused == 0 then
    local tres, terr = pg:query("SET TIME ZONE 'UTC'")
    if tres == nil then
      ngx.log(ngx.WARN, "SET TIME ZONE basarisiz: ", terr)
    end
  end
  return pg
end

-- Bağlantıyı havuza iade et
function _M.release(pg, broken)
  if not pg then return end
  if broken then
    pg:disconnect()
    return
  end
  local ok, err = pg:keepalive(cfg.idle_timeout_ms, cfg.pool_size)
  if not ok then
    ngx.log(ngx.WARN, "keepalive basarisiz: ", err)
    pg:disconnect()
  end
end

-- Bağlantıyı al, fn(pg) çalıştır, iade et
function _M.with_connection(fn)
  local pg, err = _M.acquire()
  if not pg then return nil, err end
  local ok, res1, res2 = pcall(fn, pg)
  local broken = not ok
  _M.release(pg, broken)
  if not ok then
    ngx.log(ngx.ERR, "with_connection hatasi: ", tostring(res1))
    return nil, res1
  end
  return res1, res2
end

-- init_worker'da ısıtma: n bağlantı açıp havuza bırak
function _M.warm(n)
  n = n or 5
  if not cfg then return end
  -- init_worker'da cosocket kullanılamaz, timer içinde dene
  local ok, err = ngx.timer.at(0, function(premature)
    if premature then return end
    for _ = 1, n do
      local pg, cerr = _M.acquire()
      if pg then
        _M.release(pg, false)
      else
        ngx.log(ngx.WARN, "pool warm basarisiz: ", cerr)
      end
    end
  end)
  if not ok then
    ngx.log(ngx.WARN, "warm timer kurulamadi: ", err)
  end
end

return _M
