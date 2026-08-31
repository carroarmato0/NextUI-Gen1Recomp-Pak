-- Device diagnostic for Gen1Recomp.pak.
--
-- Everything that actually decides whether this pak works lives on the device:
-- whether LOVE can create a GLES context, what resolution it lands on, whether
-- OpenAL comes up, and what GUID the controller really reports. CI cannot see any
-- of it. This runs Section A of launch.sh and prints the answers in a form
-- scripts/verify-device.sh can grep, then quits on its own so a device with no
-- working input is not left stuck in it.
--
-- Keep the output keys stable: verify-device.sh matches on
--   "renderer:", "window:", "audio:", "joystick", "savedir:".

local TONE_SECONDS   = 3
local QUIT_AFTER     = 6
local elapsed        = 0
local tone

local function log(fmt, ...)
  -- print() so it lands in the launcher's redirected stdout, i.e. the pak log.
  print(string.format(fmt, ...))
  io.flush()
end

-- The SDL video driver is the single most useful thing for diagnosing a black
-- screen, and LOVE exposes no binding for it. LuaJIT's FFI can ask SDL directly.
-- Wrapped in pcall: on a build without FFI this must degrade to "unknown" rather
-- than take the whole diagnostic down with it.
local function sdlVideoDriver()
  local okffi, ffi = pcall(require, "ffi")
  if not okffi then return "unknown (no ffi)" end
  local okdef = pcall(ffi.cdef, "const char *SDL_GetCurrentVideoDriver(void);")
  if not okdef then return "unknown (cdef failed)" end
  local okcall, res = pcall(function()
    local p = ffi.C.SDL_GetCurrentVideoDriver()
    if p == nil then return "none" end
    return ffi.string(p)
  end)
  return okcall and res or "unknown (call failed)"
end

function love.load()
  log("=== smoke test ===")
  log("os:       %s", tostring(love.system.getOS()))
  log("love:     %d.%d.%d (%s)", love.getVersion())
  log("sdlvideo: %s", sdlVideoDriver())

  local w, h, flags = love.window.getMode()
  log("window:   %dx%d fullscreen=%s vsync=%s",
      w, h, tostring(flags.fullscreen), tostring(flags.vsync))
  log("desktop:  %dx%d", love.window.getDesktopDimensions())

  -- getRendererInfo returns name, version, vendor, device. On these handhelds the
  -- version string is what reveals whether we got GLES rather than desktop GL.
  local name, version, vendor, device = love.graphics.getRendererInfo()
  log("renderer: %s | %s | %s | %s",
      tostring(name), tostring(version), tostring(vendor), tostring(device))
  log("gles_env: LOVE_GRAPHICS_USE_OPENGLES=%s",
      tostring(os.getenv("LOVE_GRAPHICS_USE_OPENGLES")))

  -- Confirms launch.sh's XDG_DATA_HOME took effect. If this points inside the pak
  -- directory, a pak update would delete the player's saves.
  log("savedir:  %s", tostring(love.filesystem.getSaveDirectory()))

  local joys = love.joystick.getJoysticks()
  log("joysticks: %d", #joys)
  for i, j in ipairs(joys) do
    log("joystick %d: name=%q guid=%s gamepad=%s buttons=%d axes=%d",
        i, j:getName(), j:getGUID(), tostring(j:isGamepad()),
        j:getButtonCount(), j:getAxisCount())
  end
  if #joys == 0 then
    log("joystick: NONE DETECTED -- input will not work in the game either")
  end

  -- WHICH mapping actually won, which is the only thing that settles whether
  -- launch.sh's SDL_GAMECONTROLLERCONFIG does anything. The GUID a device
  -- reports is not the GUID a mapping has to carry: SDL 2.0.18+ stores a CRC16
  -- of the device name in bytes 2-3, and falls back to matching with that field
  -- zeroed -- so a mapping whose GUID looks different can still be the live one.
  -- Comparing the two GUIDs alone cannot tell you; comparing the mapping can.
  for i, j in ipairs(joys) do
    local ok, mapping = pcall(love.joystick.getGamepadMappingString, j:getGUID())
    if ok and mapping then
      log("mapping %d: %s", i, mapping)
    else
      log("mapping %d: NONE -- SDL has no gamepad mapping for this GUID", i)
    end
  end

  -- A sustained sine tone is the cheapest reliable way to hear XRUN underruns:
  -- they come through as clicks or crackle in a tone that should be featureless.
  local okAudio, err = pcall(function()
    local rate, seconds = 44100, TONE_SECONDS
    local data = love.sound.newSoundData(rate * seconds, rate, 16, 1)
    for i = 0, data:getSampleCount() - 1 do
      data:setSample(i, 0.35 * math.sin(2 * math.pi * 440 * (i / rate)))
    end
    tone = love.audio.newSource(data, "static")
    tone:play()
  end)
  if okAudio then
    log("audio: ok -- %ds 440 Hz tone playing; listen for pops or crackle", TONE_SECONDS)
  else
    log("audio: FAILED -- %s", tostring(err))
  end

  log("--- quitting automatically in %ds ---", QUIT_AFTER)
end

function love.update(dt)
  elapsed = elapsed + dt
  -- Self-quitting matters: MENU is not wired to quit in a LOVE app on NextUI, so
  -- a diagnostic that waited for input could trap a device whose pad is unmapped.
  if elapsed >= QUIT_AFTER then
    log("=== smoke test done ===")
    love.event.quit()
  end
end

function love.keypressed(key)
  if key == "escape" then love.event.quit() end
end

function love.gamepadpressed(_, button)
  log("gamepadpressed: %s", tostring(button))
end

function love.joystickpressed(_, button)
  -- Logged separately from gamepadpressed: if these fire but gamepadpressed does
  -- not, SDL saw the pad but our SDL_GAMECONTROLLERCONFIG mapping did not apply.
  log("joystickpressed: button %s", tostring(button))
end

function love.draw()
  local w, h = love.graphics.getDimensions()

  -- A moving shape proves frames are actually being presented. A static image
  -- cannot distinguish a live renderer from one frozen after a single frame.
  local x = (elapsed % 2) / 2 * (w - 120)
  love.graphics.setColor(0.2, 0.8, 0.4)
  love.graphics.rectangle("fill", x, h * 0.45, 120, 80)

  -- Corner markers: if the panel is cropped or offset, these are missing.
  love.graphics.setColor(1, 0.3, 0.3)
  for _, c in ipairs({ {0, 0}, {w - 24, 0}, {0, h - 24}, {w - 24, h - 24} }) do
    love.graphics.rectangle("fill", c[1], c[2], 24, 24)
  end

  love.graphics.setColor(1, 1, 1)
  local name, version = love.graphics.getRendererInfo()
  love.graphics.print(("%dx%d  %s"):format(w, h, tostring(version)), 32, 32)
  love.graphics.print(("fps %d   quitting in %.0fs")
    :format(love.timer.getFPS(), math.max(0, QUIT_AFTER - elapsed)), 32, 56)
  love.graphics.print("listen for a clean 440 Hz tone", 32, 80)
end
