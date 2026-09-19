-- Audit context: IP ve User-Agent'i ngx.ctx.audit'e yazar (guvenilir proxy farkindalikli)
local config = require("config")

local _M = {}

local UA_MAX = 512

local function is_ip(s)
  if not s then return false end
  if s:match("^%d+%.%d+%.%d+%.%d+$") then return true end
  if s:match("^[%x:]+$") and s:find(":") then return true end
  return false
end

local function trusted_set()
  local cur = config.get()
  if not cur then return { ["127.0.0.1"] = true } end
  return cur.trusted_proxies_set or { ["127.0.0.1"] = true }
end

local function client_ip()
  local remote = ngx.var.remote_addr
  local trusted = trusted_set()
  if not trusted[remote] then return remote end
  local xff = ngx.var.http_x_forwarded_for
  if not xff or xff == "" then return remote end
  local hops = {}
  for part in xff:gmatch("[^,]+") do
    hops[#hops + 1] = part:match("^%s*(.-)%s*$")
  end
  for i = #hops, 1, -1 do
    if not trusted[hops[i]] then
      return is_ip(hops[i]) and hops[i] or remote
    end
  end
  return is_ip(hops[1]) and hops[1] or remote
end

function _M.handle()
  local ua = ngx.var.http_user_agent
  ngx.ctx.audit = {
    ip = client_ip(),
    user_agent = ua and ua:sub(1, UA_MAX) or nil,
  }
  return nil
end

return _M
