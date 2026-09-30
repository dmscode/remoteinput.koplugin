-- jsonutil 单元测试。纯 Lua 实现，可在任意 Lua 5.1+ / LuaJIT / 5.4 下运行：
--   lua tests/test_jsonutil.lua
-- 所有断言通过时打印 ALL TESTS PASSED，否则以非零码退出。

local jsonutil = require("jsonutil")

local passed, failed = 0, 0

local function check(name, cond)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
  end
end

-- ---------- decode：正确性 ----------

-- 回归用例：含反斜杠的文本（旧实现把 \\n 错误解码成换行）
local obj = jsonutil.decode('{"text":"C:\\\\new folder"}')
check("backslash-n literal survives", obj and obj.text == "C:\\new folder")

-- 各种基本转义
obj = jsonutil.decode('{"a":"line1\\nline2\\ttab\\"q\\" back\\\\slash\\/"}')
check("basic escapes", obj and obj.a == "line1\nline2\ttab\"q\" back\\slash/")

-- \uXXXX（BMP）
obj = jsonutil.decode('{"a":"\\u0041\\u4e2d\\u6587"}')
check("BMP unicode escapes", obj and obj.a == "A中文")

-- \uXXXX（代理对 → 😀 = F0 9F 98 80）
obj = jsonutil.decode('{"a":"\\ud83d\\ude00"}')
check("surrogate pair", obj and obj.a == "\240\159\152\128")

-- 代理对嵌入普通文本中
obj = jsonutil.decode('{"a":"hi \\ud83d\\ude00 bye"}')
check("surrogate pair inline", obj and obj.a == "hi \240\159\152\128 bye")

-- 孤立高代理（宽容处理，不崩溃）
obj = jsonutil.decode('{"a":"\\ud83d"}')
check("lone surrogate tolerated", obj and type(obj.a) == "string")

-- 数字、字面量、嵌套
obj = jsonutil.decode('[1, -2.5, 1e3, true, false, null]')
check("array numbers/literals",
  obj and obj[1] == 1 and obj[2] == -2.5 and obj[3] == 1000
  and obj[4] == true and obj[5] == false and obj[6] == nil)

obj = jsonutil.decode('{"outer": {"inner": [1, 2, {"x":"y"}]}}')
check("nested structure",
  obj and obj.outer.inner[3].x == "y")

-- 空容器与空白
obj = jsonutil.decode('  { "a" : 1 }  ')
check("whitespace tolerance", obj and obj.a == 1)
check("empty object", next(jsonutil.decode('{}')) == nil)
check("empty array", #jsonutil.decode('[]') == 0)

-- 空字符串字段（旧实现拒绝空文本）
obj = jsonutil.decode('{"text":""}')
check("empty string field", obj and obj.text == "")

-- ---------- decode：错误处理（必须返回 nil 而不是抛异常） ----------

check("reject unterminated string", jsonutil.decode('{"a":"abc') == nil)
check("reject trailing garbage", jsonutil.decode('{"a":1} x') == nil)
check("reject truncated object", jsonutil.decode('{"a"') == nil)
check("reject empty input", jsonutil.decode('') == nil)
check("reject bare comma", jsonutil.decode('[,]') == nil)
check("reject missing colon", jsonutil.decode('{"a" 1}') == nil)
check("reject non-string input", jsonutil.decode(42) == nil)
check("reject deep garbage", jsonutil.decode('{\1}') == nil)

-- ---------- encode ----------

check("encode escapes < > &", jsonutil.encode("a<b>c&d") == '"a\\u003cb\\u003ec\\u0026d"')
check("encode escapes quote/backslash", jsonutil.encode('a"b\\c') == '"a\\"b\\\\c"')
check("encode control chars", jsonutil.encode("a\nb\tc") == '"a\\nb\\tc"')
check("encode U+2028", jsonutil.encode("\xE2\x80\xA8") == '"\\u2028"')
check("encode array", jsonutil.encode({1, 2, 3}) == "[1,2,3]")
check("encode object", jsonutil.encode({a = 1}) == '{"a":1}')
check("encode booleans", jsonutil.encode(true) == "true" and jsonutil.encode(false) == "false")
check("encode nil -> null", jsonutil.encode(nil) == "null")
check("encode NaN -> null", jsonutil.encode(0 / 0) == "null")

-- 嵌入 <script> 的安全性：编码结果中不允许出现裸露的 "</script>"
local encoded = jsonutil.encode('</script><img src=x>')
check("no raw </script> in output", not encoded:find("</script>", 1, true))

-- ---------- encode/decode 往返 ----------

local nasty = 'a"b\\c\nd\r\te<f>&g\x01h \xE2\x80\xA8 中文 \240\159\152\128 end'
local round = jsonutil.decode(jsonutil.encode(nasty))
check("round trip nasty string", round == nasty)

local nested = { text = nasty, count = 3, flag = true, list = { "x", "y\nz" } }
local round2 = jsonutil.decode(jsonutil.encode(nested))
check("round trip nested table",
  round2 and round2.text == nasty and round2.count == 3 and round2.flag == true
  and round2.list[1] == "x" and round2.list[2] == "y\nz")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
print("ALL TESTS PASSED")
