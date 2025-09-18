-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 功能 A：候选文本中的转义序列格式化（始终开启）
--         \n \t \r \\ \s(空格) \d(-)
-- 功能 B：英文自动大写（始终开启）
--         - 首字母大写：输入首字母大写 → 候选首字母大写（Hello）
--         - 全部大写：输入前 2+ 个大写 → 候选全大写（HEllo → HELLO）
--         - 仅对 ASCII 单词生效；若候选单词含空格、-、连字符等几个符号也认为是英文
-- 功能 C：候选重排（仅编码长度 2..6 时）
--         - 第一候选永远不动
--         - 其余按组输出：①不含字母 → ②其他
--         - 仅 table 系列参与分组（table/user_table），非 table 归入"其他"
-- 新增规则：
--         - 若"第二候选"为 user_table或者table，则不执行任何排序；按原顺序直接输出并返回
-- 性能优化：
--         - 单次遍历；中文/emoji 等（首字节>0x7F）且不含 '\' 的候选极早退
--         - 正则改字节级判断；仅必要时 new Candidate
--         - 支持排序窗口（env.settings.sort_window，默认 30；<=0 表示无限制）
-- 功能 D ：对第一候选进行成对符号包裹，例如：《三毛流浪记》
local M = {}

local byte, find, gsub, upper = string.byte, string.find, string.gsub, string.upper

local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

-- 统一函数：检查是否为 table 或 user_table 类型
local function is_table_type(c)
    local t = fast_type(c)
    return t == "table" or t == "user_table"
end

local function has_ascii_alpha_fast(s)
    for i = 1, #s do
        local b = byte(s, i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return true end
        -- 以下字节符号被视作“ASCII痕迹”半角空格(32)、#(35)、·(183)、-(45)、@(64)
        if b == 32 or b == 35 or b == 183 or b == 45 or b == 64 then return true end
    end
    return false
end

local function is_ascii_word_fast(s)
    if s == "" then return false end
    for i = 1, #s do
        local b = byte(s, i)
        if not ((b >= 65 and b <= 90) or (b >= 97 and b <= 122)) then return false end
    end
    return true
end

local function ascii_equal_ignore_case(a, b)
    local la = #a
    if la ~= #b then return false end
    for i = 1, la do
        local ba, bb = byte(a, i), byte(b, i)
        if ba >= 65 and ba <= 90 then ba = ba + 32 end
        if bb >= 65 and bb <= 90 then bb = bb + 32 end
        if ba ~= bb then return false end
    end
    return true
end

local escape_map = {
    ["\\n"] = "\n",
    ["\\t"] = "\t",
    ["\\r"] = "\r",
    ["\\\\"] = "\\",
    ["\\s"] = " ",
    ["\\d"] = "-",
}
local esc_pattern = "\\[ntrsd\\\\]"

local function apply_escape_fast(text)
    if not text or find(text, "\\", 1, true) == nil then return text, false end
    local new_text = gsub(text, esc_pattern, function(esc) return escape_map[esc] or esc end)
    return new_text, new_text ~= text
end

local function format_and_autocap(cand, code_ctx)
    local text = cand.text
    if not text or text == "" then return cand end

    local b1 = byte(text, 1)
    local has_backslash = (find(text, "\\", 1, true) ~= nil)
    if (not has_backslash) and b1 and b1 > 127 then
        return cand
    end

    local changed = false
    if has_backslash then
        local t2, ch = apply_escape_fast(text)
        if ch then text, changed = t2, true end
    end

    if code_ctx.enable_cap then
        if b1 and b1 <= 127 and find(text, " ", 1, true) == nil and is_ascii_word_fast(text) then
            if cand.type == "completion" or ascii_equal_ignore_case(text, code_ctx.pure_code) then
                local new_text
                if code_ctx.all_upper then
                    new_text = upper(text)
                else
                    new_text = text:gsub("^%a", string.upper)
                end
                if new_text and new_text ~= text then
                    text, changed = new_text, true
                end
            end
        end
    end

    if not changed then return cand end
    local nc = Candidate(cand.type, cand.start, cand._end, text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

local function belong_group1_no_alpha(cand)
    return is_table_type(cand) and (not has_ascii_alpha_fast(cand.text))
end

-- 默认包装映射表（26字母专用）
local default_wrap_map = {
    a = "()",    -- 圆括号
    b = "[]",    -- 方括号
    c = "{}",    -- 花括号
    d = "<>",    -- 尖括号
    e = "\"\"",  -- 英文双引号
    f = "''",    -- 英文单引号
    g = "``",    -- 反引号
    h = "「」",  -- 直角引号
    i = "『』",  -- 双直角引号
    j = "“”",    -- 中文弯双引号
    k = "‘’",    -- 中文弯单引号
    l = "《》",  -- 书名号（双）
    m = "〈〉",  -- 书名号（单）
    n = "（）",  -- 全角圆括号
    o = "【】",  -- 黑方头括号
    p = "〔〕",  -- 方头括号
    q = "｛｝",  -- 全角花括号
    r = "［］",  -- 全角方括号
    s = "〈〉",   -- 数学尖括号
    t = "⟨⟩",   -- 数学角括号
    u = "⦅⦆",   -- 白圆括号
    v = "⦇⦈",   -- 白方括号
    w = "❰❱",   -- 装饰角括号
    x = "⟪⟫",   -- 双角括号
    y = "«»",    -- 法文双书名号
    z = "‹›",    -- 法文单书名号

    -- 双字母：其余成对括号族
    aa = "〖〗",
    bb = "〘〙",
    cc = "〚〛",
    dd = "❨❩",
    ee = "❪❫",
    ff = "❬❭",
    gg = "⦉⦊",
    hh = "⦋⦌",
    ii = "⦍⦎",
    jj = "⦏⦐",
    kk = "⦑⦒",
    ll = "❮❯",
    mm = "⌈⌉",
    nn = "⌊⌋",
    oo = "⟦⟧",
    pp = "⟮⟯",
    qq = "⟬⟭",
    rr = "❲❳",
    ss = "⌜⌝",
    tt = "⌞⌟",
    uu = "⸢⸣",
    vv = "⸤⸥",
    ww = "﹁﹂",
    xx = "﹃﹄",
    yy = "⌠⌡",
    zz = "⟅⟆",
    -- 双字母：重复/运算/标记类
    md = "**",       -- Markdown 粗体
    it = "__",       -- Markdown 斜体（下划线风格）
    st = "~~",       -- 删除线
    eq = "==",
    pl = "++",
    mi = "--",
    sl = "//",
    bs = "\\\\",     -- 反斜杠对（Lua 里需写成 "\\\\")
    at = "@@",
    dl = "$$",
    pc = "%%",
    an = "&&",
    ["or"] = "||",
    cr = "^^",
    cl = "::",
    sc = ";;",
    ex = "!!",
    qu = "??",
}

-- 从配置加载 wrap 映射
local function load_mapping_from_config(config)
    local symbol_map = {}
    for k, v in pairs(default_wrap_map) do
        symbol_map[k] = v
    end
    local ok_map, map = pcall(function() return config:get_map("paired_symbols/symkey") end)
    if ok_map and map then
        local ok_keys, keys = pcall(function() return map:keys() end)
        if ok_keys and keys then
            for _, key in ipairs(keys) do
                local ok_val, v = pcall(function() return config:get_string("paired_symbols/symkey/" .. key) end)
                if ok_val and v and #v > 0 then
                    symbol_map[string.lower(key)] = v
                end
            end
        end
    end
    return symbol_map
end

-- 加在匹配规则
local function load_wrap_pattern_from_config(config)
    local default_pat = "[a-z]\\([a-z]+)$"
    if not config then return default_pat end
    local ok, s = pcall(function() return config:get_string("paired_symbols/trigger") end)
    if ok and s and #s > 0 then
        return s
    end
    return default_pat
end

-- 安全提取包装符号的左右部分（通用版）
local function get_wrap_parts(wrap_str)
    if not wrap_str or wrap_str == "" then
        return "", ""
    end
    local chars = {}
    for char in wrap_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(chars, char)
    end
    if #chars == 0 then
        return "", ""
    elseif #chars == 1 then
        return chars[1], ""
    elseif #chars == 2 then
        return chars[1], chars[2]
    else
        return chars[1], chars[#chars]
    end
end

-- 安全注册 select_notifier
function M.init(env)
    env.wrap_map = {}
    -- 加载映射
    if env.engine and env.engine.schema and env.engine.schema.config then
        local cfg = env.engine.schema.config
        env.wrap_map = load_mapping_from_config(cfg)
        -- ★ 加载触发模式串
        env.wrap_trigger_pattern = load_wrap_pattern_from_config(cfg)
    else
        env.wrap_map = default_wrap_map
        env.wrap_trigger_pattern = "[a-z]\\([a-z]+)$"
    end

    if not env or not env.engine or not env.engine.context then
        return
    end

    local ctx_obj = env.engine.context
    if not ctx_obj.select_notifier or type(ctx_obj.select_notifier.connect) ~= "function" then
        return
    end

    env.__wanxiang_select_notifier = ctx_obj.select_notifier:connect(function(ctx)
        if not ctx then return end
        local input = ctx.input
        if not input or #input == 0 then return end

        local wrapped = _G.__wanxiang_wrap
        if not wrapped or wrapped == "" then return end

        if env and env.engine and type(env.engine.commit_text) == "function" then
            env.engine:commit_text(wrapped)
        end

        if ctx.clear then ctx:clear() end
        if env.engine.context.clear then env.engine.context:clear() end
        if env.engine.context.reset then env.engine.context:reset() end

        _G.__wanxiang_wrap = nil
        env.have_select_commit = false
        env.commit_code = nil
    end)
end

function M.fini(env)
    if env and env.__wanxiang_select_notifier and env.__wanxiang_select_notifier.disconnect then
        env.__wanxiang_select_notifier:disconnect()
        env.__wanxiang_select_notifier = nil
    end
    _G.__wanxiang_wrap = nil
end

function M.func(input, env)
    -- 清理残留包装
    _G.__wanxiang_wrap = nil

    local raw_code = ""
    if env and env.engine and env.engine.context then
        raw_code = env.engine.context.input or ""
    end

    local wrap_letter = nil
    local code = raw_code

    if raw_code and #raw_code > 0 then
        local pat = (env and env.wrap_trigger_pattern) or "[a-z]\\([a-z]+)$"
        -- ★ 用配置化的 Lua 模式串提取分组
        wrap_letter = raw_code:match(pat)
    end

    local code_len = #code
    local do_group = (code_len >= 2 and code_len <= 6)

    local sort_window = 50
    if env and env.settings and tonumber(env.settings.sort_window) then
        sort_window = tonumber(env.settings.sort_window)
    end

    local pure_code = code:gsub("[%s%p]", "")
    local all_upper = code:find("^%u%u") ~= nil
    local first_upper = (not all_upper) and (code:find("^%u") ~= nil)
    local enable_cap = (code_len > 1 and not code:find("^[%l%p]"))

    local code_ctx = {
        pure_code = pure_code,
        all_upper = all_upper,
        first_upper = first_upper,
        enable_cap = enable_cap,
    }

    if not do_group then
        local idx = 0
        for cand in input:iter() do
            idx = idx + 1
            cand = format_and_autocap(cand, code_ctx)

            if idx == 1 and wrap_letter then
                local wrap = env.wrap_map[wrap_letter:lower()]
                if wrap and cand and cand.text and cand.text ~= "" then
                    local left, right = get_wrap_parts(wrap)
                    local wrapped = left .. cand.text .. right

                    _G.__wanxiang_wrap = wrapped
                    local start_pos = cand.start
                    local end_pos = start_pos + #raw_code

                    local nc = Candidate(cand.type, start_pos, end_pos, wrapped, cand.comment)
                    nc.preedit = cand.preedit
                    yield(nc)
                    goto continue_non_group
                end
            end
            yield(cand)
            ::continue_non_group::
        end
        return
    end

    local idx = 0
    local mode = "unknown"
    local grouped_cnt = 0
    local window_closed = false
    local group2_others = {}

    local function flush_groups()
        for _, c in ipairs(group2_others) do yield(c) end
        group2_others = {}
    end

    for cand in input:iter() do
        idx = idx + 1
        cand = format_and_autocap(cand, code_ctx)

        if idx == 1 then
            if wrap_letter then
                local wrap = env.wrap_map[wrap_letter:lower()]
                if wrap and cand and cand.text and cand.text ~= "" then
                    local left, right = get_wrap_parts(wrap)
                    local wrapped = left .. cand.text .. right

                    local start_pos = cand.start
                    local end_pos = start_pos + #raw_code

                    _G.__wanxiang_wrap = wrapped

                    local nc = Candidate(cand.type, start_pos, end_pos, wrapped, cand.comment)
                    nc.preedit = cand.preedit
                    yield(nc)
                else
                    yield(cand)
                end
            else
                yield(cand)
            end

        elseif idx == 2 and mode == "unknown" then
            if is_table_type(cand) then
                mode = "passthrough"
                yield(cand)
            else
                mode = "grouping"
                grouped_cnt = 1
                if belong_group1_no_alpha(cand) then
                    yield(cand)
                else
                    group2_others[#group2_others + 1] = cand
                end
                if sort_window > 0 and grouped_cnt >= sort_window then
                    flush_groups()
                    window_closed = true
                end
            end

        else
            if mode == "passthrough" then
                yield(cand)
            else
                if (not window_closed) and ((sort_window <= 0) or (grouped_cnt < sort_window)) then
                    grouped_cnt = grouped_cnt + 1
                    if belong_group1_no_alpha(cand) then
                        yield(cand)
                    else
                        group2_others[#group2_others + 1] = cand
                    end
                    if sort_window > 0 and grouped_cnt >= sort_window then
                        flush_groups()
                        window_closed = true
                    end
                else
                    yield(cand)
                end
            end
        end
    end

    if mode == "grouping" and not window_closed then
        flush_groups()
    end
end
return M