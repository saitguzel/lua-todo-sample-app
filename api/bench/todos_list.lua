-- wrk todos list: GET /todos (TOKEN run.sh'tan); 2xx dışı yanıtlar sayılır
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli (api/bench/run.sh üretir)")
wrk.headers["Authorization"] = "Bearer " .. token
wrk.path = "/api/v1/todos?per_page=20"

local statuses = {}
response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
