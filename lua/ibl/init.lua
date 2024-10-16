local highlights = require "ibl.highlights"
local hooks = require "ibl.hooks"
local autocmds = require "ibl.autocmds"
local inlay_hints = require "ibl.inlay_hints"
local indent = require "ibl.indent"
local vt = require "ibl.virt_text"
local scp = require "ibl.scope"
local conf = require "ibl.config"
local utils = require "ibl.utils"

local namespace = vim.api.nvim_create_namespace "indent_blankline"

local M = {}

---@package
M.initialized = false

---@type table<number, { scope: TSNode?, left_offset: number, top_offset: number, tick: number }>
local global_buffer_state = {}

---@param bufnr number
local clear_buffer = function(bufnr)
    vt.clear_buffer(bufnr)
    inlay_hints.clear_buffer(bufnr)
    for _, fn in pairs(hooks.get(bufnr, hooks.type.CLEAR)) do
        fn(bufnr)
    end
end

---@param config ibl.config.full
local setup = function(config)
    M.initialized = true

    if not config.enabled then
        for bufnr, _ in pairs(global_buffer_state) do
            clear_buffer(bufnr)
        end
        global_buffer_state = {}
        inlay_hints.clear()
        return
    end

    inlay_hints.setup()
    highlights.setup()
    autocmds.setup()
    M.refresh_all()
end

--- Initializes and configures indent-blankline.
---
--- Optionally, the first parameter can be a configuration table.
--- All values that are not passed in the table are set to the default value.
--- List values get merged with the default list value.
---
--- `setup` is idempotent, meaning you can call it multiple times, and each call will reset indent-blankline.
--- If you want to only update the current configuration, use `update()`.
---@param config ibl.config?
M.setup = function(config)
    setup(conf.set_config(config))
end

--- Updates the indent-blankline configuration
---
--- The first parameter is a configuration table.
--- All values that are not passed in the table are kept as they are.
--- List values get merged with the current list value.
---@param config ibl.config
M.update = function(config)
    setup(conf.update_config(config))
end

--- Overwrites the indent-blankline configuration
---
--- The first parameter is a configuration table.
--- All values that are not passed in the table are kept as they are.
--- All values that are passed overwrite existing and default values.
---@param config ibl.config
M.overwrite = function(config)
    setup(conf.overwrite_config(config))
end

--- Configures indent-blankline for one buffer
---
--- All values that are not passed are cleared, and will fall back to the global config
---@param bufnr number
---@param config ibl.config
M.setup_buffer = function(bufnr, config)
    assert(M.initialized, "Tried to setup buffer without doing global setup")
    bufnr = utils.get_bufnr(bufnr)
    local c = conf.set_buffer_config(bufnr, config)

    if c.enabled then
        M.refresh(bufnr)
    else
        clear_buffer(bufnr)
    end
end

--- Refreshes indent-blankline in all buffers
M.refresh_all = function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        vim.api.nvim_win_call(win, function()
            M.refresh(vim.api.nvim_win_get_buf(win) --[[@as number]])
        end)
    end
end

---@class ibl.debounced_refresh_object
---@field timers table<number, uv_timer_t>
---@field queued_buffers table<number, boolean>

local debounced_refresh = setmetatable({
    timers = {},
    queued_buffers = {},
}, {
    ---@param self ibl.debounced_refresh_object
    ---@param bufnr number
    __call = function(self, bufnr)
        bufnr = utils.get_bufnr(bufnr)
        local uv = vim.uv or vim.loop
        if not self.timers[bufnr] then
            self.timers[bufnr] = uv.new_timer()
        end
        if uv.timer_get_due_in(self.timers[bufnr]) <= 50 then
            self.queued_buffers[bufnr] = nil

            local config = conf.get_config(bufnr)
            self.timers[bufnr]:start(config.debounce, 0, function()
                if self.queued_buffers[bufnr] then
                    self.queued_buffers[bufnr] = nil
                    vim.schedule_wrap(M.refresh)(bufnr)
                end
            end)

            M.refresh(bufnr)
        else
            self.queued_buffers[bufnr] = true
        end
    end,
})

--- Refreshes indent-blankline in one buffer, debounced
---
---@param bufnr number
M.debounced_refresh = function(bufnr)
    if vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_get_option_value("scrollbind", { scope = "local" }) then
        for _, b in ipairs(vim.fn.tabpagebuflist()) do
            debounced_refresh(b)
        end
    else
        debounced_refresh(bufnr)
    end
end

--- Refreshes indent-blankline in one buffer
---
--- Only use this directly if you know what you are doing, consider `debounced_refresh` instead
---@param bufnr number
M.refresh = function(bufnr)
    assert(M.initialized, "Tried to refresh without doing setup")
    bufnr = utils.get_bufnr(bufnr)
    local is_current_buffer = vim.api.nvim_get_current_buf() == bufnr
    local config = conf.get_config(bufnr)

    if not config.enabled or not vim.api.nvim_buf_is_loaded(bufnr) or not utils.is_buffer_active(bufnr, config) then
        clear_buffer(bufnr)
        return
    end

    for _, fn in
        pairs(hooks.get(bufnr, hooks.type.ACTIVE) --[=[@as ibl.hooks.cb.active[]]=])
    do
        if not fn(bufnr) then
            clear_buffer(bufnr)
            return
        end
    end

    local left_offset, top_offset, win_end, win_height, lnum = utils.get_offset(bufnr)
    if top_offset > win_end then
        return
    end

    local offset = math.max(top_offset - 1 - config.viewport_buffer.min, 0)

    local scope_disabled = false
    for _, fn in
        pairs(hooks.get(bufnr, hooks.type.SCOPE_ACTIVE) --[=[@as ibl.hooks.cb.scope_active[]]=])
    do
        if not fn(bufnr) then
            scope_disabled = true
            break
        end
    end

    local scope
    local scope_start_line
    local scope_end_line
    if not scope_disabled and config.scope.enabled then
        scope = scp.get(bufnr, config, global_buffer_state[bufnr])
        if scope and scope:start() >= 0 then
            local scope_start = scope:start()
            local scope_end = scope:end_()
            offset = top_offset - math.min(top_offset - math.min(offset, scope_start), config.viewport_buffer.max)
            scope_start_line = vim.api.nvim_buf_get_lines(bufnr, scope_start, scope_start + 1, false)
            scope_end_line = vim.api.nvim_buf_get_lines(bufnr, scope_end, scope_end + 1, false)
        end
    end

    local range = math.min(win_end + config.viewport_buffer.min, vim.api.nvim_buf_line_count(bufnr))
    local lines = vim.api.nvim_buf_get_lines(bufnr, offset, range, false)

    ---@type ibl.indent_options
    local indent_opts = {
        tabstop = vim.api.nvim_get_option_value("tabstop", { buf = bufnr }),
        vartabstop = vim.api.nvim_get_option_value("vartabstop", { buf = bufnr }),
        shiftwidth = vim.api.nvim_get_option_value("shiftwidth", { buf = bufnr }),
        smart_indent_cap = config.indent.smart_indent_cap,
    }
    local listchars = utils.get_listchars(bufnr)
    if listchars.tabstop_overwrite then
        indent_opts.tabstop = 2
        indent_opts.vartabstop = ""
    end

    local has_empty_foldtext = utils.has_empty_foldtext(bufnr)

    local indent_state
    local next_whitespace_tbl = {}
    local empty_line_counter = 0

    local buffer_state = global_buffer_state[bufnr]
        or {
            scope = nil,
            left_offset = -1,
            top_offset = -1,
            tick = 0,
        }

    local same_scope = (scope and scope:id()) == (buffer_state.scope and buffer_state.scope:id())
    local current_indent_enabled = utils.is_current_indent_active(bufnr, config)

    for _, fn in
        pairs(hooks.get(bufnr, hooks.type.CURRENT_INDENT_ACTIVE) --[=[@as ibl.hooks.cb.current_indent_active[]]=])
    do
        if not fn(bufnr) then
            current_indent_enabled = false
            break
        end
    end

    if not same_scope or current_indent_enabled then
        inlay_hints.clear_buffer(bufnr)
    end

    global_buffer_state[bufnr] = {
        left_offset = left_offset,
        top_offset = top_offset,
        scope = scope,
        tick = buffer_state.tick + 1,
    }

    local scope_col_start_single = -1
    local scope_row_start, scope_col_start, scope_row_end, scope_col_end = -1, -1, -1, -1
    local scope_index = -1
    if scope then
        scope_row_start, scope_col_start, scope_row_end, scope_col_end = scope:range()
        scope_row_start, scope_col_start, scope_row_end = scope_row_start + 1, scope_col_start + 1, scope_row_end + 1
    end
    local exact_scope_col_start = scope_col_start

    local current_indent_index = -1
    local current_indent_col_start_single = -1

    ---@class ibl.current_indent
    ---@field start_row number
    ---@field end_row number

    ---@type ibl.current_indent
    local current_indent = {
        start_row = -1,
        end_row = #lines + offset,
    }

    ---@type ibl.indent.whitespace[]
    local last_whitespace_tbl = {}
    ---@type table<integer, boolean>
    local line_skipped = {}
    ---@type ibl.hooks.cb.skip_line[]
    local skip_line_hooks = hooks.get(bufnr, hooks.type.SKIP_LINE)

    local line_num = #lines
    for i = 1, line_num do
        local line = lines[i]
        local row = i + offset
        for _, fn in pairs(skip_line_hooks) do
            if fn(buffer_state.tick, bufnr, row - 1, line) then
                line_skipped[i] = true
                break
            end
        end
    end

    --- Calc loop ---
    local calc_data = {}
    for i = 1, line_num do
        local line = lines[i]
        local row = i + offset
        if line_skipped[i] then
            goto continue_calc
        end

        local whitespace = utils.get_whitespace(line)
        local foldclosed = vim.fn.foldclosed(row)
        if is_current_buffer and foldclosed == row and not has_empty_foldtext then
            local foldtext = vim.fn.foldtextresult(row)
            local foldtext_whitespace = utils.get_whitespace(foldtext)
            if vim.fn.strwidth(foldtext_whitespace) < vim.fn.strwidth(whitespace) then
                line_skipped[i] = true
                goto continue_calc
            end
        end

        if is_current_buffer and foldclosed > -1 and foldclosed + win_height < row then
            line_skipped[i] = true
            goto continue_calc
        end

        ---@type ibl.indent.whitespace[]
        local whitespace_tbl
        local blankline = line:len() == 0

        if not blankline then
            whitespace_tbl, indent_state = indent.get(whitespace, indent_opts, indent_state, row)
            if current_indent_enabled and row > lnum and current_indent.end_row > row then
                if current_indent_col_start_single == #whitespace_tbl then
                    current_indent.end_row = row
                elseif current_indent_col_start_single > #whitespace_tbl then
                    current_indent.end_row = row - 1
                end
            end
        elseif empty_line_counter > 0 then
            empty_line_counter = empty_line_counter - 1
            whitespace_tbl = next_whitespace_tbl
        else
            if i == line_num then
                whitespace_tbl, indent_state = indent.get(whitespace, indent_opts, indent_state, row)
            else
                local j = i + 1
                while j < #lines and (lines[j]:len() == 0 or line_skipped[j]) do
                    if not line_skipped[j] then
                        empty_line_counter = empty_line_counter + 1
                    end
                    j = j + 1
                end

                local j_whitespace = utils.get_whitespace(lines[j])
                whitespace_tbl, indent_state = indent.get(j_whitespace, indent_opts, indent_state, row, true)

                if current_indent_enabled and row > lnum and current_indent.end_row > row then
                    if current_indent_col_start_single >= #whitespace_tbl then
                        current_indent.end_row = row - 1
                    end
                end

                if utils.has_end(lines[j]) then
                    local trail
                    local trail_whitespace
                    if indent_state.stack and indent_state.stack[#indent_state.stack] then
                        trail = last_whitespace_tbl[indent_state.stack[#indent_state.stack].indent + 1] or nil
                        trail_whitespace = last_whitespace_tbl[indent_state.stack[#indent_state.stack].indent]
                    end
                    if trail then
                        table.insert(whitespace_tbl, trail)
                    elseif trail_whitespace then
                        if indent.is_space_indent(trail_whitespace) then
                            table.insert(whitespace_tbl, indent.whitespace.INDENT)
                        else
                            table.insert(whitespace_tbl, indent.whitespace.TAB_START)
                        end
                    end
                    if current_indent.end_row == row - 1 then
                        current_indent.end_row = j + offset
                    end
                end
            end
            next_whitespace_tbl = whitespace_tbl
        end

        -- remove blankline trail
        if blankline and config.whitespace.remove_blankline_trail then
            while #whitespace_tbl > 0 do
                if indent.is_indent(whitespace_tbl[#whitespace_tbl]) then
                    break
                end
                table.remove(whitespace_tbl, #whitespace_tbl)
            end
        end

        -- fix horizontal scroll
        local current_left_offset = left_offset
        while #whitespace_tbl > 0 and current_left_offset > 0 do
            table.remove(whitespace_tbl, 1)
            current_left_offset = current_left_offset - 1
        end

        for _, fn in
            pairs(hooks.get(bufnr, hooks.type.WHITESPACE) --[=[@as ibl.hooks.cb.whitespace[]]=])
        do
            whitespace_tbl = fn(buffer_state.tick, bufnr, row - 1, whitespace_tbl)
        end

        last_whitespace_tbl = whitespace_tbl

        --- current indent
        if current_indent_enabled and row == lnum then
            local current_indent_whitespace_tbl = utils.quickclone(whitespace_tbl) -- vim.tbl_extend("keep", {}, whitespace_tbl)

            while #current_indent_whitespace_tbl > 0 do
                if indent.is_indent(current_indent_whitespace_tbl[#current_indent_whitespace_tbl]) then
                    table.remove(current_indent_whitespace_tbl, #current_indent_whitespace_tbl)
                    break
                end
                table.remove(current_indent_whitespace_tbl, #current_indent_whitespace_tbl)
            end

            current_indent_col_start_single = #current_indent_whitespace_tbl

            for j = indent_state and #indent_state.stack or 0, 1, -1 do
                current_indent.start_row = indent_state.stack[j].row + 1
                if indent_state.stack[j].indent <= current_indent_col_start_single then
                    break
                end
            end
            if current_indent.start_row > row then
                current_indent.start_row = math.huge
            end

            current_indent_index = #utils.tbl_filter(function(w)
                return indent.is_indent(w)
            end, current_indent_whitespace_tbl) + 1
        end

        do
            calc_data[i] = { whitespace, whitespace_tbl }
        end

        ::continue_calc::
    end

    for _, fn in
        pairs(hooks.get(bufnr, hooks.type.CURRENT_INDENT_HIGHLIGHT) --[=[@as ibl.hooks.cb.current_indent_highlight[]]=])
    do
        current_indent_index = fn(buffer_state.tick, bufnr, current_indent, current_indent_index)
    end

    if scope and scope_start_line then
        local whitespace_start = utils.get_whitespace(scope_start_line[1])
        local whitespace_end = utils.get_whitespace(scope_end_line[1])
        local whitespace_tbl_start, _ = indent.get(whitespace_start, indent_opts, indent_state, scope_row_start)
        local whitespace_tbl_end, _ = indent.get(whitespace_end, indent_opts, indent_state, scope_row_end)
        local whitespace, whitespace_tbl
        if #whitespace_tbl_end < #whitespace_tbl_start then
            whitespace = whitespace_end
            whitespace_tbl = whitespace_tbl_end
        else
            whitespace = whitespace_start
            whitespace_tbl = whitespace_tbl_start
        end

        local current_left_offset = left_offset
        while #whitespace_tbl > 0 and current_left_offset > 0 do
            table.remove(whitespace_tbl, 1)
            current_left_offset = current_left_offset - 1
        end

        for _, fn in
            pairs(hooks.get(bufnr, hooks.type.WHITESPACE) --[=[@as ibl.hooks.cb.whitespace[]]=])
        do
            whitespace_tbl = fn(buffer_state.tick, bufnr, scope_row_start - 1, whitespace_tbl)
        end

        scope_col_start = #whitespace
        scope_col_start_single = #whitespace_tbl
        scope_index = #utils.tbl_filter(function(w)
            return indent.is_indent(w)
        end, whitespace_tbl) + 1
        for _, fn in
            pairs(hooks.get(bufnr, hooks.type.SCOPE_HIGHLIGHT) --[=[@as ibl.hooks.cb.scope_highlight[]]=])
        do
            scope_index = fn(buffer_state.tick, bufnr, scope, scope_index)
        end
    end

    --- Draw loop ---
    for i = 1, line_num do
        local line = lines[i]
        local row = i + offset
        if line_skipped[i] then
            vt.clear_buffer(bufnr, row)
            goto continue_draw
        end
        local whitespace, whitespace_tbl = unpack(calc_data[i])

        local is_current_indent_active = row >= current_indent.start_row
            and row <= current_indent.end_row
        local is_current_indent_start = row + 1 == current_indent.start_row
        local is_current_indent_end = row == current_indent.end_row

        local is_scope_active = row >= scope_row_start and row <= scope_row_end
        local is_scope_start = row == scope_row_start
        local is_scope_end = row == scope_row_end

        local blankline = line:len() == 0
        local whitespace_only = not blankline and line == whitespace
        local char_map = vt.get_char_map(config, listchars, whitespace_only, blankline)
        local virt_text, scope_hl, current_indent_hl = vt.get(
            config,
            char_map,
            whitespace_tbl,
            is_current_indent_active,
            current_indent_index,
            is_current_indent_end,
            current_indent_col_start_single,
            is_scope_active,
            scope_index,
            is_scope_end,
            scope_col_start_single
        )

        -- #### set virtual text ####
        vt.clear_buffer(bufnr, row)

        -- Show exact scope
        local scope_col_start_draw = #whitespace
        local scope_show_end_cond = #whitespace_tbl > scope_col_start_single

        if config.scope.show_exact_scope then
            scope_col_start_draw = exact_scope_col_start - 1
            scope_show_end_cond = #whitespace_tbl >= scope_col_start_single
        end

        -- one line scopes
        if
            config.scope.enabled
            and (
                (config.scope.show_start and is_scope_start)
                or (config.scope.show_end and is_scope_end)
            )
            and config.scope.show_exact_scope
            and scope_row_start == scope_row_end
        then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, scope_col_start_draw, {
                end_col = scope_col_end,
                hl_group = scope_hl.underline,
                priority = config.scope.priority,
                strict = false,
            })
            inlay_hints.set(bufnr, row - 1, #whitespace, scope_hl.underline, scope_hl.underline)
        end

        -- scope start
        if
            config.scope.enabled
            and config.scope.show_start
            and is_scope_start
            and scope_row_start ~= scope_row_end
            and not (
                current_indent_enabled
                and config.current_indent.show_start
                and is_current_indent_start
                and config.current_indent.priority > config.scope.priority
            )
        then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, scope_col_start_draw, {
                end_col = #line,
                hl_group = scope_hl.underline,
                priority = config.scope.priority,
                strict = false,
            })
            inlay_hints.set(bufnr, row - 1, #whitespace, scope_hl.underline, scope_hl.underline)
        end

        -- scope end
        if
            config.scope.enabled
            and config.scope.show_end
            and is_scope_end
            and scope_show_end_cond
            and scope_row_start ~= scope_row_end
            and not (
                current_indent_enabled
                and config.current_indent.show_end
                and is_current_indent_end
                and #whitespace_tbl > current_indent_col_start_single
                and config.current_indent.priority > config.scope.priority
            )
        then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, scope_col_start, {
                end_col = scope_col_end,
                hl_group = scope_hl.underline,
                priority = config.scope.priority,
                strict = false,
            })
            inlay_hints.set(bufnr, row - 1, #whitespace, scope_hl.underline, scope_hl.underline)
        end

        -- current indent start
        if
            current_indent_enabled
            and config.current_indent.show_start
            and is_current_indent_start
            and not (
                config.scope.enabled
                and config.scope.show_start
                and is_scope_start
                and config.scope.priority >= config.current_indent.priority
            )
        then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, #whitespace, {
                end_col = #line,
                hl_group = current_indent_hl.underline,
                priority = config.current_indent.priority,
                strict = false,
            })
            inlay_hints.set(bufnr, row - 1, #whitespace, current_indent_hl.underline, current_indent_hl.underline)
        end

        -- current indent end
        if
            current_indent_enabled
            and config.current_indent.show_end
            and is_current_indent_end
            and current_indent.start_row <= row
            and #whitespace_tbl > current_indent_col_start_single
            and not (
                config.scope.enabled
                and config.scope.show_end
                and is_scope_end
                and scope_show_end_cond
                and config.scope.priority >= config.current_indent.priority
            )
        then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, #whitespace, {
                end_col = #line,
                hl_group = current_indent_hl.underline,
                priority = config.current_indent.priority,
                strict = false,
            })
            inlay_hints.set(bufnr, row - 1, #whitespace, current_indent_hl.underline, current_indent_hl.underline)
        end

        for _, fn in
            pairs(hooks.get(bufnr, hooks.type.VIRTUAL_TEXT) --[=[@as ibl.hooks.cb.virtual_text[]]=])
        do
            virt_text = fn(buffer_state.tick, bufnr, row - 1, virt_text)
        end

        -- Indent
        if #virt_text > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, 0, {
                virt_text = virt_text,
                virt_text_pos = "overlay",
                hl_mode = "combine",
                priority = config.indent.priority,
                strict = false,
                -- virt_text_win_col = 0,
                virt_text_repeat_linebreak = true,
            })
        end

        ::continue_draw::
    end
end

return M
