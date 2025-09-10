-- @amzxyz https://github.com/amzxyz/rime_wanxiang
--[[
  功能 A：候选文本中的转义序列格式化（始终开启）
           \n \t \r \\ \s(空格) \d(-)
  功能 B：英文自动大写（始终开启）
           - 首字母大写：输入首字母大写 → 候选首字母大写（Hello）
           - 全部大写：输入前 2+ 个大写 → 候选全大写（HEllo → HELLO）
           - 若候选含非 ASCII（如汉字）、含空格、或编码与候选不匹配等，则不转换
  功能 C：候选重排（仅编码长度 2..6 时）
           - 第一候选永远不动
           - 其余按组输出：①不含字母 → ②纯字母且与编码完全相同（忽略大小写）→ ③其他
           - 仅对 table 系列候选参与分组重排，非 table 归入“其他”
]]

local M = {}

------------------------------------------------------------
-- 工具函数：UTF-8 字符长度（兜底备用）
------------------------------------------------------------
local function ulen(s)
  if type(s) ~= "string" then return 0 end
  if utf8 and utf8.len then
    local n = utf8.len(s)
    if n then return n end
    local c = 0
    for _ in utf8.codes(s) do c = c + 1 end
    return c
  end
  local c = 0
  for _ in string.gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do c = c + 1 end
  return c
end

------------------------------------------------------------
-- C：仅让 table 系列参与重排
------------------------------------------------------------
local function is_table_phrase(cand)
  local g = cand.get_genuine and cand:get_genuine() or cand
  local t = (g and g.type) or cand.type or ""
  return t == "table" or t == "user_table"
end

------------------------------------------------------------
-- A：文本转义格式化
------------------------------------------------------------
local escape_map = {
  ["\\n"] = "\n",
  ["\\t"] = "\t",
  ["\\r"] = "\r",
  ["\\\\"] = "\\",
  ["\\s"] = " ",
  ["\\d"] = "-",
}
local esc_pattern = "\\[ntrsd\\\\]"

local function format_text(text)
  if type(text) ~= "string" then return text, false end
  if not text:find(esc_pattern) then return text, false end
  local new_text = text:gsub(esc_pattern, function(esc) return escape_map[esc] or esc end)
  return new_text, new_text ~= text
end

local function with_formatted_text(cand)
  local new_text, changed = format_text(cand.text)
  if not changed then return cand end
  local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
  nc.preedit = cand.preedit
  return nc
end

------------------------------------------------------------
-- B：英文自动大写（依据输入码形态）
------------------------------------------------------------
local function autocap_candidate(cand, code)
  local code_len = #code
  -- 码长为 1 或首位为小写/标点：不转换
  if code_len == 1 or code:find("^[%l%p]") then
    return cand
  end
  -- 输入码形态
  local all_upper   = code:find("^%u%u") ~= nil   -- 前 2+ 位大写 → 全大写
  local first_upper = (not all_upper) and (code:find("^%u") ~= nil)
  if not (all_upper or first_upper) then
    return cand
  end
  -- 仅对 ASCII 单词做大写
  local text = cand.text
  if text:find("[^%w%p%s]") or text:find("%s") then
    return cand
  end
  -- 编码/候选一致性（避免误改如 PS→Photoshop）
  local pure_code = code:gsub("[%s%p]", "")
  local pure_text = text:gsub("[%s%p]", "")
  -- 若希望 HDd→HDD，可注释掉下一行
  if pure_text:lower() == pure_code:lower() then
    return cand
  end
  if cand.type ~= "completion" and pure_code:lower() ~= pure_text:lower() then
    return cand
  end
  -- 应用变换
  local new_text
  if all_upper then
    new_text = text:upper()
  else
    new_text = text:gsub("^%a", string.upper)
  end
  if not new_text or new_text == text then
    return cand
  end
  local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
  nc.preedit = cand.preedit
  return nc
end

------------------------------------------------------------
-- C：分组规则所需的小函数
------------------------------------------------------------
local function is_ascii_word(s)
  return type(s) == "string" and s:find("^[A-Za-z]+$") ~= nil
end

local function has_alpha(s)
  return type(s) == "string" and s:find("%a") ~= nil  -- %a = A–Z / a–z
end

-- 纯字母且与输入编码完全相同（忽略大小写）
local function is_equal_alpha(cand_text, code)
  local pure_code = (code or ""):gsub("[%s%p]", "") -- 去空格/标点
  if not is_ascii_word(pure_code) then return false end
  if not is_ascii_word(cand_text) then return false end
  return cand_text:lower() == pure_code:lower()
end

------------------------------------------------------------
-- 主滤镜：A(格式化) → B(自动大写) → C(按需重排)
------------------------------------------------------------
function M.func(input, env)
  local code = env.engine.context.input or ""
  local code_len = #code
  local do_promote = (code_len > 1 and code_len <= 6)

  if not do_promote then
    -- 仅 A + B，不重排
    for cand in input:iter() do
      cand = with_formatted_text(cand)
      cand = autocap_candidate(cand, code)
      yield(cand)
    end
    return
  end

  -- A + B + C：第一候选不动；其余按分组顺序输出
  local first
  local no_alpha, equal_alpha, others = {}, {}, {}
  local i = 0

  for cand in input:iter() do
    cand = with_formatted_text(cand)     -- 功能 A
    cand = autocap_candidate(cand, code) -- 功能 B

    i = i + 1
    if i == 1 then
      first = cand                        -- 第一候选永远不动
    else
      -- 仅 table 系列参与分组；非 table 直接归入“其他”
      if is_table_phrase(cand) then
        local txt = cand.text
        if not has_alpha(txt) then
          no_alpha[#no_alpha + 1] = cand
        elseif is_equal_alpha(txt, code) then
          equal_alpha[#equal_alpha + 1] = cand
        else
          others[#others + 1] = cand
        end
      else
        others[#others + 1] = cand
      end
    end
  end

  if first then yield(first) end
  for _, c in ipairs(no_alpha)    do yield(c) end  -- ① 不含字母
  for _, c in ipairs(equal_alpha) do yield(c) end  -- ② 纯字母且等于编码
  for _, c in ipairs(others)      do yield(c) end  -- ③ 其他
end

return M