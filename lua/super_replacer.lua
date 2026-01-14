--[[
super_replacer.lua 一个rime OpenCC替代品，更灵活地配置能力
https://github.com/amzxyz/rime_wanxiang
by amzxyz
路径检测：UserDir > SharedDir
支持 option: true (常驻启用)
super_replacer:
    db_name: lua/replacer
    delimiter: "|"
    comment_format: "〔%s〕"
    chain: true   #true表示流水线作业，上一个option产出交给下一个处理，典型的s2t>t2hk=s2hk，false就是并行，直接用text转换
    types:
      # 场景1：输入 '哈哈' -> 变成 '1.哈哈 2.😄'
      - option: emoji           # 开关名称与上面开关名称保持一致
        mode: append            # 新增候选append 替换原候选replace 替换注释comment
        comment_mode: none      # 注释模式: "append"(默认), "text"(原文), "none"(无)
        tags: [abc]             # 生效的tag
        prefix: "_em_"          # 前缀用于区分同一个数据库的不同用途数据
        files:
          - lua/data/emoji.txt
      # 场景2：输入 'hello' -> 显示 'hello 〔你好 | 哈喽〕'
      - option: chinese_english
        mode: append        # <--- 添加注释模式
        comment_mode: none
        tags: [abc]
        prefix: "_en_"
        files:
          - lua/data/english_chinese.txt
          - lua/data/chinese_english.txt
      # 场景3：用于常驻的直接替换 option: true
      - option: true
        mode: append         # <--- 新增候选模式
        comment_mode: none
        tags: [abc]
        prefix: "_ot_"
        files:
          - lua/data/others.txt
      # 场景4：用于简繁转换的直接替换
      - option: [ s2t, s2hk, s2tw ]   #后面依赖这条流水线有一个开关为true这条流水线就能工作
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        tags: [abc]
        prefix: "_s2t_"
        files:
          - lua/data/STCharacters.txt
          - lua/data/STPhrases.txt
      - option: s2hk
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        tags: [abc]
        prefix: "_s2hk_"
        files:
          - lua/data/HKVariants.txt
          - lua/data/HKVariantsRevPhrases.txt
      - option: s2tw
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        tags: [abc]
        prefix: "_s2tw_"
        files:
          - lua/data/TWVariants.txt
          - lua/data/TWVariantsRevPhrases.txt
]]

local M = {}

-- 性能优化：本地化常用库函数
local insert = table.insert
local concat = table.concat
local s_match = string.match
local s_gmatch = string.gmatch
local s_format = string.format
local s_byte = string.byte
local s_gsub = string.gsub
local open = io.open
local type = type

-- 基础依赖
local function safe_require(name)
    local status, lib = pcall(require, name)
    if status then return lib end
    return nil
end

local userdb = safe_require("lib/userdb") or safe_require("userdb")
local bit = safe_require("lib/bit") or safe_require("bit")

-- 核心工具函数

local function get_file_hash(path)
    local f = open(path, "rb")
    if not f then return "NIL" end 
    if not bit then local s=f:seek("end"); f:close(); return tostring(s) end
    local h = 0x811C9DC5
    while true do
        local chunk = f:read(4096)
        if not chunk then break end
        for i = 1, #chunk do h=bit.bxor(h,s_byte(chunk,i)); h=(h*0x01000193)%0x100000000; h=bit.band(h,0xFFFFFFFF) end
    end
    f:close()
    return s_format("%08x", h)
end

local function calculate_tasks_signature(tasks)
    local sig_parts = {}
    for _, task in ipairs(tasks) do
        local file_hash = get_file_hash(task.path)
        insert(sig_parts, task.prefix .. "@" .. file_hash)
    end
    return concat(sig_parts, "|")
end

local function rebuild(tasks, db)
    if db.empty then db:empty() end
    for _, task in ipairs(tasks) do
        local txt_path = task.path
        local prefix = task.prefix
        local f = open(txt_path, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and not s_match(line, "^%s*#") then
                    local k, v = s_match(line, "^(%S+)%s+(.+)")
                    if k and v then
                        v = s_match(v, "^%s*(.-)%s*$")
                        db:update(prefix .. k, v)
                    end
                end
            end
            f:close()
        else
            if log and log.info then log.info("super_replacer: 无法读取文件: " .. txt_path) end
        end
    end
    return true
end

-- 模块接口

function M.init(env)
    local ns = env.name_space
    ns = s_gsub(ns, "^%*", "")
    local config = env.engine.schema.config
    
    local user_dir = rime_api:get_user_data_dir()
    local shared_dir = rime_api:get_shared_data_dir()

    -- 1. 基础配置
    local db_name = config:get_string(ns .. "/db_name") or "lua/replacer"
    local delim = config:get_string(ns .. "/delimiter") or "|"
    env.delimiter = delim
    env.comment_format = config:get_string(ns .. "/comment_format") or "〔%s〕"
    
    env.chain = config:get_bool(ns .. "/chain")
    if env.chain == nil then env.chain = false end

    if delim == " " then env.split_pattern = "%S+"
    else local esc = s_gsub(delim, "[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1"); env.split_pattern = "([^" .. esc .. "]+)" end

    -- 2. 解析 Types
    env.types = {}
    local tasks = {}

    local function resolve_path(relative)
        if not relative then return nil end
        local user_path = user_dir .. "/" .. relative
        local f = open(user_path, "r")
        if f then f:close(); return user_path end
        local shared_path = shared_dir .. "/" .. relative
        f = open(shared_path, "r")
        if f then f:close(); return shared_path end
        return user_path
    end

    local types_path = ns .. "/types"
    local type_list = config:get_list(types_path)
    
    if type_list then
        for i = 0, type_list.size - 1 do
            local entry_path = types_path .. "/@" .. i
            
            -- 解析 triggers
            local triggers = {}
            local opts_keys = {"option", "options"}
            for _, key in ipairs(opts_keys) do
                local key_path = entry_path .. "/" .. key
                local list = config:get_list(key_path)
                if list then
                    for k = 0, list.size - 1 do
                        local val = config:get_string(key_path .. "/@" .. k)
                        if val then insert(triggers, val) end
                    end
                else
                    local val = config:get_string(key_path)
                    if val then insert(triggers, val) else
                        if config:get_bool(key_path) == true then insert(triggers, true) end
                    end
                end
            end

            -- 解析 Tags
            local target_tags = nil
            local tag_keys = {"tag", "tags"}
            for _, key in ipairs(tag_keys) do
                local key_path = entry_path .. "/" .. key
                local list = config:get_list(key_path)
                if list then
                    if not target_tags then target_tags = {} end
                    for k = 0, list.size - 1 do
                        local val = config:get_string(key_path .. "/@" .. k)
                        if val then target_tags[val] = true end
                    end
                else
                    local val = config:get_string(key_path)
                    if val then 
                        if not target_tags then target_tags = {} end
                        target_tags[val] = true 
                    end
                end
            end

            if #triggers > 0 then
                local prefix = config:get_string(entry_path .. "/prefix") or ""
                local mode = config:get_string(entry_path .. "/mode") or "append"

                -- 模式: "append"(默认), "text"(原文), "none"(无)
                local comment_mode = config:get_string(entry_path .. "/comment_mode")
                if not comment_mode then comment_mode = "none" end

                insert(env.types, {
                    triggers = triggers,
                    tags = target_tags,
                    prefix = prefix,
                    mode   = mode,
                    comment_mode = comment_mode
                })

                -- 解析文件
                local keys_to_check = {"files", "file"}
                for _, key in ipairs(keys_to_check) do
                    local d_path = entry_path .. "/" .. key
                    local list = config:get_list(d_path)
                    if list then
                        for j = 0, list.size - 1 do
                            local p = resolve_path(config:get_string(d_path .. "/@" .. j))
                            if p then insert(tasks, { path = p, prefix = prefix }) end
                        end
                    else
                        local p = resolve_path(config:get_string(d_path))
                        if p then insert(tasks, { path = p, prefix = prefix }) end
                    end
                end
            end
        end
    end

    -- 3. DB 初始化
    if not userdb then return end
    local ok, db = pcall(function() local d = userdb.LevelDb(db_name); d:open(); return d end)

    if ok and db then
        env.db = db
        local cur_sig = calculate_tasks_signature(tasks)
        local old_sig = db:meta_fetch("_sig")
        local old_delim = db:meta_fetch("_delim")
        if cur_sig ~= old_sig or env.delimiter ~= old_delim then
            if rebuild(tasks, db) then
                db:meta_update("_sig", cur_sig)
                db:meta_update("_delim", env.delimiter)
            end
        end
    else
        env.db = nil
    end
end

function M.fini(env)
    if env.db then env.db:close(); env.db = nil end
end

function M.func(input, env)
    if not env.types or #env.types == 0 or not env.db then
        for cand in input:iter() do yield(cand) end
        return
    end

    local ctx = env.engine.context
    local db = env.db
    local types = env.types
    local split_pat = env.split_pattern
    local comment_fmt = env.comment_format
    local is_chain = env.chain

    local seg = ctx.composition:back()
    local current_seg_tags = seg and seg.tags or {}

    for cand in input:iter() do
        local current_text = cand.text
        local show_main = true 
        local current_main_comment = cand.comment 
        
        local pending_candidates = {} 
        local comments = {}
        
        for _, t in ipairs(types) do
            local is_active = false
            for _, trigger in ipairs(t.triggers) do
                if trigger == true then is_active = true; break
                elseif type(trigger) == "string" and ctx:get_option(trigger) then is_active = true; break end
            end
            
            local is_tag_match = true
            if t.tags then
                is_tag_match = false
                for req_tag, _ in pairs(t.tags) do
                    if current_seg_tags[req_tag] then is_tag_match = true; break end
                end
            end
            
            if is_active and is_tag_match then
                local query_text = is_chain and current_text or cand.text
                local key = t.prefix .. query_text
                local val = db:fetch(key)
                
                if val then
                    local mode = t.mode
                    
                    -- 计算注释内容
                    local rule_comment = ""
                    if t.comment_mode == "text" then
                        rule_comment = cand.text
                    elseif t.comment_mode == "append" then
                        rule_comment = cand.comment
                    else
                        rule_comment = ""
                    end

                    if mode == "comment" then
                        local parts = {}
                        for p in s_gmatch(val, split_pat) do insert(parts, p) end
                        insert(comments, concat(parts, " "))
                        
                    elseif mode == "replace" then
                        if is_chain then
                            local first = true
                            for p in s_gmatch(val, split_pat) do
                                if first then 
                                    current_text = p
                                    -- 链式替换时更新主候选注释
                                    if t.comment_mode == "none" then 
                                        current_main_comment = ""
                                    elseif t.comment_mode == "text" then
                                        current_main_comment = cand.text
                                    end
                                    first = false
                                else
                                    insert(pending_candidates, { text=p, comment=rule_comment })
                                end
                            end
                        else
                            show_main = false
                            for p in s_gmatch(val, split_pat) do 
                                insert(pending_candidates, { text=p, comment=rule_comment }) 
                            end
                        end
                    elseif mode == "append" then
                        for p in s_gmatch(val, split_pat) do 
                            insert(pending_candidates, { text=p, comment=rule_comment }) 
                        end
                    end
                end
            end
        end

        if #comments > 0 then
            local comment_str = concat(comments, " ")
            local fmt = s_format(comment_fmt, comment_str)
            if cand.comment and cand.comment ~= "" then
                cand.comment = cand.comment .. fmt
            else
                cand.comment = fmt
            end
        end

        if show_main then
            if is_chain and current_text ~= cand.text then
                local nc = Candidate("kv", cand.start, cand._end, current_text, current_main_comment)
                nc.quality = cand.quality
                yield(nc)
            else
                yield(cand)
            end
        end

        for _, item in ipairs(pending_candidates) do
            if not (show_main and item.text == current_text) then
                local nc = Candidate("kv", cand.start, cand._end, item.text, item.comment)
                nc.quality = cand.quality
                yield(nc)
            end
        end
    end
end
return M