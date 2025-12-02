-- Unicode
-- 示例：输入 U62fc 得到「拼」
-- 触发前缀默认为 recognizer/patterns/unicode 的第 2 个字符，即 U
local function unicode(input, seg, env)
    -- 获取 recognizer/patterns/unicode 的第 2 个字符作为触发前缀
    env.unicode_keyword = env.unicode_keyword or
        env.engine.schema.config:get_string('recognizer/patterns/unicode'):sub(2, 2)

    local keyword = env.unicode_keyword or ""
    if keyword == "" then
        return
    end

    -- 只要当前段以 unicode 前缀开头，就立刻进入 unicode 状态
    if input:sub(1, 1) == keyword then
        -- 用当前 composition 的最后一个 segment，如果拿不到就退回 seg
        local segment = env.engine.context
            and env.engine.context.composition
            and env.engine.context.composition:back()
            or seg

        if segment and segment.tags then
            segment.tags = segment.tags + Set({ "unicode" })
        end
    else
        -- 不以 unicode 前缀开头，直接返回
        return
    end

    -- 从这里开始才处理真正的 Uxxxx → 字符 转换
    local ucodestr = input:match(keyword .. "(%x+)")
    -- 少于 2 位十六进制的情况：只保持模式，不出候选
    if not ucodestr or #ucodestr <= 1 then
        return
    end

    local code = tonumber(ucodestr, 16)
    if code > 0x10FFFF then
        yield(Candidate("unicode", seg.start, seg._end, "数值超限！", ""))
        return
    end

    local text = utf8.char(code)
    yield(Candidate("unicode", seg.start, seg._end, text, string.format("U%x", code)))

    if code < 0x10000 then
        for i = 0, 15 do
            local text2 = utf8.char(code * 16 + i)
            yield(Candidate("unicode", seg.start, seg._end, text2, string.format("U%x~%x", code, i)))
        end
    end
end

return unicode
