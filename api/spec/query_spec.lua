-- db/query birim testleri: like_pattern, with_transaction (sahte pool ile)
local log = {}
local fake_conn = {
  query = function(_, sql)
    log[#log + 1] = sql
    -- pgmoon gibi: başarıda (res, num_queries)
    return true, 1
  end,
}
package.loaded["db.pool"] = {
  acquire = function() return fake_conn end,
  release = function() end,
}
package.loaded["db.query"] = nil
local query = require("db.query")

describe("query.like_pattern", function()
  it("% _ \\ kaçırılır", function()
    assert.equal("%a\\%b\\_c\\\\%", query.like_pattern("a%b_c\\"))
  end)
end)

describe("query.with_transaction", function()
  before_each(function() log = {}; ngx.ctx.tx_conn = nil end)

  it("başarıda BEGIN/COMMIT", function()
    local r = query.with_transaction(function() return "ok" end)
    assert.equal("ok", r)
    assert.same({ "BEGIN", "COMMIT" }, log)
  end)

  it("nil, err dönüşünde ROLLBACK ve hata iletilir", function()
    local r, err = query.with_transaction(function() return nil, { code = "CONFLICT" } end)
    assert.is_nil(r)
    assert.equal("CONFLICT", err.code)
    assert.same({ "BEGIN", "ROLLBACK" }, log)
  end)

  it("exception'da ROLLBACK ve yeniden fırlatma", function()
    assert.has_error(function() query.with_transaction(function() error("patladi", 0) end) end, "patladi")
    assert.same({ "BEGIN", "ROLLBACK" }, log)
    assert.is_nil(ngx.ctx.tx_conn)
  end)

  it("iç içe transaction dış bağlantıyı kullanır", function()
    query.with_transaction(function()
      return query.with_transaction(function() return true end)
    end)
    assert.same({ "BEGIN", "COMMIT" }, log)
  end)
end)
