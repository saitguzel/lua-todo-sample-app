-- F13: JSON encode/decode JS'e devredilir; Lua'da null'u temsil eden sentinel sağlanır.
-- encode kendi küçük Lua serializer'ı ile string üretir (nil/boş tablo/sentinel kontrolü),
-- decode JS JSON.parse'a devredilir. Dış API: json.encode(v), json.decode(s), json.null.

local json = { null = setmetatable({}, { __tostring = function() return "null" end }) }

local function is_null(v) return v == json.null end

local function encode_value(v, buf)
  local t = type(v)
  if v == nil or is_null(v) then
    buf[#buf + 1] = "null"
  elseif t == "boolean" then
    buf[#buf + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      buf[#buf + 1] = "null" -- NaN/Inf JSON'da yok
    elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      buf[#buf + 1] = string.format("%d", v)
    else
      buf[#buf + 1] = string.format("%.14g", v)
    end
  elseif t == "string" then
    buf[#buf + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      if c == "\t" then return "\\t" end
      if c == "\r" then return "\\r" end
      return string.format("\\u%04x", string.byte(c))
    end) .. '"'
  elseif t == "table" then
    -- dizi mi nesne mi: n > 0 veya next yalnızca 1..n ise dizi
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == #v then
      buf[#buf + 1] = "["
      for i = 1, #v do
        if i > 1 then buf[#buf + 1] = "," end
        encode_value(v[i], buf)
      end
      buf[#buf + 1] = "]"
    else
      buf[#buf + 1] = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then buf[#buf + 1] = "," end
        first = false
        encode_value(tostring(k), buf)
        buf[#buf + 1] = ":"
        encode_value(val, buf)
      end
      buf[#buf + 1] = "}"
    end
  else
    error("JSON'a çevrilemez tip: " .. t, 2)
  end
end

-- Encode: kendi serializer'ımız (sentinel + boş tablo ayrımı kontrol altında)
function json.encode(v)
  local buf = {}
  encode_value(v, buf)
  return table.concat(buf)
end

-- Decode: JS JSON.parse'a devredilir (hızlı ve doğru)
function json.decode(s)
  if s == nil or s == "" then return nil end
  local ok, res = pcall(js.json.decode, s)
  if not ok then error("Geçersiz JSON: " .. tostring(res), 2) end
  return res
end

return json
