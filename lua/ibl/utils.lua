local M = {}

---@param line string?
M.get_whitespace = function(line)
    if not line then
        return ""
    end
    return string.match(line, "^%s+") or ""
end

---@param opt table
---@param input table
---@param path string
M.validate = function(opt, input, path)
    vim.validate(opt)
    for key, _ in pairs(input) do
        if not opt[key] then
            error(string.format("'%s' is not a valid key of %s", key, path))
        end
    end
end

--- copy of vim.spit without vim.validate
---
---@param s string String to split
---@param sep string Separator or pattern
---@param opts (table|nil) Keyword arguments |kwargs| accepted by |vim.gsplit()|
---@return string[] List of split components
function M.split(s, sep, opts)
    local t = {}
    for c in M.gsplit(s, sep, opts) do
        table.insert(t, c)
    end
    return t
end

--- copy of vim.gsplit without vim.validate
---
--- @param s string String to split
--- @param sep string Separator or pattern
--- @param opts (table|nil) Keyword arguments |kwargs|:
---       - plain: (boolean) Use `sep` literally (as in string.find).
---       - trimempty: (boolean) Discard empty segments at start and end of the sequence.
---@return fun():string|nil (function) Iterator over the split components
function M.gsplit(s, sep, opts)
    local plain
    local trimempty = false
    if type(opts) == "boolean" then
        plain = opts -- For backwards compatibility.
    else
        opts = opts or {}
        plain, trimempty = opts.plain, opts.trimempty
    end

    local start = 1
    local done = false

    -- For `trimempty`: queue of collected segments, to be emitted at next pass.
    local segs = {}
    local empty_start = true -- Only empty segments seen so far.

    local function _pass(i, j, ...)
        if i then
            assert(j + 1 > start, "Infinite loop detected")
            local seg = s:sub(start, i - 1)
            start = j + 1
            return seg, ...
        else
            done = true
            return s:sub(start)
        end
    end

    return function()
        if trimempty and #segs > 0 then
            -- trimempty: Pop the collected segments.
            return table.remove(segs)
        elseif done or (s == "" and sep == "") then
            return nil
        elseif sep == "" then
            if start == #s then
                done = true
            end
            return _pass(start + 1, start)
        end

        local seg = _pass(s:find(sep, start, plain))

        -- Trim empty segments from start/end.
        if trimempty and seg ~= "" then
            empty_start = false
        elseif trimempty and seg == "" then
            while not done and seg == "" do
                table.insert(segs, 1, "")
                seg = _pass(s:find(sep, start, plain))
            end
            if done and seg == "" then
                return nil
            elseif empty_start then
                empty_start = false
                segs = {}
                return seg
            end
            if seg ~= "" then
                table.insert(segs, 1, seg)
            end
            return table.remove(segs)
        end

        return seg
    end
end

--- copy of vim.tbl_contains without vim.validate
---
---@param t table Table to check
---@param value any Value to compare or predicate function reference
---@param opts table? Keyword arguments |kwargs|:
---       - predicate: (boolean) `value` is a function reference to be checked (default false)
---@return boolean `true` if `t` contains `value`
M.tbl_contains = function(t, value, opts)
    local pred
    if opts and opts.predicate then
        vim.validate { value = { value, "c" } }
        pred = value
    else
        pred = function(v)
            return v == value
        end
    end

    for _, v in pairs(t) do
        if pred(v) then
            return true
        end
    end
    return false
end

--- copy of vim.tbl_count without vim.validate
---
---@param t table Table
---@return integer Number of non-nil values in table
M.tbl_count = function(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

--- copy of vim.tbl_map without vim.validate
---
---@generic T
---@param func fun(value: T): any (function) Function
---@param t table<any, T> (table) Table
---@return table Table of transformed values
M.tbl_map = function(func, t)
    local rettab = {}
    for k, v in pairs(t) do
        rettab[k] = func(v)
    end
    return rettab
end

--- copy of vim.tbl_filter without vim.validate
---
---@generic T
---@param func fun(value: T): boolean (function) Function
---@param t table<any, T> (table) Table
---@return T[] (table) Table of filtered values
M.tbl_filter = function(func, t)
    local rettab = {}
    for _, entry in pairs(t) do
        if func(entry) then
            table.insert(rettab, entry)
        end
    end
    return rettab
end

---@param codepoint integer
M.utf8_encode = function(codepoint)
    if codepoint <= 0x7F then
        return string.char(codepoint)
    elseif codepoint <= 0x7FF then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor((codepoint % 0x1000) / 0x40),
            0x80 + (codepoint % 0x40)
        )
    else
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor((codepoint % 0x40000) / 0x1000),
            0x80 + math.floor((codepoint % 0x1000) / 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
end

---@param input string?
M.encode = function(input)
    return (
        input
        and input
        :gsub("\\x%x%x", function(hex)
            return string.char(tonumber(hex:sub(3, 4), 16))
        end)
        :gsub("\\u%x%x%x%x", function(hex)
            return M.utf8_encode(tonumber(hex:sub(3, 6), 16))
        end)
        :gsub("\\U%x%x%x%x%x%x%x%x", function(hex)
            -- Note: This won't work for characters outside the range Lua's string can handle.
            return M.utf8_encode(tonumber(hex:sub(3, 10), 16))
        end)
    )
end

---@param bufnr number
---@return number?
M.get_win = function(bufnr)
    local win_list = vim.fn.win_findbuf(bufnr)
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, win in ipairs(win_list or {}) do
        if current_tab == vim.api.nvim_win_get_tabpage(win) then
            return win
        end
    end
    return win_list and win_list[1]
end

---@class ibl.listchars
---@field tabstop_overwrite boolean
---@field space_char string
---@field trail_char string?
---@field lead_char string?
---@field multispace_chars string[]?
---@field leadmultispace_chars string[]?
---@field tab_char_start string?
---@field tab_char_fill string
---@field tab_char_end string?

---@param bufnr number
---@return ibl.listchars
M.get_listchars = function(bufnr)
    local listchars
    local list = vim.opt.list:get()
    if list then
        listchars = vim.opt.listchars:get()
    end

    if bufnr ~= vim.api.nvim_get_current_buf() then
        local win_list = vim.fn.win_findbuf(bufnr)
        local win = win_list and win_list[1]
        if win then
            list = vim.api.nvim_get_option_value("list", { win = win })
            if list then
                local raw_value = vim.api.nvim_get_option_value("listchars", { win = win })
                listchars = {}
                for _, key_value_str in ipairs(M.split(raw_value, ",")) do
                    local key, value = unpack(M.split(key_value_str, ":"))
                    listchars[vim.trim(key)] = value
                end
            end
        end
    end

    if list then
        local tabstop_overwrite = false
        local tab_char
        local space_char = M.encode(listchars.space) or " "
        local multispace_chars
        local leadmultispace_chars
        if listchars.tab then
            tab_char = vim.fn.split(M.encode(listchars.tab), "\\zs")
        else
            tabstop_overwrite = true
            tab_char = { "^", "I" }
        end
        if listchars.multispace then
            multispace_chars = vim.fn.split(M.encode(listchars.multispace), "\\zs")
        end
        if listchars.leadmultispace then
            leadmultispace_chars = vim.fn.split(M.encode(listchars.leadmultispace), "\\zs")
        end
        return {
            tabstop_overwrite = tabstop_overwrite,
            space_char = space_char,
            trail_char = M.encode(listchars.trail),
            multispace_chars = multispace_chars,
            leadmultispace_chars = leadmultispace_chars,
            lead_char = M.encode(listchars.lead),
            tab_char_start = tab_char[1] or space_char,
            tab_char_fill = tab_char[2] or space_char,
            tab_char_end = tab_char[3],
        }
    end
    return {
        tabstop_overwrite = false,
        space_char = " ",
        trail_char = nil,
        lead_char = nil,
        multispace_chars = nil,
        leadmultispace_chars = nil,
        tab_char_start = nil,
        tab_char_fill = " ",
        tab_char_end = nil,
    }
end

---@param bufnr number
M.get_filetypes = function(bufnr)
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    if filetype == "" then
        return { "" }
    end
    return M.split(filetype, ".", { plain = true, trimempty = true })
end

local has_end_reg = vim.regex "^\\s*\\(}\\|]\\|)\\|end\\)"
---@param line string
M.has_end = function(line)
    if has_end_reg and has_end_reg:match_str(line) ~= nil then
        return true
    end
    return false
end

---@param bufnr number
M.get_offset = function(bufnr)
    local win = 0
    local win_view
    local win_end
    if bufnr == vim.api.nvim_get_current_buf() then
        win_view = vim.fn.winsaveview()
        win_end = vim.fn.line "w$"
    else
        local win_list = vim.fn.win_findbuf(bufnr)
        if not win_list or not win_list[1] then
            return 0, 0, 0, 0, 0
        end
        win = win_list[1]
        win_view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end

    local win_height = vim.api.nvim_win_get_height(win)
    if not win_end then
        win_end = win_height + (win_view.topline or 0)
    end
    if win_view.lnum > win_end then
        win_view.topline = win_view.lnum
        win_end = win_view.lnum + win_height
    end

    return win_view.leftcol or 0, win_view.topline or 0, win_end, win_height, win_view.lnum or 0
end

---@param bufnr number
---@param config ibl.config
M.is_buffer_active = function(bufnr, config)
    for _, filetype in ipairs(M.get_filetypes(bufnr)) do
        if M.tbl_contains(config.exclude.filetypes, filetype) then
            return false
        end
    end

    local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
    if M.tbl_contains(config.exclude.buftypes, buftype) then
        return false
    end

    return true
end

---@param bufnr number
---@param config ibl.config
M.is_current_indent_active = function(bufnr, config)
    if not config.current_indent.enabled then
        return false
    end
    for _, filetype in ipairs(M.get_filetypes(bufnr)) do
        if vim.tbl_contains(config.current_indent.exclude.filetypes, filetype) then
            return false
        end
    end

    return true
end

---@param bufnr number
---@return number
M.get_bufnr = function(bufnr)
    if not bufnr or bufnr == 0 then
        return vim.api.nvim_get_current_buf() --[[@as number]]
    end
    return bufnr
end

---@generic T: table
---@vararg T
---@return T
M.tbl_join = function(...)
    return vim.iter({ ... }):flatten():totable()
end

---@generic T
---@param list T[]
---@param i number
---@return T
M.tbl_get_index = function(list, i)
    return list[((i - 1) % #list) + 1]
end

M.highlight_from_extmark = function(bufnr, config, start_row, start_col, end_row, end_col, fallback_index)
    local highlight = config.scope.highlight

    if type(highlight) ~= "table" or start_row == math.huge then
        return fallback_index
    end

    local reverse_hls = {}
    for i, hl in ipairs(highlight) do
        reverse_hls[hl] = i
    end

    local start_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)
    local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)
    local end_pos
    local start_pos
    local start_pos_col
    local end_pos_col

    local function inspect_pos(pos)
        return vim.api.nvim_buf_get_extmarks(bufnr, -1, pos, pos, {
            type = "highlight",
            details = true,
        })
    end

    if end_line[1] then
        local end_pos_find = #end_line[1] - 1
        local try_find = end_line[1]:find "%S"
        if try_find then
            end_pos_find = try_find - 1
        end
        end_pos = inspect_pos { end_row, end_pos_find }
        end_pos_col = inspect_pos { end_row, end_col - 1 }
    end
    if start_line[1] then
        start_pos = inspect_pos { start_row, #start_line[1] - 1 }
        start_pos_col = inspect_pos { start_row, start_col }
    end

    if not end_pos and not start_pos then
        return fallback_index
    end

    -- it is most accurate to get correct colors from rainbow-delimiters via
    -- the scope, since you can have something like:
    -- function()
    --   ...
    -- end,
    -- where the last symbol will give you rainbow-delimiters highlights
    -- from the comma (nothing) and the last parenthesis (the wrong color)
    for _, extmark in ipairs(start_pos_col or {}) do
        local i = reverse_hls[extmark[4].hl_group]
        if i ~= nil then
            return i
        end
    end
    for _, extmark in ipairs(end_pos_col or {}) do
        local i = reverse_hls[extmark[4].hl_group]
        if i ~= nil then
            return i
        end
    end

    -- For some languages the scope extends before or after the delimiters.
    -- Make an attempt to capture them anyway by looking at the first character of the last line,
    -- and the last character of the first line.
    for _, extmark in ipairs(end_pos or {}) do
        local i = reverse_hls[extmark[4].hl_group]
        if i ~= nil then
            return i
        end
    end
    for _, extmark in ipairs(start_pos or {}) do
        local i = reverse_hls[extmark[4].hl_group]
        if i ~= nil then
            return i
        end
    end
    return fallback_index
end

---@param bufnr number
---@return boolean
M.has_empty_foldtext = function(bufnr)
    if vim.fn.has "nvim-0.10" == 0 then
        return false
    end
    local win = M.get_win(bufnr)
    if not win then
        return false
    end
    return vim.api.nvim_get_option_value("foldtext", { win = win }) == ""
end

M.quickclone = function(tbl)
    local res = {}
    for i, x in ipairs(tbl) do
        res[i] = x
    end
    return res
end

return M
