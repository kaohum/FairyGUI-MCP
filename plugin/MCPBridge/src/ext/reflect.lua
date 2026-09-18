-- MCPBridge 扩展 · 探测模块
-- 用途：在编辑器运行环境中实时查看 API 可用性，便于开发与排错
--
-- 已知限制（xLua 环境实测）：
--   * 不能对 Type 对象调用 GetMembers（报 No such type: Xxx.GetMembers）
--   * 实例的 metatable.__index 是 function，无法枚举成员名
-- 因此可用手段是：
--   1) 静态类对象（CS.FairyEditor.Xxx）是 table，可 pairs 枚举静态成员
--   2) 按候选名逐个 pcall 访问 obj[name]，判断是否存在（probe_api）
--
-- 命令:
--   reflect      枚举静态类成员（type 模式）或已有对象的可见成员
--   probe_api    候选成员名存在性探测（最实用）
--   probe_get    按路径读取对象/属性（如 App.activeDoc.content.children[0].name）
--   probe_call   调用对象的某个方法并返回结果（开发调试用）

local App = App
local U = dofile(_G._mcpUtilPath)

local R = {}

-- ---------- 对象解析 ----------

function R.resolveObj(desc)
    if desc == nil or desc == "app" then return App, "App" end
    if desc == "doc" or desc == "activeDoc" then return U.requireDoc(), "App.activeDoc" end
    if desc == "content" then return U.content(), "doc.content" end
    if desc == "pkg" then return U.pkgOfDoc(), "doc.packageItem.owner" end
    if desc == "project" then return U.get(App, "project"), "App.project" end
    if desc == "docview" then return U.get(App, "docView"), "App.docView" end
    if desc == "libview" then return U.get(App, "libView"), "App.libView" end
    if desc == "testview" then return U.get(App, "testView"), "App.testView" end
    if desc == "timelineview" then return U.get(App, "timelineView"), "App.timelineView" end
    if desc == "item" then
        local pi = U.get(U.requireDoc(), "packageItem")
        return pi, "doc.packageItem"
    end
    if type(desc) == "string" and desc:sub(1, 11) == "controller:" then
        local cname = desc:sub(12)
        local ctrl = nil
        pcall(function()
            local content = U.content()
            -- GetController 依赖内部名称索引，不一定可靠，这里按列表遍历兜底
            U.each(U.get(content, "controllers"), function(c)
                if not ctrl and U.getStr(c, "name") == cname then ctrl = c end
            end)
            if not ctrl then ctrl = content:GetController(cname) end
        end)
        return ctrl, "controller:" .. cname
    end
    if desc == "transitions" then
        return U.get(U.content(), "transitions"), "content.transitions"
    end
    if desc == "controllers" then
        return U.get(U.content(), "controllers"), "content.controllers"
    end
    if type(desc) == "string" and desc:sub(1, 6) == "trans:" then
        local tname = desc:sub(7)
        local trans = nil
        pcall(function()
            U.each(U.get(U.get(U.content(), "transitions"), "items"), function(t)
                if not trans and U.getStr(t, "name") == tname then trans = t end
            end)
        end)
        return trans, "transition:" .. tname
    end
    if type(desc) == "string" and desc:sub(1, 8) == "element:" then
        local c = U.content()
        return U.resolveTarget({ name = desc:sub(9) }, c), desc:sub(9)
    end
    if type(desc) == "string" and desc:sub(1, 6) == "type::" then
        -- type::FairyEditor.FPackage
        local name = desc:sub(7)
        local obj = nil
        pcall(function()
            local cur = CS
            for seg in string.gmatch(name, "[^.]+") do
                if seg ~= "CS" then cur = cur[seg] end
            end
            obj = cur
        end)
        return obj, name
    end
    -- 默认当作元素名
    local c = U.content()
    return U.resolveTarget({ name = desc }, c), desc
end

-- ---------- 成员枚举 ----------

local function membersFromStaticClass(obj, out)
    if type(obj) ~= "table" then return false end
    for k, v in pairs(obj) do
        if type(k) == "string" then
            out[#out + 1] = {
                name = k,
                kind = (type(v) == "function") and "Method" or "Member",
                signature = type(v)
            }
        end
    end
    return true
end

local function membersFromMetatable(obj, out)
    local ok, mt = pcall(function() return getmetatable(obj) end)
    if ok and mt and type(mt) == "table" then
        local idx = rawget(mt, "__index")
        if type(idx) == "table" then
            for k, v in pairs(idx) do
                if type(k) == "string" then
                    out[#out + 1] = { name = k, kind = (type(v) == "function") and "Method" or "Member", signature = type(v) }
                end
            end
            return true, "metatable"
        end
    end
    return false, "metatable __index is not enumerable (xLua)"
end

-- ---------- 命令：reflect ----------

function R.handleReflect(params, bridgePath)
    local mode = params.mode or "type"
    local limit = U.int(params.limit) or 200
    local target = params.target or params.of or params.type_name or params.name

    local obj, label = R.resolveObj(target)

    local out = {}
    local diag = {}
    if mode == "type" then
        local ok = membersFromStaticClass(obj, out)
        diag.source = ok and "staticClassTable" or "unavailable"
        diag.note = ok and nil or "该对象不是静态类 table，无法枚举"
    else
        local ok, why = membersFromMetatable(obj, out)
        if not ok and type(obj) == "table" then
            membersFromStaticClass(obj, out)
            diag.source = "staticClassTable"
        else
            diag.source = why
        end
    end

    local filtered = {}
    local kindFilter = params.kind
    local nameFilter = params.filter
    for _, m in ipairs(out) do
        local okKind = (not kindFilter or kindFilter == "" or m.kind == kindFilter)
        local okName = (not nameFilter or nameFilter == ""
            or string.find(string.lower(m.name), string.lower(nameFilter), 1, true))
        if okKind and okName then filtered[#filtered + 1] = m end
    end

    table.sort(filtered, function(a, b) return (a.name or "") < (b.name or "") end)
    if limit and #filtered > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = filtered[i] end
        filtered = trimmed
    end

    return { target = label, count = #filtered, members = filtered, diag = diag }
end

-- ---------- 命令：probe_api ----------

function R.handleProbeApi(params, bridgePath)
    local obj, label = R.resolveObj(params.target or params.of)
    local names = params.names or params.members or {}
    if #names == 0 then error("缺少候选成员列表 names") end

    local results = {}
    for _, n in ipairs(names) do
        local entry = { name = n }
        local ok, v = pcall(function() return obj[n] end)
        if ok and v ~= nil then
            entry.exists = true
            entry.valueType = type(v)
            entry.value = U.str(v)
            if type(v) == "function" then entry.kind = "Method" end
        elseif ok then
            entry.exists = false
            entry.valueType = "nil"
            local ok2, v2 = pcall(function() return obj[n] end)
            entry.value = U.str(v2)
        else
            entry.exists = false
            entry.error = U.str(v)
        end
        results[#results + 1] = entry
    end

    return { target = label, count = #results, members = results }
end

-- ---------- 命令：probe_call ----------

-- 参数字符串里以 "element:xxx" 开头的会被解析成实际的元素对象，
-- 便于直接探测需要传对象的编辑器 API（如 doc:SetSelection(obj)）。
local function toCsArgs(args)
    local out = {}
    for i, a in ipairs(args) do
        if type(a) == "string" and a:sub(1, 8) == "element:" then
            local target = nil
            pcall(function() target = U.resolveTarget({ name = a:sub(9) }, U.content()) end)
            out[i] = target or a
        else
            out[i] = a
        end
    end
    return out
end

function R.handleProbeCall(params, bridgePath)
    local obj, label = R.resolveObj(params.target or params.of)
    local method = params.method
    if not method then error("缺少参数: method") end
    local args = params.args or {}
    local instanceCall = U.bool(params.instance_call)
    if instanceCall == nil then instanceCall = true end

    local argc = #args
    local ok, res
    if instanceCall then
        ok, res = pcall(function()
            local f = obj[method]
            return f(obj, toCsArgs(args))
        end)
    else
        ok, res = pcall(function()
            local f = obj[method]
            return f(toCsArgs(args))
        end)
    end

    local outType = nil
    local outValue = nil
    if ok then
        if res == nil then
            outType = "nil"
        elseif type(res) == "userdata" then
            outType = "userdata"
            outValue = U.str(res)
        elseif type(res) == "table" then
            outType = "table"
            local items = {}
            local n = U.count(res)
            if n > 0 then
                local max = n < 20 and n or 20
                for i = 0, max - 1 do
                    local itemOk, item = pcall(function() return res[i] end)
                    if itemOk then items[#items + 1] = U.str(item) end
                end
                outValue = items
            else
                local tmp = {}
                local cnt = 0
                for k, v in pairs(res) do
                    cnt = cnt + 1
                    if cnt <= 20 then tmp[U.str(k)] = U.str(v) end
                end
                if cnt > 0 then outValue = tmp end
            end
        else
            outType = type(res)
            outValue = res
        end
    end

    return {
        target = label,
        method = method,
        instance_call = instanceCall,
        ok = ok,
        resultType = outType,
        result = outValue,
        error = ok and nil or U.str(res)
    }
end

-- ---------- 命令：probe_get ----------

function R.handleProbeGet(params, bridgePath)
    local rootName = params.root or "doc"
    local path = params.path
    if not path then error("缺少参数: path") end

    -- path 允许以根别名开头（如 "doc.packageItem.file"），
    -- 这时用它决定根并把这一段消费掉，否则会把 "doc" 当成 doc 的一个成员去取，必然取不到。
    local segs = {}
    for s in string.gmatch(path, "[^.]+") do segs[#segs + 1] = s end
    local aliases = { doc = true, app = true, content = true, pkg = true }
    if #segs > 1 and aliases[segs[1]] then
        rootName = segs[1]
        table.remove(segs, 1)
    end

    local root
    if rootName == "app" then
        root = App
    elseif rootName == "doc" then
        root = U.requireDoc()
    elseif rootName == "content" then
        root = U.content()
    elseif rootName == "pkg" then
        root = U.pkgOfDoc()
    else
        root = U.resolveTarget({ name = rootName }, U.content())
    end

    local cur = root
    local trail = {}
    for _, seg in ipairs(segs) do
        local idx = tonumber(string.match(seg, "%[([%d%.]+)%]"))
        local key = idx and string.gsub(seg, "%[.*%]$", "") or seg
        local ok, v = pcall(function()
            if idx then return cur[key][idx] end
            return cur[key]
        end)
        if not ok then
            return { path = path, reached = trail, error = "读取失败: " .. tostring(v) }
        end
        cur = v
        trail[#trail + 1] = seg
        if cur == nil then
            return { path = path, reached = trail, value_type = "nil", value = nil }
        end
    end

    local vt = type(cur)
    local out = nil
    if vt == "userdata" then
        local ok2, s = pcall(function() return tostring(cur) end)
        out = ok2 and s or "<userdata>"
    else
        out = cur
    end
    return { path = path, value_type = vt, value = out }
end

function R.register(CH)
    for k, v in pairs(R) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return R
