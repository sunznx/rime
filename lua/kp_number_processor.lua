-- https://github.com/amzxyz/rime_wanxiang
-- 万象家族 lua，小键盘行为控制：
--   - 小键盘数字：根据 kp_number_mode 决定 “参与编码 / 直接上屏”
--   - 主键盘数字：在有候选菜单时，用于选第 n 个候选
--
-- 用法示例（schema.yaml）：
--   engine:
--     processors:
--       - lua_processor@*kp_number_processor
--   # 小键盘模式（可省略，默认 auto）
--   # auto    : 空闲时直接上屏，输入中参与编码
--   # compose : 无论是否在输入中，小键盘都参与编码（不直接上屏）
--   kp_number_mode: auto

local wanxiang = require("wanxiang")

-- 小键盘键码映射
local KP = {
    [0xFFB1] = 1, [0xFFB2] = 2, [0xFFB3] = 3,
    [0xFFB4] = 4, [0xFFB5] = 5, [0xFFB6] = 6,
    [0xFFB7] = 7, [0xFFB8] = 8, [0xFFB9] = 9,
    [0xFFB0] = 0,
}

local P = {}

-- 加载配置中的正则模式
local function load_function_patterns(config)
    local patterns = {}
    local ok_list, list = pcall(function() return config:get_list("kp_number/patterns") end)
    
    if ok_list and list and list.size and list.size > 0 then
        for i = 0, list.size - 1 do
            local item = list:get_value_at(i)
            if item then table.insert(patterns, item:get_string()) end
        end
    end

    -- 默认保底配置
    if #patterns == 0 then
        patterns = {
            "^/[0-9]$", "^/10$", "^/[A-Za-z]+$", "^`[A-Za-z]*$", "^``[A-Za-z/`']*$",
            "^U[%da-f]+$", "^R[0-9]+%.?[0-9]*$",
            "^N0[1-9]?0?[1-9]?$", "^N1[02]?0?[1-9]?$", "^N0[1-9]?[1-2]?[1-9]?$",
            "^N1[02]?[1-2]?[1-9]?$", "^N0[1-9]?3?[01]?$", "^N1[02]?3?[01]?$",
            "^N19?[0-9]?[0-9]?[01]?[0-2]?[0-3]?[0-9]?$", 
            "^N20?[0-9]?[0-9]?[01]?[0-2]?[0-3]?[0-9]?$",
            "^V.*$",
        }
    end
    return patterns
end

-- 判断是否为命令模式
local function is_function_code_after_digit(env, context, digit_char)
    if not context or not digit_char or digit_char == "" then return false end
    local code = context.input or ""
    local s = code .. digit_char
    local pats = env.function_patterns
    if not pats then return false end
    
    for _, pat in ipairs(pats) do
        if s:match(pat) then return true end
    end
    return false
end

function P.init(env)
    local engine = env.engine
    local config = engine.schema.config
    local context = engine.context

    -- 核心：判断并缓存设备类型
    env.is_mobile = wanxiang.is_mobile_device()

    env.page_size = config:get_int("menu/page_size") or 6
    
    local m = config:get_string("kp_number/kp_number_mode") or "auto"
    env.kp_mode = (m == "compose") and "compose" or "auto"

    env.context = context
    env.is_composing = context:is_composing()
    env.has_menu = context:has_menu()
    env.function_patterns = load_function_patterns(config)

    env.kp_update_connection = context.update_notifier:connect(function(ctx)
        env.context = ctx
        env.is_composing = ctx:is_composing()
        env.has_menu = ctx:has_menu()
    end)
end

function P.fini(env)
    if env.kp_update_connection then
        env.kp_update_connection:disconnect()
        env.kp_update_connection = nil
    end
    env.context = nil
    env.function_patterns = nil
end

function P.func(key, env)
    if key:release() then 
        return wanxiang.RIME_PROCESS_RESULTS.kNoop 
    end

    local context = env.context
    local kp_num = KP[key.keycode]

    -----------------------------------------------------------
    -- 1. 桌面端小键盘专用逻辑 (非 Mobile 才执行)
    --    Mobile 端直接跳过此段，进入下方通用逻辑
    -----------------------------------------------------------
    if kp_num ~= nil and not env.is_mobile then
        local ch = tostring(kp_num)

        -- 检查命令模式
        if is_function_code_after_digit(env, context, ch) then
            context:push_input(ch)
            return wanxiang.RIME_PROCESS_RESULTS.kAccepted
        end

        -- Auto / Compose 模式处理
        if env.kp_mode == "auto" then
            if env.is_composing then
                context:push_input(ch)
            else
                env.engine:commit_text(ch)
            end
        else
            context:push_input(ch)
        end
        return wanxiang.RIME_PROCESS_RESULTS.kAccepted
    end

    -----------------------------------------------------------
    -- 2. 主键盘数字 / 移动端小键盘逻辑
    -----------------------------------------------------------
    local r = key:repr() or ""

    -- 特殊处理：如果是移动端且按下了小键盘，强制将其视为普通数字
    if kp_num ~= nil and env.is_mobile then
        r = tostring(kp_num)
    end

    -- 仅处理数字键
    if r:match("^[0-9]$") then
        -- 优先检查：是否匹配命令模式（参与编码）
        if is_function_code_after_digit(env, context, r) then
            context:push_input(r)
            return wanxiang.RIME_PROCESS_RESULTS.kAccepted
        end

        -- 其次检查：是否有菜单（用于选词）
        -- 这就是移动端小键盘想要的效果：有菜单时选词
        if env.has_menu then
            local d = tonumber(r)
            local page_sz = env.page_size
            
            if d and d >= 1 and d <= page_sz then
                local composition = context.composition
                if composition and not composition:empty() then
                    local seg = composition:back()
                    local menu = seg.menu
                    
                    if menu and not menu:empty() then
                        local sel_index = seg.selected_index or 0
                        local page_no = math.floor(sel_index / page_sz)
                        local index = (page_no * page_sz) + (d - 1)

                        if index < menu:candidate_count() then
                            if context:select(index) then
                                return wanxiang.RIME_PROCESS_RESULTS.kAccepted
                            end
                        end
                    end
                end
            end
            -- 如果是数字键但没选中（例如超出页码），不做处理，交由系统（通常会上屏数字）
            return wanxiang.RIME_PROCESS_RESULTS.kNoop
        end
    end

    return wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P