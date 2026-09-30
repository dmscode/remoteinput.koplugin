-- ==================== JSON 编解码 ====================
-- 自包含的轻量 JSON 实现（纯 Lua 5.1，无外部依赖）。
-- encode 额外转义 < > & 与 U+2028/U+2029，保证结果可安全嵌入
-- HTML <script> 块或作为 API 响应体使用。
-- decode 是完整的递归下降解析器，正确处理 \uXXXX 与代理对。

local jsonutil = {}

-- ---------- 编码 ----------

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function encodeString(s)
  -- 先处理常规字符，再替换 U+2028/U+2029（在 JSON 中合法但会终止 JS 字符串；
  -- 若顺序颠倒，主转义会把替换产生的反斜杠再次转义）
  s = s:gsub('[%c"\\<>&]', function(c)
    local e = ESCAPES[c]
    if e then
      return e
    elseif c == '<' then
      return '\\u003c'
    elseif c == '>' then
      return '\\u003e'
    elseif c == '&' then
      return '\\u0026'
    end
    return string.format('\\u%04x', string.byte(c))
  end)
  s = s:gsub('\xE2\x80\xA8', '\\u2028')
  s = s:gsub('\xE2\x80\xA9', '\\u2029')
  return '"' .. s .. '"'
end

local function encodeValue(val)
  local t = type(val)
  if t == "string" then
    return encodeString(val)
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return "null"
    end
    return tostring(val)
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "table" then
    if #val > 0 then
      local parts = {}
      for i = 1, #val do
        parts[i] = encodeValue(val[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, v in pairs(val) do
        parts[#parts + 1] = encodeString(tostring(k)) .. ':' .. encodeValue(v)
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return "null"
end

function jsonutil.encode(val)
  return encodeValue(val)
end

-- ---------- 解码 ----------

local function skipWS(s, pos)
  while pos <= #s do
    local c = s:byte(pos)
    if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then
      pos = pos + 1
    else
      break
    end
  end
  return pos
end

local function utf8Encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  else
    return string.char(0xF0 + math.floor(cp / 262144),
      0x80 + math.floor(cp / 4096) % 64,
      0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
end

local parseValue

local function parseString(s, pos)
  pos = pos + 1 -- 跳过开头的引号
  local buf = {}
  while true do
    -- 批量追加不含引号和反斜杠的普通字符段
    local plain = s:match('^[^"\\]*', pos)
    if #plain > 0 then
      buf[#buf + 1] = plain
      pos = pos + #plain
    end
    local c = s:byte(pos)
    if not c then
      error("unterminated string")
    elseif c == 0x22 then -- " 字符串结束
      return table.concat(buf), pos + 1
    elseif c == 0x5C then -- \ 转义
      pos = pos + 1
      local e = s:byte(pos)
      if e == 0x75 then -- \uXXXX（pos 由本分支自行推进，不走公共收尾）
        local hex = s:sub(pos + 1, pos + 4)
        if not hex:match('^%x%x%x%x$') then
          error("bad \\u escape")
        end
        local cp = tonumber(hex, 16)
        pos = pos + 5 -- 越过 'u' 与 4 位十六进制
        -- 处理 UTF-16 代理对
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == '\\u' then
          local hex2 = s:sub(pos + 2, pos + 5)
          if hex2:match('^%x%x%x%x$') then
            local low = tonumber(hex2, 16)
            if low >= 0xDC00 and low <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
              pos = pos + 6
            end
          end
        end
        buf[#buf + 1] = utf8Encode(cp)
      elseif e == 0x22 then
        buf[#buf + 1] = '"'
        pos = pos + 1
      elseif e == 0x5C then
        buf[#buf + 1] = '\\'
        pos = pos + 1
      elseif e == 0x2F then
        buf[#buf + 1] = '/'
        pos = pos + 1
      elseif e == 0x62 then
        buf[#buf + 1] = '\b'
        pos = pos + 1
      elseif e == 0x66 then
        buf[#buf + 1] = '\f'
        pos = pos + 1
      elseif e == 0x6E then
        buf[#buf + 1] = '\n'
        pos = pos + 1
      elseif e == 0x72 then
        buf[#buf + 1] = '\r'
        pos = pos + 1
      elseif e == 0x74 then
        buf[#buf + 1] = '\t'
        pos = pos + 1
      else
        error("bad escape character")
      end
    else
      -- 理论上不可达：plain 已吃掉普通字符
      buf[#buf + 1] = string.char(c)
      pos = pos + 1
    end
  end
end

local function parseNumber(s, pos)
  local numStr = s:match('^%-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  local num = tonumber(numStr)
  if not num or numStr == "" or numStr == "-" then
    error("bad number at position " .. pos)
  end
  return num, pos + #numStr
end

local function parseArray(s, pos)
  pos = pos + 1 -- 跳过 [
  local arr = {}
  pos = skipWS(s, pos)
  if s:byte(pos) == 0x5D then -- ]
    return arr, pos + 1
  end
  while true do
    local val
    val, pos = parseValue(s, pos)
    arr[#arr + 1] = val
    pos = skipWS(s, pos)
    local c = s:byte(pos)
    if c == 0x2C then -- ,
      pos = pos + 1
    elseif c == 0x5D then -- ]
      return arr, pos + 1
    else
      error("expected ',' or ']' at position " .. (pos or 0))
    end
  end
end

local function parseObject(s, pos)
  pos = pos + 1 -- 跳过 {
  local obj = {}
  pos = skipWS(s, pos)
  if s:byte(pos) == 0x7D then -- }
    return obj, pos + 1
  end
  while true do
    pos = skipWS(s, pos)
    if s:byte(pos) ~= 0x22 then
      error("expected object key at position " .. (pos or 0))
    end
    local key, val
    key, pos = parseString(s, pos)
    pos = skipWS(s, pos)
    if s:byte(pos) ~= 0x3A then -- :
      error("expected ':' at position " .. (pos or 0))
    end
    pos = pos + 1
    val, pos = parseValue(s, pos)
    obj[key] = val
    pos = skipWS(s, pos)
    local c = s:byte(pos)
    if c == 0x2C then -- ,
      pos = pos + 1
    elseif c == 0x7D then -- }
      return obj, pos + 1
    else
      error("expected ',' or '}' at position " .. (pos or 0))
    end
  end
end

parseValue = function(s, pos)
  pos = skipWS(s, pos)
  if pos > #s then
    error("unexpected end of input")
  end
  local c = s:byte(pos)
  if c == 0x7B then -- {
    return parseObject(s, pos)
  elseif c == 0x5B then -- [
    return parseArray(s, pos)
  elseif c == 0x22 then -- "
    return parseString(s, pos)
  elseif c == 0x74 then -- t
    if s:sub(pos, pos + 3) == 'true' then
      return true, pos + 4
    end
  elseif c == 0x66 then -- f
    if s:sub(pos, pos + 4) == 'false' then
      return false, pos + 5
    end
  elseif c == 0x6E then -- n
    if s:sub(pos, pos + 3) == 'null' then
      return nil, pos + 4
    end
  else
    return parseNumber(s, pos)
  end
  error("bad value at position " .. pos)
end

--- 解析 JSON 文本，成功返回值，失败返回 nil 和错误信息。
function jsonutil.decode(str)
  if type(str) ~= "string" then
    return nil, "input is not a string"
  end
  local ok, value, pos = pcall(parseValue, str, 1)
  if not ok then
    return nil, tostring(value)
  end
  pos = skipWS(str, pos)
  if pos <= #str then
    return nil, "trailing garbage at position " .. pos
  end
  return value
end

return jsonutil
