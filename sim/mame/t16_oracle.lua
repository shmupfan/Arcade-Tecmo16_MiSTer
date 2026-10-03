-- Tecmo 16 (Final Star Force / Riot / Ganbare Ginkun) MAME oracle: write
-- logs plus per-frame state dumps (PLAN M0.4).
--
-- Usage (normally via sim/Makefile, which calls sim/mame/run_mame.sh):
--   DUMP_DIR=<outdir> DUMP_FRAMES=<list> TOTAL=<n> \
--     sim/mame/run_mame.sh <set> sim/mame/t16_oracle.lua
--
-- Environment:
--   DUMP_DIR     output directory (default sim/mame/out/<set>)
--   DUMP_FRAMES  comma list of frames and ranges "a-b" or "a-b/step" to dump
--   TOTAL        last frame of the run (default: last dump frame)
--   NO_SNAP      1 = skip snap.png
--   HEAVY_LOG    1 = log every palette/sprite/tile RAM write row by row
--                (default: per-frame per-class summaries only)
--   VISLOG       1 = write vislog.csv: every tile RAM, palette, scroll and
--                flip write made during the visible scan (lines 16-239) of
--                a frame in DUMP_FRAMES, with the word's value before the
--                write (M1 mid-scan replay, sim/m1/midscan.py)
--   NO_DUMP      1 = do not write frame dumps (use with VISLOG to log a
--                capture that already has its dumps)
--   MAINRAM      1 = for every frame in DUMP_FRAMES write ram/NNNNNN.main (main
--                RAM 0x100000-0x103fff), .work (Final Star Force work RAM
--                0x122000-0x127fff, Riot/Ginkun extra RAM 0x124000-0x124fff)
--                and .snd (sound RAM 0xf000-0xfbff then 0xfffe-0xffff), and
--                reads.csv: every main CPU read of 0x150020-0x150051 and
--                0x160000-0x16001f with the value MAME returned (M2)
--   STACKLOW     1 = record the lowest 68000 SP seen at any main RAM write
--                (summary.txt "stack low-water")
--   INPUTS       "frame:PORT:Field name:value;..." input events
--   FIELDS       "PORT:Field name:value;..." DIP user values at start
--
-- Frame numbering (as in the Dooyong and 1945k III oracles): the frame
-- notifier runs inside screen vblank_begin, after MAME has rendered the
-- frame and before the vblank callbacks (IRQ5 assert and
-- tecmo16_state::screen_vblank, tecmo16.cpp:684-685). Frame N = the N-th
-- notifier call. The driver never forces a partial update, so the tile
-- RAM, palette, scroll and flip state read here are exactly what MAME
-- rendered frame N from.
--
-- Sprites lag two frames (tecmo16.cpp:330-341): at vblank N-1 the sprite
-- bitmap is drawn from the buffered sprite RAM and then the buffer is
-- refreshed from the live RAM. Frame N therefore shows the buffer as it
-- stood at notifier N-1 (spr_buf_prev.bin), which held the live RAM of
-- vblank N-2. spr_buf.bin (buffer at notifier N) and spr_live.bin are
-- dumped too, so the lag is checked rather than assumed.
--
-- Beam position of a write: screen:time_until_pos (MAME 0.288 Lua has no
-- screen:vpos()), in MAME's 256 x 256 geometry (visible lines 16-239,
-- tecmo16.cpp:681-682). scan_frame = the frame whose scan-out (or the
-- vblank after it) the write falls in.
--
-- Byte order of every .bin written here: 16-bit values high byte first.
-- All tap and notifier handles are pinned in _G.

local m = manager.machine
local setname = emu.romname()
local outdir = os.getenv("DUMP_DIR") or ("sim/mame/out/" .. setname)
os.execute("mkdir -p '" .. outdir .. "'")

local function parse_frames(s)
  local t, maxf = {}, 0
  for tok in string.gmatch(s or "", "([^,]+)") do
    local a, b, st = tok:match("^(%d+)-(%d+)/(%d+)$")
    if not a then a, b = tok:match("^(%d+)-(%d+)$"); st = 1 end
    if a then
      for f = tonumber(a), tonumber(b), tonumber(st) do t[f] = true; if f > maxf then maxf = f end end
    elseif tonumber(tok) then
      t[tonumber(tok)] = true; if tonumber(tok) > maxf then maxf = tonumber(tok) end
    end
  end
  return t, maxf
end

local dump_frames, maxdump = parse_frames(os.getenv("DUMP_FRAMES") or "")
local no_snap = os.getenv("NO_SNAP") == "1"
local total = tonumber(os.getenv("TOTAL") or "0")
if total == 0 then total = maxdump end
if total == 0 then total = 600 end
local heavy = os.getenv("HEAVY_LOG") == "1"
local vislog_on = os.getenv("VISLOG") == "1"
local no_dump = os.getenv("NO_DUMP") == "1"

local MACHINE = {
  fstarfrc = "base", fstarfrcj = "base", fstarfrcja = "base", fstarfrcw = "base",
  ginkun = "ginkun", riot = "riot", riotw = "riot",
}
local machine_name = MACHINE[setname]
assert(machine_name, "unknown set " .. setname)

local main = m.devices[":maincpu"].spaces["program"]
local sndsp = m.devices[":audiocpu"].spaces["program"]
local mainram_on = os.getenv("MAINRAM") == "1"
local screen = m.screens[":screen"]

---------------------------------------------------------------------------
-- items
---------------------------------------------------------------------------
local function item_of(tag, name)
  local d = m.devices[tag]
  if not d then return nil end
  local idx = d.items[name]
  if not idx then return nil end
  return emu.item(idx)
end

local it_sprbuf = assert(item_of(":spriteram", "0/m_buffered"))
local it_scx = assert(item_of(":", "0/m_scroll_x"))
local it_scy = assert(item_of(":", "0/m_scroll_y"))
local it_ccx = assert(item_of(":", "0/m_scroll_char_x"))
local it_ccy = assert(item_of(":", "0/m_scroll_char_y"))
local it_flipx = assert(item_of(":", "0/m_flip_screen_x"))
local it_flipy = assert(item_of(":", "0/m_flip_screen_y"))
local it_vmaxy = assert(item_of(":screen", "0/m_visarea.max_y"))
local it_vminy = assert(item_of(":screen", "0/m_visarea.min_y"))

---------------------------------------------------------------------------
-- timing
---------------------------------------------------------------------------
local FRAME_S = screen.frame_period
local LINE_S = screen.scan_period
local PIX_S = screen.pixel_period
local VTOTAL = math.floor(FRAME_S / LINE_S + 0.5)
local HTOTAL = math.floor(LINE_S / PIX_S + 0.5)
local VB_LINE = it_vmaxy:read(0) + 1     -- first line after the visible area (240)
local VIS_MIN = it_vminy:read(0)         -- first visible line (16)
local frame = 0

local function beam()
  local pos = FRAME_S - screen:time_until_pos(0, 0)
  local line = math.floor(pos / LINE_S + 1e-6)
  if line > VTOTAL - 1 then line = VTOTAL - 1 end
  local hpos = math.floor((pos - line * LINE_S) / PIX_S + 1e-6)
  if hpos < 0 then hpos = 0 end
  local scan = (line >= VB_LINE) and frame or (frame + 1)
  return line, hpos, scan
end

---------------------------------------------------------------------------
-- logs
---------------------------------------------------------------------------
local wlog = assert(io.open(outdir .. "/writes.csv", "w"))
wlog:write("frame,line,hpos,scan_frame,visible,class,addr,data,mask\n")
local hits = {}
local summ = {}
local sumlog = assert(io.open(outdir .. "/heavy_summary.csv", "w"))
sumlog:write("frame,class,count,visible_count,first_line,last_line\n")

local function is_visible(line) return line >= VIS_MIN and line < VB_LINE end

local function logw(class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  wlog:write(string.format("%d,%d,%d,%d,%d,%s,%06x,%x,%x\n",
    frame, line, hpos, scan, is_visible(line) and 1 or 0, class, addr, data, mask or 0))
end

local function heavyw(class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  local vis = is_visible(line)
  local s = summ[class]
  if not s then s = { n = 0, v = 0, first = nil, last = nil }; summ[class] = s end
  s.n = s.n + 1
  if vis then s.v = s.v + 1 end
  if not s.first then s.first = line end
  s.last = line
  if heavy then
    wlog:write(string.format("%d,%d,%d,%d,%d,%s,%06x,%x,%x\n",
      frame, line, hpos, scan, vis and 1 or 0, class, addr, data, mask or 0))
  end
end

-- VISLOG: one row per write in the visible scan of a dumped frame.
-- old = the 16-bit word (RAM) or register value before the write; for
-- scroll_char_y also whether it had ever been written (spec 7: the -16
-- text offset applies from the first write on).
local vlog = nil
if vislog_on then
  vlog = assert(io.open(outdir .. "/vislog.csv", "w"))
  vlog:write("scan_frame,line,hpos,class,addr,data,mask,old,old_written\n")
end
local function visw(class, addr, data, mask, oldfn)
  if not vlog then return end
  local line, hpos, scan = beam()
  if not (is_visible(line) and dump_frames[scan]) then return end
  local old, ow = oldfn()
  vlog:write(string.format("%d,%d,%d,%s,%06x,%x,%x,%x,%d\n",
    scan, line, hpos, class, addr, data, mask or 0xffff, old, ow or 0))
end
local function ram_old(addr) return function() return main:read_u16(addr & 0xfffffe), 0 end end

_G._t16_taps = {}
local function tap(lo, hi, name, fn)
  local h = main:install_write_tap(lo, hi, name, function(offset, data, mask)
    fn(offset, data, mask)
  end)
  table.insert(_G._t16_taps, h)
end
local function rtap(lo, hi, name)
  local h = main:install_read_tap(lo, hi, name, function(offset, data, mask)
    hits[name] = (hits[name] or 0) + 1
  end)
  table.insert(_G._t16_taps, h)
end

-- video and system registers (tecmo16.cpp:378-390)
local REG = {
  [0x160000] = "scroll_char_x", [0x160006] = "scroll_char_y",
  [0x16000c] = "fg_scroll_x", [0x160012] = "fg_scroll_y",
  [0x160018] = "bg_scroll_x", [0x16001e] = "bg_scroll_y",
}
local VREG_ITEM = {
  [0x160000] = function() return it_ccx:read(0) end,
  [0x160006] = function() return it_ccy:read(0) end,
  [0x16000c] = function() return it_scx:read(0) end,
  [0x160012] = function() return it_scy:read(0) end,
  [0x160018] = function() return it_scx:read(1) end,
  [0x16001e] = function() return it_scy:read(1) end,
}
tap(0x160000, 0x16001f, "vreg", function(o, d, mk)
  local name = REG[o & 0xfffffe] or string.format("vreg_%06x", o)
  local itf = VREG_ITEM[o & 0xfffffe]
  if itf then
    visw(name, o, d, mk, function()
      return itf() & 0xffff, ((hits["scroll_char_y"] or 0) > 0) and 1 or 0
    end)
  end
  logw(name, o, d, mk)
end)
tap(0x150000, 0x150001, "flip", function(o, d, mk)
  visw("flip", o, d, mk, function() return it_flipx:read(0), 0 end)
  logw("flip", o, d, mk)
end)
tap(0x150010, 0x150011, "soundlatch", function(o, d, mk) logw("soundlatch", o, d, mk) end)
tap(0x150020, 0x150021, "irq_150021", function(o, d, mk) logw("irq_150021", o, d, mk) end)
tap(0x150030, 0x150031, "irq_150031", function(o, d, mk) logw("irq_150031", o, d, mk) end)
tap(0x150040, 0x15005f, "sys_other", function(o, d, mk) logw("sys_other", o, d, mk) end)
tap(0x000000, 0x07ffff, "romw", function(o, d, mk) logw("romw", o, d, mk) end)
rtap(0x160000, 0x16001f, "vreg_read")

-- STACKLOW=1: the lowest 68000 stack pointer seen at any main RAM write
-- (the stack's low-water mark), written to summary.txt (M2: RAM below the
-- stack pointer at a notifier is dead stack, not game state)
local stack_low = 0x1000000
if os.getenv("STACKLOW") == "1" then
  local spst = m.devices[":maincpu"].state["SP"]
  local h = main:install_write_tap(0x100000, 0x103fff, "stacklow", function(offset, data, mask)
    local sp = spst.value
    if sp < stack_low then stack_low = sp end
  end)
  table.insert(_G._t16_taps, h)
end

local rlog = nil
if mainram_on then
  rlog = assert(io.open(outdir .. "/reads.csv", "w"))
  rlog:write("frame,line,hpos,addr,data,mask\n")
  local function rl(lo, hi, name)
    local h = main:install_read_tap(lo, hi, name, function(offset, data, mask)
      local line, hpos = beam()
      rlog:write(string.format("%d,%d,%d,%06x,%x,%x\n", frame, line, hpos, offset, data, mask))
    end)
    table.insert(_G._t16_taps, h)
  end
  rl(0x150020, 0x150051, "rlog_io")
  rl(0x160000, 0x16001f, "rlog_vreg")
end

-- palette entries written since power-on (BLACK palette at start,
-- tecmo16.cpp:688)
local pal_written = {}
tap(0x140000, 0x141fff, "pal", function(o, d, mk)
  visw("pal", o, d, mk, ram_old(o))
  pal_written[(o - 0x140000) >> 1] = true
  heavyw("pal", o, d, mk)
end)
tap(0x130000, 0x130fff, "spr", function(o, d, mk) heavyw("spr", o, d, mk) end)
tap(0x110000, 0x110fff, "charram", function(o, d, mk) visw("charram", o, d, mk, ram_old(o)); heavyw("charram", o, d, mk) end)
if machine_name == "base" then
  -- fstarfrc_map (tecmo16.cpp:395-405)
  tap(0x120000, 0x1207ff, "fgvram", function(o, d, mk) visw("fgvram", o, d, mk, ram_old(o)); heavyw("fgvram", o, d, mk) end)
  tap(0x120800, 0x120fff, "fgcram", function(o, d, mk) visw("fgcram", o, d, mk, ram_old(o)); heavyw("fgcram", o, d, mk) end)
  tap(0x121000, 0x1217ff, "bgvram", function(o, d, mk) visw("bgvram", o, d, mk, ram_old(o)); heavyw("bgvram", o, d, mk) end)
  tap(0x121800, 0x121fff, "bgcram", function(o, d, mk) visw("bgcram", o, d, mk, ram_old(o)); heavyw("bgcram", o, d, mk) end)
else
  -- ginkun_map (tecmo16.cpp:407-417)
  tap(0x120000, 0x120fff, "fgvram", function(o, d, mk) visw("fgvram", o, d, mk, ram_old(o)); heavyw("fgvram", o, d, mk) end)
  tap(0x121000, 0x121fff, "fgcram", function(o, d, mk) visw("fgcram", o, d, mk, ram_old(o)); heavyw("fgcram", o, d, mk) end)
  tap(0x122000, 0x122fff, "bgvram", function(o, d, mk) visw("bgvram", o, d, mk, ram_old(o)); heavyw("bgvram", o, d, mk) end)
  tap(0x123000, 0x123fff, "bgcram", function(o, d, mk) visw("bgcram", o, d, mk, ram_old(o)); heavyw("bgcram", o, d, mk) end)
  tap(0x124000, 0x124fff, "extra124", function(o, d, mk) heavyw("extra124", o, d, mk) end)
end

---------------------------------------------------------------------------
-- state dump
---------------------------------------------------------------------------
local function item_bytes(it)
  local parts = {}
  local char = string.char
  for i = 0, it.count - 1 do
    local v = it:read(i)
    if it.size == 1 then parts[#parts + 1] = char(v & 0xff)
    else parts[#parts + 1] = char((v >> 8) & 0xff, v & 0xff) end
  end
  return table.concat(parts)
end

local function share_bytes(tag)
  local s = m.memory.shares[tag]
  local parts = {}
  local char = string.char
  for a = 0, s.size - 1, 2 do
    local v = s:read_u16(a)
    parts[#parts + 1] = char(v >> 8, v & 0xff)
  end
  return table.concat(parts)
end

local function wfile(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function space_words(sp, lo, hi)
  local parts = {}
  local char = string.char
  for a = lo, hi, 2 do
    local v = sp:read_u16(a)
    parts[#parts + 1] = char(v >> 8, v & 0xff)
  end
  return table.concat(parts)
end
local function space_bytes(sp, lo, hi)
  local parts = {}
  local char = string.char
  for a = lo, hi do parts[#parts + 1] = char(sp:read_u8(a)) end
  return table.concat(parts)
end
local function dump_ram(n)
  local d = outdir .. "/ram"
  os.execute("mkdir -p '" .. d .. "'")
  local b = string.format("%s/%06d", d, n)
  wfile(b .. ".main", space_words(main, 0x100000, 0x103fff))
  if machine_name == "base" then
    wfile(b .. ".work", space_words(main, 0x122000, 0x127fff))
  else
    wfile(b .. ".work", space_words(main, 0x124000, 0x124fff))
  end
  wfile(b .. ".snd", space_bytes(sndsp, 0xf000, 0xfbff) .. space_bytes(sndsp, 0xfffe, 0xffff))
  local st = m.devices[":maincpu"].state
  wfile(b .. ".cpu", string.format("%x %x %x\n", st["SP"].value, st["PC"].value, st["SR"].value))
end

local pending_pixels = nil
local prev_sprbuf = string.rep("\0", 4096)

local function dump_frame(n, cur_sprbuf)
  local d = string.format("%s/frames/%06d", outdir, n)
  os.execute("mkdir -p '" .. d .. "'")
  pending_pixels = d
  wfile(d .. "/palette.bin", share_bytes(":palette"))
  local pal = m.palettes[":palette"]
  local pw, pc = {}, {}
  for i = 0, pal.entries - 1 do
    pw[#pw + 1] = string.char(pal_written[i] and 1 or 0)
    local c = pal:pen_color(i)
    pc[#pc + 1] = string.char(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, (c >> 24) & 0xff)
  end
  wfile(d .. "/palette_written.bin", table.concat(pw))
  wfile(d .. "/pens.bin", table.concat(pc))
  wfile(d .. "/fgvram.bin", share_bytes(":videoram1"))
  wfile(d .. "/fgcram.bin", share_bytes(":colorram1"))
  wfile(d .. "/bgvram.bin", share_bytes(":videoram2"))
  wfile(d .. "/bgcram.bin", share_bytes(":colorram2"))
  wfile(d .. "/charram.bin", share_bytes(":charram"))
  wfile(d .. "/spr_live.bin", share_bytes(":spriteram"))
  wfile(d .. "/spr_buf.bin", cur_sprbuf)
  wfile(d .. "/spr_buf_prev.bin", prev_sprbuf)
  local js = {}
  js[#js + 1] = string.format('  "set": "%s"', setname)
  js[#js + 1] = string.format('  "machine": "%s"', machine_name)
  js[#js + 1] = string.format('  "frame": %d', n)
  js[#js + 1] = string.format('  "width": %d', screen.width)
  js[#js + 1] = string.format('  "height": %d', screen.height)
  js[#js + 1] = string.format('  "vis_min_y": %d', VIS_MIN)
  js[#js + 1] = string.format('  "htotal": %d', HTOTAL)
  js[#js + 1] = string.format('  "vtotal": %d', VTOTAL)
  js[#js + 1] = string.format('  "fg_scroll_x": %d', it_scx:read(0))
  js[#js + 1] = string.format('  "bg_scroll_x": %d', it_scx:read(1))
  js[#js + 1] = string.format('  "fg_scroll_y": %d', it_scy:read(0))
  js[#js + 1] = string.format('  "bg_scroll_y": %d', it_scy:read(1))
  js[#js + 1] = string.format('  "char_scroll_x": %d', it_ccx:read(0))
  js[#js + 1] = string.format('  "char_scroll_y": %d', it_ccy:read(0))
  js[#js + 1] = string.format('  "char_y_written": %s', (hits["scroll_char_y"] or 0) > 0 and "true" or "false")
  js[#js + 1] = string.format('  "flip_x": %d', it_flipx:read(0))
  js[#js + 1] = string.format('  "flip_y": %d', it_flipy:read(0))
  wfile(d .. "/state.json", "{\n" .. table.concat(js, ",\n") .. "\n}\n")
  if not no_snap then screen:snapshot(d .. "/snap.png") end
end

---------------------------------------------------------------------------
-- per-frame trace (every frame)
---------------------------------------------------------------------------
local ftrace = assert(io.open(outdir .. "/frames.csv", "w"))
ftrace:write("frame,fg_sx,fg_sy,bg_sx,bg_sy,ch_sx,ch_sy,flip,irq31,irq21,sprbuf_changed\n")
local irq31_frame, irq21_frame = 0, 0
tap(0x150020, 0x150021, "irq21_count", function() irq21_frame = irq21_frame + 1 end)
tap(0x150030, 0x150031, "irq31_count", function() irq31_frame = irq31_frame + 1 end)

---------------------------------------------------------------------------
-- inputs and DIP fields
---------------------------------------------------------------------------
local events = {}
for tok in string.gmatch(os.getenv("INPUTS") or "", "([^;]+)") do
  local f, port, field, val = tok:match("^%s*(%d+):([^:]+):([^:]+):(%d+)%s*$")
  if f then
    local ev = events[tonumber(f)] or {}
    ev[#ev + 1] = { port, field, tonumber(val) }
    events[tonumber(f)] = ev
  end
end
local ilog = assert(io.open(outdir .. "/inputs.csv", "w"))
ilog:write("frame,port,field,value\n")
local function field_of(port, name)
  local p = m.ioport.ports[":" .. port]
  assert(p, "no port " .. port)
  local fl = p.fields[name]
  assert(fl, "no field '" .. name .. "' in " .. port)
  return fl
end
for tok in string.gmatch(os.getenv("FIELDS") or "", "([^;]+)") do
  local port, field, val = tok:match("^%s*([^:]+):([^:]+):(%d+)%s*$")
  if port then
    field_of(port, field).user_value = tonumber(val)
    ilog:write(string.format("0,%s,%s,user_value=%s\n", port, field, val))
  end
end

---------------------------------------------------------------------------
-- frame notifier
---------------------------------------------------------------------------
local vpos_check = "not checked"
_G._t16_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 2 then
    local l, h = beam()
    vpos_check = string.format("beam at notifier: line %d hpos %d (expected %d, 0); visible %dx%d from line %d; total %dx%d; screen frame_number %d at notifier %d",
      l, h, VB_LINE, screen.width, screen.height, VIS_MIN, HTOTAL, VTOTAL, screen:frame_number(), frame)
  end
  for class, s in pairs(summ) do
    sumlog:write(string.format("%d,%s,%d,%d,%d,%d\n", frame - 1, class, s.n, s.v, s.first, s.last))
  end
  summ = {}
  local cur = item_bytes(it_sprbuf)
  ftrace:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", frame,
    it_scx:read(0), it_scy:read(0), it_scx:read(1), it_scy:read(1), it_ccx:read(0), it_ccy:read(0),
    it_flipx:read(0), irq31_frame, irq21_frame, (cur ~= prev_sprbuf) and 1 or 0))
  irq31_frame, irq21_frame = 0, 0
  if pending_pixels then
    wfile(pending_pixels .. "/screen.argb", (screen:pixels()))
    wfile(pending_pixels .. "/palette_next.bin", share_bytes(":palette"))
    pending_pixels = nil
  end
  if dump_frames[frame] and not no_dump then dump_frame(frame, cur) end
  if dump_frames[frame] and mainram_on then dump_ram(frame) end
  prev_sprbuf = cur
  local ev = events[frame]
  if ev then
    for _, e in ipairs(ev) do
      field_of(e[1], e[2]):set_value(e[3])
      ilog:write(string.format("%d,%s,%s,%d\n", frame, e[1], e[2], e[3]))
    end
  end
  if frame > total then
    wlog:close(); sumlog:close(); ftrace:close(); ilog:close()
    if vlog then vlog:close() end
    if rlog then rlog:close() end
    local s = assert(io.open(outdir .. "/summary.txt", "w"))
    s:write(string.format("set %s machine %s frames %d\n", setname, machine_name, frame))
    s:write(vpos_check .. "\n")
    local keys = {}
    for k in pairs(hits) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do s:write(string.format("tap %s hits %d\n", k, hits[k])) end
    s:write(string.format("taps installed %d\n", #_G._t16_taps))
    if stack_low < 0x1000000 then s:write(string.format("stack low-water %06x\n", stack_low)) end
    s:close()
    m:exit()
  end
end)

print(string.format("t16_oracle: %s (%s) total %d frames -> %s", setname, machine_name, total, outdir))
