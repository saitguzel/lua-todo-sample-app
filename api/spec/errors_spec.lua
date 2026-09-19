-- Hata enjeksiyonu birim testleri: entegrasyonda üretilemeyen INTERNAL_ERROR, DB_UNAVAILABLE, MAIL_FAILED
local protocol = require("todo_shared.protocol")

describe("error_handler", function()
  local errors = require("middleware.error_handler")

  it("app error olmayan hata → 500 INTERNAL_ERROR, iç mesaj sızmaz", function()
    local res = errors.respond("attempt to index nil: /app/src/x.lua:12")
    assert.equal(500, res.status)
    assert.equal("INTERNAL_ERROR", res.json.error.code)
    assert.is_nil(res.json.error.message:find("/app/src"))
  end)

  it("MAIL_FAILED → 502", function()
    assert.equal(502, protocol.http_status("MAIL_FAILED"))
    assert.equal(502, errors.respond(errors.new("MAIL_FAILED")).status)
  end)
end)

describe("query DB_UNAVAILABLE", function()
  it("bağlantı alınamazsa DB_UNAVAILABLE (503)", function()
    package.loaded["db.pool"] = { acquire = function() return nil, "connection refused" end, release = function() end }
    package.loaded["db.query"] = nil
    local query = require("db.query")
    local rows, err = query.query("SELECT 1")
    assert.is_nil(rows)
    assert.equal("DB_UNAVAILABLE", err.code)
    assert.equal(503, protocol.http_status(err.code))
    package.loaded["db.query"] = nil
    package.loaded["db.pool"] = nil
  end)
end)
