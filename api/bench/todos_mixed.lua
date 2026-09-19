-- wrk mixed: %70 GET /todos, %20 POST /todos, %10 PATCH /todos/<id> (id'ler POST yanıtlarından)
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli (api/bench/run.sh üretir)")
local headers = { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }

local ids = {}
local counter = 0
local statuses = {}

request = function()
  counter = counter + 1
  local r = math.random(100)
  if r <= 70 or (r > 90 and #ids == 0) then
    return wrk.format("GET", "/api/v1/todos?per_page=20", headers)
  elseif r <= 90 then
    return wrk.format("POST", "/api/v1/todos", headers, string.format('{"title":"Bench %d"}', counter))
  end
  return wrk.format("PATCH", "/api/v1/todos/" .. ids[math.random(#ids)], headers, '{"status":"completed"}')
end

-- wrk status'ü sayı olarak verir
response = function(status, _, body)
  statuses[status] = (statuses[status] or 0) + 1
  if status == 201 and body and #ids < 1000 then
    local id = body:match('"id"%s*:%s*"([^"]+)"')
    if id then ids[#ids + 1] = id end
  end
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
