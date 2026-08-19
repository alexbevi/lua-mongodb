-- luacheck: globals love

function love.conf(t)
  t.identity = "lua-mongodb-pong"
  t.version = "11.5"
  t.console = false
  t.window.title = "MongoDB Change Stream Pong"
  t.window.width = 800
  t.window.height = 600
  t.window.resizable = false
  t.window.vsync = 1
end
