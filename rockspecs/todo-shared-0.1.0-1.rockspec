package = "todo-shared"
version = "0.1.0-1"
source = { url = "git+file:///dev/null" }
description = {
  summary = "Todo uygulaması ortak tipler, doğrulama ve protokol",
  license = "MIT",
}
dependencies = { "lua >= 5.1, < 5.5" }
build = {
  type = "builtin",
  modules = {
    ["todo_shared.types"] = "shared/src/types.lua",
    ["todo_shared.validation"] = "shared/src/validation.lua",
    ["todo_shared.protocol"] = "shared/src/protocol.lua",
  },
}
