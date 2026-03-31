local M = {}

local defaults = {
	fold_command = "Fold",
	unfold_command = "Unfold",
}

local config = vim.deepcopy(defaults)

local function trim_ws(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_inline(text)
	text = text or ""
	local lines = vim.split(text, "\n", { plain = true })

	while #lines > 0 and trim_ws(lines[1]) == "" do
		table.remove(lines, 1)
	end
	while #lines > 0 and trim_ws(lines[#lines]) == "" do
		table.remove(lines)
	end

	for i, line in ipairs(lines) do
		lines[i] = trim_ws(line)
	end

	return table.concat(lines, " ")
end

local function split_top_level_commas(text)
	local items = {}
	local start_idx = 1
	local depth_paren, depth_brack, depth_brace = 0, 0, 0
	local quote = nil
	local escaped = false

	for i = 1, #text do
		local ch = text:sub(i, i)
		if quote then
			if escaped then
				escaped = false
			elseif ch == "\\" then
				escaped = true
			elseif ch == quote then
				quote = nil
			end
		else
			if ch == "'" or ch == '"' or ch == "`" then
				quote = ch
			elseif ch == "(" then
				depth_paren = depth_paren + 1
			elseif ch == ")" then
				depth_paren = math.max(0, depth_paren - 1)
			elseif ch == "[" then
				depth_brack = depth_brack + 1
			elseif ch == "]" then
				depth_brack = math.max(0, depth_brack - 1)
			elseif ch == "{" then
				depth_brace = depth_brace + 1
			elseif ch == "}" then
				depth_brace = math.max(0, depth_brace - 1)
			elseif ch == "," and depth_paren == 0 and depth_brack == 0 and depth_brace == 0 then
				items[#items + 1] = text:sub(start_idx, i - 1)
				start_idx = i + 1
			end
		end
	end

	items[#items + 1] = text:sub(start_idx)
	return items
end

local function compare_pos(a, b)
	if a[1] ~= b[1] then
		return a[1] < b[1] and -1 or 1
	end
	if a[2] ~= b[2] then
		return a[2] < b[2] and -1 or 1
	end
	return 0
end

local function cursor_within(start_pos, end_pos, cursor_pos)
	return compare_pos(start_pos, cursor_pos) <= 0 and compare_pos(cursor_pos, end_pos) <= 0
end

local function get_visual_selection_range()
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local sr, sc = start_pos[2], start_pos[3]
	local er, ec = end_pos[2], end_pos[3]
	if sr == 0 or er == 0 then
		return nil
	end

	if sr > er or (sr == er and sc > ec) then
		sr, er = er, sr
		sc, ec = ec, sc
	end

	local start_line = vim.api.nvim_buf_get_lines(0, sr - 1, sr, false)[1] or ""
	local end_line = vim.api.nvim_buf_get_lines(0, er - 1, er, false)[1] or ""
	if sc < 1 then sc = 1 end
	if ec < 1 then ec = 1 end
	if sc > #start_line + 1 then sc = #start_line + 1 end
	if ec > #end_line then ec = #end_line end

	local lines = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
	if #lines == 0 then return nil end
	if sr == er then
		lines = { start_line:sub(sc, ec) }
	else
		lines[1] = lines[1]:sub(sc)
		lines[#lines] = lines[#lines]:sub(1, ec)
	end

	return {
		sr = sr,
		sc = sc,
		er = er,
		ec = ec,
		text = table.concat(lines, "\n"),
		base_indent = (start_line:sub(1, sc - 1):match("^%s*") or ""),
	}
end

local function find_enclosing_delimited_regions()
	local buf = vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)
	local cur_pos = { cur[1], cur[2] + 1 }
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local stack = {}
	local regions = {}
	local openers = { ["("] = ")", ["["] = "]", ["{"] = "}" }
	local closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
	local quote = nil
	local escaped = false

	for row, line in ipairs(lines) do
		for col = 1, #line do
			local ch = line:sub(col, col)
			if quote then
				if escaped then
					escaped = false
				elseif ch == "\\" then
					escaped = true
				elseif ch == quote then
					quote = nil
				end
			else
				if ch == "'" or ch == '"' or ch == "`" then
					quote = ch
				elseif openers[ch] then
					stack[#stack + 1] = {
						open = ch,
						close = openers[ch],
						start_pos = { row, col },
					}
				elseif closers[ch] and stack[#stack] and stack[#stack].open == closers[ch] then
					local entry = table.remove(stack)
					local region = {
						buf = buf,
						open = entry.open,
						close = entry.close,
						start_pos = entry.start_pos,
						end_pos = { row, col },
					}
					if cursor_within(region.start_pos, region.end_pos, cur_pos) then
						regions[#regions + 1] = region
					end
				end
			end
		end
	end

	table.sort(regions, function(a, b)
		local start_cmp = compare_pos(a.start_pos, b.start_pos)
		if start_cmp ~= 0 then
			return start_cmp > 0
		end
		return compare_pos(a.end_pos, b.end_pos) < 0
	end)

	if #regions > 0 then
		return regions
	end

	local row, col0 = cur[1], cur[2]
	local line = lines[row] or ""
	for col = math.max(1, col0 + 1), #line do
		local ch = line:sub(col, col)
		if openers[ch] then
			return {
				{
					buf = buf,
					open = ch,
					close = openers[ch],
					start_pos = { row, col },
					end_pos = { row, col },
				},
			}
		end
	end

	return {}
end

local function get_region_parts(region)
	local bufnr = region.buf
	local sr, sc1 = region.start_pos[1], region.start_pos[2]
	local er, ec1 = region.end_pos[1], region.end_pos[2]
	local sc0, ec0 = sc1 - 1, ec1 - 1

	local start_line = vim.api.nvim_buf_get_lines(bufnr, sr - 1, sr, false)[1] or ""
	local end_line = vim.api.nvim_buf_get_lines(bufnr, er - 1, er, false)[1] or ""

	local prefix = start_line:sub(1, sc0)
	local suffix = end_line:sub(ec0 + 2)
	local open_ch = start_line:sub(sc0 + 1, sc0 + 1)
	local close_ch = end_line:sub(ec0 + 1, ec0 + 1)

	local inside_lines = vim.api.nvim_buf_get_lines(bufnr, sr - 1, er, false)
	if #inside_lines == 0 then inside_lines = { "" } end
	if sr == er then
		inside_lines = { start_line:sub(sc0 + 2, ec0) }
	else
		inside_lines[1] = inside_lines[1]:sub(sc0 + 2)
		inside_lines[#inside_lines] = inside_lines[#inside_lines]:sub(1, ec0)
	end

	return {
		buf = bufnr,
		sr = sr,
		er = er,
		prefix = prefix,
		suffix = suffix,
		open_ch = open_ch,
		close_ch = close_ch,
		inside_text = table.concat(inside_lines, "\n"),
		base_indent = prefix:match("^%s*") or "",
	}
end

local function replace_visual_selection(range, new_lines)
	local start_line = vim.api.nvim_buf_get_lines(0, range.sr - 1, range.sr, false)[1] or ""
	local end_line = vim.api.nvim_buf_get_lines(0, range.er - 1, range.er, false)[1] or ""
	local prefix = start_line:sub(1, range.sc - 1)
	local suffix = end_line:sub(range.ec + 1)

	if #new_lines == 0 then
		new_lines = { "" }
	end

	local out = {}
	if #new_lines == 1 then
		out = { prefix .. new_lines[1] .. suffix }
	else
		out[1] = prefix .. new_lines[1]
		for i = 2, #new_lines - 1 do
			out[#out + 1] = new_lines[i]
		end
		out[#out + 1] = new_lines[#new_lines] .. suffix
	end

	vim.api.nvim_buf_set_lines(0, range.sr - 1, range.er, false, out)
	vim.api.nvim_win_set_cursor(0, { range.sr, #prefix })
end

local function replace_region_text(parts, new_lines)
	local bufnr = parts.buf

	if #new_lines == 0 then
		new_lines = { "" }
	end

	local out = {}
	if #new_lines == 1 then
		out = { parts.prefix .. new_lines[1] .. parts.suffix }
	else
		out[1] = parts.prefix .. new_lines[1]
		for i = 2, #new_lines - 1 do
			out[#out + 1] = new_lines[i]
		end
		out[#out + 1] = new_lines[#new_lines] .. parts.suffix
	end

	vim.api.nvim_buf_set_lines(bufnr, parts.sr - 1, parts.er, false, out)
	vim.api.nvim_win_set_cursor(0, { parts.sr, #parts.prefix })
end

local function unwrap_wrapped_collection(text)
	local t = trim_ws(text)
	if #t < 2 then
		return nil
	end

	local open = t:sub(1, 1)
	local close = t:sub(-1)
	local pairs = { ["("] = ")", ["["] = "]", ["{"] = "}" }
	if pairs[open] ~= close then
		return nil
	end

	local stack = {}
	local quote = nil
	local escaped = false
	local closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

	for i = 1, #t do
		local ch = t:sub(i, i)
		if quote then
			if escaped then
				escaped = false
			elseif ch == "\\" then
				escaped = true
			elseif ch == quote then
				quote = nil
			end
		else
			if ch == "'" or ch == '"' or ch == "`" then
				quote = ch
			elseif pairs[ch] then
				stack[#stack + 1] = ch
			elseif closers[ch] then
				if stack[#stack] ~= closers[ch] then
					return nil
				end
				stack[#stack] = nil
				if #stack == 0 and i < #t then
					return nil
				end
			end
		end
	end

	if #stack ~= 0 then
		return nil
	end

	return {
		open = open,
		close = close,
		inside = t:sub(2, -2),
	}
end

local function get_active_visual_range()
	local mode = vim.fn.mode(1)
	if not mode:match("^[vVs\22]") then
		return nil
	end
	return get_visual_selection_range()
end

local function get_recent_visual_range_at_cursor()
	local range = get_visual_selection_range()
	if not range then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_pos = { cursor[1], cursor[2] + 1 }
	local start_pos = { range.sr, range.sc }
	local end_pos = { range.er, range.ec }
	if cursor_within(start_pos, end_pos, cursor_pos) then
		return range
	end
	return nil
end

local function collect_collection_targets()
	local visual_range = get_active_visual_range() or get_recent_visual_range_at_cursor()
	local targets = {}
	if visual_range then
		local wrapped = unwrap_wrapped_collection(visual_range.text)
		targets[#targets + 1] = {
			base_indent = visual_range.base_indent,
			original_text = visual_range.text,
			replace = function(new_lines)
				replace_visual_selection(visual_range, new_lines)
			end,
			wrapped = wrapped,
		}
		return targets
	end

	for _, region in ipairs(find_enclosing_delimited_regions()) do
		if compare_pos(region.start_pos, region.end_pos) < 0 then
			local parts = get_region_parts(region)
			targets[#targets + 1] = {
				base_indent = parts.base_indent,
				original_text = parts.open_ch .. parts.inside_text .. parts.close_ch,
				replace = function(new_lines)
					replace_region_text(parts, new_lines)
				end,
				wrapped = {
					open = parts.open_ch,
					close = parts.close_ch,
					inside = parts.inside_text,
				},
			}
		end
	end

	return targets
end

local function get_shiftwidth()
	local sw = vim.fn.shiftwidth()
	if sw == nil or sw <= 0 then
		sw = 2
	end
	return sw
end

local function find_next_collection_span(text, start_idx)
	local openers = { ["("] = ")", ["["] = "]", ["{"] = "}" }
	local closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
	local quote = nil
	local escaped = false
	local stack = {}
	local span_start = nil

	for i = start_idx or 1, #text do
		local ch = text:sub(i, i)
		if quote then
			if escaped then
				escaped = false
			elseif ch == "\\" then
				escaped = true
			elseif ch == quote then
				quote = nil
			end
		else
			if ch == "'" or ch == '"' or ch == "`" then
				quote = ch
			elseif openers[ch] then
				if not span_start then
					span_start = i
				end
				stack[#stack + 1] = ch
			elseif closers[ch] and stack[#stack] == closers[ch] then
				stack[#stack] = nil
				if #stack == 0 and span_start then
					return span_start, i
				end
			end
		end
	end

	return nil
end

local transform_text

local function transform_collection_text(text, base_indent, mode)
	local wrapped = unwrap_wrapped_collection(text)
	if not wrapped then
		return text
	end

	local child_indent = base_indent .. string.rep(" ", get_shiftwidth())
	local raw_items = split_top_level_commas(wrapped.inside)
	local items = {}
	for _, item in ipairs(raw_items) do
		local cleaned = trim_ws(item)
		if cleaned ~= "" then
			local transformed = transform_text(cleaned, child_indent, mode)
			if mode == "fold" then
				transformed = normalize_inline(transformed)
			end
			items[#items + 1] = transformed
		end
	end

	if mode == "fold" then
		return wrapped.open .. table.concat(items, ", ") .. wrapped.close
	end

	if #items < 2 then
		return wrapped.open .. table.concat(items, ", ") .. wrapped.close
	end

	local lines = { wrapped.open }
	for i, item in ipairs(items) do
		local item_lines = vim.split(item, "\n", { plain = true })
		if #item_lines == 0 then
			item_lines = { "" }
		end

		lines[#lines + 1] = child_indent .. item_lines[1]
		for j = 2, #item_lines do
			lines[#lines + 1] = item_lines[j]
		end
		if i < #items then
			lines[#lines] = lines[#lines] .. ","
		end
	end
	lines[#lines + 1] = base_indent .. wrapped.close
	return table.concat(lines, "\n")
end

transform_text = function(text, base_indent, mode)
	local out = {}
	local idx = 1

	while idx <= #text do
		local span_start, span_end = find_next_collection_span(text, idx)
		if not span_start or not span_end then
			out[#out + 1] = text:sub(idx)
			break
		end

		out[#out + 1] = text:sub(idx, span_start - 1)
		out[#out + 1] = transform_collection_text(text:sub(span_start, span_end), base_indent, mode)
		idx = span_end + 1
	end

	return table.concat(out)
end

local function build_unfolded_lines(target)
	local transformed = transform_text(target.original_text, target.base_indent, "unfold")
	if transformed == target.original_text then
		return nil
	end
	return vim.split(transformed, "\n", { plain = true })
end

local function build_folded_lines(target)
	local transformed = transform_text(target.original_text, target.base_indent, "fold")
	if transformed == target.original_text then
		return nil
	end
	return vim.split(transformed, "\n", { plain = true })
end

local function select_collection_target(builder)
	local targets = collect_collection_targets()
	for _, target in ipairs(targets) do
		local new_lines = builder(target)
		if new_lines and table.concat(new_lines, "\n") ~= trim_ws(target.original_text) then
			return target, new_lines
		end
	end

	local fallback = targets[1]
	if fallback then
		return fallback, builder(fallback)
	end

	return nil, nil
end

function M.unfold()
	if vim.bo.buftype ~= "" or not vim.bo.modifiable then
		vim.notify("Unfold only works in modifiable file buffers", vim.log.levels.WARN)
		return
	end

	local target, out = select_collection_target(build_unfolded_lines)
	if not target then
		vim.notify("Place the cursor in a bracketed collection or make a selection, then run :" .. config.unfold_command, vim.log.levels.WARN)
		return
	end
	if not out then
		vim.notify("No comma-separated list to unfold", vim.log.levels.INFO)
		return
	end

	target.replace(out)
end

function M.fold()
	if vim.bo.buftype ~= "" or not vim.bo.modifiable then
		vim.notify("Fold only works in modifiable file buffers", vim.log.levels.WARN)
		return
	end

	local target, out = select_collection_target(build_folded_lines)
	if not target then
		vim.notify("Place the cursor in a bracketed collection or make a selection, then run :" .. config.fold_command, vim.log.levels.WARN)
		return
	end
	if not out then
		vim.notify("No list content to fold", vim.log.levels.INFO)
		return
	end

	target.replace(out)
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

	pcall(vim.api.nvim_del_user_command, config.fold_command)
	pcall(vim.api.nvim_del_user_command, config.unfold_command)

	vim.api.nvim_create_user_command(config.fold_command, M.fold, {
		range = true,
		desc = "Fold the enclosing comma-separated collection",
	})
	vim.api.nvim_create_user_command(config.unfold_command, M.unfold, {
		range = true,
		desc = "Unfold the enclosing comma-separated collection",
	})
end

return M
