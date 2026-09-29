-- spectral_note.lua
-- 8-band dynamics visualizer & MIDI Note velocity sender
--
-- PAGE 1: Master Stereo In/Out Level Monitor
-- PAGE 2: 8-Band Strips UI
--
-- MIDI NOTES: 36 - 43 (Bands 1 to 8)
-- Velocity represents band peak/attack amplitude (1 - 127)
--
-- CONTROLS:
-- K3: Switch Page (1 <-> 2)
-- K2: Switch E2 Mode (Attack <-> Gain)
-- E1: Select Band (1 - 8)
-- E2: Adjust Attack (ms) OR Gain
-- E3: Adjust Decay (s)

engine.name = 'SpectralNote'

local midi_out
local midi_channel = 1
local base_note = 36 -- Note 36 (C2) through 43 (G2)

local page = 2
local e2_mode = 1 -- 1 = Attack, 2 = Gain
local sel_band = 1

local num_bands = 8
local freqs = { 60, 132, 290, 639, 1405, 3091, 6801, 14962 }
local note_names = { "C2", "C#2", "D2", "D#2", "E2", "F2", "F#2", "G2" }

local band_amps = { 0, 0, 0, 0, 0, 0, 0, 0 }
local band_peaks = { 0, 0, 0, 0, 0, 0, 0, 0 }

-- MIDI Note Trigger State Machine per band
local note_active = { false, false, false, false, false, false, false, false }
local prev_amps = { 0, 0, 0, 0, 0, 0, 0, 0 }
local note_hold_timer = { 0, 0, 0, 0, 0, 0, 0, 0 }

local trig_threshold = 0.08  -- Minimum amplitude to register a note strike
local release_threshold = 0.04 -- Amplitude below which note turns off
local min_hold_ticks = 3      -- Hold at least ~100ms to avoid micro-clicks

local atks = {}
local dcys = {}
local gains = { 1.0, 1.0, 0.7, 0.6, 0.6, 0.7, 1.0, 1.0 }

for i = 1, num_bands do
  atks[i] = math.max(0.001, 0.015 - ((i - 1) * 0.0016))
  dcys[i] = math.max(0.01, 0.18 - ((i - 1) * 0.02))
end

local poll_l, poll_r
local master_l, master_r = 0, 0
local peak_l, peak_r = 0, 0

local function amp_to_norm_db(amp)
  if amp == nil or amp <= 0.001 then return 0 end
  local db = 20 * math.log10(amp)
  return util.clamp(util.linlin(-60, 0, 0, 1, db), 0, 1)
end

local function all_notes_off()
  if midi_out then
    for i = 1, num_bands do
      if note_active[i] then
        midi_out:note_off(base_note + (i - 1), 0, midi_channel)
        note_active[i] = false
      end
    end
  end
end

function init()
  midi_out = midi.connect(1)

  params:add_group("8-BAND DYNAMICS", 28)
  params:add_control("master_gain", "Master Gain", controlspec.new(0.1, 10.0, "exp", 0.01, 2.0))
  params:set_action("master_gain", function(val) engine.setMasterGain(val) end)

  params:add_control("trig_thresh", "Trig Threshold", controlspec.new(0.01, 0.5, "lin", 0.01, 0.08))
  params:set_action("trig_thresh", function(val) trig_threshold = val end)

  params:add_number("midi_chan", "MIDI Channel", 1, 16, 1)
  params:set_action("midi_chan", function(val)
    all_notes_off()
    midi_channel = val
  end)

  for i = 1, num_bands do
    params:add_control("atk_" .. i, "Band " .. i .. " Atk", controlspec.new(0.001, 0.75, "exp", 0.001, atks[i], "s"))
    params:set_action("atk_" .. i, function(v) atks[i] = v; engine.setAtk(i, v) end)

    params:add_control("dcy_" .. i, "Band " .. i .. " Dcy", controlspec.new(0.01, 3.0, "exp", 0.01, dcys[i], "s"))
    params:set_action("dcy_" .. i, function(v) dcys[i] = v; engine.setDcy(i, v) end)

    params:add_control("gain_" .. i, "Band " .. i .. " Gain", controlspec.new(0.01, 2.5, "lin", 0.01, gains[i]))
    params:set_action("gain_" .. i, function(v) gains[i] = v; engine.setBandGain(i, v) end)
  end

  -- OSC listener receives 8-band amps from SuperCollider
  osc.event = function(path, args, from)
    if path == "/bandAmps" then
      for i = 1, num_bands do
        local amp = util.clamp(args[i] or 0.0, 0.0, 1.0)
        band_amps[i] = amp
        if amp > band_peaks[i] then band_peaks[i] = amp end

        local note_num = base_note + (i - 1)

        -- Dynamic Strike / Velocity Calculation
        -- Detect rising transient above threshold
        if amp > trig_threshold and (amp - prev_amps[i]) > 0.03 and not note_active[i] then
          -- Convert normalized amplitude (0.0 - 1.0) to MIDI Velocity (1 - 127)
          local vel = util.clamp(math.floor(amp * 127), 1, 127)
          if midi_out then
            midi_out:note_on(note_num, vel, midi_channel)
          end
          note_active[i] = true
          note_hold_timer[i] = min_hold_ticks

        elseif note_active[i] then
          -- Decrement minimum hold duration
          if note_hold_timer[i] > 0 then
            note_hold_timer[i] = note_hold_timer[i] - 1
          end

          -- Turn note off once below release threshold and hold timer has passed
          if note_hold_timer[i] == 0 and amp < release_threshold then
            if midi_out then
              midi_out:note_off(note_num, 0, midi_channel)
            end
            note_active[i] = false
          end
        end

        prev_amps[i] = amp
      end
    end
  end

  -- Stereo polls for Page 1
  poll_l = poll.set("sc_amp_l")
  poll_l.time = 1 / 30
  poll_l.callback = function(val)
    master_l = master_l * 0.7 + amp_to_norm_db(val) * 0.3
    if master_l > peak_l then peak_l = master_l end
  end
  poll_l:start()

  poll_r = poll.set("sc_amp_r")
  poll_r.time = 1 / 30
  poll_r.callback = function(val)
    master_r = master_r * 0.7 + amp_to_norm_db(val) * 0.3
    if master_r > peak_r then peak_r = master_r end
  end
  poll_r:start()

  -- UI refresh loop (30 fps)
  metro.init(function()
    peak_l = math.max(master_l, peak_l - 0.005)
    peak_r = math.max(master_r, peak_r - 0.005)
    for i = 1, num_bands do
      band_peaks[i] = math.max(band_amps[i], band_peaks[i] - 0.008)
    end
    redraw()
  end, 1 / 30):start()
end

function key(n, z)
  if z == 1 then
    if n == 3 then
      page = (page == 1) and 2 or 1
    elseif n == 2 then
      e2_mode = (e2_mode == 1) and 2 or 1
    end
  end
end

function enc(n, d)
  if page == 2 then
    if n == 1 then
      sel_band = util.clamp(sel_band + d, 1, num_bands)
    elseif n == 2 then
      if e2_mode == 1 then
        params:delta("atk_" .. sel_band, d)
      else
        params:delta("gain_" .. sel_band, d)
      end
    elseif n == 3 then
      params:delta("dcy_" .. sel_band, d)
    end
  elseif page == 1 then
    if n == 2 then
      params:delta("master_gain", d)
    end
  end
end

local function draw_page_1()
  screen.level(3)
  screen.move(4, 10)
  screen.text("MASTER STEREO LEVEL")
  screen.move(78, 10)
  screen.text("K3 -> BANDS")

  local function draw_bar(label, y, val, peak)
    screen.level(4)
    screen.move(4, y + 7)
    screen.text(label)

    local bx, bw, bh = 18, 104, 10
    screen.level(2)
    screen.rect(bx, y, bw, bh)
    screen.stroke()

    local fill = math.floor(val * (bw - 2))
    if fill > 0 then
      screen.level(fill > (bw * 0.85) and 15 or 8)
      screen.rect(bx + 1, y + 1, fill, bh - 2)
      screen.fill()
    end

    local px = math.floor(bx + 1 + peak * (bw - 3))
    if px >= bx + 1 then
      screen.level(15)
      screen.move(px, y)
      screen.line(px, y + bh - 1)
      screen.stroke()
    end
  end

  draw_bar("L", 18, master_l, peak_l)
  draw_bar("R", 32, master_r, peak_r)

  screen.level(3)
  screen.move(4, 52)
  screen.text(string.format("E2: Master Gain (%.2f)", params:get("master_gain")))
  screen.move(4, 62)
  screen.text(string.format("MIDI Ch:%d | Notes: 36-43 (C2-G2)", midi_channel))
end

local function draw_page_2()
  -- Header
  local active_note_str = string.format("B%d: %s (#%d)", sel_band, note_names[sel_band], base_note + sel_band - 1)
  screen.level(3)
  screen.move(2, 7)
  screen.text(active_note_str)

  screen.level(15)
  screen.move(96, 7)
  screen.text(e2_mode == 1 and "[ATK]" or "[GAIN]")

  -- 8 Strips
  local col_w = 14
  local meter_h = 32

  for i = 1, num_bands do
    local x = (i - 1) * 16 + 2

    -- Highlight selected channel background
    if i == sel_band then
      screen.level(2)
      screen.rect(x - 1, 9, col_w, meter_h + 8)
      screen.fill()
    end

    -- Meter Frame (glows brighter when MIDI note is firing)
    screen.level(note_active[i] and 15 or (i == sel_band and 6 or 2))
    screen.rect(x + 2, 11, 8, meter_h)
    screen.stroke()

    -- Active Level fill
    local fill_h = math.floor(band_amps[i] * (meter_h - 2))
    if fill_h > 0 then
      screen.level(note_active[i] and 15 or 7)
      screen.rect(x + 3, 11 + (meter_h - 2 - fill_h), 6, fill_h)
      screen.fill()
    end

    -- Peak Hold Mark
    local py = 11 + math.floor((1 - band_peaks[i]) * (meter_h - 2))
    screen.level(12)
    screen.move(x + 2, py)
    screen.line(x + 9, py)
    screen.stroke()

    -- Note Trigger indicator dot below strip
    if note_active[i] then
      screen.level(15)
      screen.rect(x + 4, 46, 4, 2)
      screen.fill()
    end

    -- Band number label
    screen.level(i == sel_band and 15 or 3)
    screen.move(x + 4, 55)
    screen.text(tostring(i))
  end

  -- Dynamic Footer controls
  screen.level(2)
  screen.move(2, 63)
  if e2_mode == 1 then
    screen.text(string.format("A:%.3fs D:%.2fs (K2:Gain)", atks[sel_band], dcys[sel_band]))
  else
    screen.text(string.format("G:%.2f  D:%.2fs (K2:Atk)", gains[sel_band], dcys[sel_band]))
  end
end

function redraw()
  screen.clear()
  if page == 1 then
    draw_page_1()
  else
    draw_page_2()
  end
  screen.update()
end

function cleanup()
  all_notes_off()
  if poll_l then poll_l:stop() end
  if poll_r then poll_r:stop() end
end
