-- Tüm Lua kaynakları için ortak lint kuralları
std = "ngx_lua"
max_line_length = 120
codes = true
exclude_files = { "lua_modules/", ".luarocks/", "web/node_modules/" }

-- Shared kod hem LuaJIT hem Lua 5.4'te çalışır: sadece ortak alt küme
files["shared/src/"] = { std = "lua51+lua54" }
-- Frontend Wasmoon (Lua 5.4) + JS köprüsü global'i
files["web/src/"] = { std = "lua54", read_globals = { "js" } }
-- busted spec dosyaları
files["**/spec/"] = { std = "+busted" }
-- wrk betikleri: wrk global'i ve callback'ler (request/response/done) wrk tarafından okunur
files["api/bench/"] = { std = "lua51", globals = { "wrk", "request", "response", "done", "init", "setup" } }
