local M = {}

local defaults = {
  fold_command = "Fold",
  unfold_command = "Unfold",
  mappings = { unfold = "<leader>uf", fold = "<leader>fu" },
}
local config = vim.deepcopy(defaults)

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shiftwidth()
  local width = vim.fn.shiftwidth()
  return width > 0 and width or 2
end

local function pos_cmp(a, b)
  if a[1] ~= b[1] then return a[1] < b[1] and -1 or 1 end
  if a[2] ~= b[2] then return a[2] < b[2] and -1 or 1 end
  return 0
end

-- Iterate code characters, ignoring strings and the comment forms shared by the
-- languages this plugin is normally used with.  This deliberately remains a
-- lexer, rather than pretending to be a language parser.
local function code_chars(text, fn)
  local quote, escaped, block_comment = nil, false, false
  local i = 1
  while i <= #text do
    local ch, next_ch = text:sub(i, i), text:sub(i + 1, i + 1)
    if block_comment then
      if ch == "*" and next_ch == "/" then block_comment, i = false, i + 2 else i = i + 1 end
    elseif quote then
      if escaped then escaped = false
      elseif ch == "\\" then escaped = true
      elseif ch == quote then quote = nil end
      i = i + 1
    elseif ch == "'" or ch == '"' or ch == "`" then
      quote, i = ch, i + 1
    elseif ch == "/" and next_ch == "*" then
      block_comment, i = true, i + 2
    elseif ch == "/" and next_ch == "/" then
      -- Do not treat # as a comment: CSS colours and selectors use it heavily.
      local newline = text:find("\n", i, true)
      i = newline and newline + 1 or #text + 1
    elseif ch == "-" and next_ch == "-" then
      local newline = text:find("\n", i, true)
      i = newline and newline + 1 or #text + 1
    else
      fn(ch, i)
      i = i + 1
    end
  end
end

local pairs = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function unwrap(text)
  local value = trim(text)
  if #value < 2 or pairs[value:sub(1, 1)] ~= value:sub(-1) then return nil end
  local stack, valid = {}, true
  code_chars(value, function(ch, i)
    if pairs[ch] then stack[#stack + 1] = ch
    elseif closers[ch] then
      if stack[#stack] ~= closers[ch] then valid = false; return end
      stack[#stack] = nil
      if #stack == 0 and i < #value then valid = false end
    end
  end)
  if not valid or #stack ~= 0 then return nil end
  return { open = value:sub(1, 1), close = value:sub(-1), inside = value:sub(2, -2) }
end

-- Return top-level items and whether the source ended with a separator.
local function split_sequence(text, separator, ignore_nesting)
  local items, start, stack = {}, 1, {}
  code_chars(text, function(ch, i)
    if pairs[ch] then stack[#stack + 1] = ch
    elseif closers[ch] and stack[#stack] == closers[ch] then stack[#stack] = nil
    elseif ch == separator and (ignore_nesting or #stack == 0) then
      items[#items + 1] = text:sub(start, i - 1)
      start = i + 1
    end
  end)
  local tail = text:sub(start)
  local trailing = trim(tail) == "" and #items > 0
  if not trailing then items[#items + 1] = tail end
  local nonempty = {}
  for _, item in ipairs(items) do if trim(item) ~= "" then nonempty[#nonempty + 1] = item end end
  return nonempty, trailing
end

local function sequence_kind(text)
  local commas = select(1, split_sequence(text, ","))
  if #commas > 1 then return "," end
  local semis = select(1, split_sequence(text, ";"))
  if #semis > 1 then return ";" end
  return nil
end

local transform

local function inline(text)
  return table.concat(vim.tbl_map(trim, vim.split(text, "\n", { plain = true })), " ")
end

local function dot_positions(text)
  local positions, stack = {}, {}
  code_chars(text, function(ch, i)
    if pairs[ch] then stack[#stack + 1] = ch
    elseif closers[ch] and stack[#stack] == closers[ch] then stack[#stack] = nil
    elseif ch == "." and #stack == 0 then
      local before, after = text:sub(i - 1, i - 1), text:sub(i + 1, i + 1)
      -- Do not turn decimal numbers, ranges, or spread/rest syntax into chains.
      if before ~= "." and after ~= "." and not before:match("%d") then positions[#positions + 1] = i end
    end
  end)
  return positions
end

local function transform_sequence(text, base_indent, mode, separator)
  local items, trailing = split_sequence(text, separator, true)
  if #items < 2 then return text end
  for i, item in ipairs(items) do items[i] = trim(item) end
  if mode == "fold" then
    return table.concat(items, separator .. " ") .. (trailing and separator or "")
  end
  local indent = base_indent
  for i, item in ipairs(items) do
    items[i] = indent .. item .. ((i < #items or trailing) and separator or "")
  end
  return table.concat(items, "\n")
end

local function transform_dots(text, base_indent, mode)
  if mode == "fold" then
    local folded = text:gsub("%s*\n%s*%.%s*", ".")
    return folded
  end
  if text:find("\n", 1, true) then return text end
  local dots = dot_positions(text)
  if #dots == 0 then return text end
  local lines, start = {}, 1
  for _, dot in ipairs(dots) do
    lines[#lines + 1] = trim(text:sub(start, dot - 1))
    start = dot
  end
  lines[#lines + 1] = trim(text:sub(start))
  if lines[1] == "" then return text end
  local indent = base_indent .. string.rep(" ", shiftwidth())
  for i = 2, #lines do lines[i] = indent .. lines[i] end
  return table.concat(lines, "\n")
end

local function transform_wrapped(text, base_indent, mode, requested_separator)
  local wrapped = unwrap(text)
  if not wrapped then return transform_dots(text, base_indent, mode) end
  local separator = requested_separator or sequence_kind(wrapped.inside)
  if not separator then
    -- Still recurse into a call/index/object nested in an otherwise ordinary expression.
    return wrapped.open .. transform(wrapped.inside, base_indent, mode, requested_separator) .. wrapped.close
  end

  local items, trailing = split_sequence(wrapped.inside, separator)
  local child_indent = base_indent .. string.rep(" ", shiftwidth())
  for i, item in ipairs(items) do
    items[i] = transform(trim(item), child_indent, mode, requested_separator)
    if mode == "fold" then items[i] = inline(items[i]) end
  end
  if mode == "fold" then
    return wrapped.open .. table.concat(items, separator .. " ") .. (trailing and separator or "") .. wrapped.close
  end
  if #items < 2 then return wrapped.open .. table.concat(items, separator .. " ") .. (trailing and separator or "") .. wrapped.close end

  local lines = { wrapped.open }
  for i, item in ipairs(items) do
    local item_lines = vim.split(item, "\n", { plain = true })
    lines[#lines + 1] = child_indent .. item_lines[1]
    for j = 2, #item_lines do lines[#lines + 1] = item_lines[j] end
    if i < #items or trailing then lines[#lines] = lines[#lines] .. separator end
  end
  lines[#lines + 1] = base_indent .. wrapped.close
  return table.concat(lines, "\n")
end

local function first_delimited_span(text)
  local stack, start, finish = {}, nil, nil
  code_chars(text, function(ch, i)
    if finish then return end
    if pairs[ch] then
      if not start then start = i end
      stack[#stack + 1] = ch
    elseif closers[ch] and stack[#stack] == closers[ch] then
      stack[#stack] = nil
      if #stack == 0 then finish = i end
    end
  end)
  return start, finish
end

transform = function(text, base_indent, mode, requested_separator)
  local wrapped = unwrap(text)
  if wrapped then return transform_wrapped(text, base_indent, mode, requested_separator) end
  if requested_separator == "." or (not requested_separator and (#dot_positions(text) > 0 or (mode == "fold" and text:match("\n%s*%.")))) then
    return transform_dots(text, base_indent, mode)
  end
  if requested_separator == "," or requested_separator == ";" then
    return transform_sequence(text, base_indent, mode, requested_separator)
  end

  -- Expressions such as `call({ one: 1, two: 2 })` are not themselves
  -- delimited, but can contain one or more delimited sequences.
  local out, offset = {}, 1
  while offset <= #text do
    local start, finish = first_delimited_span(text:sub(offset))
    if not start then
      out[#out + 1] = transform_dots(text:sub(offset), base_indent, mode)
      break
    end
    out[#out + 1] = transform(text:sub(offset, offset + start - 2), base_indent, mode, requested_separator)
    out[#out + 1] = transform_wrapped(text:sub(offset + start - 1, offset + finish - 1), base_indent, mode, requested_separator)
    offset = offset + finish
  end
  return table.concat(out)
end

local function visual_range()
  local a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local sr, sc, er, ec = a[2], a[3], b[2], b[3]
  if sr == 0 or er == 0 then return nil end
  if sr > er or (sr == er and sc > ec) then sr, er, sc, ec = er, sr, ec, sc end
  local lines = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
  if #lines == 0 then return nil end
  sc = math.max(1, math.min(sc, #lines[1] + 1)); ec = math.max(1, math.min(ec, #lines[#lines]))
  if sr == er then lines = { lines[1]:sub(sc, ec) } else lines[1] = lines[1]:sub(sc); lines[#lines] = lines[#lines]:sub(1, ec) end
  return { sr = sr, sc = sc, er = er, ec = ec, text = table.concat(lines, "\n"), indent = (vim.api.nvim_buf_get_lines(0, sr - 1, sr, false)[1]:sub(1, sc - 1):match("^%s*") or "") }
end

local function replace_range(range, lines)
  local first = vim.api.nvim_buf_get_lines(0, range.sr - 1, range.sr, false)[1] or ""
  local last = vim.api.nvim_buf_get_lines(0, range.er - 1, range.er, false)[1] or ""
  local prefix, suffix = first:sub(1, range.sc - 1), last:sub(range.ec + 1)
  if #lines == 1 then lines[1] = prefix .. lines[1] .. suffix
  else lines[1] = prefix .. lines[1]; lines[#lines] = lines[#lines] .. suffix end
  vim.api.nvim_buf_set_lines(0, range.sr - 1, range.er, false, lines)
  vim.api.nvim_win_set_cursor(0, { range.sr, #prefix })
end

local function enclosing_regions()
  local lines, cursor = vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.api.nvim_win_get_cursor(0)
  local source = table.concat(lines, "\n")
  local line_starts = { 1 }
  for newline in source:gmatch("()\n") do line_starts[#line_starts + 1] = newline + 1 end
  local function index_to_pos(index)
    local low, high = 1, #line_starts
    while low < high do
      local middle = math.floor((low + high + 1) / 2)
      if line_starts[middle] <= index then low = middle else high = middle - 1 end
    end
    return low, index - line_starts[low] + 1
  end
  local stack, found = {}, {}
  code_chars(source, function(ch, index)
    local row, col = index_to_pos(index)
    if pairs[ch] then stack[#stack + 1] = { ch = ch, row = row, col = col }
    elseif closers[ch] and stack[#stack] and stack[#stack].ch == closers[ch] then
      local open = table.remove(stack)
      if (open.row < cursor[1] or (open.row == cursor[1] and open.col <= cursor[2] + 1)) and (row > cursor[1] or (row == cursor[1] and col >= cursor[2] + 1)) then
        found[#found + 1] = { sr = open.row, sc = open.col, er = row, ec = col }
      end
    end
  end)
  table.sort(found, function(a, b) return a.sr > b.sr or (a.sr == b.sr and a.sc > b.sc) end)
  return found
end

local function region_range(region)
  local lines = vim.api.nvim_buf_get_lines(0, region.sr - 1, region.er, false)
  if region.sr == region.er then lines = { lines[1]:sub(region.sc, region.ec) } else lines[1] = lines[1]:sub(region.sc); lines[#lines] = lines[#lines]:sub(1, region.ec) end
  local line = vim.api.nvim_buf_get_lines(0, region.sr - 1, region.sr, false)[1]
  return { sr = region.sr, sc = region.sc, er = region.er, ec = region.ec, text = table.concat(lines, "\n"), indent = line:sub(1, region.sc - 1):match("^%s*") or "" }
end

local function line_sequence_range(separator)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  if #select(1, split_sequence(line, separator, true)) < 2 then return nil end
  return { sr = row, sc = 1, er = row, ec = #line, text = line, indent = line:match("^%s*") or "" }
end

local function dot_chain_range()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local first, last = row, row
  while first > 1 and trim(lines[first]):match("^%.") do first = first - 1 end
  while last < #lines and trim(lines[last + 1]):match("^%.") do last = last + 1 end
  if last == first and #dot_positions(lines[row]) == 0 then return nil end
  return { sr = first, sc = 1, er = last, ec = #lines[last], text = table.concat(vim.list_slice(lines, first, last), "\n"), indent = lines[first]:match("^%s*") or "" }
end

local function target(constraint, separator)
  local mode = vim.fn.mode(1)
  if mode:match("^[vVs\22]") then return visual_range() end
  for _, region in ipairs(enclosing_regions()) do
    local range = region_range(region)
    if not constraint or range.text:sub(1, 1) == constraint then return range end
  end
  if separator == "." then return dot_chain_range() end
  if separator == "," or separator == ";" then return line_sequence_range(separator) end
  return nil
end

local function parse_argument(argument)
  if argument == "(" or argument == "[" or argument == "{" then return nil, argument end
  if argument == "," or argument == ";" or argument == "." then return argument, nil end
  if argument == nil or argument == "" then return nil, nil end
  return false, nil
end

local function run(mode, argument)
  if vim.bo.buftype ~= "" or not vim.bo.modifiable then
    vim.notify((mode == "fold" and "Fold" or "Unfold") .. " only works in modifiable file buffers", vim.log.levels.WARN)
    return
  end
  local separator, constraint = parse_argument(argument)
  if separator == false then
    vim.notify("Expected one of: , ; . ( [ {", vim.log.levels.WARN)
    return
  end
  local range = target(constraint, separator)
  if not range then
    vim.notify("Place the cursor in a delimited sequence or dot chain, or select text", vim.log.levels.WARN)
    return
  end
  local output = transform(range.text, range.indent, mode, separator)
  -- A cursor inside `foo.bar()` is also inside the empty call parentheses.
  -- Prefer the useful containing dot chain when that small region is unchanged.
  if output == range.text and (separator == "." or separator == nil) and not vim.fn.mode(1):match("^[vVs\22]") then
    local chain = dot_chain_range()
    if chain then
      range, output = chain, transform(chain.text, chain.indent, mode, separator)
    end
  end
  if output == range.text then
    vim.notify("No supported sequence found", vim.log.levels.INFO)
    return
  end
  replace_range(range, vim.split(output, "\n", { plain = true }))
end

function M.fold(argument) run("fold", argument) end
function M.unfold(argument) run("unfold", argument) end

local function prompt(mode)
  local argument = vim.fn.getcharstr()
  run(mode, argument)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  pcall(vim.api.nvim_del_user_command, config.fold_command)
  pcall(vim.api.nvim_del_user_command, config.unfold_command)
  vim.api.nvim_create_user_command(config.fold_command, function(command) M.fold(command.args) end, {
    nargs = "?", range = true, desc = "Fold a sequence: :Fold [,;.( [{]"
  })
  vim.api.nvim_create_user_command(config.unfold_command, function(command) M.unfold(command.args) end, {
    nargs = "?", range = true, desc = "Unfold a sequence: :Unfold [,;.( [{]"
  })

  if config.mappings and config.mappings.unfold then
    vim.keymap.set({ "n", "x" }, config.mappings.unfold, function() prompt("unfold") end, { desc = "Unfold sequence" })
  end
  if config.mappings and config.mappings.fold then
    vim.keymap.set({ "n", "x" }, config.mappings.fold, function() prompt("fold") end, { desc = "Fold sequence" })
  end
end

return M
