local conf = require "ibl.config"
local utils = require "ibl.utils"
local indent = require "ibl.indent"
local M = {}

---@enum ibl.hooks.type
M.type = {
    ACTIVE = "ACTIVE",
    SCOPE_ACTIVE = "SCOPE_ACTIVE",
    CURRENT_INDENT_ACTIVE = "CURRENT_INDENT_ACTIVE",
    SKIP_LINE = "SKIP_LINE",
    WHITESPACE = "WHITESPACE",
    VIRTUAL_TEXT = "VIRTUAL_TEXT",
    SCOPE_HIGHLIGHT = "SCOPE_HIGHLIGHT",
    CURRENT_INDENT_HIGHLIGHT = "CURRENT_INDENT_HIGHLIGHT",
    CLEAR = "CLEAR",
    HIGHLIGHT_SETUP = "HIGHLIGHT_SETUP",
}

---@class ibl.hooks.options
---@field bufnr number?
local default_opts = {
    bufnr = nil,
}

local hooks = {
    [M.type.ACTIVE] = {},
    [M.type.SCOPE_ACTIVE] = {},
    [M.type.CURRENT_INDENT_ACTIVE] = {},
    [M.type.SKIP_LINE] = {},
    [M.type.WHITESPACE] = {},
    [M.type.VIRTUAL_TEXT] = {},
    [M.type.SCOPE_HIGHLIGHT] = {},
    [M.type.CURRENT_INDENT_HIGHLIGHT] = {},
    [M.type.CLEAR] = {},
    [M.type.HIGHLIGHT_SETUP] = {},
    buffer_scoped = {},
}
local count = 0

---@alias ibl.hooks.cb.active fun(bufnr: number): boolean
---@alias ibl.hooks.cb.scope_active fun(bufnr: number): boolean
---@alias ibl.hooks.cb.current_indent_active fun(bufnr: number): boolean
---@alias ibl.hooks.cb.skip_line fun(tick: number, bufnr: number, row: number, line: string): boolean
---@alias ibl.hooks.cb.whitespace fun(tick: number, bufnr: number, row: number, whitespace: ibl.indent.whitespace[]): ibl.indent.whitespace[]
---@alias ibl.hooks.cb.virtual_text fun(tick: number, bufnr: number, row: number, virt_text: ibl.virtual_text): ibl.virtual_text
---@alias ibl.hooks.cb.scope_highlight fun(tick: number, bufnr: number, scope: TSNode, scope_index: number): number
---@alias ibl.hooks.cb.current_indent_highlight fun(tick: number, bufnr: number, current_indent: ibl.current_indent, current_indent_index: number): number
---@alias ibl.hooks.cb.clear fun(bufnr: number)
---@alias ibl.hooks.cb.highlight_setup fun()

--- Registers a hook
---
--- Each hook type takes a callback a different function, and a configuration table
---@param type ibl.hooks.type
---@param cb function
---@param opts ibl.hooks.options
---@overload fun(type: 'ACTIVE', cb: ibl.hooks.cb.active, opts: ibl.hooks.options?): string
---@overload fun(type: 'SCOPE_ACTIVE', cb: ibl.hooks.cb.scope_active, opts: ibl.hooks.options?): string
---@overload fun(type: 'CURRENT_INDENT_ACTIVE', cb: ibl.hooks.cb.current_indent_active, opts: ibl.hooks.options?): string
---@overload fun(type: 'SKIP_LINE', cb: ibl.hooks.cb.skip_line, opts: ibl.hooks.options?): string
---@overload fun(type: 'WHITESPACE', cb: ibl.hooks.cb.whitespace, opts: ibl.hooks.options?): string
---@overload fun(type: 'VIRTUAL_TEXT', cb: ibl.hooks.cb.virtual_text, opts: ibl.hooks.options?): string
---@overload fun(type: 'SCOPE_HIGHLIGHT', cb: ibl.hooks.cb.scope_highlight, opts: ibl.hooks.options?): string
---@overload fun(type: 'CURRENT_INDENT_HIGHLIGHT', cb: ibl.hooks.cb.current_indent_highlight, opts: ibl.hooks.options?): string
---@overload fun(type: 'CLEAR', cb: ibl.hooks.cb.clear, opts: ibl.hooks.options?): string
---@overload fun(type: 'HIGHLIGHT_SETUP', cb: ibl.hooks.cb.highlight_setup, opts: ibl.hooks.options?): string
M.register = function(type, cb, opts)
    vim.validate {
        type = {
            type,
            function(t)
                return M.type[t] == t
            end,
            "hooks type enum",
        },
        cb = { cb, "function" },
        opts = { opts, "table", true },
    }
    opts = vim.tbl_deep_extend("keep", opts or {}, default_opts)
    vim.validate {
        bufnr = { opts.bufnr, "number", true },
    }
    if opts.bufnr then
        opts.bufnr = utils.get_bufnr(opts.bufnr)
    end
    count = count + 1
    local hook_id = type .. "_" .. tostring(count)

    if opts.bufnr then
        local bufnr = tostring(opts.bufnr)
        if not hooks.buffer_scoped[bufnr] then
            hooks.buffer_scoped[bufnr] = {
                [M.type.ACTIVE] = {},
                [M.type.SCOPE_ACTIVE] = {},
                [M.type.CURRENT_INDENT_ACTIVE] = {},
                [M.type.SKIP_LINE] = {},
                [M.type.WHITESPACE] = {},
                [M.type.VIRTUAL_TEXT] = {},
                [M.type.SCOPE_HIGHLIGHT] = {},
                [M.type.CURRENT_INDENT_HIGHLIGHT] = {},
                [M.type.CLEAR] = {},
                [M.type.HIGHLIGHT_SETUP] = {},
            }
        end
        hooks.buffer_scoped[bufnr][type][hook_id] = cb
    else
        hooks[type][hook_id] = cb
    end

    return hook_id
end

--- Clears a hook by id
---
---@param id string
M.clear = function(id)
    vim.validate { id = { id, "string" } }
    local type, hook_id = unpack(utils.split(id, "_"))
    if not type or not hook_id or not utils.tbl_contains(M.type, type) then
        return
    end
    hooks[type][hook_id] = nil
end

--- Clears all hooks
---
M.clear_all = function()
    hooks = {
        [M.type.ACTIVE] = {},
        [M.type.SCOPE_ACTIVE] = {},
        [M.type.CURRENT_INDENT_ACTIVE] = {},
        [M.type.SKIP_LINE] = {},
        [M.type.WHITESPACE] = {},
        [M.type.VIRTUAL_TEXT] = {},
        [M.type.SCOPE_HIGHLIGHT] = {},
        [M.type.CURRENT_INDENT_HIGHLIGHT] = {},
        [M.type.CLEAR] = {},
        [M.type.HIGHLIGHT_SETUP] = {},
        buffer_scoped = {},
    }
end

--- Returns all hooks of the given type for a buffer
---
---@param bufnr number
---@param type ibl.hooks.type
---@overload fun(bufnr: number, type: 'ACTIVE'): ibl.hooks.cb.active[]
---@overload fun(bufnr: number, type: 'SCOPE_ACTIVE'): ibl.hooks.cb.scope_active[]
---@overload fun(bufnr: number, type: 'CURRENT_INDENT_ACTIVE'): ibl.hooks.cb.current_indent_active[]
---@overload fun(bufnr: number, type: 'SKIP_LINE'): ibl.hooks.cb.skip_line[]
---@overload fun(bufnr: number, type: 'WHITESPACE'): ibl.hooks.cb.whitespace[]
---@overload fun(bufnr: number, type: 'VIRTUAL_TEXT'): ibl.hooks.cb.virtual_text[]
---@overload fun(bufnr: number, type: 'SCOPE_HIGHLIGHT'): ibl.hooks.cb.scope_highlight[]
---@overload fun(bufnr: number, type: 'CURRENT_INDENT_HIGHLIGHT'): ibl.hooks.cb.current_indent_highlight[]
---@overload fun(bufnr: number, type: 'CLEAR'): ibl.hooks.cb.clear[]
---@overload fun(bufnr: number, type: 'HIGHLIGHT_SETUP'): ibl.hooks.cb.highlight_setup[]
M.get = function(bufnr, type)
    local bufnr_str = tostring(bufnr)
    local list = {}
    for _, hook in pairs(hooks[type]) do
        table.insert(list, hook)
    end
    if hooks.buffer_scoped[bufnr_str] then
        for _, hook in pairs(hooks.buffer_scoped[bufnr_str][type]) do
            table.insert(list, hook)
        end
    end

    return list
end

--- Built in hooks
---
--- You can register them yourself using `hooks.register`
---
--- <code>
--- hooks.register(
---     hooks.type.SKIP_LINE,
---     hooks.builtin.skip_preproc_lines,
---     { bufnr = 0 }
--- )
--- </code>
M.builtin = {
    ---@type ibl.hooks.cb.skip_line
    skip_preproc_lines = function(_, _, _, line)
        for _, pattern in ipairs {
            "^#%s*if",
            "^#%s*ifdef",
            "^#%s*ifndef",
            "^#%s*elif",
            "^#%s*elifdef",
            "^#%s*elifndef",
            "^#%s*else",
            "^#%s*endif",
            "^#%s*define",
            "^#%s*undef",
            "^#%s*warning",
            "^#%s*error",
        } do
            if line:match(pattern) then
                return true
            end
        end
        return false
    end,

    ---@type ibl.hooks.cb.scope_highlight
    scope_highlight_from_extmark = function(_, bufnr, scope, scope_index)
        local config = conf.get_config(bufnr)
        local start_row, start_col = scope:start()
        local end_row, end_col = scope:end_()

        return utils.highlight_from_extmark(bufnr, config, start_row, start_col, end_row, end_col, scope_index)
    end,

    ---@type ibl.hooks.cb.current_indent_highlight
    current_indent_highlight_from_extmark = function(_, bufnr, current_indent, current_indent_index)
        local config = conf.get_config(bufnr)

        return utils.highlight_from_extmark(
            bufnr,
            config,
            current_indent.start_row - 1,
            -1,
            current_indent.end_row - 1,
            -1,
           current_indent_index
        )
    end,

    ---@type ibl.hooks.cb.whitespace
    hide_first_space_indent_level = function(_, _, _, whitespace_tbl)
        if whitespace_tbl[1] == indent.whitespace.INDENT then
            whitespace_tbl[1] = indent.whitespace.SPACE
        end
        return whitespace_tbl
    end,

    ---@type ibl.hooks.cb.whitespace
    hide_first_tab_indent_level = function(_, _, _, whitespace_tbl)
        if
            whitespace_tbl[1] == indent.whitespace.TAB_START
            or whitespace_tbl[1] == indent.whitespace.TAB_START_SINGLE
        then
            whitespace_tbl[1] = indent.whitespace.TAB_FILL
        end
        return whitespace_tbl
    end,
}

return M
