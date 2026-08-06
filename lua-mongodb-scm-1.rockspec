rockspec_format = "3.0"

package = "lua-mongodb"
version = "scm-1"

source = {
  url = "git+https://github.com/lua-mongodb/lua-mongodb.git",
}

description = {
  summary = "Pure-Lua MongoDB driver",
  detailed = [[
    A coroutine-aware MongoDB driver implemented in Lua without wrapping
    libmongoc. The project is pre-alpha and currently under development.
  ]],
  homepage = "https://github.com/lua-mongodb/lua-mongodb",
  license = "Apache-2.0",
}

dependencies = {
  "lua >= 5.4, < 5.5",
}

test_dependencies = {
  "busted == 2.3.0-1",
  "luacheck == 1.2.0-1",
}

build = {
  type = "builtin",
  modules = {
    mongodb = "src/mongodb/init.lua",
    ["mongodb.error"] = "src/mongodb/error.lua",
    ["mongodb.runtime_guard"] = "src/mongodb/runtime_guard.lua",
  },
}
