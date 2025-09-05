
-- 欢迎使用万象拼音方案
-- @amzxyz
-- https://github.com/amzxyz/rime_wanxiang
-- a/、aa/ 触发预设编码自动上屏快符，支持将值设为"repeat" 以支持对应按键重复上屏功能，custom>schema>lua最终合并键值
-- 由于间接辅助使用的/作为第三字符引导，因此间接辅助模式下只能加载单字母快符表的扩展，其他情况则支持a/、aa/更多扩展

local wanxiang = require("wanxiang")

-- 读取 RIME 配置文件中的符号映射表（值为 "" 表示禁用）
local function load_mapping_from_config(config)
    local symbol_map = {}
    local ok_map, map = pcall(function() return config:get_map("quick_symbol_text") end)
    if ok_map and map then
        local ok_keys, keys = pcall(function() return map:keys() end)
        if ok_keys and keys then
            for _, key in ipairs(keys) do
                local v = config:get_string("quick_symbol_text/" .. key)
                if v ~= nil then
                    symbol_map[string.lower(key)] = v
                end
            end
        end
    end
    return symbol_map
end

-- 默认符号映射表
local default_mapping = {
    q = "“",
    w = "？",
    e = "（",
    r = "）",
    t = "~",
    y = "·",
    u = "『",
    i = "』",
    o = "〖",
    p = "〗",
    a = "！",
    s = "……",
    d = "、",
    f = "“",
    g = "”",
    h = "‘",
    j = "’",
    k = "【",
    l = "】",
    z = "。",
    x = "？",
    c = "！",
    v = "——",
    b = "%",
    n = "《",
    m = "》"
}
-- 初始化符号输入的状态
local function init(env)
    local config = env.engine.schema.config
    -- 由 wanxiang 判断是否处于“间接辅助模式”（md 非 unknown）
    local _, md = wanxiang.get_input_method_type(env, true)
    env.indirect_aux_mode = (md ~= nil and md ~= "unknown")

    -- 正则保持通用：任意字母串 + '/'
    env.single_symbol_pattern = "^(%a+)/$"

    -- 构造生效映射：间接辅助模式下只让单字母键进入表；否则表里有啥就生效啥
    env.mapping = {}

    -- 默认表（都是单字母）直接并入
    for k, v in pairs(default_mapping) do
        env.mapping[k] = v
    end

    -- custom 并入（根据模式过滤）
    local custom_mapping = load_mapping_from_config(config)
    for k, v in pairs(custom_mapping) do
        local key = tostring(k):lower()
        if env.indirect_aux_mode then
            -- 仅保留 a-z 的单字母键
            if #key == 1 and key:match("^[a-z]$") then
                env.mapping[key] = v
            end
        else
            -- 非间接模式：不做长度限制；表里有啥就生效啥
            env.mapping[key] = v
        end
    end

    env.last_commit_text = "欢迎使用万象拼音！"

    -- 提交通知器：更新 last_commit_text
    env.quick_symbol_text_commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
        local commit_text = ctx:get_commit_text()
        if commit_text ~= "" then
            env.last_commit_text = commit_text
        end
    end)

    -- 更新通知器：匹配并上屏（不再做长度判断，只看映射表是否有该键）
    env.quick_symbol_text_update_notifier = env.engine.context.update_notifier:connect(function(context)
        local input = context.input or ""
        local key = string.match(input, env.single_symbol_pattern)
        if not key then return end

        key = string.lower(key)
        local symbol = env.mapping[key]
        if symbol == nil or symbol == "" then
            return  -- 未配置或显式禁用：放行
        elseif symbol == "repeat" then
            if env.last_commit_text ~= "" then
                env.engine:commit_text(env.last_commit_text)
                context:clear()
            end
        else
            env.engine:commit_text(symbol)
            context:clear()
        end
    end)
end

local function fini(env)
    if env.quick_symbol_text_commit_notifier then
        env.quick_symbol_text_commit_notifier:disconnect()
    end
    if env.quick_symbol_text_update_notifier then
        env.quick_symbol_text_update_notifier:disconnect()
    end
end

local function processor(key_event, env)
    local input = env.engine.context.input
    local key = string.match(input, env.single_symbol_pattern)
    if key then
        key = string.lower(key)
        local symbol = env.mapping[key]
        if symbol ~= nil and symbol ~= "" then
            return wanxiang.RIME_PROCESS_RESULTS.kAccepted
        end
    end
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
end
return { init = init, fini = fini, func = processor }