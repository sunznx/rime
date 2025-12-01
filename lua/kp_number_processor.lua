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
  [0xFFB1] = 1,  -- KP_1
  [0xFFB2] = 2,
  [0xFFB3] = 3,
  [0xFFB4] = 4,
  [0xFFB5] = 5,
  [0xFFB6] = 6,
  [0xFFB7] = 7,
  [0xFFB8] = 8,
  [0xFFB9] = 9,
  [0xFFB0] = 0,  -- KP_0
}

local P = {}

---@param env Env
function P.init(env)
  -- 移动端：直接禁用本脚本，当它不存在
  if wanxiang.is_mobile_device and wanxiang.is_mobile_device() then
    env.disabled = true
    return
  end

  local engine  = env.engine
  local config  = engine.schema.config
  local context = engine.context

  env.disabled = false

  -- 读数字选词个数
  env.page_size = config:get_int("menu/page_size") or 6

  -- 读小键盘模式：auto / compose，默认 auto
  local m = config:get_string("kp_number_mode") or "auto"
  if m ~= "auto" and m ~= "compose" then
    m = "auto"
  end
  env.kp_mode = m

  -- 初始化状态快照
  env.context      = context
  env.is_composing = context:is_composing()
  env.has_menu     = context:has_menu()

  -- 用 update_notifier 同步 context / is_composing / has_menu
  env.kp_update_connection = context.update_notifier:connect(
    function(ctx)
      env.context      = ctx
      env.is_composing = ctx:is_composing()
      env.has_menu     = ctx:has_menu()
    end
  )
end

---@param env Env
function P.fini(env)
  if env.kp_update_connection then
    env.kp_update_connection:disconnect()
    env.kp_update_connection = nil
  end
  env.context      = nil
  env.is_composing = nil
  env.has_menu     = nil
end

---@param key KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key, env)
  -- 移动端：当脚本不存在，直接 Noop
  if env.disabled then
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
  end

  -- 只处理按下
  if key:release() then
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
  end

  local engine  = env.engine
  local context = env.context or engine.context
  local mode    = env.kp_mode or "auto"
  local page_sz = env.page_size

  local is_composing = env.is_composing
  local has_menu     = env.has_menu

  ----------------------------------------------------------------------
  -- 1) 功能模式：R+数字 / U+... / 计算器 / 时间日期 等
  --    在这些模式下，数字只能作为“输入键”，不能当“上屏键/选词键”
  ----------------------------------------------------------------------
  local in_function_mode = false
  if wanxiang.is_function_mode_active then
    -- 加一层 pcall 防御，避免异常导致崩溃
    local ok, res = pcall(wanxiang.is_function_mode_active, context)
    if ok and res then
      in_function_mode = true
    end
  end

  if in_function_mode then
    -- 不做任何特殊处理，交给后续 processor（如 ascii_composer）按正常输入处理
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
  end

  ----------------------------------------------------------------------
  -- 2) 小键盘数字：auto / compose
  ----------------------------------------------------------------------
  local kp_num = KP[key.keycode]
  if kp_num ~= nil then
    local ch = tostring(kp_num)  -- "0".."9"

    if mode == "auto" then
      -- 输入中：参与编码；空闲：直接上屏
      if is_composing then
        if context.push_input then
          context:push_input(ch)
        else
          context.input = (context.input or "") .. ch
        end
      else
        engine:commit_text(ch)
      end
    else
      -- compose：始终参与编码
      if context.push_input then
        context:push_input(ch)
      else
        context.input = (context.input or "") .. ch
      end
    end

    return wanxiang.RIME_PROCESS_RESULTS.kAccepted
  end

  ----------------------------------------------------------------------
  -- 3) 主键盘数字：非输入状态下，直接上屏数字
  ----------------------------------------------------------------------
  if not is_composing then
    local r = key:repr() or ""
    -- 只处理 0–9 这类数字键
    if r:match("^[0-9]$") then
      engine:commit_text(r)
      return wanxiang.RIME_PROCESS_RESULTS.kAccepted
    end
    -- 非数字键就继续往下走（交给其它 processor）
  end

  ----------------------------------------------------------------------
  -- 4) 主键盘数字：有候选菜单时，用来选第 n 个候选
  ----------------------------------------------------------------------
  if has_menu then
    local r = key:repr()
    local d = tonumber(r)

    if d and d >= 1 and d <= page_sz then
      if context:select(d - 1) then
        context:confirm_current_selection()
        return wanxiang.RIME_PROCESS_RESULTS.kAccepted
      end
    end

    return wanxiang.RIME_PROCESS_RESULTS.kNoop
  end

  return wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P
