-- F17: fetch.lua testleri — coroutine köprüsü, hata eşleme, tek-uçuş refresh.
local fake = require("helper") -- js mock'unu yükler
local json = require("json")

-- api.configure resetlenebilir olması için fetch.lua fresh require edilir
package.loaded["fetch"] = nil
local api = require("fetch")

local function in_coroutine(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then error(err, 2) end
end

local tokens = nil

api.configure({
  base = "http://test/api/v1",
  get_tokens = function() return tokens end,
  set_tokens = function(a, r) tokens = { access_token = a, refresh_token = r } end,
  on_logout = function() tokens = nil end,
})

describe("api request", function()
  before_each(function()
    fake.reset()
    tokens = nil
  end)

  it("200 JSON data döner", function()
    fake.queue_response(200, json.encode({ data = { id = "t1", title = "x" } }))
    in_coroutine(function()
      local data, err = api.get("/todos/t1")
      assert.is_nil(err)
      assert.equal("t1", data.id)
    end)
  end)

  it("liste yanıtı items+meta ile döner", function()
    fake.queue_response(200, json.encode({ data = { { id = "t1" } }, meta = { total = 1, page = 1 } }))
    in_coroutine(function()
      local data, err = api.get("/todos")
      assert.is_nil(err)
      assert.equal(1, #data.items)
      assert.equal(1, data.meta.total)
    end)
  end)

  it("422 VALIDATION_FAILED details ile döner", function()
    fake.queue_response(422, json.encode({ error = { code = "VALIDATION_FAILED",
      message = "Girdi doğrulanamadı", details = { title = { "zorunlu alan" } } } }))
    in_coroutine(function()
      local data, err = api.post("/todos", { title = "" })
      assert.is_nil(data)
      assert.equal("VALIDATION_FAILED", err.code)
      assert.same({ title = { "zorunlu alan" } }, err.details)
    end)
  end)

  it("ağ hatası NETWORK_ERROR üretir (frontend'e özel kod)", function()
    fake.queue_response(0, "", { net_err = "fetch failed" })
    in_coroutine(function()
      local data, err = api.get("/todos")
      assert.is_nil(data)
      assert.equal("NETWORK_ERROR", err.code)
    end)
  end)

  it("Authorization header token varsa eklenir", function()
    tokens = { access_token = "abc", refresh_token = "r" }
    fake.queue_response(200, json.encode({ data = true }))
    in_coroutine(function()
      api.get("/todos")
    end)
    assert.matches("Bearer abc", fake.calls[1].headers)
  end)

  it("login'de Authorization eklenmez", function()
    tokens = { access_token = "abc", refresh_token = "r" }
    fake.queue_response(200, json.encode({ data = { access_token = "a2", refresh_token = "r2", user = {} } }))
    in_coroutine(function()
      api.post("/auth/login", { email = "a@b.c", password = "x12345678A" })
    end)
    assert.not_matches("Bearer", fake.calls[1].headers or "")
  end)

  it("401 TOKEN_EXPIRED → refresh → istek tekrarlanır (tek-uçuş)", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    -- 1) orijinal istek 401, 2) refresh 200, 3) tekrar 200
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_EXPIRED", message = "Oturum süresi doldu" } }))
    fake.queue_response(200, json.encode({ data = { access_token = "yeni", refresh_token = "r2" } }))
    fake.queue_response(200, json.encode({ data = { id = "t1" } }))
    in_coroutine(function()
      local data, err = api.get("/todos/t1")
      assert.is_nil(err)
      assert.equal("t1", data.id)
    end)
    -- çağrı sırası: GET, POST /auth/refresh, GET (tekrar)
    assert.equals(3, #fake.calls)
    assert.equal("http://test/api/v1/auth/refresh", fake.calls[2].url)
    assert.equal("GET", fake.calls[3].method)
    -- yeni token kullanıldı
    assert.matches("Bearer yeni", fake.calls[3].headers)
    assert.equal("yeni", tokens.access_token)
  end)

  it("refresh başarısız → on_logout çağrılır", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_EXPIRED" } }))
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_REVOKED" } }))
    in_coroutine(function()
      local data, err = api.get("/todos")
      assert.is_nil(data)
    end)
    assert.is_nil(tokens) -- on_logout çalıştı
  end)

  it("204 → true döner", function()
    fake.queue_response(204, "")
    in_coroutine(function()
      local ok, err = api.delete("/todos/t1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  it("query encoder url-encode yapar", function()
    assert.equal("?q=fatura%20%C3%B6de&page=2", api._encode_query({ q = "fatura öde", page = 2 }))
  end)
end)
