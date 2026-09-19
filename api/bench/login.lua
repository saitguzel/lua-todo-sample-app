-- wrk login senaryosu: POST /auth/login sabit govde
wrk.method = "POST"
wrk.path = "/api/v1/auth/login"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"email":"user@todoapp.local","password":"User123!"}'

local counter = 0
request = function()
  counter = counter + 1
  wrk.headers["X-Forwarded-For"] = "10.0." .. (counter % 250) .. "." .. (counter % 200 + 1)
  return wrk.format()
end
