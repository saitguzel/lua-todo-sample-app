-- log_cleanup birim testleri (resty altında, gerçek job_locks dict'i): should_run, run_once, tick kilidi
local CFG = { audit = { retention_days = 30, cleanup_batch_size = 1000, cleanup_hour = 3, cleanup_enabled = true } }
package.loaded["config"] = { get = function() return CFG end, current = CFG }

-- Sahte pool: remaining eski satır sayısını batch'ler halinde "siler"
local db = {}
local function reset_db(opts)
  db = { remaining = opts.remaining or 0, lock = opts.lock ~= false, down = opts.down, meta = {} }
end
package.loaded["db.pool"] = {
  acquire = function()
    if db.down then return nil, "connection refused" end
    return {
      query = function(_, sql, a, b, c, d)
        if sql:find("pg_try_advisory_lock") then return { { ok = db.lock } }, 1 end
        if sql:find("pg_advisory_unlock") then return { { ok = true } }, 1 end
        if sql:find("DELETE FROM audit_logs") then
          local n = math.min(db.remaining, b)
          db.remaining = db.remaining - n
          local rows = {}
          for i = 1, n do rows[i] = { ["?column?"] = 1 } end
          return rows, 1
        end
        if sql:find("INSERT INTO cleanup_logs") then
          db.meta[#db.meta + 1] = { deleted = a, batches = b, duration_ms = c, status = d }
          return { affected_rows = 1 }, 1
        end
        error("beklenmeyen sql: " .. sql)
      end,
    }
  end,
  release = function() end,
}
package.loaded["jobs.log_cleanup"] = nil
local job = require("jobs.log_cleanup")
job.BATCH_PAUSE = 0

-- 2026-09-18 03:00:00 UTC
local AT3 = 1789700400

describe("log_cleanup.should_run", function()
  it("yanlış saat → false", function()
    assert.is_false(job.should_run(AT3, 4, nil))
  end)
  it("doğru saat + dün çalışmış → true", function()
    assert.is_true(job.should_run(AT3, 3, "2026-09-17"))
  end)
  it("doğru saat + bugün çalışmış → false", function()
    assert.is_false(job.should_run(AT3, 3, "2026-09-18"))
  end)
  it("last_run nil → true", function()
    assert.is_true(job.should_run(AT3, 3, nil))
  end)
end)

describe("log_cleanup.run_once", function()
  before_each(function() ngx.shared.job_locks:flush_all() end)

  it("25.000 eski satır → 25 batch, meta-log success", function()
    reset_db({ remaining = 25000 })
    local r = assert(job.run_once())
    assert.equal(25000, r.deleted)
    assert.equal(25, r.batches)
    assert.equal("success", r.status)
    assert.equal(0, db.remaining)
    assert.same({ deleted = 25000, batches = 25, status = "success" },
      { deleted = db.meta[1].deleted, batches = db.meta[1].batches, status = db.meta[1].status })
    assert.truthy(ngx.shared.job_locks:get("last_run:log_cleanup"))
  end)

  it("advisory lock alınamazsa skipped, silme yok", function()
    reset_db({ remaining = 500, lock = false })
    local r = assert(job.run_once())
    assert.equal("skipped", r.status)
    assert.equal(500, db.remaining)
    assert.equal(0, #db.meta)
  end)

  it("DB kapalı → nil, err (exception yok)", function()
    reset_db({ down = true })
    local r, err = job.run_once()
    assert.is_nil(r)
    assert.truthy(err:find("connection refused"))
  end)
end)

describe("log_cleanup.tick", function()
  local real_should_run
  setup(function() real_should_run = job.should_run; job.should_run = function() return true end end)
  teardown(function() job.should_run = real_should_run end)
  before_each(function() ngx.shared.job_locks:flush_all() end)

  it("worker içi kilit tutuluyorsa çalışmaz", function()
    reset_db({ remaining = 10 })
    ngx.shared.job_locks:set("lock:log_cleanup", 999, 60)
    job.tick(false)
    assert.equal(10, db.remaining)
  end)

  it("kilit boşsa çalışır ve kilidi bırakır", function()
    reset_db({ remaining = 10 })
    job.tick(false)
    assert.equal(0, db.remaining)
    assert.is_nil(ngx.shared.job_locks:get("lock:log_cleanup"))
  end)

  it("premature tick hiçbir şey yapmaz", function()
    reset_db({ remaining = 10 })
    job.tick(true)
    assert.equal(10, db.remaining)
  end)
end)
