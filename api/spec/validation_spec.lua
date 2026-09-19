-- Validation şema testleri: shared validation'ın API'deki kullanımı (F11 §5.2)
local v = require("todo_shared.validation")

local function errs(schema, input)
  local clean, e = v.validate(schema, input)
  return clean, e or {}
end

describe("todo_create", function()
  local S = v.schemas.todo_create

  it("minimal title geçer", function()
    local clean = assert(v.validate(S, { title = "Süt al" }))
    assert.equal("Süt al", clean.title)
  end)

  it("boş nesne → title zorunlu", function()
    local clean, e = errs(S, {})
    assert.is_nil(clean)
    assert.same({ "zorunlu alan" }, e.title)
  end)

  it("256 karakter title reddedilir, 255 geçer", function()
    assert.is_nil(v.validate(S, { title = string.rep("a", 256) }))
    assert.is_not_nil(v.validate(S, { title = string.rep("ğ", 255) }))
  end)

  it("geçersiz status ve priority", function()
    assert.truthy(select(2, errs(S, { title = "x", status = "done" })).status)
    assert.truthy(select(2, errs(S, { title = "x", priority = "urgent" })).priority)
  end)

  it("due_date geçersiz", function()
    assert.truthy(select(2, errs(S, { title = "x", due_date = "2026-13-01" })).due_date)
  end)

  it("tags tip hatası [2]", function()
    local _, e = errs(S, { title = "x", tags = { "a", 5 } })
    assert.truthy(e.tags and table.concat(e.tags, " "):find("%[2%]"))
  end)

  it("tags 21 eleman reddedilir, 20 geçer", function()
    local tags = {}
    for i = 1, 20 do tags[i] = "t" .. i end
    assert.is_not_nil(v.validate(S, { title = "x", tags = tags }))
    tags[21] = "t21"
    assert.is_nil(v.validate(S, { title = "x", tags = tags }))
  end)

  it("tekrarlı tag reddedilir", function()
    assert.is_nil(v.validate(S, { title = "x", tags = { "a", "a" } }))
  end)

  it("bilinmeyen alan kabul edilmez (mass-assignment)", function()
    local clean = v.validate(S, { title = "x", foo = 1 })
    assert.is_true(clean == nil or clean.foo == nil)
  end)
end)

describe("todo_patch", function()
  it("boş nesne → VALIDATION hatası", function()
    assert.is_nil(v.validate_partial(v.schemas.todo_patch, {}))
  end)

  it("tek alan geçer", function()
    local clean = assert(v.validate_partial(v.schemas.todo_patch, { title = "Yeni" }))
    assert.equal("Yeni", clean.title)
  end)
end)

describe("user şemaları", function()
  local S = v.schemas.user_create

  it("geçersiz email", function()
    assert.truthy(select(2, errs(S, { email = "bad", password = "Valid123!", role = "todouser" })).email)
  end)

  it("zayıf parola: kısa ve harf+rakam yok", function()
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "Ab1", role = "todouser" })).password)
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "abcdefghij", role = "todouser" })).password)
  end)

  it("role root reddedilir", function()
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "Valid123!", role = "root" })).role)
  end)

  it("user_update tüm alanlar opsiyonel", function()
    assert.is_not_nil(v.validate(v.schemas.user_update, { full_name = "Ad" }))
  end)
end)

describe("auth şemaları", function()
  it("login email+password zorunlu", function()
    local _, e = errs(v.schemas.login, {})
    assert.truthy(e.email)
    assert.truthy(e.password)
  end)

  it("reset token + new_password", function()
    assert.is_not_nil(v.validate(v.schemas.reset_password, { token = string.rep("a", 64), new_password = "Valid123!" }))
    assert.is_nil(v.validate(v.schemas.reset_password, { token = "kisa", new_password = "Valid123!" }))
  end)

  it("forgot email zorunlu", function()
    assert.truthy(select(2, errs(v.schemas.forgot_password, {})).email)
  end)
end)

describe("utf8", function()
  it("Türkçe başlık karakter bazlı sayılır", function()
    -- "Çalışma planı ğüşiöç" = 20 karakter (byte değil)
    assert.equal(20, v.utf8_len("Çalışma planı ğüşiöç"))
    assert.is_not_nil(v.validate(v.schemas.todo_create, { title = "Çalışma planı ğüşiöç" }))
  end)
end)
