-- MCPBridge 命令处理器
-- 处理来自 MCP 服务的命令并返回结果

local CommandHandler = {}

-- 已处理的命令 ID 集合（防止重复处理）
local processedCommands = {}

-- ========== 内嵌 JSON 解析（dkjson 2.5，纯 Lua，MIT 许可） ==========
-- 替代 CS.FairyEditor.JsonUtil.DecodeJson（间歇性返回 nil）
-- dkjson 源码直接内联：插件环境中 dofile 无法定位自身路径
-- （PluginPath 仅在 main.lua 的加载环境可见），故用立即执行函数包装
local json = (function()
-- Module options:
local always_try_using_lpeg = true
local register_global_module_table = false
local global_module_name = 'json'

--[==[

David Kolf's JSON module for Lua 5.1/5.2

Version 2.5


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2014 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--]==]

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
      pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
      string.rep, string.gsub, string.sub, string.byte, string.char,
      string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

local json = { version = "dkjson 2.5" }

if register_global_module_table then
  _G[global_module_name] = json
end

local _ENV = nil -- blocking globals in Lua 5.2

pcall (function()
  -- Enable access to blocked metatables.
  -- Don't worry, this module doesn't change anything in them.
  local debmeta = require "debug".getmetatable
  if debmeta then getmetatable = debmeta end
end)

json.null = setmetatable ({}, {
  __tojson = function () return "null" end
})

local function isarray (tbl)
  local max, n, arraylen = 0, 0, 0
  for k,v in pairs (tbl) do
    if k == 'n' and type(v) == 'number' then
      arraylen = v
      if v > max then
        max = v
      end
    else
      if type(k) ~= 'number' or k < 1 or floor(k) ~= k then
        return false
      end
      if k > max then
        max = k
      end
      n = n + 1
    end
  end
  if max > 10 and max > arraylen and max > n * 2 then
    return false -- don't create an array with too many holes
  end
  return true, max
end

local escapecodes = {
  ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n",  ["\r"] = "\\r",  ["\t"] = "\\t"
}

local function escapeutf8 (uchar)
  local value = escapecodes[uchar]
  if value then
    return value
  end
  local a, b, c, d = strbyte (uchar, 1, 4)
  a, b, c, d = a or 0, b or 0, c or 0, d or 0
  if a <= 0x7f then
    value = a
  elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
    value = (a - 0xc0) * 0x40 + b - 0x80
  elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
    value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
  elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
    value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
  else
    return ""
  end
  if value <= 0xffff then
    return strformat ("\\u%.4x", value)
  elseif value <= 0x10ffff then
    -- encode as UTF-16 surrogate pair
    value = value - 0x10000
    local highsur, lowsur = 0xD800 + floor (value/0x400), 0xDC00 + (value % 0x400)
    return strformat ("\\u%.4x\\u%.4x", highsur, lowsur)
  else
    return ""
  end
end

local function fsub (str, pattern, repl)
  -- gsub always builds a new string in a buffer, even when no match
  -- exists. First using find should be more efficient when most strings
  -- don't contain the pattern.
  if strfind (str, pattern) then
    return gsub (str, pattern, repl)
  else
    return str
  end
end

local function quotestring (value)
  -- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
  value = fsub (value, "[%z\1-\31\"\\\127]", escapeutf8)
  if strfind (value, "[\194\216\220\225\226\239]") then
    value = fsub (value, "\194[\128-\159\173]", escapeutf8)
    value = fsub (value, "\216[\128-\132]", escapeutf8)
    value = fsub (value, "\220\143", escapeutf8)
    value = fsub (value, "\225\158[\180\181]", escapeutf8)
    value = fsub (value, "\226\128[\140-\143\168-\175]", escapeutf8)
    value = fsub (value, "\226\129[\160-\175]", escapeutf8)
    value = fsub (value, "\239\187\191", escapeutf8)
    value = fsub (value, "\239\191[\176-\191]", escapeutf8)
  end
  return "\"" .. value .. "\""
end
json.quotestring = quotestring

local function replace(str, o, n)
  local i, j = strfind (str, o, 1, true)
  if i then
    return strsub(str, 1, i-1) .. n .. strsub(str, j+1, -1)
  else
    return str
  end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint ()
  decpoint = strmatch(tostring(0.5), "([^05+])")
  -- build a filter that can be used to remove group separators
  numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str (num)
  return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num (str)
  local num = tonumber(replace(str, ".", decpoint))
  if not num then
    updatedecpoint()
    num = tonumber(replace(str, ".", decpoint))
  end
  return num
end

local function addnewline2 (level, buffer, buflen)
  buffer[buflen+1] = "\n"
  buffer[buflen+2] = strrep ("  ", level)
  buflen = buflen + 2
  return buflen
end

function json.addnewline (state)
  if state.indent then
    state.bufferlen = addnewline2 (state.level or 0,
                           state.buffer, state.bufferlen or #(state.buffer))
  end
end

local encode2 -- forward declaration

local function addpair (key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
  local kt = type (key)
  if kt ~= 'string' and kt ~= 'number' then
    return nil, "type '" .. kt .. "' is not supported as a key by JSON."
  end
  if prev then
    buflen = buflen + 1
    buffer[buflen] = ","
  end
  if indent then
    buflen = addnewline2 (level, buffer, buflen)
  end
  buffer[buflen+1] = quotestring (key)
  buffer[buflen+2] = ":"
  return encode2 (value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
  local buflen = state.bufferlen
  if type (res) == 'string' then
    buflen = buflen + 1
    buffer[buflen] = res
  end
  return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
  defaultmessage = defaultmessage or reason
  local handler = state.exception
  if not handler then
    return nil, defaultmessage
  else
    state.bufferlen = buflen
    local ret, msg = handler (reason, value, state, defaultmessage)
    if not ret then return nil, msg or defaultmessage end
    return appendcustom(ret, buffer, state)
  end
end

function json.encodeexception(reason, value, state, defaultmessage)
  return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function (value, indent, level, buffer, buflen, tables, globalorder, state)
  local valtype = type (value)
  local valmeta = getmetatable (value)
  valmeta = type (valmeta) == 'table' and valmeta -- only tables
  local valtojson = valmeta and valmeta.__tojson
  if valtojson then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    state.bufferlen = buflen
    local ret, msg = valtojson (value, state)
    if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
    tables[value] = nil
    buflen = appendcustom(ret, buffer, state)
  elseif value == nil then
    buflen = buflen + 1
    buffer[buflen] = "null"
  elseif valtype == 'number' then
    local s
    if value ~= value or value >= huge or -value >= huge then
      -- This is the behaviour of the original JSON implementation.
      s = "null"
    else
      s = num2str (value)
    end
    buflen = buflen + 1
    buffer[buflen] = s
  elseif valtype == 'boolean' then
    buflen = buflen + 1
    buffer[buflen] = value and "true" or "false"
  elseif valtype == 'string' then
    buflen = buflen + 1
    buffer[buflen] = quotestring (value)
  elseif valtype == 'table' then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    level = level + 1
    local isa, n = isarray (value)
    if n == 0 and valmeta and valmeta.__jsontype == 'object' then
      isa = false
    end
    local msg
    if isa then -- JSON array
      buflen = buflen + 1
      buffer[buflen] = "["
      for i = 1, n do
        buflen, msg = encode2 (value[i], indent, level, buffer, buflen, tables, globalorder, state)
        if not buflen then return nil, msg end
        if i < n then
          buflen = buflen + 1
          buffer[buflen] = ","
        end
      end
      buflen = buflen + 1
      buffer[buflen] = "]"
    else -- JSON object
      local prev = false
      buflen = buflen + 1
      buffer[buflen] = "{"
      local order = valmeta and valmeta.__jsonorder or globalorder
      if order then
        local used = {}
        n = #order
        for i = 1, n do
          local k = order[i]
          local v = value[k]
          if v then
            used[k] = true
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            prev = true -- add a seperator before the next element
          end
        end
        for k,v in pairs (value) do
          if not used[k] then
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            if not buflen then return nil, msg end
            prev = true -- add a seperator before the next element
          end
        end
      else -- unordered
        for k,v in pairs (value) do
          buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
          if not buflen then return nil, msg end
          prev = true -- add a seperator before the next element
        end
      end
      if indent then
        buflen = addnewline2 (level - 1, buffer, buflen)
      end
      buflen = buflen + 1
      buffer[buflen] = "}"
    end
    tables[value] = nil
  else
    return exception ('unsupported type', value, state, buffer, buflen,
      "type '" .. valtype .. "' is not supported by JSON.")
  end
  return buflen
end

function json.encode (value, state)
  state = state or {}
  local oldbuffer = state.buffer
  local buffer = oldbuffer or {}
  state.buffer = buffer
  updatedecpoint()
  local ret, msg = encode2 (value, state.indent, state.level or 0,
                   buffer, state.bufferlen or 0, state.tables or {}, state.keyorder, state)
  if not ret then
    error (msg, 2)
  elseif oldbuffer == buffer then
    state.bufferlen = ret
    return true
  else
    state.bufferlen = nil
    state.buffer = nil
    return concat (buffer)
  end
end

local function loc (str, where)
  local line, pos, linepos = 1, 1, 0
  while true do
    pos = strfind (str, "\n", pos, true)
    if pos and pos < where then
      line = line + 1
      linepos = pos
      pos = pos + 1
    else
      break
    end
  end
  return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated (str, what, where)
  return nil, strlen (str) + 1, "unterminated " .. what .. " at " .. loc (str, where)
end

local function scanwhite (str, pos)
  while true do
    pos = strfind (str, "%S", pos)
    if not pos then return nil end
    local sub2 = strsub (str, pos, pos + 1)
    if sub2 == "\239\187" and strsub (str, pos + 2, pos + 2) == "\191" then
      -- UTF-8 Byte Order Mark
      pos = pos + 3
    elseif sub2 == "//" then
      pos = strfind (str, "[\n\r]", pos + 2)
      if not pos then return nil end
    elseif sub2 == "/*" then
      pos = strfind (str, "*/", pos + 2)
      if not pos then return nil end
      pos = pos + 2
    else
      return pos
    end
  end
end

local escapechars = {
  ["\""] = "\"", ["\\"] = "\\", ["/"] = "/", ["b"] = "\b", ["f"] = "\f",
  ["n"] = "\n", ["r"] = "\r", ["t"] = "\t"
}

local function unichar (value)
  if value < 0 then
    return nil
  elseif value <= 0x007f then
    return strchar (value)
  elseif value <= 0x07ff then
    return strchar (0xc0 + floor(value/0x40),
                    0x80 + (floor(value) % 0x40))
  elseif value <= 0xffff then
    return strchar (0xe0 + floor(value/0x1000),
                    0x80 + (floor(value/0x40) % 0x40),
                    0x80 + (floor(value) % 0x40))
  elseif value <= 0x10ffff then
    return strchar (0xf0 + floor(value/0x40000),
                    0x80 + (floor(value/0x1000) % 0x40),
                    0x80 + (floor(value/0x40) % 0x40),
                    0x80 + (floor(value) % 0x40))
  else
    return nil
  end
end

local function scanstring (str, pos)
  local lastpos = pos + 1
  local buffer, n = {}, 0
  while true do
    local nextpos = strfind (str, "[\"\\]", lastpos)
    if not nextpos then
      return unterminated (str, "string", pos)
    end
    if nextpos > lastpos then
      n = n + 1
      buffer[n] = strsub (str, lastpos, nextpos - 1)
    end
    if strsub (str, nextpos, nextpos) == "\"" then
      lastpos = nextpos + 1
      break
    else
      local escchar = strsub (str, nextpos + 1, nextpos + 1)
      local value
      if escchar == "u" then
        value = tonumber (strsub (str, nextpos + 2, nextpos + 5), 16)
        if value then
          local value2
          if 0xD800 <= value and value <= 0xDBff then
            -- we have the high surrogate of UTF-16. Check if there is a
            -- low surrogate escaped nearby to combine them.
            if strsub (str, nextpos + 6, nextpos + 7) == "\\u" then
              value2 = tonumber (strsub (str, nextpos + 8, nextpos + 11), 16)
              if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
                value = (value - 0xD800)  * 0x400 + (value2 - 0xDC00) + 0x10000
              else
                value2 = nil -- in case it was out of range for a low surrogate
              end
            end
          end
          value = value and unichar (value)
          if value then
            if value2 then
              lastpos = nextpos + 12
            else
              lastpos = nextpos + 6
            end
          end
        end
      end
      if not value then
        value = escapechars[escchar] or escchar
        lastpos = nextpos + 2
      end
      n = n + 1
      buffer[n] = value
    end
  end
  if n == 1 then
    return buffer[1], lastpos
  elseif n > 1 then
    return concat (buffer), lastpos
  else
    return "", lastpos
  end
end

local scanvalue -- forward declaration

local function scantable (what, closechar, str, startpos, nullval, objectmeta, arraymeta)
  local len = strlen (str)
  local tbl, n = {}, 0
  local pos = startpos + 1
  if what == 'object' then
    setmetatable (tbl, objectmeta)
  else
    setmetatable (tbl, arraymeta)
  end
  while true do
    pos = scanwhite (str, pos)
    if not pos then return unterminated (str, what, startpos) end
    local char = strsub (str, pos, pos)
    if char == closechar then
      return tbl, pos + 1
    end
    local val1, err
    val1, pos, err = scanvalue (str, pos, nullval, objectmeta, arraymeta)
    if err then return nil, pos, err end
    pos = scanwhite (str, pos)
    if not pos then return unterminated (str, what, startpos) end
    char = strsub (str, pos, pos)
    if char == ":" then
      if val1 == nil then
        return nil, pos, "cannot use nil as table index (at " .. loc (str, pos) .. ")"
      end
      pos = scanwhite (str, pos + 1)
      if not pos then return unterminated (str, what, startpos) end
      local val2
      val2, pos, err = scanvalue (str, pos, nullval, objectmeta, arraymeta)
      if err then return nil, pos, err end
      tbl[val1] = val2
      pos = scanwhite (str, pos)
      if not pos then return unterminated (str, what, startpos) end
      char = strsub (str, pos, pos)
    else
      n = n + 1
      tbl[n] = val1
    end
    if char == "," then
      pos = pos + 1
    end
  end
end

scanvalue = function (str, pos, nullval, objectmeta, arraymeta)
  pos = pos or 1
  pos = scanwhite (str, pos)
  if not pos then
    return nil, strlen (str) + 1, "no valid JSON value (reached the end)"
  end
  local char = strsub (str, pos, pos)
  if char == "{" then
    return scantable ('object', "}", str, pos, nullval, objectmeta, arraymeta)
  elseif char == "[" then
    return scantable ('array', "]", str, pos, nullval, objectmeta, arraymeta)
  elseif char == "\"" then
    return scanstring (str, pos)
  else
    local pstart, pend = strfind (str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
    if pstart then
      local number = str2num (strsub (str, pstart, pend))
      if number then
        return number, pend + 1
      end
    end
    pstart, pend = strfind (str, "^%a%w*", pos)
    if pstart then
      local name = strsub (str, pstart, pend)
      if name == "true" then
        return true, pend + 1
      elseif name == "false" then
        return false, pend + 1
      elseif name == "null" then
        return nullval, pend + 1
      end
    end
    return nil, pos, "no valid JSON value at " .. loc (str, pos)
  end
end

local function optionalmetatables(...)
  if select("#", ...) > 0 then
    return ...
  else
    return {__jsontype = 'object'}, {__jsontype = 'array'}
  end
end

function json.decode (str, pos, nullval, ...)
  local objectmeta, arraymeta = optionalmetatables(...)
  return scanvalue (str, pos, nullval, objectmeta, arraymeta)
end

function json.use_lpeg ()
  local g = require ("lpeg")

  if g.version() == "0.11" then
    error "due to a bug in LPeg 0.11, it cannot be used for JSON matching"
  end

  local pegmatch = g.match
  local P, S, R = g.P, g.S, g.R

  local function ErrorCall (str, pos, msg, state)
    if not state.msg then
      state.msg = msg .. " at " .. loc (str, pos)
      state.pos = pos
    end
    return false
  end

  local function Err (msg)
    return g.Cmt (g.Cc (msg) * g.Carg (2), ErrorCall)
  end

  local SingleLineComment = P"//" * (1 - S"\n\r")^0
  local MultiLineComment = P"/*" * (1 - P"*/")^0 * P"*/"
  local Space = (S" \n\r\t" + P"\239\187\191" + SingleLineComment + MultiLineComment)^0

  local PlainChar = 1 - S"\"\\\n\r"
  local EscapeSequence = (P"\\" * g.C (S"\"\\/bfnrt" + Err "unsupported escape sequence")) / escapechars
  local HexDigit = R("09", "af", "AF")
  local function UTF16Surrogate (match, pos, high, low)
    high, low = tonumber (high, 16), tonumber (low, 16)
    if 0xD800 <= high and high <= 0xDBff and 0xDC00 <= low and low <= 0xDFFF then
      return true, unichar ((high - 0xD800)  * 0x400 + (low - 0xDC00) + 0x10000)
    else
      return false
    end
  end
  local function UTF16BMP (hex)
    return unichar (tonumber (hex, 16))
  end
  local U16Sequence = (P"\\u" * g.C (HexDigit * HexDigit * HexDigit * HexDigit))
  local UnicodeEscape = g.Cmt (U16Sequence * U16Sequence, UTF16Surrogate) + U16Sequence/UTF16BMP
  local Char = UnicodeEscape + EscapeSequence + PlainChar
  local String = P"\"" * g.Cs (Char ^ 0) * (P"\"" + Err "unterminated string")
  local Integer = P"-"^(-1) * (P"0" + (R"19" * R"09"^0))
  local Fractal = P"." * R"09"^0
  local Exponent = (S"eE") * (S"+-")^(-1) * R"09"^1
  local Number = (Integer * Fractal^(-1) * Exponent^(-1))/str2num
  local Constant = P"true" * g.Cc (true) + P"false" * g.Cc (false) + P"null" * g.Carg (1)
  local SimpleValue = Number + String + Constant
  local ArrayContent, ObjectContent

  -- The functions parsearray and parseobject parse only a single value/pair
  -- at a time and store them directly to avoid hitting the LPeg limits.
  local function parsearray (str, pos, nullval, state)
    local obj, cont
    local npos
    local t, nt = {}, 0
    repeat
      obj, cont, npos = pegmatch (ArrayContent, str, pos, nullval, state)
      if not npos then break end
      pos = npos
      nt = nt + 1
      t[nt] = obj
    until cont == 'last'
    return pos, setmetatable (t, state.arraymeta)
  end

  local function parseobject (str, pos, nullval, state)
    local obj, key, cont
    local npos
    local t = {}
    repeat
      key, obj, cont, npos = pegmatch (ObjectContent, str, pos, nullval, state)
      if not npos then break end
      pos = npos
      t[key] = obj
    until cont == 'last'
    return pos, setmetatable (t, state.objectmeta)
  end

  local Array = P"[" * g.Cmt (g.Carg(1) * g.Carg(2), parsearray) * Space * (P"]" + Err "']' expected")
  local Object = P"{" * g.Cmt (g.Carg(1) * g.Carg(2), parseobject) * Space * (P"}" + Err "'}' expected")
  local Value = Space * (Array + Object + SimpleValue)
  local ExpectedValue = Value + Space * Err "value expected"
  ArrayContent = Value * Space * (P"," * g.Cc'cont' + g.Cc'last') * g.Cp()
  local Pair = g.Cg (Space * String * Space * (P":" + Err "colon expected") * ExpectedValue)
  ObjectContent = Pair * Space * (P"," * g.Cc'cont' + g.Cc'last') * g.Cp()
  local DecodeValue = ExpectedValue * g.Cp ()

  function json.decode (str, pos, nullval, ...)
    local state = {}
    state.objectmeta, state.arraymeta = optionalmetatables(...)
    local obj, retpos = pegmatch (DecodeValue, str, pos, nullval, state)
    if state.msg then
      return nil, state.pos, state.msg
    else
      return obj, retpos
    end
  end

  -- use this function only once:
  json.use_lpeg = function () return json end

  json.using_lpeg = true

  return json -- so you can get the module using json = require "dkjson".use_lpeg()
end

if always_try_using_lpeg then
  pcall (json.use_lpeg)
end

return json

end)()

-- ========== 辅助函数 ==========

-- 辅助函数：从 C# Dictionary 获取值
local function getDictValue(dict, key)
    local value = nil
    pcall(function()
        value = dict:get_Item(key)
    end)
    return value
end

-- 辅助函数：将 C# Dictionary/Hashtable 转换为 Lua table
local function csharpToLua(obj)
    if obj == nil then return nil end

    local t = type(obj)
    if t == "string" or t == "number" or t == "boolean" then
        return obj
    end

    -- 检查是否是 C# Dictionary/Hashtable
    if obj.Keys then
        local result = {}
        local enumerator = obj.Keys:GetEnumerator()
        while enumerator:MoveNext() do
            local key = enumerator.Current
            local value = obj:get_Item(key)
            result[key] = csharpToLua(value)
        end
        return result
    end

    return obj
end

-- 辅助函数：使用 GetScreenShot 截取 DisplayObject 并保存为 PNG
-- 支持可选的裁剪区域（cropX, cropY, cropW, cropH）
-- 返回 true 表示成功，false 表示失败
local function captureDisplayObject(displayObj, screenshotPath, scale, cropX, cropY, cropW, cropH)
    scale = scale or 1
    -- 调用 GetScreenShot 获取 Texture2D
    local texture = displayObj:GetScreenShot(nil, scale)
    if not texture then
        error("GetScreenShot 返回 nil，无法截取")
    end

    -- 调试：打印实际返回的 texture 尺寸 vs displayObject 尺寸
    pcall(function()
        fprint(string.format("[MCPBridge] DisplayObject %sx%s, Texture %sx%s",
            tostring(displayObj.width or 0), tostring(displayObj.height or 0),
            tostring(texture.width or 0), tostring(texture.height or 0)))
    end)

    local ok, err = pcall(function()
        local saveTexture = texture
        local texW, texH = texture.width, texture.height
        local needCrop = cropX and cropY and cropW and cropH
        local cropNote = nil

        if needCrop then
            -- UI 坐标 ≠ 纹理像素坐标（GetScreenShot 会按 scale 出图，且 displayObject
            -- 自身可能带缩放），所以先等比换算再钳制到纹理范围内。
            -- 早先直接用 UI 坐标调 GetPixels，越界会抛
            -- "Texture2D.GetPixels: the size of data ... outside the target buffer bounds"，
            -- 整条截图链路就断了，这里必须保证任何情况下都不越界。
            local objW = displayObj.width or texW
            local objH = displayObj.height or texH
            local sx = (objW ~= 0) and (texW / objW) or 1
            local sy = (objH ~= 0) and (texH / objH) or 1

            local cx = math.floor(cropX * sx)
            local cy = math.floor(cropY * sy)
            local cw = math.floor(cropW * sx)
            local ch = math.floor(cropH * sy)

            -- 钳制
            if cx < 0 then cx = 0 end
            if cy < 0 then cy = 0 end
            if cx > texW - 1 then cx = texW - 1 end
            if cy > texH - 1 then cy = texH - 1 end
            if cw > texW - cx then cw = texW - cx end
            if ch > texH - cy then ch = texH - cy end

            if cw > 0 and ch > 0 then
                -- Unity Texture2D 的 Y 轴自下而上，需要翻转
                local cropYFlipped = texH - cy - ch
                if cropYFlipped < 0 then cropYFlipped = 0 end
                local okPixels, pixels = pcall(function()
                    return texture:GetPixels(cx, cropYFlipped, cw, ch)
                end)
                if okPixels and pixels ~= nil then
                    local okMake, cropped = pcall(function()
                        local t = CS.UnityEngine.Texture2D(cw, ch)
                        t:SetPixels(pixels)
                        t:Apply()
                        return t
                    end)
                    if okMake and cropped ~= nil then
                        saveTexture = cropped
                        cropNote = string.format("裁剪到 %dx%d at (%d,%d)", cw, ch, cx, cy)
                    else
                        cropNote = "创建裁剪纹理失败，退回整图"
                    end
                else
                    cropNote = "GetPixels 失败，退回整图: " .. tostring(pixels)
                end
            else
                cropNote = string.format("裁剪区无效(%.0fx%.0f)，退回整图", cropW, cropH)
            end
        end

        if cropNote then
            pcall(function() fprint("[MCPBridge] " .. cropNote) end)
        end

        -- 编码为 PNG
        local pngBytes = CS.UnityEngine.ImageConversion.EncodeToPNG(saveTexture)
        -- 写入文件
        CS.System.IO.File.WriteAllBytes(screenshotPath, pngBytes)

        -- 释放裁剪纹理
        if saveTexture ~= texture then
            pcall(function() CS.UnityEngine.Object.Destroy(saveTexture) end)
        end
    end)

    -- 释放 Texture2D
    CS.UnityEngine.Object.Destroy(texture)

    if not ok then
        error("截图保存失败: " .. tostring(err))
    end
    return true
end

-- ========== 初始化 ==========

-- 初始化通信目录
function CommandHandler.initBridge(bridgePath)
    -- 转换路径分隔符（Windows 兼容）
    bridgePath = bridgePath:gsub("/", "\\")
    local dirs = {"\\commands", "\\results", "\\screenshots"}
    for _, dir in ipairs(dirs) do
        local fullPath = bridgePath .. dir
        -- 使用 C# System.IO 创建目录
        if not CS.System.IO.Directory.Exists(fullPath) then
            CS.System.IO.Directory.CreateDirectory(fullPath)
        end
    end
    fprint("[MCPBridge] 通信目录已初始化: " .. bridgePath)
    -- 保存桥接路径，供 ext 扩展模块诊断使用
    CommandHandler._bridgePath = bridgePath
end

-- ========== 轮询 ==========

-- 调试输出：写入 bridge/debug.txt（诊断桥接链路用）
local function debugWrite(bridgePath, msg)
    pcall(function()
        local f = io.open(bridgePath:gsub("/", "\\") .. "\\debug.txt", "a")
        if f then
            f:write(os.date("%H:%M:%S ") .. msg .. "\n")
            f:close()
        end
    end)
end

-- 桥接日志：打进编辑器控制台，同时写入 get_logs 用的共享缓冲区。
--
-- 为什么不能直接 fprint：
--   FairyEditor 给每个 dofile 出来的 chunk 独立环境，main.lua 里对全局 fprint 的
--   拦截（日志环形缓冲区）对本文件不生效——本文件里的 fprint 是编辑器原生那个。
--   所以必须显式写 _G._mcpLogBuffer（_G 才是各 chunk 真正共享的）。
local function bridgeLog(msg)
    local line = "[MCPBridge] " .. tostring(msg)
    pcall(function() fprint(line) end)
    pcall(function()
        local buf = _G._mcpLogBuffer
        if not buf then return end
        buf[#buf + 1] = { time = os.date("%H:%M:%S"), level = "info", message = line }
        while #buf > 500 do table.remove(buf, 1) end
    end)
end

-- 定期清理 results 目录。
-- 客户端只读不删（它一删就在短时间内产生成百上千次删除，会触发宿主的批量删除保护），
-- 所以由插件自己每分钟看一次，文件多了就清掉较旧的一半。
local _lastGc = 0
local function gcResults(bridgePath)
    local now = os.time()
    if now - _lastGc < 60 then return end
    _lastGc = now
    pcall(function()
        local dir = bridgePath:gsub("/", "\\") .. "\\results"
        if not CS.System.IO.Directory.Exists(dir) then return end
        local files = CS.System.IO.Directory.GetFiles(dir, "*.json")
        if files == nil then return end
        -- C# 数组的长度在不同环境下可能是 Length / # / 只能逐个索引，这里全都兜住
        local n = 0
        pcall(function() if type(files.Length) == "number" then n = files.Length end end)
        if n == 0 then pcall(function() if type(#files) == "number" then n = #files end end) end
        if n == 0 then
            for i = 0, 100000 do
                local f = nil
                pcall(function() f = files[i] end)
                if f == nil then break end
                n = i + 1
            end
        end
        debugWrite(bridgePath, "results 目录文件数=" .. tostring(n))
        if n <= 200 then return end
        local arr = {}
        for i = 0, n - 1 do
            local f = nil
            pcall(function() f = files[i] end)
            if f ~= nil then arr[#arr + 1] = tostring(f) end
        end
        table.sort(arr)
        local keep = 100
        for i = 1, (#arr - keep) do
            pcall(function() CS.System.IO.File.Delete(arr[i]) end)
        end
        local leftover = 0
        pcall(function() leftover = CS.System.IO.Directory.GetFiles(dir, "*.json").Length end)
        debugWrite(bridgePath, "已清理 results 目录，保留 " .. tostring(leftover) .. " 个结果文件")
    end)
end

-- 轮询命令
local _apiProbed = false
function CommandHandler.poll(bridgePath)
    -- 首次轮询时加载 ext 扩展命令模块（此时 bridgePath 已确定）
    CommandHandler.loadExt(bridgePath)
    gcResults(bridgePath)

    -- 转换路径分隔符（Windows 兼容）
    local commandsDir = bridgePath:gsub("/", "\\") .. "\\commands"

    -- 一次性 API 探测
    if not _apiProbed then
        _apiProbed = true
        local lines = {}
        pcall(function() lines[#lines+1] = "JsonUtil=" .. tostring(CS.FairyEditor.JsonUtil) end)
        pcall(function() lines[#lines+1] = "JsonUtil.DecodeJson=" .. tostring(CS.FairyEditor.JsonUtil.DecodeJson) end)
        pcall(function() lines[#lines+1] = "Utils.JsonUtil=" .. tostring(CS.FairyEditor.Utils.JsonUtil) end)
        pcall(function() lines[#lines+1] = "Utils.JsonUtil.DecodeJson=" .. tostring(CS.FairyEditor.Utils.JsonUtil.DecodeJson) end)
        pcall(function() lines[#lines+1] = "JsonUtil.EncodeJson=" .. tostring(CS.FairyEditor.JsonUtil.EncodeJson) end)
        pcall(function()
            local r = CS.FairyEditor.JsonUtil.DecodeJson('{"a":1}')
            lines[#lines+1] = "DecodeJson(test)=" .. tostring(r)
        end)
        pcall(function()
            local r = CS.FairyEditor.JsonUtil.DecodeJson('{"a":1}')
            if r ~= nil and r.Keys then
                lines[#lines+1] = "test.get_Item(a)=" .. tostring(r:get_Item("a"))
            end
        end)
        debugWrite(bridgePath, "API探测: " .. table.concat(lines, " | "))
    end

    -- 检查目录是否存在
    if not CS.System.IO.Directory.Exists(commandsDir) then
        return
    end

    -- 遍历命令文件
    local files = CS.System.IO.Directory.GetFiles(commandsDir, "*.json")
    if not files or files.Length == 0 then
        return
    end

    debugWrite(bridgePath, "发现 " .. files.Length .. " 个命令文件")

    for i = 0, files.Length - 1 do
        local filePath = files[i]
        local fileName = CS.System.IO.Path.GetFileNameWithoutExtension(filePath)

        -- 跳过已处理的命令
        if processedCommands[fileName] then
            goto continue
        end

        -- 读取并执行命令
        local success, content = pcall(function()
            local f = io.open(filePath, "r")
            if f then
                local txt = f:read("*a")
                f:close()
                return txt
            end
            return nil
        end)

        if not success then
            debugWrite(bridgePath, "读取文件失败: " .. tostring(content))
        end

        if success and content then
            -- 调试：打印原始内容
            fprint("[MCPBridge] 原始内容长度: " .. #content)
            fprint("[MCPBridge] 原始内容: " .. string.sub(content, 1, 200))

            -- 解析 JSON：优先 dkjson（纯 Lua，稳定），失败回退 C# JsonUtil
            local jsonOk, cmd = pcall(function()
                if json then
                    local obj, pos, msg = json.decode(content)
                    if obj == nil then
                        error("dkjson: " .. tostring(msg) .. " at pos " .. tostring(pos))
                    end
                    return obj
                end
                return CS.FairyEditor.JsonUtil.DecodeJson(content)
            end)

            if not jsonOk then
                debugWrite(bridgePath, "JSON 解析抛错: " .. tostring(cmd))
                fprint("[MCPBridge] JSON 解析失败: " .. tostring(cmd))
            elseif not cmd then
                debugWrite(bridgePath, "JSON 解析返回 nil")
            else
                debugWrite(bridgePath, "JSON 解析成功(dkjson=" .. tostring(json ~= nil) .. ")，进入执行")
            end

            if jsonOk and cmd then
                -- dkjson 返回纯 Lua table（旧路径 C# Dictionary 也兼容）
                local action = nil
                local cmdId = nil

                if type(cmd) == "table" then
                    -- dkjson 路径：直接字段访问
                    action = cmd.action
                    cmdId = cmd.id
                elseif cmd.Keys then
                    -- 旧路径：C# Dictionary 遍历 Keys
                    local enumerator = cmd.Keys:GetEnumerator()
                    while enumerator:MoveNext() do
                        local key = enumerator.Current
                        local value = nil
                        pcall(function()
                            value = cmd:get_Item(key)
                        end)
                        if key == "action" then action = value end
                        if key == "id" then cmdId = value end
                    end
                end

                -- 日志策略：轮询静默，只有真正处理命令时才打印（收到 + 完成两行）。
                bridgeLog("→ " .. tostring(action or "unknown")
                    .. (cmdId and (" [" .. tostring(cmdId) .. "]") or ""))

                -- 执行命令
                local execOk, result = pcall(function()
                    return CommandHandler.execute(cmd, bridgePath)
                end)
                if not execOk then
                    debugWrite(bridgePath, "execute 抛错: " .. tostring(result))
                    result = { id = cmdId, status = "error", error = tostring(result) }
                end

                -- 完成/失败各打一行，失败的把原因带出来，方便在控制台直接定位
                if type(result) == "table" and result.status == "error" then
                    bridgeLog("← " .. tostring(action) .. " 失败: "
                        .. string.sub(tostring(result.error or ""), 1, 300))
                else
                    bridgeLog("← " .. tostring(action) .. " 完成")
                end

                -- 写入结果
                local writeOk, writeErr = pcall(function()
                    CommandHandler.writeResult(bridgePath, fileName, result)
                end)
                if not writeOk then
                    debugWrite(bridgePath, "writeResult 抛错: " .. tostring(writeErr))
                else
                    debugWrite(bridgePath, "命令 " .. tostring(action) .. " 处理完成，结果已写入 " .. fileName .. ".json")
                end

                -- 命令执行完毕后重置 runInBackground
                -- 确保即使 F5 等模式在 handler 内部覆盖了此值，也能恢复
                CS.UnityEngine.Application.runInBackground = true

                -- 标记为已处理
                processedCommands[fileName] = true

                -- 清理旧记录（保留最近 100 个）
                local count = 0
                for _ in pairs(processedCommands) do count = count + 1 end
                if count > 100 then
                    processedCommands = {}
                end
            end
        end

        -- 删除命令文件
        pcall(function()
            CS.FairyEditor.IOUtil.DeleteFile(filePath, false)
        end)

        ::continue::
    end
end

-- ========== 命令执行 ==========

-- 执行命令
function CommandHandler.execute(cmd, bridgePath)
    -- cmd 可能是 dkjson 解析出的纯 Lua table，也可能是旧路径的 C# Dictionary
    local isLuaTable = (type(cmd) == "table")
    local action = isLuaTable and cmd.action or getDictValue(cmd, "action")
    local rawParams = (isLuaTable and cmd.params) or getDictValue(cmd, "params") or {}
    local cmdId = isLuaTable and cmd.id or getDictValue(cmd, "id")

    -- 将 params 转换为 Lua table
    local params = csharpToLua(rawParams)

    -- 命令处理器映射
    local handlers = {
        ["activate"] = CommandHandler.handleActivate,
        ["reload"] = CommandHandler.handleReload,
        ["open_component"] = CommandHandler.handleOpenComponent,
        ["preview"] = CommandHandler.handlePreview,
        ["screenshot"] = CommandHandler.handleScreenshot,
        ["get_selection"] = CommandHandler.handleGetSelection,
        ["save"] = CommandHandler.handleSave,
        ["close"] = CommandHandler.handleClose,
        ["get_component_info"] = CommandHandler.handleGetComponentInfo,
        ["list_packages"] = CommandHandler.handleListPackages,
        ["list_components"] = CommandHandler.handleListComponents,
        ["start_test"] = CommandHandler.handleStartTest,
        ["stop_test"] = CommandHandler.handleStopTest,
        ["switch_device"] = CommandHandler.handleSwitchDevice,
        ["capture_preview"] = CommandHandler.handleCapturePreview,
        ["list_devices"] = CommandHandler.handleListDevices,
        ["switch_controller"] = CommandHandler.handleSwitchController,
        ["list_controllers"] = CommandHandler.handleListControllers,
        ["select_element"] = CommandHandler.handleSelectElement,
        ["probe_plugin_api"] = CommandHandler.handleProbePluginApi,
        ["probe_publish"] = CommandHandler.handleProbePublish,
        ["open_publish_settings"] = CommandHandler.handleOpenPublishSettings,
        ["publish_package"] = CommandHandler.handlePublishPackage,
        ["publish_all"] = CommandHandler.handlePublishAll,
        ["dev_hotfix"] = CommandHandler.handleDevHotfix,
        -- 日志管理（暂未启用）
        -- ["get_logs"] = CommandHandler.handleGetLogs,
        -- ["clear_logs"] = CommandHandler.handleClearLogs,
        -- ["probe_logs"] = CommandHandler.handleProbeLogs,
    }

    local handler = handlers[action]

    -- 扩展命令（由 src/ext 下的模块注册）
    if not handler and CommandHandler._extHandlers then
        handler = CommandHandler._extHandlers[action]
    end

    if not handler then
        return {
            id = cmdId,
            status = "error",
            error = "未知命令: " .. (action or "nil")
        }
    end

    -- 执行处理器
    local success, result = pcall(function()
        return handler(params, bridgePath)
    end)

    if success then
        return {
            id = cmdId,
            status = "success",
            data = result
        }
    else
        return {
            id = cmdId,
            status = "error",
            error = tostring(result)
        }
    end
end

-- 写入结果
function CommandHandler.writeResult(bridgePath, cmdId, result)
    local resultPath = bridgePath:gsub("/", "\\") .. "\\results\\" .. cmdId .. ".json"

    -- 手动构建 JSON 字符串
    local function tableToJson(t, indent)
        indent = indent or 0
        local spaces = string.rep("  ", indent)
        local nextSpaces = string.rep("  ", indent + 1)

        if type(t) ~= "table" then
            if type(t) == "string" then
                -- 转义特殊字符
                local escaped = t
                    :gsub("\\", "\\\\")
                    :gsub('"', '\\"')
                    :gsub("\n", "\\n")
                    :gsub("\r", "\\r")
                    :gsub("\t", "\\t")
                return '"' .. escaped .. '"'
            elseif type(t) == "number" or type(t) == "boolean" then
                return tostring(t)
            else
                return "null"
            end
        end

        -- 检查是否是数组
        local isArray = true
        local maxIndex = 0
        for k, v in pairs(t) do
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxIndex then maxIndex = k end
        end

        if isArray and maxIndex > 0 then
            local parts = {}
            for i = 1, maxIndex do
                parts[#parts + 1] = nextSpaces .. tableToJson(t[i], indent + 1)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "]"
        else
            local parts = {}
            for k, v in pairs(t) do
                local keyStr = type(k) == "string" and k or tostring(k)
                parts[#parts + 1] = nextSpaces .. '"' .. keyStr .. '": ' .. tableToJson(v, indent + 1)
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "}"
        end
    end

    local success, err = pcall(function()
        local content = tableToJson(result)
        local f = io.open(resultPath, "w")
        if f then
            f:write(content)
            f:close()
        else
            fprint("[MCPBridge] 无法写入结果文件: " .. resultPath)
        end
    end)

    if not success then
        fprint("[MCPBridge] 写入结果失败: " .. tostring(err))
    end
end

-- ========== 命令处理器实现 ==========

-- 激活编辑器
function CommandHandler.handleActivate(params, bridgePath)
    -- Lua 侧无法直接激活窗口，Python 端通过 Win32 API 负责激活
    -- 此处仅设置 runInBackground 确保定时器持续运行
    local ok, err = pcall(function()
        CS.UnityEngine.Application.runInBackground = true
    end)
    if ok then
        return { activated = false, reason = "Lua cannot activate window; Python Win32 handles activation", runInBackground = true }
    else
        return { activated = false, reason = "failed to set runInBackground: " .. tostring(err) }
    end
end

-- 刷新资源
function CommandHandler.handleReload(params, bridgePath)
    if params.package_name then
        local pkg = App.project:GetPackageByName(params.package_name)
        if pkg then
            -- FIX-1: 逐级尝试所有刷新方式，不再在第一次成功 pcall 后停止
            -- pkg:Touch() 可能返回成功但编辑器无视觉变化，需要组合多种方式
            local methodsAttempted = {}
            local methodsSucceeded = {}

            -- 方式1: pkg:Touch() — 标记包为需要刷新
            local ok1 = pcall(function() pkg:Touch() end)
            table.insert(methodsAttempted, "pkg:Touch()")
            if ok1 then
                table.insert(methodsSucceeded, "pkg:Touch()")
                fprint("[MCPBridge] reload: pkg:Touch() ok")
            end

            -- 方式2: pkg:Reload()（如果存在）
            local ok2 = pcall(function() pkg:Reload() end)
            table.insert(methodsAttempted, "pkg:Reload()")
            if ok2 then
                table.insert(methodsSucceeded, "pkg:Reload()")
                fprint("[MCPBridge] reload: pkg:Reload() ok")
            end

            -- 方式3: 遍历 pkg.items 并对每个 item 调用 Touch()
            local ok3 = pcall(function()
                local items = pkg.items
                if items and items.Count > 0 then
                    for i = 0, items.Count - 1 do
                        local item = items[i]
                        pcall(function() item:Touch() end)
                    end
                end
            end)
            table.insert(methodsAttempted, "item:Touch() all")
            if ok3 then
                table.insert(methodsSucceeded, "item:Touch() all")
                fprint("[MCPBridge] reload: item:Touch() on all items ok")
            end

            -- 方式4: App.project:RefreshPackage(pkg)
            local ok4 = pcall(function() App.project:RefreshPackage(pkg) end)
            table.insert(methodsAttempted, "project:RefreshPackage")
            if ok4 then
                table.insert(methodsSucceeded, "project:RefreshPackage")
                fprint("[MCPBridge] reload: project:RefreshPackage() ok")
            end

            -- 方式5: 延迟 0.2s 后再执行一次 Touch()（给编辑器时间处理前面的标记）
            local ok5 = pcall(function()
                CS.FairyGUI.Timers.inst:Add(0.2, 1, function()
                    pcall(function() pkg:Touch() end)
                    fprint("[MCPBridge] reload: delayed pkg:Touch() executed")
                end)
            end)
            table.insert(methodsAttempted, "delayed pkg:Touch()")
            if ok5 then
                table.insert(methodsSucceeded, "delayed pkg:Touch()")
                fprint("[MCPBridge] reload: delayed pkg:Touch() scheduled")
            end

            local anySucceeded = #methodsSucceeded > 0
            return {
                reloaded = anySucceeded,
                package = params.package_name,
                methods_attempted = table.concat(methodsAttempted, "; "),
                methods_succeeded = table.concat(methodsSucceeded, "; "),
                note = anySucceeded and "已尝试多种刷新方式，请检查编辑器是否有视觉变化"
                        or "所有刷新方式均不可用"
            }
        else
            error("包不存在: " .. params.package_name)
        end
    else
        -- 全量刷新：使用定时器异步执行，避免阻塞主线程和 poll 轮询
        -- 立即返回成功，让调用方知道命令已接收
        CS.FairyGUI.Timers.inst:Add(0.1, 1, function()
            fprint("[MCPBridge] 正在执行 App.RefreshProject...")
            pcall(function()
                App.RefreshProject()
            end)
            fprint("[MCPBridge] App.RefreshProject 完成")
        end)
        return { reloaded = true, async = true, message = "全量刷新已异步触发" }
    end
end

-- 辅助函数：在包中查找组件（支持路径和纯名称）
-- 路径格式：Buttons/Button01 或 Button01
local function findComponentItem(pkg, compName)
    -- 纯名称查找（向后兼容）
    local item = pkg:FindItemByName(compName)
    if item then return item end

    -- 尝试带 .xml 后缀
    item = pkg:GetItemByFileName(pkg.rootItem, compName .. ".xml")
    if item then return item end

    -- 路径格式：递归遍历 rootItem 匹配完整路径
    local pathParts = {}
    for part in compName:gmatch("[^/]+") do
        table.insert(pathParts, part)
    end

    if #pathParts > 1 then
        local fileName = pathParts[#pathParts] .. ".xml"
        local dirParts = {}
        for i = 1, #pathParts - 1 do
            table.insert(dirParts, pathParts[i])
        end

        -- 递归遍历查找
        local function searchInFolder(parentItem, dirIndex)
            if dirIndex > #dirParts then
                -- 已在目标目录，查找文件
                return pkg:GetItemByFileName(parentItem, fileName)
            end
            -- 查找当前层级的目录
            local targetDir = dirParts[dirIndex]
            if parentItem and parentItem.children then
                for i = 0, parentItem.children.Count - 1 do
                    local child = parentItem.children[i]
                    if child and child.type == "folder" and child.name == targetDir then
                        return searchInFolder(child, dirIndex + 1)
                    end
                end
            end
            return nil
        end

        item = searchInFolder(pkg.rootItem, 1)
        if item then return item end
    end

    return nil
end

-- 打开组件
function CommandHandler.handleOpenComponent(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 打开文档
    local url = item:GetURL()
    App.docView:OpenDocument(url, true)

    return {
        opened = true,
        url = url,
        name = item.name,
        path = item.path
    }
end

-- 预览组件
function CommandHandler.handlePreview(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 显示预览
    App.ShowPreview(item)

    return {
        previewing = true,
        url = item:GetURL(),
        name = item.name
    }
end

-- 截图
function CommandHandler.handleScreenshot(params, bridgePath)
    local target = params.target or "editor"
    local saveName = params.save_name or ("screenshot_" .. os.time())
    local scale = params.scale or 1

    local screenshotPath = bridgePath:gsub("/", "\\") .. "\\screenshots\\" .. saveName .. ".png"

    if target == "preview" then
        -- 使用 GetScreenShot 精确截取当前打开组件的画布渲染
        local doc = App.activeDoc
        if not doc then
            error("没有打开的文档，无法截取组件画布")
        end
        local content = doc.content
        if not content then
            error("文档内容为空")
        end
        local displayObj = content.displayObject
        if not displayObj then
            error("组件 displayObject 为空")
        end

        -- 收集调试信息
        local debugInfo = {}
        table.insert(debugInfo, "content_size=" .. content.width .. "x" .. content.height)
        table.insert(debugInfo, "dobj_size=" .. displayObj.width .. "x" .. displayObj.height)
        pcall(function()
            local b = displayObj:GetBounds(nil)
            table.insert(debugInfo, "dobj_bounds=" .. b.x .. "," .. b.y .. "," .. b.width .. "," .. b.height)
        end)
        pcall(function()
            if displayObj.numChildren then
                table.insert(debugInfo, "dobj_children=" .. displayObj.numChildren)
                for i = 0, math.min(displayObj.numChildren - 1, 5) do
                    local child = displayObj:GetChildAt(i)
                    if child then
                        table.insert(debugInfo, "child" .. i .. "=" .. child.width .. "x" .. child.height)
                    end
                end
            end
        end)

        captureDisplayObject(displayObj, screenshotPath, scale)

        local debugText = table.concat(debugInfo, "|")
        return {
            screenshot = saveName .. ".png",
            path = screenshotPath,
            captured = true,
            debug = debugText
        }
    else
        -- target="editor": 返回标记，由 Python 端使用 Win32 API 截取全屏
        return {
            screenshot = saveName .. ".png",
            path = screenshotPath,
            captured = false,
            use_python_capture = true,
            message = "editor 模式由 Python 端截取"
        }
    end
end

-- 获取选中元素
function CommandHandler.handleGetSelection(params, bridgePath)
    local doc = App.activeDoc
    if not doc then
        return { selection = {}, message = "没有打开的文档" }
    end

    local selection = doc:GetSelection()
    local result = {}

    if selection and selection.Count > 0 then
        for i = 0, selection.Count - 1 do
            local obj = selection[i]
            if obj then
                table.insert(result, {
                    id = obj.id or "",
                    name = obj.name or "",
                    type = obj.objectType or "unknown"
                })
            end
        end
    end

    return { selection = result, count = #result }
end

-- 保存文档
function CommandHandler.handleSave(params, bridgePath)
    local doc = App.activeDoc
    if doc then
        doc:Save()
        return { saved = true }
    end
    return { saved = false, message = "没有打开的文档" }
end

-- 关闭文档
function CommandHandler.handleClose(params, bridgePath)
    local doc = App.activeDoc
    if doc then
        App.docView:CloseDocument(doc)
        return { closed = true }
    end
    return { closed = false, message = "没有打开的文档" }
end

-- 获取组件信息
function CommandHandler.handleGetComponentInfo(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    return {
        name = item.name,
        id = item.id,
        type = item.type,
        width = item.width,
        height = item.height,
        path = item.path,
        url = item:GetURL(),
        exported = item.exported
    }
end

-- 列出所有包
function CommandHandler.handleListPackages(params, bridgePath)
    local packages = {}
    local allPackages = App.project.allPackages

    if allPackages then
        for i = 0, allPackages.Count - 1 do
            local pkg = allPackages[i]
            table.insert(packages, {
                name = pkg.name,
                id = pkg.id,
                path = pkg.basePath
            })
        end
    end

    return { packages = packages, count = #packages }
end

-- 列出包内组件
function CommandHandler.handleListComponents(params, bridgePath)
    local pkgName = params.package_name
    if not pkgName then
        error("缺少参数: package_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local components = {}
    local items = pkg.items

    if items then
        for i = 0, items.Count - 1 do
            local item = items[i]
            if item.type == "component" then
                table.insert(components, {
                    name = item.name,
                    id = item.id,
                    path = item.path,
                    width = item.width,
                    height = item.height,
                    exported = item.exported
                })
            end
        end
    end

    return { components = components, count = #components, package = pkgName }
end

-- ========== 预览测试命令 ==========

-- 辅助函数：从适配设置中查找设备信息
-- 返回 { resolutionX, resolutionY, found, scaleMode, screenMatchMode } 或 nil
local function findDeviceInfo(deviceName)
    if not deviceName then return nil end

    local adaptSettings = App.project:GetSettings("Adaptation")
    if not adaptSettings then return nil end

    local function searchInList(devices)
        if not devices then return nil end
        for i = 0, devices.Count - 1 do
            local dev = devices[i]
            if dev.name == deviceName then
                return dev
            end
        end
        return nil
    end

    local dev = searchInList(adaptSettings.defaultDevices) or searchInList(adaptSettings.devices)
    if dev then
        return {
            resolutionX = dev.resolutionX,
            resolutionY = dev.resolutionY,
            found = true,
            scaleMode = adaptSettings.scaleMode,
            screenMatchMode = adaptSettings.screenMatchMode,
            designX = adaptSettings.designResolutionX,
            designY = adaptSettings.designResolutionY
        }
    end
    return nil
end

-- 辅助函数：探查 testView 运行时的内部结构（用于调试设备切换和截图）
local function probeTestViewInternals(testView)
    local info = {}
    table.insert(info, "type=" .. tostring(testView:GetType()))
    table.insert(info, "running=" .. tostring(testView.running))
    table.insert(info, "visible=" .. tostring(testView.visible))
    table.insert(info, "size=" .. testView.width .. "x" .. testView.height)
    table.insert(info, "viewSize=" .. (testView.viewWidth or 0) .. "x" .. (testView.viewHeight or 0))
    table.insert(info, "numChildren=" .. tostring(testView.numChildren))

    -- 遍历子元素
    for i = 0, (testView.numChildren or 0) - 1 do
        local child = testView:GetChildAt(i)
        if child then
            local childInfo = string.format(
                "child%d: name=%s type=%s size=%dx%d visible=%s",
                i, child.name or "", tostring(child:GetType()),
                child.width, child.height, tostring(child.visible)
            )
            table.insert(info, childInfo)
        end
    end

    -- 探查内部属性
    local internalProps = {
        "stage", "Stage", "_stage", "content", "Content", "_content",
        "contentPane", "ContentPane", "_contentPane",
        "mainContainer", "_mainContainer", "viewPanel", "_viewPanel",
        "frame", "Frame",
        "displayObject", "DisplayObject", "_displayObject",
        "viewWidth", "viewHeight", "ViewWidth", "ViewHeight",
    }
    for _, prop in ipairs(internalProps) do
        local ok, val = pcall(function() return testView[prop] end)
        if ok and val ~= nil then
            local vtype = type(val)
            local vstr = tostring(val)
            if vtype == "userdata" then
                pcall(function()
                    vstr = string.format("%s (%.0fx%.0f)", tostring(val:GetType()), val.width, val.height)
                end)
            end
            table.insert(info, prop .. "=" .. vstr .. " [" .. vtype .. "]")
        end
    end

    -- 探查内部方法
    local internalMethods = {
        "SetSize", "setSize", "SetScale", "setScale",
        "Refresh", "refresh", "Repaint", "repaint",
        "UpdateSize", "updateSize", "ApplyDevice", "applyDevice",
    }
    for _, method in ipairs(internalMethods) do
        local ok, val = pcall(function() return testView[method] end)
        if ok and val ~= nil then
            table.insert(info, method .. "=[method:" .. type(val) .. "]")
        end
    end

    return table.concat(info, "\n")
end

-- 辅助函数：保存 testView 原始尺寸/缩放（用于恢复）
local mTestViewState = nil

local function saveTestViewState(testView)
    if mTestViewState then return end  -- 已保存，不重复
    mTestViewState = {
        viewWidth = testView.viewWidth or testView.width or 0,
        viewHeight = testView.viewHeight or testView.height or 0,
        width = testView.width or 0,
        height = testView.height or 0,
    }
    -- 保存 contentPane 状态
    pcall(function()
        local cp = testView.contentPane
        if cp then
            mTestViewState.cpWidth = cp.width
            mTestViewState.cpHeight = cp.height
            mTestViewState.cpScaleX = cp.scaleX or 1
            mTestViewState.cpScaleY = cp.scaleY or 1
        end
    end)
    fprint("[MCPBridge] 已保存 testView 原始状态: " ..
        string.format("view=%dx%d, content=%.0fx%.0f",
            mTestViewState.viewWidth, mTestViewState.viewHeight,
            mTestViewState.cpWidth or 0, mTestViewState.cpHeight or 0))
end

local function restoreTestViewState(testView)
    if not mTestViewState then return end
    pcall(function()
        if mTestViewState.viewWidth > 0 then
            testView.viewWidth = mTestViewState.viewWidth
        end
        if mTestViewState.viewHeight > 0 then
            testView.viewHeight = mTestViewState.viewHeight
        end
    end)
    -- 恢复 contentPane 状态
    pcall(function()
        local cp = testView.contentPane
        if cp and mTestViewState.cpWidth then
            cp:SetSize(mTestViewState.cpWidth, mTestViewState.cpHeight)
            cp:SetScale(mTestViewState.cpScaleX, mTestViewState.cpScaleY)
        end
    end)
    fprint("[MCPBridge] 已恢复 testView 原始状态")
    mTestViewState = nil
end

-- 辅助函数：设置 testView 的预览设备分辨率
-- Bug1 修复：绝对不调用 GRoot.inst:SetContentScaleFactor()，只影响 testView.contentPane
-- 返回 succeeded, methodsList
local function applyTestViewDevice(testView, resX, resY, scaleMode, screenMatchMode)
    local succeeded = false
    local methods = {}

    -- 策略1: 获取 contentPane 并设置其尺寸（最精确，只影响预览内容）
    local contentPane = nil
    pcall(function() contentPane = testView.contentPane end)
    if not contentPane then pcall(function() contentPane = testView.ContentPane end) end

    if contentPane then
        local ok1 = pcall(function()
            contentPane:SetSize(resX, resY)
        end)
        table.insert(methods, "contentPane:SetSize(" .. resX .. "," .. resY .. ")")
        if ok1 then succeeded = true end
    end

    -- 策略2: 设置 contentPane 的缩放比
    if contentPane and not succeeded then
        local adaptSettings = App.project:GetSettings("Adaptation")
        local designX = 0
        local designY = 0
        pcall(function()
            designX = adaptSettings.designResolutionX or 0
            designY = adaptSettings.designResolutionY or 0
        end)
        if designX > 0 and designY > 0 then
            local scaleX = resX / designX
            local scaleY = resY / designY
            local ok2 = pcall(function()
                contentPane:SetScale(scaleX, scaleY)
            end)
            table.insert(methods, "contentPane:SetScale(" .. string.format("%.3f", scaleX) .. "," .. string.format("%.3f", scaleY) .. ")")
            if ok2 then succeeded = true end
        end
    end

    -- 策略3: 设置 testView 的 viewWidth/viewHeight
    if not succeeded then
        local ok3 = pcall(function()
            testView.viewWidth = resX
            testView.viewHeight = resY
        end)
        table.insert(methods, "testView.viewWidth/Height=" .. resX .. "x" .. resY)
        if ok3 then succeeded = true end
    end

    -- 策略4: 设置 testView 的 size（SetSize）
    if not succeeded then
        local ok4 = pcall(function()
            testView:SetSize(resX, resY)
        end)
        table.insert(methods, "testView:SetSize(" .. resX .. "," .. resY .. ")")
        if ok4 then succeeded = true end
    end

    -- 策略5: 通过内部 Stage 设置（testView 独立的 stage，不影响编辑器全局 GRoot）
    if not succeeded then
        local stage = nil
        pcall(function() stage = testView.stage end)
        if not stage then pcall(function() stage = testView.Stage end) end

        if stage then
            local ok5 = pcall(function()
                stage:SetSize(resX, resY)
            end)
            table.insert(methods, "stage:SetSize(" .. resX .. "," .. resY .. ")")
            if ok5 then succeeded = true end
        end
    end

    -- 注意：策略6（GRoot.inst:SetContentScaleFactor）已删除，它会缩放整个编辑器UI

    fprint("[MCPBridge] 设备切换结果: succeeded=" .. tostring(succeeded) .. ", methods=[" .. table.concat(methods, "], [") .. "]")
    return succeeded, table.concat(methods, "; ")
end

-- 辅助函数：获取 testView 的预览内容 displayObject（用于精确截图）
-- 策略优先级：
--   1. testView.child[0]:GetChild("docContainer") - 整个预览容器，配合裁剪到模拟设备区域
--   2. testView 第一个子元素的 displayObject（整个预览面板，含编辑器UI）
--   3. contentPane.displayObject
--   4. testView.displayObject（回退）
-- 返回值：displayObject, source, [cropX, cropY, cropW, cropH] - 裁剪信息（可选）
local function getTestViewCaptureTarget(testView)
    -- 策略1（最优）: docContainer + 裁剪到模拟设备屏幕
    if testView.numChildren and testView.numChildren > 0 then
        local child0 = nil
        pcall(function() child0 = testView:GetChildAt(0) end)
        if child0 then
            local docContainer = nil
            pcall(function() docContainer = child0:GetChild("docContainer") end)
            if docContainer and docContainer.numChildren > 0 then
                local deviceScreen = nil
                pcall(function() deviceScreen = docContainer:GetChildAt(0) end)
                if deviceScreen then
                    local dobj = nil
                    pcall(function() dobj = docContainer.displayObject end)
                    if dobj then
                        -- deviceScreen 在 docContainer 内的子元素的真实偏移
                        -- 通过 deviceScreen 自身坐标 + 它内部第一个子元素的偏移得到
                        local cropX = deviceScreen.x or 0
                        local cropY = deviceScreen.y or 0
                        if deviceScreen.numChildren and deviceScreen.numChildren > 0 then
                            local inner = nil
                            pcall(function() inner = deviceScreen:GetChildAt(0) end)
                            if inner then
                                cropX = cropX + (inner.x or 0)
                                cropY = cropY + (inner.y or 0)
                            end
                        end
                        local cropW = deviceScreen.width or 0
                        local cropH = deviceScreen.height or 0
                        fprint(string.format("[MCPBridge] 截图目标(docContainer + crop): %sx%s at (%s,%s)",
                            tostring(cropW), tostring(cropH),
                            tostring(cropX), tostring(cropY)))
                        return dobj, "docContainer_cropped", cropX, cropY, cropW, cropH
                    end
                end
            end
        end
    end

    -- 策略2: docContainer 整体（含设备外灰色区域）
    if testView.numChildren and testView.numChildren > 0 then
        local child0 = nil
        pcall(function() child0 = testView:GetChildAt(0) end)
        if child0 then
            local docContainer = nil
            pcall(function() docContainer = child0:GetChild("docContainer") end)
            if docContainer then
                local dobj = nil
                pcall(function() dobj = docContainer.displayObject end)
                if dobj then
                    return dobj, "docContainer"
                end
            end
        end
    end

    -- 策略3（旧逻辑）: testView.child[0].displayObject
    if testView.numChildren and testView.numChildren > 0 then
        local child = nil
        pcall(function() child = testView:GetChildAt(0) end)
        if child then
            local dobj = nil
            pcall(function() dobj = child.displayObject end)
            if dobj then
                return dobj, "child0_" .. tostring(child.name)
            end
        end
    end

    -- 策略4: contentPane.displayObject
    local contentPane = nil
    pcall(function() contentPane = testView.contentPane end)
    if not contentPane then pcall(function() contentPane = testView.ContentPane end) end

    if contentPane then
        local dobj = nil
        pcall(function() dobj = contentPane.displayObject end)
        if dobj then
            return dobj, "contentPane"
        end
    end

    -- 策略5: testView.displayObject（最后回退）
    local dobj = nil
    pcall(function() dobj = testView.displayObject end)
    if dobj then
        return dobj, "testView_displayObject"
    end

    return nil, "none"
end

-- 启动预览测试（F5）
-- FIX-1: device_name 通过延迟定时器 + 多策略设置设备分辨率
-- FIX-2: 组件大于 testView 可视区域时自动调整 testView 尺寸
function CommandHandler.handleStartTest(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name
    local deviceName = params.device_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 如果 testView 已在运行，先停止再重新启动，避免缓存状态导致显示上一次的组件
    local testView = App.testView
    if testView and testView.running then
        fprint("[MCPBridge] testView 正在运行，先停止再重新启动")
        testView:Stop()
    end

    -- F5 预览运行的是编辑器当前打开的组件（activeDoc），而非 Start 参数指定的组件
    -- 因此必须先打开目标组件文档，确保 activeDoc 指向正确组件
    local url = item:GetURL()
    App.docView:OpenDocument(url, true)

    -- 启动 F5 预览测试
    App.testView:Start(item)
    -- F5 模式会设置 runInBackground = false，导致窗口失焦后定时器停止
    -- 启动后立即重置，确保后续命令能正常轮询
    CS.UnityEngine.Application.runInBackground = true

    -- FIX-1: 如果指定了设备，通过延迟定时器切换分辨率
    -- testView:Start 是异步的，立即设置可能不生效
    local currentDevice = "default"
    local resX = 0
    local resY = 0
    local deviceFound = false

    if deviceName then
        local devInfo = findDeviceInfo(deviceName)
        if devInfo and devInfo.found then
            resX = devInfo.resolutionX
            resY = devInfo.resolutionY
            currentDevice = deviceName
            deviceFound = true

            -- FIX-2: 增加延迟到 0.5s，确保 testView:Start 内部初始化完成
            CS.FairyGUI.Timers.inst:Add(0.5, 1, function()
                local tv = App.testView
                if tv and tv.running then
                    -- 保存原始状态以便恢复
                    saveTestViewState(tv)
                    applyTestViewDevice(tv, resX, resY, devInfo.scaleMode, devInfo.screenMatchMode)
                else
                    fprint("[MCPBridge] testView 未运行，无法设置设备分辨率")
                end
            end)
        else
            -- 设备未找到，打印所有可用设备名称用于调试
            fprint("[MCPBridge] 设备未找到: '" .. deviceName .. "'")
            local adaptSettings = App.project:GetSettings("Adaptation")
            if adaptSettings then
                if adaptSettings.defaultDevices then
                    for i = 0, adaptSettings.defaultDevices.Count - 1 do
                        local dev = adaptSettings.defaultDevices[i]
                        fprint("[MCPBridge]  默认设备[" .. i .. "]: '" .. dev.name .. "' (" .. dev.resolutionX .. "x" .. dev.resolutionY .. ")")
                    end
                end
                if adaptSettings.devices then
                    for i = 0, adaptSettings.devices.Count - 1 do
                        local dev = adaptSettings.devices[i]
                        fprint("[MCPBridge]  自定义设备[" .. i .. "]: '" .. dev.name .. "' (" .. dev.resolutionX .. "x" .. dev.resolutionY .. ")")
                    end
                end
            end
        end
    end

    -- FIX-2: 如果组件尺寸大于 testView 可视区域，调整 testView 尺寸确保组件完整可见
    local compW = item.width or 0
    local compH = item.height or 0

    CS.FairyGUI.Timers.inst:Add(0.5, 1, function()
        local tv = App.testView
        if not tv or not tv.running then return end
        if compW <= 0 or compH <= 0 then return end

        local viewW = tv.viewWidth > 0 and tv.viewWidth or tv.width
        local viewH = tv.viewHeight > 0 and tv.viewHeight or tv.height
        if viewW <= 0 or viewH <= 0 then return end

        if compW > viewW or compH > viewH then
            pcall(function()
                tv.viewWidth = compW
                tv.viewHeight = compH
            end)
            fprint("[MCPBridge] 组件(" .. compW .. "x" .. compH .. ")大于预览区域(" .. viewW .. "x" .. viewH .. ")，已调整 testView 尺寸")
        end
    end)

    return {
        started = true,
        item_name = item.name,
        item_id = item.id,
        component = compName,
        package = pkgName,
        component_size = { width = compW, height = compH },
        device = currentDevice,
        device_found = deviceFound,
        resolutionX = resX,
        resolutionY = resY
    }
end

-- 停止预览测试
function CommandHandler.handleStopTest(params, bridgePath)
    local testView = App.testView
    if testView and testView.running then
        -- 恢复设备切换前的原始尺寸/缩放
        restoreTestViewState(testView)
        testView:Stop()
        -- 停止 F5 后重置 runInBackground，确保编辑器恢复正常后台运行
        CS.UnityEngine.Application.runInBackground = true
        return { stopped = true }
    end
    return { stopped = false, message = "预览未运行" }
end

-- 切换设备分辨率
function CommandHandler.handleSwitchDevice(params, bridgePath)
    local deviceName = params.device_name

    if not deviceName then
        error("缺少参数: device_name")
    end

    local testView = App.testView
    if not testView or not testView.running then
        error("预览未运行，请先调用 start_test")
    end

    -- 保存原始状态（如果还未保存）
    saveTestViewState(testView)

    local devInfo = findDeviceInfo(deviceName)
    if not devInfo or not devInfo.found then
        error("设备未找到: " .. deviceName)
    end

    local resX = devInfo.resolutionX
    local resY = devInfo.resolutionY
    local _, methods = applyTestViewDevice(testView, resX, resY, devInfo.scaleMode, devInfo.screenMatchMode)

    return {
        switched = true,
        device = deviceName,
        resolutionX = resX,
        resolutionY = resY,
        methods = methods
    }
end

-- 截取预览截图
-- FIX-3: 使用 getTestViewCaptureTarget 精确定位截图目标，而非 GRoot.inst 全屏
function CommandHandler.handleCapturePreview(params, bridgePath)
    local saveName = params.save_name or ("preview_" .. os.time())
    local deviceName = params.device_name
    local scale = params.scale or 1

    local testView = App.testView
    if not testView or not testView.running then
        error("预览未运行，请先调用 start_test")
    end

    -- 如果指定了设备，先切换
    if deviceName then
        CommandHandler.handleSwitchDevice({ device_name = deviceName }, bridgePath)
        saveName = saveName .. "_" .. deviceName:gsub(" ", "_")
    end

    local screenshotPath = bridgePath:gsub("/", "\\") .. "\\screenshots\\" .. saveName .. ".png"

    -- 截图模式：
    --   auto（默认）裁剪到模拟设备屏幕区域
    --   full        不裁剪，输出整个容器的渲染结果（裁剪区算错时的兜底）
    local mode = params.mode or "auto"

    local captureObj, captureSource, cropX, cropY, cropW, cropH = getTestViewCaptureTarget(testView)
    if not captureObj then
        error("无法获取预览渲染对象")
    end

    if mode == "full" then
        cropX, cropY, cropW, cropH = nil, nil, nil, nil
        captureSource = tostring(captureSource) .. "_full"
    end

    captureDisplayObject(captureObj, screenshotPath, scale, cropX, cropY, cropW, cropH)

    return {
        captured = true,
        screenshot = saveName .. ".png",
        path = screenshotPath,
        capture_source = captureSource,
        mode = mode,
    }
end

-- 列出可用设备
function CommandHandler.handleListDevices(params, bridgePath)
    local adaptSettings = App.project:GetSettings("Adaptation")
    if not adaptSettings then
        error("无法获取适配设置")
    end

    local devices = {}

    -- 默认设备
    if adaptSettings.defaultDevices then
        for i = 0, adaptSettings.defaultDevices.Count - 1 do
            local dev = adaptSettings.defaultDevices[i]
            table.insert(devices, {
                name = dev.name,
                resolutionX = dev.resolutionX,
                resolutionY = dev.resolutionY,
                source = "default"
            })
        end
    end

    -- 自定义设备
    if adaptSettings.devices then
        for i = 0, adaptSettings.devices.Count - 1 do
            local dev = adaptSettings.devices[i]
            table.insert(devices, {
                name = dev.name,
                resolutionX = dev.resolutionX,
                resolutionY = dev.resolutionY,
                source = "custom"
            })
        end
    end

    -- 当前适配设置
    local scaleMode = adaptSettings.scaleMode or "unknown"
    local screenMathMode = adaptSettings.screenMatchMode or "unknown"
    local designX = adaptSettings.designResolutionX or 0
    local designY = adaptSettings.designResolutionY or 0

    return {
        devices = devices,
        count = #devices,
        scaleMode = scaleMode,
        screenMatchMode = screenMathMode,
        designResolution = { x = designX, y = designY }
    }
end

-- ========== 控制器操作命令 ==========

-- 切换控制器状态
function CommandHandler.handleSwitchController(params, bridgePath)
    local controllerName = params.controller_name
    local pageIndex = params.page_index
    local pageName = params.page_name

    if not controllerName then
        error("缺少参数: controller_name")
    end

    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    local component = doc.content
    if not component then
        error("无法获取文档组件")
    end

    -- 从 controllers 集合中按名称查找
    local ctrl = nil
    local ctrls = component.controllers
    if ctrls then
        for i = 0, ctrls.Count - 1 do
            local c = ctrls[i]
            -- 集合里可能有 null 空洞，必须判空
            if c ~= nil and c.name == controllerName then
                ctrl = c
                break
            end
        end
    end

    if not ctrl then
        error("控制器不存在: " .. controllerName)
    end

    local oldIndex = ctrl.selectedIndex
    local totalPages = ctrl.pageCount

    if pageName then
        -- 按页名称切换：从 XML 解析页面名称匹配索引
        local pkgName = ""
        local compName = ""
        pcall(function()
            pkgName = doc.packageItem.owner.name
            compName = doc.packageItem.name:gsub("%.xml$", "")
        end)
        error("page_name 暂不支持在编辑器端使用，请使用 page_index 代替（可先用 list_controllers 获取页面索引）")
    elseif pageIndex ~= nil then
        -- 按页索引切换
        if pageIndex < 0 or pageIndex >= totalPages then
            error("页索引超出范围: " .. pageIndex .. "（总页数: " .. totalPages .. "）")
        end
        ctrl.selectedIndex = pageIndex
    else
        error("缺少参数: page_index 或 page_name")
    end

    return {
        switched = true,
        controller = controllerName,
        oldIndex = oldIndex,
        newIndex = ctrl.selectedIndex,
        totalPages = totalPages
    }
end

-- 列出控制器
function CommandHandler.handleListControllers(params, bridgePath)
    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    local content = doc.content
    if not content then
        error("无法获取文档组件")
    end

    local ctrls = content.controllers
    if not ctrls then
        return { controllers = {}, count = 0, component = doc.displayTitle or "unknown" }
    end

    local controllers = {}
    local holes = 0

    -- 注意：content.controllers 里可能存在 null 空洞（编辑器在失败的新增调用后会留下空槽），
    -- 直接索引会拿到 nil 并让整个命令崩掉，这里必须跳过。
    for i = 0, ctrls.Count - 1 do
        local ctrl = ctrls[i]
        if ctrl == nil then
            holes = holes + 1
        else
            table.insert(controllers, {
                name = ctrl.name,
                selectedIndex = ctrl.selectedIndex,
                pageCount = ctrl.pageCount,
                alias = ctrl.alias or "",
                exported = ctrl.exported or false
            })
        end
    end

    -- 获取包名和组件名，供 Python 侧从 XML 补充页面名称
    local pkgName = ""
    local compName = ""
    local ok, _ = pcall(function()
        pkgName = doc.packageItem.owner.name
        compName = doc.packageItem.name:gsub("%.xml$", "")
    end)

    return {
        controllers = controllers,
        count = #controllers,
        rawCount = ctrls.Count,
        holes = holes,
        component = doc.displayTitle or "unknown",
        package_name = pkgName,
        component_name = compName
    }
end

-- ========== 选择元素命令 (NEW-1) ==========

-- 在编辑器中选中指定元素
--
-- 已知限制（FairyEditor 私有 API 限制，无解）：
-- 右侧检查器面板的渲染源是 Document.inspectingTarget 字段，该字段是 C# 的
-- { get; private set; } 只读属性，setter 由编辑器 selectionLayer 鼠标事件链路
-- 内部触发，外部 Lua 无法写入。这意味着本工具只能更新 selection（驱动画布选中
-- 框），无法让右侧检查器面板自动切换到所选元素的属性。如需查看属性，必须由人
-- 工在编辑器中手动点击元素。
--
-- 实现采用 UnselectAll + SelectObject 组合：
-- - UnselectAll：清空旧选择，避免 SelectObject 把目标加入而不是替换
-- - SelectObject(obj, scrollToView, allowOpenGroups)：编辑器内部选中元素的标
--   准 API，会同步 selection 集合并触发画布选中框跟随
function CommandHandler.handleSelectElement(params, bridgePath)
    -- 兼容两种参数名：扩展模块统一用 name，基础命令原来用 element_name
    local elementName = params.element_name or params.name or params.element

    if not elementName then
        error("缺少参数: name（或 element_name）")
    end

    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    -- doc.content 类型为 FairyEditor.FComponent
    -- FComponent:GetChild(name) 返回 FairyEditor.FObject（不是 FairyGUI.GObject）
    -- Document:SelectObject 期望的也是 FObject，类型完全匹配
    local content = doc.content
    if not content then
        error("无法获取文档组件")
    end

    -- 策略1: 直接按名称查找
    local targetChild = nil
    pcall(function()
        targetChild = content:GetChild(elementName)
    end)

    -- 策略2: 遍历 FComponent.children 列表兜底
    if not targetChild then
        pcall(function()
            local children = content.children
            if children and children.Count then
                for i = 0, children.Count - 1 do
                    local child = children[i]
                    if child and child.name == elementName then
                        targetChild = child
                        break
                    end
                end
            end
        end)
    end

    if not targetChild then
        error("元素不存在: " .. elementName)
    end

    -- UnselectAll + SelectObject 组合：先清空旧选择再添加目标，等价于"独占选中"
    pcall(function() doc:UnselectAll() end)

    local selectOk, selectErr = pcall(function()
        doc:SelectObject(targetChild, true, true)
    end)

    if not selectOk then
        error("选中失败: " .. tostring(selectErr))
    end

    -- 尝试通过 docFactory:InvokeDocumentMethod 调用 Document 内部非 public 方法
    -- 来同步 inspectingTarget。这是 FairyEditor 给 Lua 插件预留的反射调用入口。
    local inspectorSyncMethod = "none"
    local inspectorSynced = false
    pcall(function()
        local methodCandidates = {
            "InspectObject", "Inspect", "SetInspectingTarget",
            "DoInspect", "UpdateInspectingTarget",
        }
        for _, methodName in ipairs(methodCandidates) do
            local args = CS.System.Array.CreateInstance(typeof(CS.System.Object), 1)
            args:SetValue(targetChild, 0)
            local invokeOk = pcall(function()
                App.docFactory:InvokeDocumentMethod(methodName, args)
            end)
            if invokeOk then
                -- 检查 inspectingTarget 是否真的被改了
                if doc.inspectingTarget and doc.inspectingTarget.name == elementName then
                    inspectorSynced = true
                    inspectorSyncMethod = "InvokeDocumentMethod(" .. methodName .. ")"
                    break
                end
            end
        end
    end)

    -- 校验 selection 是否真的更新到目标元素
    local selectionVerified = false
    pcall(function()
        local sel = doc:GetSelection()
        if sel and sel.Count == 1 and sel[0] and sel[0].name == elementName then
            selectionVerified = true
        end
    end)

    return {
        selected = true,
        element_name = elementName,
        selection_verified = selectionVerified,
        inspector_synced = inspectorSynced,
        inspector_sync_method = inspectorSyncMethod,
        note = inspectorSynced
            and "selection 已更新且检查器面板已同步"
            or "selection 已更新（画布选中框已切换）。检查器面板的 inspectingTarget 是 FairyEditor 私有 setter，外部 Lua 无法写入；如需查看元素属性请在编辑器中手动点击。"
    }
end

-- ========== 插件管理命令 ==========

-- 探查插件管理 API
function CommandHandler.handleProbePluginApi(params, bridgePath)
    local found = {}
    local target = params.target or "overview"

    if target == "overview" then
        -- 探查 App 上与插件相关的属性
        local appProps = {
            "pluginManager", "PluginManager", "pluginMgr", "PluginMgr",
            "plugins", "Plugins", "pluginSystem", "PluginSystem",
            "luaEnv", "LuaEnv", "luaManager", "LuaManager",
        }

        for _, prop in ipairs(appProps) do
            local ok, val = pcall(function() return App[prop] end)
            if ok and val ~= nil then
                table.insert(found, {
                    path = "App." .. prop,
                    valtype = type(val),
                    value = tostring(val)
                })
            end
        end

    elseif target == "pluginManager" then
        -- 深入探查 App.pluginManager 的属性和方法
        local mgr = App.pluginManager
        local props = {
            "allPlugins", "plugins", "loadedPlugins", "pluginList",
            "count", "Count",
            "ReloadAll", "Reload", "ReloadPlugin",
            "LoadPlugin", "UnloadPlugin",
            "LoadAll", "StopAll", "RestartAll",
            "Dispose",
        }

        for _, prop in ipairs(props) do
            local ok, val = pcall(function() return mgr[prop] end)
            if ok and val ~= nil then
                table.insert(found, {
                    path = "pluginManager." .. prop,
                    valtype = type(val),
                    value = tostring(val)
                })
            end
        end

        -- 探查 allPlugins 中的第一个插件信息
        local ok, plugins = pcall(function() return mgr.allPlugins end)
        if ok and plugins then
            local pcount = plugins.Count
            table.insert(found, { path = "allPlugins.Count", valtype = "number", value = tostring(pcount) })

            if pcount > 0 then
                local p0 = plugins[0]
                local infoProps = {"name", "id", "path", "enabled", "loaded", "running",
                                   "version", "desc", "author",
                                   "Reload", "reload", "Restart", "restart",
                                   "Start", "start", "Stop", "stop",
                                   "Load", "load", "Unload", "unload"}
                for _, ip in ipairs(infoProps) do
                    local ok2, val2 = pcall(function() return p0[ip] end)
                    if ok2 and val2 ~= nil then
                        table.insert(found, {
                            path = "pluginInfo[0]." .. ip,
                            valtype = type(val2),
                            value = tostring(val2)
                        })
                    end
                end
            end
        end

    elseif target == "luaManager" then
        -- 探查 LuaManager
        local ok, lm = pcall(function() return CS.FairyEditor.LuaManager end)
        if ok and lm then
            local props = {
                "inst", "Instance", "instance",
                "Reload", "reload", "ReloadAll", "reloadAll",
                "RestartAll", "restartAll",
                "LoadScript", "loadScript",
                "DoFile", "doFile",
            }
            for _, prop in ipairs(props) do
                local ok2, val = pcall(function() return lm[prop] end)
                if ok2 and val ~= nil then
                    table.insert(found, {
                        path = "LuaManager." .. prop,
                        valtype = type(val),
                        value = tostring(val)
                    })
                end
            end
        end

    elseif target == "console" then
        -- 探查控制台/日志相关 API
        local csTypes = {
            "Console", "OutputPanel", "LogManager", "OutputManager",
            "TraceManager", "MessageManager", "OutputView",
        }
        for _, t in ipairs(csTypes) do
            local ok, val = pcall(function() return CS.FairyEditor[t] end)
            if ok and val ~= nil then
                table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
            end
        end

    elseif target == "console_deep" then
        -- 深入探查 CS.FairyEditor.Console 实例
        local console = CS.FairyEditor.Console
        if not console then
            table.insert(found, { path = "CS.FairyEditor.Console", valtype = "nil", value = "not found" })
        else
            -- 获取 inst 单例
            local inst = nil
            local ok, v = pcall(function() return console.inst end)
            if ok and v ~= nil then inst = v end

            local obj = inst or console
            local prefix = inst and "Console.inst" or "Console"

            local subProps = {
                "logs", "Logs", "items", "Items", "messages", "Messages",
                "entries", "Entries", "records", "Records", "list", "List",
                "GetLogs", "getLogs", "GetMessages", "getMessages", "GetEntries", "GetItems",
                "Clear", "clear", "ClearAll", "clearAll", "ClearLogs", "Reset",
                "Count", "count", "length", "Length",
                "view", "View", "panel", "Panel", "content", "Content",
            }
            for _, sp in ipairs(subProps) do
                local ok2, val2 = pcall(function() return obj[sp] end)
                if ok2 and val2 ~= nil then
                    local vtype = type(val2)
                    local vstr = tostring(val2)
                    -- 如果是集合，尝试获取 Count
                    if vtype == "table" and val2.Count ~= nil then
                        local ok3, cnt = pcall(function() return val2.Count end)
                        if ok3 then vstr = vstr .. " [Count=" .. tostring(cnt) .. "]" end
                    end
                    table.insert(found, { path = prefix .. "." .. sp, valtype = vtype, value = vstr })
                end
            end
        end

    elseif target == "pluginSystem" then
        -- 探查 PluginSystem
        local ok, ps = pcall(function() return CS.FairyEditor.PluginSystem end)
        if ok and ps then
            local props = {
                "inst", "Instance", "instance",
                "Reload", "reload", "ReloadAll", "reloadAll",
                "Restart", "restart", "RestartAll", "restartAll",
                "LoadAll", "loadAll",
            }
            for _, prop in ipairs(props) do
                local ok2, val = pcall(function() return ps[prop] end)
                if ok2 and val ~= nil then
                    table.insert(found, {
                        path = "PluginSystem." .. prop,
                        valtype = type(val),
                        value = tostring(val)
                    })
                end
            end
        end

    elseif target == "preview_scale" then
        -- 探查预览缩放相关属性
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                -- 探查 contentScaler 控件
                local scaler = nil
                pcall(function() scaler = child0:GetChild("contentScaler") end)
                if scaler then
                    local props = {"value", "title", "text", "selected", "selectedIndex"}
                    for _, p in ipairs(props) do
                        local ok, val = pcall(function() return scaler[p] end)
                        if ok and val ~= nil then
                            table.insert(found, { path = "contentScaler." .. p, value = tostring(val) })
                        end
                    end
                end

                -- 探查 docContainer 内部元素的缩放
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer and docContainer.numChildren > 0 then
                    table.insert(found, {
                        path = "docContainer",
                        value = string.format("%sx%s, scaleX=%s, scaleY=%s",
                            tostring(docContainer.width or 0), tostring(docContainer.height or 0),
                            tostring(docContainer.scaleX or 1), tostring(docContainer.scaleY or 1))
                    })
                    local devCont = nil
                    pcall(function() devCont = docContainer:GetChildAt(0) end)
                    if devCont then
                        table.insert(found, {
                            path = "deviceContainer",
                            value = string.format("%sx%s, scaleX=%s, scaleY=%s, x=%s, y=%s",
                                tostring(devCont.width or 0), tostring(devCont.height or 0),
                                tostring(devCont.scaleX or 1), tostring(devCont.scaleY or 1),
                                tostring(devCont.x or 0), tostring(devCont.y or 0))
                        })
                    end
                end
            end
        end

    elseif target == "docContainer_deep" then
        -- 探查 docContainer.child[0] 里面的内容
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer and docContainer.numChildren > 0 then
                    local devCont = nil
                    pcall(function() devCont = docContainer:GetChildAt(0) end)
                    if devCont then
                        local n = devCont.numChildren or 0
                        table.insert(found, {
                            path = "docContainer.child[0]",
                            value = string.format("name=%s, %sx%s, numChildren=%d",
                                tostring(devCont.name or ""),
                                tostring(devCont.width or 0),
                                tostring(devCont.height or 0), n)
                        })
                        for i = 0, math.min(n - 1, 10) do
                            local gc = nil
                            pcall(function() gc = devCont:GetChildAt(i) end)
                            if gc then
                                table.insert(found, {
                                    path = "deviceContainer.child[" .. i .. "]",
                                    value = string.format("name=%s, %sx%s at (%s,%s)",
                                        tostring(gc.name or ""),
                                        tostring(gc.width or 0), tostring(gc.height or 0),
                                        tostring(gc.x or 0), tostring(gc.y or 0))
                                })
                            end
                        end
                    end
                end
            end
        end

    elseif target == "docContainer" then
        -- 探查 docContainer 内部结构（找到模拟设备区域）
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer then
                    local n = docContainer.numChildren or 0
                    table.insert(found, { path = "docContainer.numChildren", value = tostring(n) })
                    for i = 0, math.min(n - 1, 14) do
                        local gc = nil
                        pcall(function() gc = docContainer:GetChildAt(i) end)
                        if gc then
                            table.insert(found, {
                                path = "docContainer.child[" .. i .. "]",
                                value = string.format("name=%s, %sx%s at (%s,%s)",
                                    tostring(gc.name or ""),
                                    tostring(gc.width or 0), tostring(gc.height or 0),
                                    tostring(gc.x or 0), tostring(gc.y or 0))
                            })
                        end
                    end
                end
            end
        end

    elseif target == "testView_grandchild" then
        -- 探查 testView.child[0] 内部的所有子元素
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child = nil
            pcall(function() child = tv:GetChildAt(0) end)
            if child and child.numChildren then
                local n = child.numChildren
                table.insert(found, { path = "child0.numChildren", value = tostring(n) })
                for i = 0, math.min(n - 1, 14) do
                    local gc = nil
                    pcall(function() gc = child:GetChildAt(i) end)
                    if gc then
                        table.insert(found, {
                            path = "child0.child[" .. i .. "]",
                            value = string.format("name=%s, %dx%d at (%d,%d)",
                                tostring(gc.name or ""), gc.width or 0, gc.height or 0,
                                gc.x or 0, gc.y or 0)
                        })
                    end
                end
            end
        end

    elseif target == "testView_child0" then
        -- 探查 testView 第一个子元素（被预览的组件）
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child = nil
            pcall(function() child = tv:GetChildAt(0) end)
            if child then
                local props = {
                    "name", "x", "y", "width", "height", "scaleX", "scaleY",
                    "displayObject", "numChildren", "asCom", "AsCom",
                }
                for _, p in ipairs(props) do
                    local ok, val = pcall(function() return child[p] end)
                    if ok and val ~= nil then
                        table.insert(found, { path = "child0." .. p, valtype = type(val), value = tostring(val) })
                    end
                end
                -- 如果 displayObject 存在，深入一层
                local dobj = nil
                pcall(function() dobj = child.displayObject end)
                if dobj then
                    local sp = {"x", "y", "width", "height", "name", "scaleX", "scaleY"}
                    for _, p in ipairs(sp) do
                        local ok, val = pcall(function() return dobj[p] end)
                        if ok and val ~= nil then
                            table.insert(found, { path = "child0.displayObject." .. p, valtype = type(val), value = tostring(val) })
                        end
                    end
                end
            end
        end

    elseif target == "testView_full" then
        -- 深入探查 testView 内部结构
        local tv = App.testView
        if tv then
            local props = {
                "running", "visible", "contentPane", "ContentPane",
                "stage", "Stage", "displayObject", "DisplayObject",
                "view", "View", "panel", "Panel", "container", "Container",
                "viewWidth", "viewHeight", "width", "height",
                "scaleX", "scaleY", "scale",
                "x", "y", "name",
                "numChildren", "GetChildAt", "GetChild",
                "rootView", "RootView", "host", "Host",
                "parent", "Parent",
                "GetScreenShot", "GetBounds",
                "viewport", "Viewport", "frame", "Frame",
                "preview", "Preview", "previewWindow", "PreviewWindow",
                "tester", "Tester",
                "originSize", "size",
                "testView", "innerView",
            }
            for _, p in ipairs(props) do
                local ok, val = pcall(function() return tv[p] end)
                if ok and val ~= nil then
                    table.insert(found, { path = "testView." .. p, valtype = type(val), value = tostring(val) })
                    -- 如果是对象，深入一层
                    if type(val) == "userdata" or type(val) == "table" then
                        local subProps = {"displayObject", "x", "y", "width", "height", "name", "scaleX", "scaleY", "numChildren", "parent"}
                        for _, sp in ipairs(subProps) do
                            local ok2, sv = pcall(function() return val[sp] end)
                            if ok2 and sv ~= nil then
                                table.insert(found, { path = "testView." .. p .. "." .. sp, valtype = type(sv), value = tostring(sv) })
                            end
                        end
                    end
                end
            end
        end

    elseif target == "testView" then
        -- 探查 App.testView 相关 API
        local tvProps = {"testView", "TestView", "previewView", "PreviewView"}
        for _, pName in ipairs(tvProps) do
            local ok, tv = pcall(function() return App[pName] end)
            if ok and tv ~= nil then
                table.insert(found, { path = "App." .. pName, valtype = type(tv), value = tostring(tv) })
                -- 探查 testView 的属性和方法
                local methods = {
                    "running", "Running", "visible", "Visible",
                    "Start", "start", "Run", "run", "Show", "show",
                    "Stop", "stop", "Close", "close", "Hide", "hide",
                    "item", "Item", "content", "Content",
                    "component", "Component",
                }
                for _, m in ipairs(methods) do
                    local ok2, val2 = pcall(function() return tv[m] end)
                    if ok2 and val2 ~= nil then
                        table.insert(found, {
                            path = "App." .. pName .. "." .. m,
                            valtype = type(val2),
                            value = tostring(val2)
                        })
                    end
                end
            end
        end

        -- 探查 App 上的测试/预览相关方法
        local appMethods = {
            "StartTest", "startTest", "RunTest", "runTest",
            "TestPreview", "testPreview",
            "ShowTestView", "showTestView",
            "StartPreview", "startPreview",
        }
        for _, m in ipairs(appMethods) do
            local ok, val = pcall(function() return App[m] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. m, valtype = type(val), value = tostring(val) })
            end
        end
    elseif target == "publishSettings" then
        -- 探查发布设置相关 API
        local pubProps = {
            "publishView", "PublishView", "publishSettings", "PublishSettings",
            "showPublishDialog", "ShowPublishDialog", "openPublishDialog", "OpenPublishDialog",
            "publishDialog", "PublishDialog", "publishPanel", "PublishPanel",
        }
        for _, prop in ipairs(pubProps) do
            local ok, val = pcall(function() return App[prop] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. prop, valtype = type(val), value = tostring(val) })
            end
        end
        -- 尝试调用发布设置相关方法
        local pubMethods = {
            "showPublishView", "ShowPublishView", "openPublishSettings", "OpenPublishSettings",
            "showPublishDialog", "ShowPublishDialog", "openPublishPanel", "OpenPublishPanel",
        }
        for _, method in ipairs(pubMethods) do
            local ok, val = pcall(function() return App[method] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. method, valtype = type(val), value = tostring(val) })
            end
        end
        -- 尝试 CS.FairyEditor 中发布相关的类
        local pubTypes = {
            "PublishView", "PublishDialog", "PublishSettings", "PublishDialogBase",
        }
        for _, t in ipairs(pubTypes) do
            local ok, val = pcall(function() return CS.FairyEditor[t] end)
            if ok and val ~= nil then
                table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
            end
        end

    end

    return { found_apis = found, count = #found, target = target }
end

-- 重载所有插件
function CommandHandler.handleReloadAllPlugins(params, bridgePath)
    local results = {}

    -- 探查可用的插件管理 API
    local apiFound = {}
    local mgr = nil

    -- 尝试多种路径获取 pluginManager
    local mgrPaths = {
        "App.pluginManager", "App.PluginManager", "App.pluginMgr",
        "CS.FairyEditor.PluginSystem.inst",
        "CS.FairyEditor.PluginSystem.Instance",
    }
    for _, path in ipairs(mgrPaths) do
        local ok, val = pcall(function()
            local parts = {}
            for p in path:gmatch("[^.]+") do
                table.insert(parts, p)
            end
            local obj = _G
            for _, p in ipairs(parts) do
                if obj == _G and p == "App" then
                    obj = App
                elseif obj == _G and p == "CS" then
                    obj = CS
                elseif obj == CS and p == "FairyEditor" then
                    obj = CS.FairyEditor
                else
                    obj = obj[p]
                end
            end
            return obj
        end)
        if ok and val ~= nil then
            mgr = val
            table.insert(apiFound, path)
        end
    end

    -- 获取所有插件信息
    -- 注意：allPlugins 不一定是 List（可能是数组或字典），Count 可能不存在，
    -- 直接做算术会抛 "attempt to perform arithmetic on a nil value"，这里全部做防御。
    local pluginNames = {}
    if mgr then
        local ok, plugins = pcall(function() return mgr.allPlugins end)
        if ok and plugins ~= nil then
            local n = nil
            pcall(function() if type(plugins.Count) == "number" then n = plugins.Count end end)
            if n == nil then
                pcall(function() if type(plugins.Length) == "number" then n = plugins.Length end end)
            end
            if n ~= nil then
                for i = 0, n - 1 do
                    local item = nil
                    pcall(function() item = plugins[i] end)
                    local nm = nil
                    if item ~= nil then
                        pcall(function() nm = item.name end)
                        if nm == nil then pcall(function() nm = item.Value.name end) end
                        if nm == nil then pcall(function() nm = item.Key end) end
                    end
                    if nm ~= nil then table.insert(pluginNames, tostring(nm)) end
                end
            else
                table.insert(results, "allPlugins 无法枚举（没有 Count/Length）")
            end
        end
    end
    table.insert(results, "loaded plugins: " .. table.concat(pluginNames, ", "))
    table.insert(results, "api found: " .. table.concat(apiFound, ", "))

    -- 尝试直接调用 ReloadAll（不延迟），让 pcall 捕获错误
    local methodUsed = "none"
    local reloadOk = false

    -- 方式1: PluginSystem.inst:ReloadAll()
    local ok1, err1 = pcall(function()
        local ps = CS.FairyEditor.PluginSystem
        if ps and ps.inst then
            ps.inst:ReloadAll()
            methodUsed = "PluginSystem.inst:ReloadAll()"
            reloadOk = true
        elseif ps and ps.Instance then
            ps.Instance:ReloadAll()
            methodUsed = "PluginSystem.Instance:ReloadAll()"
            reloadOk = true
        end
    end)
    if ok1 and reloadOk then
        fprint("[MCPBridge] ReloadAll via PluginSystem succeeded")
    elseif not ok1 then
        fprint("[MCPBridge] ReloadAll via PluginSystem failed: " .. tostring(err1))
    end

    -- 方式2: App.pluginManager:ReloadAll()
    if not reloadOk then
        local ok2, _ = pcall(function()
            if mgr then
                mgr:ReloadAll()
                methodUsed = "pluginManager:ReloadAll()"
                reloadOk = true
            end
        end)
        if ok2 and reloadOk then
            fprint("[MCPBridge] ReloadAll via pluginManager succeeded")
        end
    end

    -- 方式3: 遍历所有插件逐个 Reload
    if not reloadOk and mgr then
        local ok3, _ = pcall(function()
            local plugins = mgr.allPlugins
            if plugins then
                for i = 0, plugins.Count - 1 do
                    local p = plugins[i]
                    pcall(function() p:Reload() end)
                end
                methodUsed = "per-plugin Reload()"
                reloadOk = true
            end
        end)
        if ok3 and reloadOk then
            fprint("[MCPBridge] ReloadAll via per-plugin Reload succeeded")
        end
    end

    -- 方式4: 定时器延迟执行（作为兜底）
    if not reloadOk then
        CS.FairyGUI.Timers.inst:Add(0.8, 1, function()
            fprint("[MCPBridge] Fallback: scheduled PluginSystem.ReloadAll in timer...")
            pcall(function()
                local ps = CS.FairyEditor.PluginSystem
                if ps and ps.inst then
                    ps.inst:ReloadAll()
                end
            end)
        end)
        methodUsed = "PluginSystem.ReloadAll (delayed 0.8s fallback)"
    end

    table.insert(results, "method: " .. methodUsed)
    table.insert(results, "immediate_result: " .. tostring(reloadOk))

    return {
        reloaded = reloadOk or methodUsed:find("fallback") ~= nil,
        method = methodUsed,
        details = results,
        warning = reloadOk and "all plugins reloaded, MCPBridge will re-initialize"
                  or "direct reload failed, fallback timer scheduled"
    }
end

-- ========== 发布命令 ==========

-- 内部函数：通过 PublishHandler 单包发布（FairyGUI 编辑器的正确单包发布 API）
-- 关键：xLua 未暴露 PublishHandler.New 静态方法，必须直接构造 CS.FairyEditor.PublishHandler(pkg, branch)
-- branch 取 App.project.activeBranch（无分支时为空字符串）；Run 异步触发，产物秒级写入，
-- isSuccess 字段返回时尚未更新（不可靠），判完成需看 exportPath 下 {pkg}_fui.bytes 的 mtime
local function tryPublishViaHandler(pkgName)
    local pkg = nil
    local getPkgOk = pcall(function() pkg = App.project:GetPackageByName(pkgName) end)
    if not getPkgOk or not pkg then
        return false, "package not found: " .. tostring(pkgName)
    end
    local handler
    local branch = App.project.activeBranch or ""
    local newOk = pcall(function()
        handler = CS.FairyEditor.PublishHandler(pkg, branch)
    end)
    if not newOk or not handler then
        return false, "PublishHandler construct failed"
    end
    local runOk = pcall(function() handler:Run() end)
    if not runOk then
        return false, "PublishHandler.Run failed"
    end
    return true, "PublishHandler", handler.exportPath or ""
end

-- 内部函数：尝试通过工具栏按钮点击发布
local function tryPublishViaToolbar()
    local toolbar = nil
    pcall(function() toolbar = App.mainView.toolbar end)
    if not toolbar then
        return false, "toolbar not found"
    end

    local buttonNames = {
        "tbPublish", "tbPublishDesc", "btnPublish", "btnPublishDesc",
        "tbPublishAll", "btnPublishAll", "tbExport", "btnExport",
    }

    for _, btnName in ipairs(buttonNames) do
        local btn = nil
        local hasBtn, _ = pcall(function() btn = toolbar:GetChild(btnName) end)
        if hasBtn and btn then
            local clickParams = {{true, true}, {false, false}, {true, false}, {false, true}}
            for _, cp in ipairs(clickParams) do
                local clickOk, _ = pcall(function() btn:FireClick(cp[1], cp[2]) end)
                if clickOk then
                    CS.UnityEngine.Application.runInBackground = true
                    return true, "FireClick(" .. tostring(cp[1]) .. "," .. tostring(cp[2]) .. ") on " .. btnName
                end
            end
        end
    end

    return false, "no publish button found in toolbar"
end

-- 打开发布设置对话框
function CommandHandler.handleOpenPublishSettings(params, bridgePath)
    -- 探查 CS.FairyEditor.PublishSettings 的方法
    local found = {}
    local settingsClass = CS.FairyEditor.PublishSettings
    if settingsClass then
        -- 尝试各种打开方法
        local methods = {
            "Show", "show", "Open", "open", "ShowDialog", "showDialog",
            "ShowSettings", "showSettings", "OpenDialog", "openDialog",
            "ShowWindow", "showWindow", "OpenWindow", "openWindow",
            "ShowPanel", "showPanel", "OpenPanel", "openPanel",
            "ShowSettingsWindow", "OpenSettingsWindow",
            "inst", "Instance", "instance",
        }
        for _, m in ipairs(methods) do
            local ok, val = pcall(function() return settingsClass[m] end)
            if ok and val ~= nil then
                table.insert(found, { path = "PublishSettings." .. m, valtype = type(val), value = tostring(val) })
            end
        end
    end

    -- 尝试点击 tbPublishSettings 按钮
    local toolbar = App.mainView.toolbar
    if toolbar then
        local btn = nil
        pcall(function() btn = toolbar:GetChild("tbPublishSettings") end)
        if btn then
            local clickParams = {{true, true}, {false, false}, {true, false}, {false, true}}
            for _, cp in ipairs(clickParams) do
                local clickOk, _ = pcall(function() btn:FireClick(cp[1], cp[2]) end)
                if clickOk then
                    table.insert(found, { method = "FireClick", params = tostring(cp[1])..","..tostring(cp[2]), button = "tbPublishSettings", success = true })
                    break
                end
            end
        else
            table.insert(found, { error = "tbPublishSettings button not found" })
        end
    end

    return { found = found, count = #found }
end

-- 探查发布相关 API
function CommandHandler.handleProbePublish(params, bridgePath)
    local found = {}

    -- App 上的发布相关属性和方法
    local appProps = {
        "publishView", "PublishView", "publishSettings", "PublishSettings",
        "showPublishDialog", "ShowPublishDialog", "showPublishView", "ShowPublishView",
        "openPublishDialog", "OpenPublishDialog", "publishDialog", "PublishDialog",
        "publishPanel", "PublishPanel", "openPublishSettings", "OpenPublishSettings",
    }
    for _, prop in ipairs(appProps) do
        local ok, val = pcall(function() return App[prop] end)
        if ok and val ~= nil then
            table.insert(found, { path = "App." .. prop, valtype = type(val), value = tostring(val) })
        end
    end

    -- CS.FairyEditor 中的发布相关类
    local csTypes = {
        "PublishView", "PublishDialog", "PublishSettings", "PublishDialogBase",
        "Publish", "PublishHandler", "PublishManager",
    }
    for _, t in ipairs(csTypes) do
        local ok, val = pcall(function() return CS.FairyEditor[t] end)
        if ok and val ~= nil then
            table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
        end
    end

    -- 工具栏上所有子元素
    local toolbar = nil
    pcall(function() toolbar = App.mainView.toolbar end)
    if toolbar then
        table.insert(found, { path = "toolbar.childCount", valtype = "number", value = tostring(toolbar.numChildren or 0) })
        if toolbar.numChildren then
            for i = 0, math.min(toolbar.numChildren - 1, 30) do
                local child = toolbar:GetChildAt(i)
                if child then
                    table.insert(found, { path = "toolbar.child[" .. i .. "].name", valtype = "string", value = child.name })
                end
            end
        end
    end

    return { found_apis = found, count = #found }
end

-- 发布指定包
function CommandHandler.handlePublishPackage(params, bridgePath)
    local pkgName = params.package_name
    if not pkgName then error("缺少参数: package_name") end

    -- 优先用 PublishHandler 单包发布（正确 API，只发布目标包）
    local handlerOk, handlerMethod, exportPath = tryPublishViaHandler(pkgName)
    if handlerOk then
        return {
            published = true, package = pkgName, path = exportPath, method = handlerMethod,
            message = string.format("已发布包 '%s'（单包发布，路径: %s）", pkgName, exportPath)
        }
    end

    -- fallback：工具栏按钮（会发布所有包，仅在单包 API 失败时使用）
    local toolbarOk, toolbarMethod = tryPublishViaToolbar()
    if toolbarOk then
        return {
            published = true, package = pkgName, method = toolbarMethod,
            warning = "单包发布 API 失败，回退到工具栏全量发布",
            message = string.format("已触发发布（回退全量，单包失败原因: %s）", handlerMethod)
        }
    end

    return {
        published = false, package = pkgName,
        reason = "no working publish method found",
        handler_tried = handlerMethod, toolbar_tried = toolbarMethod,
        message = "发布失败: 单包 API 与工具栏均失败"
    }
end

-- 发布所有包（工具栏全量发布）
function CommandHandler.handlePublishAll(params, bridgePath)
    local allPackages = App.project.allPackages
    if not allPackages or allPackages.Count == 0 then error("项目中没有包") end

    local totalCount = allPackages.Count
    local packageNames = {}
    for i = 0, allPackages.Count - 1 do
        table.insert(packageNames, allPackages[i].name)
    end

    -- 确保发布后保持后台运行（main.lua poll 每 0.1s 也会持续重置，此处为发布瞬间保障）
    CS.UnityEngine.Application.runInBackground = true

    local toolbarOk, toolbarMethod = tryPublishViaToolbar()
    if toolbarOk then
        return {
            total = totalCount, published = totalCount, failed = 0,
            packages = packageNames, method = toolbarMethod,
            message = string.format("已触发所有 %d 个包的发布", totalCount)
        }
    end

    return {
        total = totalCount, published = 0, failed = totalCount,
        packages = packageNames,
        reason = "no working publish method found",
        toolbar_tried = toolbarMethod,
        message = "发布失败: 工具栏发布按钮不可用"
    }
end

-- ========== 日志管理命令 ==========

-- 获取编辑器日志（从 main.lua 的 fprint 拦截缓冲区读取）
function CommandHandler.handleGetLogs(params, bridgePath)
    local buf = _G._mcpLogBuffer
    if not buf then
        return { total = 0, logs = {}, returned = 0, start_index = 0, note = "日志缓冲区未初始化" }
    end

    local maxCount = params.max_count or 100
    local level = params.level or "all"

    local total = #buf
    local logs = {}
    local count = 0
    local startIdx = math.max(1, total - maxCount + 1)

    for i = startIdx, total do
        if count >= maxCount then break end
        local entry = buf[i]
        if entry and (level == "all" or entry.level == level) then
            table.insert(logs, {
                time = entry.time or "",
                level = entry.level or "info",
                message = entry.message or ""
            })
            count = count + 1
        end
    end

    return {
        total = total,
        logs = logs,
        returned = count,
        start_index = startIdx
    }
end

-- 清空编辑器日志（清空 fprint 拦截缓冲区）
function CommandHandler.handleClearLogs(params, bridgePath)
    local buf = _G._mcpLogBuffer
    if not buf then
        return { cleared = false, note = "日志缓冲区未初始化" }
    end

    local oldCount = #buf
    for i = #buf, 1, -1 do
        table.remove(buf, i)
    end

    return {
        cleared = true,
        method = "buffer:clear()",
        cleared_count = oldCount
    }
end

-- 深度探查日志存储位置
function CommandHandler.handleProbeLogs(params, bridgePath)
    local result = {}
    local target = params.target or "consoleview"

    if target == "consoleview" then
        local cv = App.consoleView
        if not cv then
            return { error = "App.consoleView is nil" }
        end
        local props = {
            "items","Items","logs","Logs","messages","Messages","list","List",
            "content","Content","text","Text","data","Data",
            "GetLogs","getLogs","GetItems","getItems","GetMessages",
            "Clear","clear","ClearAll","clearAll","ClearLogs",
            "count","Count","length","Length",
            "view","View","logList","LogList",
        }
        for _, name in ipairs(props) do
            local ok, v = pcall(function() return cv[name] end)
            if ok and v ~= nil then
                local vstr = tostring(v)
                local vtype = type(v)
                if vtype == "table" or vtype == "userdata" then
                    local ok2, c = pcall(function() return v.Count end)
                    if ok2 and c ~= nil then vstr = vstr .. " [Count=" .. tostring(c) .. "]" end
                end
                table.insert(result, { name = "consoleView."..name, valtype = vtype, value = vstr })
            end
        end

    elseif target == "fprint_source" then
        local found = {}

        local ok, fp = pcall(function() return fprint end)
        if ok and fp then
            table.insert(found, { name = "fprint", valtype = type(fp), value = tostring(fp) })
        end

        local appMethods = {"Log","log","Print","print","AddLog","addLog","Write","write","Trace","trace"}
        for _, m in ipairs(appMethods) do
            local ok2, v = pcall(function() return App[m] end)
            if ok2 and v ~= nil then
                table.insert(found, { name = "App."..m, valtype = type(v), value = tostring(v) })
            end
        end

        for _, cls in ipairs({"LogManager","OutputManager","TraceManager"}) do
            local ok2, inst = pcall(function()
                local c = CS.FairyEditor[cls]
                return c and c.inst
            end)
            if ok2 and inst ~= nil then
                for _, col in ipairs({"items","Items","logs","Logs","list","List","messages","Messages"}) do
                    local ok3, v = pcall(function() return inst[col] end)
                    if ok3 and v ~= nil then
                        local cnt = 0
                        pcall(function()
                            local c = v.Count
                            if type(c) == "number" then cnt = c
                            elseif c ~= nil then cnt = tonumber(tostring(c)) or 0 end
                        end)
                        table.insert(found, {
                            name = cls..".inst."..col,
                            valtype = type(v),
                            value = tostring(v),
                            count = cnt
                        })
                    end
                end
            end
        end

        return { found = found }
    end

    return { probes = result }
end

-- 开发诊断命令（临时用途：检查 PluginPath 可见性、尝试重载插件本体）
function CommandHandler.handleDevHotfix(params, bridgePath)
    local res = { bridgePath = bridgePath }
    local okP, pluginPath = pcall(function() return PluginPath end)
    res.pluginPathVisible = okP
    res.pluginPathValue = okP and tostring(pluginPath) or nil
    res.globalMcpPluginPath = _G._mcpPluginPath
    res.extHandlers = 0
    if CommandHandler._extHandlers then
        local n = 0
        for _ in pairs(CommandHandler._extHandlers) do n = n + 1 end
        res.extHandlers = n
    end

    if params.do_reload_plugins then
        local attempts = {}
        pcall(function()
            local mgr = App.pluginManager
            local names = { "ReloadAll", "Reload", "ReloadPlugins", "ReloadAllPlugins",
                            "LoadAll", "RestartAll", "StopAll", "Dispose" }
            for _, n in ipairs(names) do
                local okc, err = pcall(function() mgr[n](mgr) end)
                attempts[#attempts + 1] = { method = n, ok = okc, err = tostring(err), exists = (mgr[n] ~= nil) }
            end
        end)
        res.reloadAttempts = attempts
    end
    return res
end

-- ========== 加载扩展命令模块（src/ext） ==========
-- 注意：本文件执行时 initBridge() 尚未调用（8668: initBridge 由 main.lua 在 dofile 之后调用），
-- 因此不能在此处立即加载 ext，改为定义成函数，由 poll() 首次轮询时调用——那时 bridgePath 已知。
-- 触发热重载信号后 ext 模块会被重新 dofile，因此扩展命令同样支持热重载，无需重启编辑器。
local _extLoaded = false

function CommandHandler.loadExt(bridgePath)
    if _extLoaded then return end
    _extLoaded = true

    local function log(msg)
        pcall(function() fprint("[MCPBridge:ext] " .. msg) end)
        pcall(function()
            local candidates = {}
            if bridgePath and bridgePath ~= "" then
                candidates[#candidates + 1] = (bridgePath:gsub("/", "\\")) .. "\\ext.log"
            end
            local tmp = os.getenv("TEMP")
            if tmp then candidates[#candidates + 1] = tmp .. "\\mcpbridge_ext.log" end
            for _, p in ipairs(candidates) do
                local f = io.open(p, "a")
                if f then
                    f:write(os.date("%H:%M:%S ") .. msg .. "\n")
                    f:close()
                    break
                end
            end
        end)
    end

    -- 插件路径解析（优先级：main.lua 写入的全局 -> 由 bridgePath 反推 -> PluginPath 全局）
    -- FairyEditor 的 PluginPath 只在 main.lua 环境可见，子模块取不到，
    -- 所以用 xxx/plugins/MCPBridge/bridge 反推插件根目录 xxx/plugins/MCPBridge
    local base = _G._mcpPluginPath
    if (not base or base == "") and bridgePath and bridgePath ~= "" then
        base = (bridgePath:gsub("\\", "/")):gsub("/bridge/?$", "")
    end
    if (not base or base == "") then
        local okPluginPath, pluginPathGlobal = pcall(function() return PluginPath end)
        if okPluginPath and pluginPathGlobal then base = pluginPathGlobal end
    end
    log("loadExt base=" .. tostring(base))
    if not base or base == "" then
        log("无法确定插件路径，跳过 ext 扩展模块加载")
        return
    end
    -- 存入全局，供 ext 子模块定位自身（FairyEditor 的 PluginPath 在子模块中不可见）
    _G._mcpPluginPath = base

    local path = base .. "/src/ext/init.lua"
    local ok, ext = pcall(function() return dofile(path) end)
    if not ok or type(ext) ~= "table" or not ext.register then
        log("加载 ext/init.lua 失败: " .. tostring(ext) .. " (path=" .. path .. ")")
        return
    end

    CommandHandler._extHandlers = {}
    local rok, res = pcall(function() return ext.register(CommandHandler, CommandHandler._extHandlers, base) end)
    if rok then
        local n = 0
        for _ in pairs(CommandHandler._extHandlers) do n = n + 1 end
        log("已加载，可用命令数: " .. tostring(n))
    else
        log("ext 扩展注册失败: " .. tostring(res))
    end
end

return CommandHandler
