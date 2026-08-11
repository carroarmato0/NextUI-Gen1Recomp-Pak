-- Deliberately minimal, and deliberately NOT a copy of Gen1Recomp's conf.lua.
-- The point of this diagnostic is to answer questions about the device, so it
-- must not itself depend on anything that could be the thing at fault.
function love.conf(t)
  t.identity = "gen1recomp-smoke"
  t.window.title = "Gen1Recomp pak smoke test"
  -- Ask for the same size Gen1Recomp asks for, so the reported window size tells
  -- us how the vendor SDL2 treats a windowed request with no window manager.
  t.window.width = 1024
  t.window.height = 768
  t.window.resizable = true
  t.window.vsync = 1
  t.modules.joystick = true
  t.modules.physics = false
  t.version = "11.5"
end
