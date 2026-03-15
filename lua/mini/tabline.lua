--- *mini.tabline* Tabline
---
--- MIT License Copyright (c) 2021 Evgeni Chasnovski
---
--- Key idea: show all listed buffers in readable way with minimal total width.
---
--- Features:
--- - Buffers are listed in the order of their identifier (see |bufnr()|).
---
--- - Buffer names are made unique by extending paths to files or appending
---   unique identifier to buffers without name.
---
--- - Current buffer is displayed "optimally centered" (in center of screen
---   while maximizing the total number of buffers shown) when there are many
---   buffers open.
---
--- - 'Buffer tabs' are clickable if Neovim allows it.
---
--- - Extra information section in case of multiple Neovim tabpages.
---
--- - Truncation symbols which show if there are tabs to the left and/or right.
---   Exact characters are taken from 'listchars' global value (`precedes` and
---   `extends` fields) and are shown only if 'list' option is enabled.
---
--- What it doesn't do:
--- - Custom buffer order is not supported.
---
--- # Setup ~
---
--- This module needs a setup with `require('mini.tabline').setup({})`
--- (replace `{}` with your `config` table). It will create global Lua table
--- `MiniTabline` which you can use for scripting or manually (with
--- `:lua MiniTabline.*`).
---
--- See |MiniTabline.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.minitabline_config` which should have same structure as
--- `MiniTabline.config`. See |mini.nvim-buffer-local-config| for more details.
---
--- # Suggested option values ~
---
--- Some options are set automatically by |MiniTabline.setup()|:
--- - 'showtabline' is set to 2 to always show tabline.
---
--- # Disabling ~
---
--- To disable (show empty tabline), set `vim.g.minitabline_disable` (globally) or
--- `vim.b.minitabline_disable` (for a buffer) to `true`. Considering high number
--- of different scenarios and customization intentions, writing exact rules
--- for disabling module's functionality is left to user. See
--- |mini.nvim-disabling-recipes| for common recipes.
---@tag MiniTabline

-- Module definition ==========================================================
local MiniTabline = {}
local H = {}

--- Module setup
---
---@param config table|nil Module config table. See |MiniTabline.config|.
---
---@usage >lua
---   require('mini.tabline').setup() -- use default config
---   -- OR
---   require('mini.tabline').setup({}) -- replace {} with your config table
--- <
MiniTabline.setup = function(config)
  _G.MiniTabline = MiniTabline
  config = H.setup_config(config)
  H.apply_config(config)
  H.create_autocommands()
  vim.api.nvim_exec(
    [[function! MiniTablineSwitchBuffer(buf_id, clicks, button, mod)
        execute 'buffer' a:buf_id
      endfunction]],
    false
  )
end

--- Defaults ~
---# Format ~
---
--- `config.format` is a required callable that takes a `tab` object and returns
--- an array of segments. Each segment is a table with:
--- - `text` (string): the text to display.
--- - `hl` (string|nil): highlight group name, or nil to continue previous highlight.
---
--- The `tab` object contains:
--- - `buf_id` (number): buffer identifier.
--- - `label` (string): pre-computed unique label.
--- - `is_active` (boolean): true if buffer is current.
--- - `is_visible` (boolean): true if buffer is displayed in some window.
--- - `is_modified` (boolean): true if buffer has unsaved changes.
---
--- Example: >lua
---
---   format = function(tab)
---     local hl = tab.is_active and 'TabLineSel' or 'TabLine'
---     return {
---       { text = ' ', hl = hl },
---       { text = tab.label, hl = hl },
---       { text = tab.is_modified and ' +' or '', hl = hl },
---       { text = ' ', hl = hl },
---     }
---   end
--- <
MiniTabline.config = {
  format = nil,
  tabpage_section = 'left',
}
---minidoc_afterlines_end

-- Module functionality =======================================================
--- Make string for |'tabline'|
MiniTabline.make_tabline_string = function()
  if H.is_disabled() then return '' end
  H.make_tabpage_section()
  H.list_tabs()
  H.deduplicate_labels()
  H.finalize_segments()
  local display_left, display_right = H.calculate_display_range()
  H.truncate_tabs(display_left, display_right)
  return H.concat_tabs()
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(MiniTabline.config)
-- Table to keep track of tabs
H.tabs = {}
-- Keep track of initially unnamed buffers
H.unnamed_buffers_seq_ids = {}
-- Separator of file path
H.path_sep = package.config:sub(1, 1)
-- String with tabpage prefix
H.tabpage_section = ''
-- Data about truncation characters used when there are too much tabs
H.trunc = { left = '', right = '', needs_left = false, needs_right = false }
-- Buffer number of center buffer
H.center_buf_id = nil

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})
  H.check_type('format', config.format, 'function')
  H.check_type('tabpage_section', config.tabpage_section, 'string')
  return config
end

H.apply_config = function(config)
  MiniTabline.config = config
  -- Make tabline always visible (essential for custom tabline)
  vim.o.showtabline = 2
  -- Cache truncation characters
  H.cache_trunc_chars()
  -- Set tabline string
  vim.o.tabline = '%!v:lua.MiniTabline.make_tabline_string()'
end

H.create_autocommands = function()
  local gr = vim.api.nvim_create_augroup('MiniTabline', {})
  vim.api.nvim_create_autocmd('OptionSet', {
    group = gr,
    pattern = { 'list', 'listchars' },
    callback = H.cache_trunc_chars,
  })
end

H.is_disabled = function() return vim.g.minitabline_disable == true or vim.b.minitabline_disable == true end

H.get_config = function()
  return vim.tbl_deep_extend('force', MiniTabline.config, vim.b.minitabline_config or {})
end

-- Work with tabpages ---------------------------------------------------------
H.make_tabpage_section = function()
  local n_tabpages = vim.fn.tabpagenr('$')
  if n_tabpages == 1 or H.get_config().tabpage_section == 'none' then
    H.tabpage_section = ''
    return
  end
  local cur_tabpagenr = vim.fn.tabpagenr()
  H.tabpage_section = string.format(' Tab %s/%s ', cur_tabpagenr, n_tabpages)
end

-- Work with tabs -------------------------------------------------------------
-- List tabs
H.list_tabs = function()
  local cur_buf = vim.api.nvim_get_current_buf()
  local tabs = {}
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf_id].buflisted then
      local label, label_extender = H.construct_label_data(buf_id)
      local tab = {
        buf_id = buf_id,
        label = label,
        label_extender = label_extender,
        is_active = buf_id == cur_buf,
        is_visible = vim.fn.bufwinnr(buf_id) > 0,
        is_modified = vim.bo[buf_id].modified,
        tabfunc = '%' .. buf_id .. '@MiniTablineSwitchBuffer@',
      }
      table.insert(tabs, tab)
    end
  end
  H.tabs = tabs
end

-- Tab's label and label extender
H.construct_label_data = function(buf_id)
  local label, label_extender
  local bufpath = vim.api.nvim_buf_get_name(buf_id)
  if bufpath ~= '' then
    -- Process path buffer
    label = vim.fn.fnamemodify(bufpath, ':t')
    label_extender = H.make_path_extender(buf_id)
  else
    -- Process unnamed buffer
    label = H.make_unnamed_label(buf_id)
    label_extender = function(x) return x end
  end
  return label, label_extender
end

H.make_path_extender = function(buf_id)
  -- Add parent to current label (if possible)
  return function(label)
    local full_path = vim.api.nvim_buf_get_name(buf_id)
    -- Using `vim.pesc` prevents effect of problematic characters (like '.')
    local pattern = string.format('[^%s]+%s%s$', H.path_sep, H.path_sep, vim.pesc(label))
    return string.match(full_path, pattern) or label
  end
end

-- Work with unnamed buffers --------------------------------------------------
-- Unnamed buffers are tracked in `H.unnamed_buffers_seq_ids` for
-- disambiguation. This table is designed to store 'sequential' buffer
-- identifier. This approach allows to have the following behavior:
-- - Create three unnamed buffers.
-- - Delete second one.
-- - Tab label for third one remains the same.
H.make_unnamed_label = function(buf_id)
  local buftype = vim.bo[buf_id].buftype
  -- Differentiate quickfix/location lists and scratch/other unnamed buffers
  local label = buftype == 'quickfix'
      -- There can be only one quickfix buffer and many location buffers
       and (vim.fn.getqflist({ qfbufnr = true }).qfbufnr == buf_id and '*quickfix*' or '*location*')
     or ((buftype == 'nofile' or buftype == 'acwrite') and '!' or '*')
  -- Possibly add tracking id
  local unnamed_id = H.get_unnamed_id(buf_id)
  if unnamed_id > 1 then label = string.format('%s(%d)', label, unnamed_id) end
  return label
end

H.get_unnamed_id = function(buf_id)
  -- Use existing sequential id if possible
  local seq_id = H.unnamed_buffers_seq_ids[buf_id]
  if seq_id ~= nil then return seq_id end
  -- Cache sequential id for currently unnamed buffer `buf_id`
  H.unnamed_buffers_seq_ids[buf_id] = vim.tbl_count(H.unnamed_buffers_seq_ids) + 1
  return H.unnamed_buffers_seq_ids[buf_id]
end

-- Work with labels -----------------------------------------------------------
H.deduplicate_labels = function()
  if #H.tabs == 0 then return end
  local nonunique_buf_ids = H.get_nonunique_buf_ids()
  while #nonunique_buf_ids > 0 do
    local nothing_changed = true
    for _, idx in ipairs(nonunique_buf_ids) do
      local tab = H.tabs[idx]
      local old_label = tab.label
      tab.label = tab.label_extender(tab.label)
      if old_label ~= tab.label then nothing_changed = false end
    end
    if nothing_changed then break end
    nonunique_buf_ids = H.get_nonunique_buf_ids()
  end
end

H.get_nonunique_buf_ids = function()
  local label_counts = {}
  for _, tab in ipairs(H.tabs) do
    label_counts[tab.label] = (label_counts[tab.label] or 0) + 1
  end
  local res = {}
  for i, tab in ipairs(H.tabs) do
    if label_counts[tab.label] > 1 then table.insert(res, i) end
  end
  return res
end

-- Fit tabline to maximum displayed width -------------------------------------
-- Pass 1: Calculate segment positions and total width
H.finalize_segments = function()
  local config = H.get_config()
  local pos = 0
  for _, tab in ipairs(H.tabs) do
    tab.segments = config.format(tab)
    tab.start = pos
    for _, seg in ipairs(tab.segments) do
      seg.start = pos
      seg.width = vim.api.nvim_strwidth(seg.text)
      pos = pos + seg.width
    end
    tab.width = pos - tab.start
  end
  H.total_width = pos
end

-- Pass 2: Calculate display range
H.calculate_display_range = function()
  if #H.tabs == 0 then return 0, H.total_width end

  local cur_buf = vim.api.nvim_get_current_buf()
  if vim.bo[cur_buf].buflisted then H.center_buf_id = cur_buf end

  local center_offset = 1
  for _, tab in ipairs(H.tabs) do
    if tab.buf_id == H.center_buf_id then
      center_offset = tab.start + tab.width
    end
  end

  local screen_width = vim.o.columns - vim.api.nvim_strwidth(H.tabpage_section)
  local display_right = math.min(H.total_width, math.floor(center_offset + 0.5 * screen_width))
  local display_left = math.max(0, display_right - screen_width)
  display_right = math.min(display_left + screen_width, H.total_width)

  H.trunc.needs_left = H.trunc.left ~= '' and display_left > 0
  H.trunc.needs_right = H.trunc.right ~= '' and display_right < H.total_width

  if H.trunc.needs_left then display_left = display_left + 1 end
  if H.trunc.needs_right then display_right = display_right - 1 end

  return display_left, display_right
end

-- Pass 3: Truncate segments to display range
H.truncate_tabs = function(display_left, display_right)
  local visible = {}
  for _, tab in ipairs(H.tabs) do
    local tab_end = tab.start + tab.width
    if tab_end > display_left and tab.start < display_right then
      for _, seg in ipairs(tab.segments) do
        local seg_end = seg.start + seg.width
        if seg_end <= display_left or seg.start >= display_right then
          seg.skip = true
        else
          local trim_left = math.max(0, display_left - seg.start)
          local trim_right = math.max(0, seg_end - display_right)
          if trim_left > 0 or trim_right > 0 then
            seg.text = vim.fn.strcharpart(seg.text, trim_left, seg.width - trim_left - trim_right)
          end
        end
      end
      table.insert(visible, tab)
    end
  end
  H.tabs = visible
end

H.cache_trunc_chars = function()
  if vim.go.list then
    local listchars = vim.go.listchars
    H.trunc.left = listchars:match('precedes:(.[^,]*)') or ''
    H.trunc.right = listchars:match('extends:(.[^,]*)') or ''
  else
    H.trunc.left = ''
    H.trunc.right = ''
  end
end

-- Concatenate tabs into single tabline string --------------------------------
H.concat_tabs = function()
  -- NOTE: it is assumed that all padding is incorporated into segments
  local t = {}
  if H.trunc.needs_left then
    table.insert(t, H.trunc.left:gsub('%%', '%%%%'))
  end
  local last_hl
  local prev_skipped = false
  for _, tab in ipairs(H.tabs) do
    local parts = { tab.tabfunc }
    for _, seg in ipairs(tab.segments) do
      if seg.skip then
        prev_skipped = true
      else
        local text = seg.text:gsub('%%', '%%%%')
        if seg.hl then
          last_hl = seg.hl
          table.insert(parts, '%#' .. seg.hl .. '#' .. text)
        elseif prev_skipped and last_hl then
          table.insert(parts, '%#' .. last_hl .. '#' .. text)
        else
          table.insert(parts, text)
        end
        prev_skipped = false
      end
    end
    table.insert(t, table.concat(parts, ''))
  end
  if H.trunc.needs_right then
    table.insert(t, H.trunc.right:gsub('%%', '%%%%'))
  end
  -- Usage of `%X` makes filled space to the right "non-clickable"
  local res = table.concat(t, '') .. '%X%#TabLineFill#'
  -- Add tabpage section
  if H.tabpage_section ~= '' then
    local position = H.get_config().tabpage_section
    if position == 'left' then
      res = H.tabpage_section:gsub('%%', '%%%%') .. res
    elseif position == 'right' then
      res = res .. '%=' .. H.tabpage_section:gsub('%%', '%%%%')
    end
  end
  return res
end

-- Utilities ------------------------------------------------------------------
H.error = function(msg) error('(mini.tabline) ' .. msg, 0) end

H.check_type = function(name, val, ref, allow_nil)
  if type(val) == ref or (allow_nil and val == nil) then return end
  H.error(string.format('`%s` should be %s, not %s', name, ref, type(val)))
end

return MiniTabline
