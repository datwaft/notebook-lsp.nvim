-- Reads jupytext Markdown notebooks the way jupytext does: a port of the parts
-- of jupytext/header.py, cell_reader.py (MarkdownCellReader), cell_metadata.py,
-- stringparser.py and languages.py that decide which lines are code cells, and
-- in which language. Markdown cells and cell metadata are read only as far as
-- that needs. It matches jupytext 1.19.6 (see DEVELOPMENT.md to follow a newer
-- one).
--
-- Ported from jupytext, Copyright (c) 2018-2026 Marc Wouts, MIT License.
-- See THIRD_PARTY_NOTICES.
local M = {}

---@class notebook_lsp.jupytext.Cell
---@field language string the kernel's language, or the cell's own (e.g. "bash") for cells jupytext runs through a magic
---@field start integer 0-based row of the cell's first line of code
---@field lines string[]

---@class notebook_lsp.jupytext.Notebook
---@field language string the kernel's language
---@field cells notebook_lsp.jupytext.Cell[] code cells, in order

-- Comment syntax by language, for the languages jupytext has scripts for (_SCRIPT_EXTENSIONS)
local COMMENT = {
  python = "#",
  coconut = "#",
  R = "#",
  julia = "#",
  ["c++"] = "//",
  scheme = ";;",
  clojure = ";;",
  bash = "#",
  powershell = "#",
  q = "/",
  matlab = "%",
  ["wolfram language"] = "(*",
  idl = ";",
  javascript = "//",
  typescript = "//",
  scala = "//",
  rust = "//",
  robotframework = "#",
  csharp = "//",
  fsharp = "//",
  sos = "#",
  java = "//",
  groovy = "//",
  sage = "#",
  ocaml = "(*",
  haskell = "--",
  tcl = "#",
  maxima = "/*",
  gnuplot = "#",
  stata = "//",
  sas = "/*",
  jenner = "/*",
  xonsh = "#",
  logtalk = "%",
  lua = "--",
  go = "//",
}

-- Languages a code cell can be in (_JUPYTER_LANGUAGES), in lower case, and the
-- names a code fence can use (_JUPYTER_LANGUAGES_LOWER_AND_UPPER)
local LANGUAGES, FENCE_LANGUAGES = {}, {}
do
  local magics = {
    "R",
    "bash",
    "sh",
    "python",
    "python2",
    "python3",
    "coconut",
    "javascript",
    "js",
    "perl",
    "html",
    "latex",
    "markdown",
    "pypy",
    "ruby",
    "script",
    "svg",
    "matlab",
    "octave",
    "idl",
    "robotframework",
    "sas",
    "spark",
    "sql",
    "cython",
    "haskell",
    "tcl",
    "gnuplot",
    "wolfram language",
  }
  local languages = vim.list_extend(vim.list_extend(magics, vim.tbl_keys(COMMENT)), { "c#", "f#", "cs", "fs" })
  for _, language in ipairs(languages) do
    LANGUAGES[language:lower()] = true
    FENCE_LANGUAGES[language] = true
    FENCE_LANGUAGES[language:upper()] = true
  end
end

-- Python's None, which jupytext gives attributes without a value (e.g. `.noeval`)
local NONE = vim.NIL

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function strip(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Index of the last `needle` in `text` that starts before `before`, or nil.
---@param before integer? exclusive; the whole text when nil
local function rfind(text, needle, before)
  local found
  local i = text:find(needle, 1, true)
  while i and (before == nil or i < before) do
    found = i
    i = text:find(needle, i + 1, true)
  end
  return found
end

--- jupytext's usual_language_name: the name jupytext compares languages by.
local function usual_language_name(language)
  language = language:lower()
  if language == "r" then
    return "R"
  elseif vim.startswith(language, "c++") then
    return "c++"
  elseif language == "octave" then
    return "matlab"
  elseif language == "cs" or language == "c#" then
    return "csharp"
  elseif language == "fs" or language == "f#" then
    return "fsharp"
  elseif language == "sas" then
    return "SAS"
  end
  return language
end

--------------------------------------------------------------------------------
-- The YAML header
--------------------------------------------------------------------------------

-- Marks a YAML value this reader can't read, such as a flow mapping
local UNSUPPORTED = {}

--- Reads the block mappings of plain and quoted scalars that jupytext writes.
--- Values it can't read are kept as unsupported, and fail when looked up.
---@param lines string[]
---@return table
local function read_yaml(lines)
  local root = {}
  local stack = { { indent = -1, map = root } }
  for _, line in ipairs(lines) do
    local indent, key, value = line:match("^( *)([%w_%-%.]+)%s*:(.*)$")
    -- Other lines (list items, comments, continued scalars) only hold values we don't read
    if key and (value == "" or value:match("^%s")) then
      while stack[#stack].indent >= #indent do
        table.remove(stack)
      end
      local map = stack[#stack].map
      value = strip(value)
      if value == "" then
        map[key] = {}
        table.insert(stack, { indent = #indent, map = map[key] })
      elseif vim.startswith(value, "'") then
        local quoted = assert(value:match("^'(.*)'"), "notebook-lsp: can't read the notebook header line: " .. line)
        map[key] = quoted:gsub("''", "'")
      elseif vim.startswith(value, '"') then
        map[key] = assert(value:match('^"(.*)"'), "notebook-lsp: can't read the notebook header line: " .. line)
      elseif value:match("^[%[{|>&*!%%@`]") then
        map[key] = { [UNSUPPORTED] = value }
      else
        map[key] = value:gsub("%s+#.*$", "")
      end
    end
  end
  return root
end

--- The string at `path` (e.g. "kernelspec.language") of a read_yaml tree, or nil.
---@return string?
local function yaml_string(tree, path)
  local node = tree
  for key in path:gmatch("[^.]+") do
    if node == nil then
      return nil
    end
    assert(type(node) == "table", ("notebook-lsp: the notebook header has no mapping at %s"):format(path))
    node = node[key]
    if type(node) == "table" and node[UNSUPPORTED] then
      error(("notebook-lsp: can't read %s in the notebook header: %s"):format(path, node[UNSUPPORTED]))
    end
  end
  assert(
    node == nil or type(node) == "string",
    ("notebook-lsp: %s in the notebook header is not a string"):format(path)
  )
  return node
end

--- jupytext's header_to_metadata_and_cell: the `jupyter` metadata of the YAML
--- header, which may be hidden in an HTML comment, and the index of the first
--- line after the header. Nil when there is no header with a `jupyter` section.
---@param lines string[]
---@return table? jupyter
---@return integer first
local function read_header(lines)
  local function encoding(line)
    return line:match("coding[:=][ \t]*([%-_.%w]+)")
  end

  local jupyter, in_jupyter, in_html_div, started, ended = {}, false, false, false, false
  local last = 0
  for i, line in ipairs(lines) do
    last = i
    if i == 1 and vim.startswith(line, "#!") then
      goto continue
    end
    if i == 1 or (i == 2 and not encoding(lines[1])) then
      local name = encoding(line)
      if name then
        assert(name == "utf-8", "notebook-lsp: encodings other than utf-8 are not supported")
        goto continue
      end
    end
    if vim.startswith(strip(line), "<!--") then
      in_html_div = true
      goto continue
    end
    if in_html_div then
      if ended and line:find("-->", 1, true) then
        break
      end
      if not started and is_blank(line) then
        goto continue
      end
    end
    if line:match("^%-%-%-%s*$") then
      if not started then
        started = true
        goto continue
      end
      ended = true
      if in_html_div then
        goto continue
      end
      break
    end
    if not started and not is_blank(line) then
      break
    end
    if line:match("^jupyter%s*:%s*$") then
      in_jupyter = true
    elseif line ~= "" and not line:match("^%s") then
      in_jupyter = false
    end
    if in_jupyter then
      table.insert(jupyter, line)
    end
    ::continue::
  end

  if not ended or #jupyter == 0 then
    return nil, 1
  end
  if lines[last + 1] and is_blank(lines[last + 1]) then
    last = last + 1
  end
  return read_yaml(jupyter).jupyter, last + 1
end

--------------------------------------------------------------------------------
-- Cell options, as in ```python key="value" .attribute
--------------------------------------------------------------------------------

--- jupytext's relax_json_loads, for the JSON jupytext writes (jupytext also
--- reads Python literals). Nil when `text` is not JSON.
local function json(text)
  -- Whether the text is JSON is the question, so the decoding error is the answer
  local ok, value = pcall(vim.json.decode, strip(text))
  if ok then
    return value
  end
end

--- jupytext's parse_key_equal_value: `key1=value1 .attribute key2=value2`.
---@return table<string, any>
local function parse_key_equal_value(text)
  text = strip(text)
  if text == "" then
    return {}
  end

  local last_space = rfind(text, " ") or 0
  local last_word = text:sub(last_space + 1)
  if not vim.startswith(text, "--") and last_word:match("^[%a_%.][%w_%.]*$") then
    local result = { [last_word] = NONE }
    if last_space > 1 then
      result = vim.tbl_extend("force", result, parse_key_equal_value(text:sub(1, last_space - 1)))
    end
    return result
  end

  -- Try each `=`, from the right, until one has a key on its left and a value on its right
  local equal_sign
  while true do
    equal_sign = rfind(text, "=", equal_sign)
    if not equal_sign then
      return { incorrectly_encoded_metadata = text }
    end
    local previous_space = rfind((text:sub(1, equal_sign - 1):gsub("%s+$", "")), " ") or 0
    local key = strip(text:sub(previous_space + 1, equal_sign - 1))
    if key:match("^[%w_%.@/%-]+$") then
      local value = json(text:sub(equal_sign + 1))
      if value ~= nil then
        local metadata = previous_space > 1 and parse_key_equal_value(text:sub(1, previous_space - 1)) or {}
        metadata[key] = value
        return metadata
      end
    end
  end
end

--- jupytext's text_to_metadata: the language and metadata on a code fence.
---@return string? language
---@return table<string, any> metadata
local function text_to_metadata(text)
  text = strip(text)
  local curly = text:find("{", 1, true)
  local equal_sign = text:find("=", 1, true)
  if curly == nil or (equal_sign and equal_sign < curly) then
    if LANGUAGES[text:lower()] then
      return text, {}
    end
    local language, options = text:match("^([^ ]*) (.*)$")
    if language and LANGUAGES[language:lower()] then
      return language, parse_key_equal_value(options)
    end
    return nil, parse_key_equal_value(text)
  end
  local language = strip(text:sub(1, curly - 1))
  local metadata = json(text:sub(curly))
  if type(metadata) ~= "table" then
    metadata = { incorrectly_encoded_metadata = text:sub(curly) }
  end
  return language ~= "" and language or nil, metadata
end

--- jupytext's is_active, for the .ipynb notebook the cell ends up in.
local function is_active(metadata)
  if type(metadata.run_control) == "table" and metadata.run_control.frozen == true then
    return true
  end
  for _, tag in ipairs(type(metadata.tags) == "table" and metadata.tags or {}) do
    if type(tag) == "string" and vim.startswith(tag, "active-") then
      return vim.tbl_contains(vim.split(tag, "-", { plain = true }), "ipynb")
    end
  end
  if metadata.active == nil then
    return true
  end
  assert(
    type(metadata.active) == "string",
    "notebook-lsp: unsupported cell option active=" .. vim.inspect(metadata.active)
  )
  return vim.tbl_contains(vim.split(metadata.active, "[.,]"), "ipynb")
end

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

--- jupytext's StringParser: tells whether a line starts inside a string, so a
--- fence inside a multi-line string doesn't end the cell.
---@param language string?
local function string_parser(language)
  local parser = {}
  local single, triple ---@type string?, string?
  local python, comment = language ~= "R", COMMENT[language]

  function parser.is_quoted()
    return language ~= nil and (single or triple) ~= nil
  end

  function parser.read_line(line)
    if language == nil then
      return
    end
    if not parser.is_quoted() and comment and vim.startswith((line:gsub("^%s+", "")), comment) then
      return
    end
    local triple_start = -1
    for i = 1, #line do
      local char = line:sub(i, i)
      if single == nil and triple == nil and comment and line:sub(i, i + #comment - 1) == comment then
        break
      end
      if (char == '"' or char == "'") and line:sub(i - 1, i - 1) ~= "\\" then
        if single == char then
          single = nil
        elseif single == nil and python then
          if i >= 3 and line:sub(i - 2, i) == char:rep(3) and i >= triple_start + 3 then
            -- A triple quote: the end of a multi-line string, or the start of one
            if triple == char then
              triple, triple_start = nil, i
            elseif triple == nil then
              triple, triple_start = char, i
            end
          elseif triple == nil then
            single = char
          end
        end
      end
    end
    -- Python strings in single quotes end with the line
    if python then
      single = nil
    end
  end

  return parser
end

local function region_start(line)
  local after = line:match("^<!%-%-%s*#(.*)%-%->%s*$")
  for _, name in ipairs({ "region", "markdown", "md", "raw" }) do
    if after and vim.startswith(after, name) then
      return name
    end
  end
end

---@class (private) notebook_lsp.jupytext.ReadCell
---@field type "code"|"markdown"|"raw"
---@field language string?
---@field first integer index of the cell's first line
---@field stop integer index of the cell's end marker, or past its last line

--- jupytext's MarkdownCellReader.read: reads the cell that starts at
--- `lines[first]`, and returns it and the index where the next cell starts.
---@param lines string[]
---@param first integer
---@param default_language string the notebook's main language
---@return notebook_lsp.jupytext.ReadCell cell
---@return integer next
local function read_cell(lines, first, default_language)
  -- Lines are indexed from 0 at `first`, like the lines jupytext gives each reader
  local count = #lines - first + 1
  local function line_at(i)
    return lines[first + i]
  end

  local cell_type, language, metadata, end_region
  local end_code = function(line)
    return line:match("^```%s*$") ~= nil
  end

  --- start_code_re and options_to_metadata: the language and metadata of the
  --- code cell `line` opens, or nil. Like jupytext, it also sets the fence that
  --- closes code blocks from then on.
  ---@return {language: string?, metadata: table<string, any>}?
  local function fence_options(line)
    local extra_backticks, space, rest = line:match("^```(`*)(%s*)(.*)$")
    if not rest then
      return nil
    end
    for fence_language in pairs(FENCE_LANGUAGES) do
      local after = rest:sub(#fence_language + 1)
      if vim.startswith(rest, fence_language) and (after == "" or after:match("^%s")) then
        local closing = "```" .. extra_backticks
        end_code = function(candidate)
          return vim.startswith(candidate, closing)
        end
        local options_language, options_metadata = text_to_metadata(space .. " " .. fence_language .. " " .. after)
        return { language = options_language, metadata = options_metadata }
      end
    end
    return nil
  end

  -- metadata_and_language_from_option_line
  local region = region_start(line_at(0))
  if region then
    cell_type, metadata = region == "raw" and "raw" or "markdown", {}
    end_region = function(line)
      return line:match("^<!%-%-%s*#end" .. region .. "%s*%-%->%s*$") ~= nil
    end
  else
    local fence = fence_options(line_at(0))
    if fence then
      language, metadata = fence.language, fence.metadata
      -- Cells with a .noeval attribute are Markdown
      if metadata[".noeval"] == NONE then
        cell_type, metadata, language = "markdown", {}, nil
      end
    end
  end
  if metadata and metadata.language ~= nil then
    assert(type(metadata.language) == "string", "notebook-lsp: unsupported cell option language")
    language, metadata.language = metadata.language, nil
  end

  --- find_cell_end: the end of cell marker, the start of the next cell, and
  --- whether the cell ended explicitly.
  ---@return integer, integer, boolean
  local function find_cell_end()
    if end_region then
      for i = 0, count - 1 do
        if end_region(line_at(i)) then
          return i, i + 1, true
        end
      end
    elseif metadata == nil then
      -- A Markdown cell: it ends at two blank lines, or where a code cell or a region starts
      cell_type = "markdown"
      local prev_blank, in_explicit_code_block, in_indented_code_block = 0, false, false
      for i = 0, count - 1 do
        local line = line_at(i)
        if in_explicit_code_block and end_code(line) then
          in_explicit_code_block = false
        elseif prev_blank > 0 and vim.startswith(line, "    ") and not is_blank(line) then
          in_indented_code_block = true
          prev_blank = 0
        else
          if in_indented_code_block and not is_blank(line) and not vim.startswith(line, "    ") then
            in_indented_code_block = false
          end
          if not in_indented_code_block and not in_explicit_code_block then
            local starts_region = region_start(line) ~= nil
            local fence = not starts_region and fence_options(line) or nil
            local starts_cell = fence ~= nil
              and FENCE_LANGUAGES[fence.language] ~= nil
              and fence.metadata[".noeval"] ~= NONE
            if starts_region or starts_cell then
              if i > 1 and prev_blank > 0 then
                return i - 1, i, false
              end
              return i, i, false
            elseif fence or vim.startswith(line, "```{") then
              -- Code blocks that are not cells: .noeval ones, and MyST directives
              in_explicit_code_block = true
              prev_blank = 0
            elseif vim.startswith(line, "```") then
              -- Code blocks in languages that aren't Jupyter's
              if prev_blank >= 2 then
                return i - 2, i, true
              end
              in_explicit_code_block = true
              prev_blank = 0
            elseif is_blank(line) then
              prev_blank = prev_blank + 1
            elseif prev_blank >= 2 then
              return i - 2, i, true
            else
              prev_blank = 0
            end
          end
        end
      end
    else
      cell_type = "code"
      local parser = string_parser(language or default_language)
      for i = 1, count - 1 do
        local line = line_at(i)
        if parser.is_quoted() then
          parser.read_line(line)
        else
          parser.read_line(line)
          if end_code(line) then
            return i, i + 1, true
          end
        end
      end
    end
    return count, count, false
  end

  -- find_cell_content
  local cell_end_marker, next_cell_start, explicit_eoc = find_cell_end()
  if cell_type == "code" then
    if not is_active(metadata) then
      cell_type = "raw"
    elseif not language then
      -- Code blocks with no language are Markdown (from format version 1.2)
      cell_type, explicit_eoc = "markdown", false
      cell_end_marker = cell_end_marker + 1
    end
  end
  if
    next_cell_start + 1 < count
    and is_blank(line_at(next_cell_start))
    and not is_blank(line_at(next_cell_start + 1))
  then
    next_cell_start = next_cell_start + 1
  elseif
    explicit_eoc
    and next_cell_start + 2 < count
    and is_blank(line_at(next_cell_start))
    and is_blank(line_at(next_cell_start + 1))
    and not is_blank(line_at(next_cell_start + 2))
  then
    next_cell_start = next_cell_start + 2
  end
  assert(next_cell_start > 0, "notebook-lsp: the jupytext reader is blocked at line " .. first)

  return { type = cell_type, language = language, first = first, stop = first + cell_end_marker },
    first + next_cell_start
end

--- Returns nil when `lines` are not a jupytext Markdown notebook, and errors when
--- they are a jupytext notebook in a format this plugin doesn't support.
---@param lines string[]
---@return notebook_lsp.jupytext.Notebook?
function M.read(lines)
  local jupyter, first = read_header(lines)
  if not jupyter then
    return nil
  end

  local format = yaml_string(jupyter, "jupytext.text_representation.format_name")
  if format ~= nil and format ~= "markdown" then
    error("notebook-lsp: unsupported jupytext format: " .. format)
  end
  local version = yaml_string(jupyter, "jupytext.text_representation.format_version")
  if version == "1.0" or version == "1.1" then
    error("notebook-lsp: unsupported jupytext Markdown format version " .. version)
  end
  local custom_language_magics = yaml_string(jupyter, "jupytext.custom_language_magics")
  if custom_language_magics ~= nil and custom_language_magics ~= "" then
    error("notebook-lsp: unsupported jupytext option: custom_language_magics")
  end

  -- default_language_from_metadata_and_ext
  local language = yaml_string(jupyter, "jupytext.main_language") or yaml_string(jupyter, "kernelspec.language")
  if language == nil then
    error("notebook-lsp: the notebook has no kernel language")
  end
  if language ~= "R" and language ~= "sas" then
    language = vim.startswith(language, "C++") and "c++" or language:lower():gsub("#", "sharp")
  end

  local cells = {}
  while first <= #lines do
    local cell, next = read_cell(lines, first, language)
    if cell.type == "code" then
      -- set_main_and_cell_language: other languages than the kernel's run through a magic
      local cell_language = assert(cell.language)
      if cell_language == language or usual_language_name(cell_language) == language then
        cell_language = language
      end
      table.insert(cells, {
        language = cell_language,
        start = cell.first,
        lines = vim.list_slice(lines, cell.first + 1, cell.stop - 1),
      })
    end
    first = next
  end
  return { language = language, cells = cells }
end

return M
