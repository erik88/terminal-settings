-- WezTerm config: Ptyxis-style process tinting (sudo / ssh / Claude Code),
-- per-tab colors, smart Ctrl+C / Ctrl+V and full tab titles.
-- Works on Linux and macOS (and Windows, minus process detection quirks).

local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

---------------------------------------------------------------------------
-- Colors per process kind
---------------------------------------------------------------------------

-- active = active tab + header bar, inactive = background tabs
local KIND_COLORS = {
  superuser = { active = '#c01c28', inactive = '#7a1c22', fg = '#ffffff' }, -- red
  remote    = { active = '#613583', inactive = '#3d2552', fg = '#ffffff' }, -- purple
  claude    = { active = '#d97757', inactive = '#8a4c38', fg = '#ffffff' }, -- orange
}

-- Default header (window frame) colors, used when no special process runs.
local FRAME_BG_ACTIVE = '#303030'
local FRAME_BG_INACTIVE = '#242424'

---------------------------------------------------------------------------
-- Process classification
---------------------------------------------------------------------------

local SUPERUSER = { sudo = true, su = true, doas = true, run0 = true, pkexec = true }
local REMOTE = {
  ssh = true, mosh = true, ['mosh-client'] = true, et = true, telnet = true,
  sftp = true, scp = true, slogin = true, rlogin = true,
}

local function basename(s)
  if not s or s == '' then return '' end
  return (s:gsub('\\', '/'):match('([^/]+)$') or s):gsub('%.exe$', '')
end

-- Returns 'superuser', 'remote', 'claude' or nil.
local function classify_info(info)
  if not info then return nil end

  local names = {
    basename(info.name),
    basename(info.executable),
    basename(info.argv and info.argv[1]),
  }

  for _, n in ipairs(names) do
    if SUPERUSER[n] then return 'superuser' end
  end
  for _, n in ipairs(names) do
    if REMOTE[n] then return 'remote' end
  end

  -- Claude Code: the native install's executable is .../claude/versions/X.Y.Z
  -- (so the exe name is a version number); argv[1] is "claude". The npm
  -- install runs under node with ".../claude-code/cli.js" in argv.
  for _, n in ipairs(names) do
    if n == 'claude' then return 'claude' end
  end
  local exe = (info.executable or ''):gsub('\\', '/')
  if exe:find('/claude/versions/', 1, true) then return 'claude' end
  for _, arg in ipairs(info.argv or {}) do
    if arg:find('claude-code', 1, true) then return 'claude' end
  end

  return nil
end

-- Fallback for when WezTerm can't read the foreground process at all. This
-- happens on macOS for root-owned processes such as sudo. `ps` can see them,
-- so ask it which processes are in the tty's foreground group ("+" in STAT).
-- Results are cached briefly, because format-tab-title runs on every redraw.
local ps_cache = {}

local function classify_via_ps(pane)
  local ok, tty = pcall(function() return pane:get_tty_name() end)
  if not ok or not tty or tty == '' then return nil end
  tty = tty:gsub('^/dev/', '')

  local now = os.time()
  local cached = ps_cache[tty]
  if cached and now - cached.at < 1 then return cached.kind end

  local kind = nil
  local ok2, success, stdout = pcall(wezterm.run_child_process,
    { 'ps', '-t', tty, '-o', 'stat=,comm=' })
  if ok2 and success then
    for line in stdout:gmatch('[^\n]+') do
      local stat, comm = line:match('^%s*(%S+)%s+(.+)$')
      if stat and stat:find('+', 1, true) then
        local k = classify_info({ name = basename(comm) })
        if k == 'superuser' then kind = k; break end
        kind = kind or k
      end
    end
  end

  ps_cache[tty] = { at = now, kind = kind }
  return kind
end

-- Kinds found through the ps fallback, by pane id. `ps` can only run from
-- async events (update-status), not from format-tab-title, so update-status
-- fills this table and format-tab-title reads it.
local ps_kind_by_pane = {}

-- allow_ps: true only when called from an async event.
local function classify_pane(pane, allow_ps)
  local ok, info = pcall(function() return pane:get_foreground_process_info() end)
  if not ok then return nil end
  if info ~= nil then
    ps_kind_by_pane[pane:pane_id()] = nil
    return classify_info(info)
  end
  if allow_ps then
    local kind = classify_via_ps(pane)
    ps_kind_by_pane[pane:pane_id()] = kind or false
    return kind
  end
  return ps_kind_by_pane[pane:pane_id()] or nil
end

local function classify_pane_id(pane_id, allow_ps)
  local ok, pane = pcall(wezterm.mux.get_pane, pane_id)
  if not ok or not pane then return nil end
  return classify_pane(pane, allow_ps)
end

---------------------------------------------------------------------------
-- Tabs: color + full (verbatim) user titles
---------------------------------------------------------------------------

wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  -- A title set by the user (Ctrl+Shift+E) replaces the whole title.
  local title = tab.tab_title
  if not title or title == '' then
    title = tab.active_pane.title
  end
  title = wezterm.truncate_right(title, math.max(1, max_width - 2))

  local kind = classify_pane_id(tab.active_pane.pane_id)
  local colors = kind and KIND_COLORS[kind]
  if not colors then
    return ' ' .. title .. ' '
  end

  return {
    { Background = { Color = tab.is_active and colors.active or colors.inactive } },
    { Foreground = { Color = colors.fg } },
    { Text = ' ' .. title .. ' ' },
  }
end)

---------------------------------------------------------------------------
-- Header bar: follows the active tab, like Ptyxis
---------------------------------------------------------------------------

local window_kind = {}

-- WezTerm only rebuilds the tab bar on certain events (focus, OSC title
-- change, status text change, ...). A title derived from the foreground
-- process (zsh -> vim) changes silently, so the tab bar would stay stale
-- until the mouse hovers it. We track a signature of all tab titles/kinds
-- and, when it changes, toggle the (invisible) right status, which makes
-- WezTerm recompute the tab bar.
local tab_signature = {}
local status_toggle = {}

wezterm.on('update-status', function(window, pane)
  local id = window:window_id()
  local sig = {}

  -- Refresh every tab in this window (including background tabs), so that
  -- format-tab-title has ps-based results for root-owned processes.
  local ok, tabs = pcall(function() return window:mux_window():tabs() end)
  if ok and tabs then
    for _, t in ipairs(tabs) do
      local p = t:active_pane()
      if p then
        local k
        if p:pane_id() ~= pane:pane_id() then
          k = classify_pane(p, true)
        end
        local okt, ptitle = pcall(function() return p:get_title() end)
        sig[#sig + 1] = t:get_title() .. '\0' .. (okt and ptitle or '')
          .. '\0' .. tostring(k)
      end
    end
  end

  local kind = classify_pane(pane, true) or 'none'
  sig[#sig + 1] = kind

  local s = table.concat(sig, '\1')
  if tab_signature[id] ~= s then
    tab_signature[id] = s
    status_toggle[id] = not status_toggle[id]
  end
  -- Must be called on EVERY tick: WezTerm schedules the next update-status
  -- only from set_right_status/set_left_status. An unchanged value just
  -- re-arms the timer; a changed one also rebuilds the tab bar.
  window:set_right_status(status_toggle[id] and ' ' or '')

  if window_kind[id] == kind then return end
  window_kind[id] = kind
  wezterm.log_info('process-tint: window ' .. id .. ' -> ' .. kind)

  local overrides = window:get_config_overrides() or {}
  local colors = KIND_COLORS[kind]
  if colors then
    overrides.window_frame = {
      active_titlebar_bg = colors.active,
      inactive_titlebar_bg = colors.inactive,
      font_size = config.window_frame.font_size,
    }
    overrides.colors = { tab_bar = { inactive_tab_edge = colors.inactive } }
  else
    overrides.window_frame = nil
    overrides.colors = nil
  end
  window:set_config_overrides(overrides)
end)

---------------------------------------------------------------------------
-- Appearance
---------------------------------------------------------------------------

config.color_scheme = 'Builtin Dark'
config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.tab_max_width = 32
config.status_update_interval = 500
config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
config.window_frame = {
  active_titlebar_bg = FRAME_BG_ACTIVE,
  inactive_titlebar_bg = FRAME_BG_INACTIVE,
  -- Controls the height of the header bar and tabs.
  font_size = 13.0,
}

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------

local set_tab_title = act.PromptInputLine {
  description = 'Tab title (empty = automatic):',
  action = wezterm.action_callback(function(window, pane, line)
    -- line is nil when cancelled with Escape
    if line ~= nil then
      window:active_tab():set_title(line)
    end
  end),
}

config.keys = {
  -- Ctrl+C: copy if there is a selection, otherwise send ^C (SIGINT).
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local sel = window:get_selection_text_for_pane(pane)
      if sel and sel ~= '' then
        window:perform_action(act.CopyTo 'Clipboard', pane)
        window:perform_action(act.ClearSelection, pane)
      else
        window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
      end
    end),
  },
  -- Ctrl+V: paste.
  { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },

  -- Set the entire tab title.
  { key = 'e', mods = 'CTRL|SHIFT', action = set_tab_title },
  { key = 'e', mods = 'CMD|SHIFT', action = set_tab_title },
}

return config
