-- MCPBridge 扩展 · 编辑操作模块
-- 命令:
--   create_element       创建元素（基础类型或拖入资源/组件实例）
--   delete_element       删除元素
--   rename_element       重命名元素
--   move_element         调整层级（上移/下移/置顶/置底/指定索引/换父级）
--   duplicate_element    复制元素
--   group_ops            组操作（创建/销毁/打开/关闭）
--   align_elements       对齐（左/右/水平居中/上/下/垂直居中）
--   distribute_elements  等间距分布（水平/垂直）
--   history_undo         撤销
--   history_redo         重做
--   save_all_documents   保存所有打开的文档
--   close_all_documents  关闭所有文档

local App = App
local U = dofile(_G._mcpUtilPath)

-- 快照模块（可选依赖，用于破坏性操作前自动留档）
local Snap = nil
pcall(function()
    Snap = dofile(_G._mcpExtRoot .. "snapshot.lua")
end)

local E = {}

-- 破坏性操作前自动快照（可通过 auto_snapshot=false 关闭）
local function autoSnap(doc, bridgePath, note, params)
    if params and U.bool(params.auto_snapshot) == false then return nil end
    if not (Snap and Snap.autoSnapshot) then return nil end
    local ok, target = pcall(function() return Snap.autoSnapshot(doc, bridgePath, note) end)
    if ok then return target end
    return nil
end

-- 允许的创建类型 -> FairyEditor.FObjectType 常量值
local CREATE_TYPES = {
    image = "image", graph = "graph", text = "text", richtext = "richtext",
    inputtext = "inputtext", loader = "loader", loader3d = "loader3D",
    movieclip = "movieclip", component = "component", list = "list", group = "group",
    button = "button", label = "label", combobox = "combobox",
    progressbar = "progressbar", slider = "slider", scrollbar = "scrollbar",
}

local function selectOnly(doc, obj)
    pcall(function() doc:UnselectAll() end)
    pcall(function() doc:SelectObject(obj, false, true) end)
end

local function selectMany(doc, objs)
    pcall(function() doc:UnselectAll() end)
    for _, o in ipairs(objs) do
        pcall(function() doc:SelectObject(o, false, true) end)
    end
end

-- ========== 创建 ==========

function E.handleCreateElement(params, bridgePath)
    local content, doc = U.content()
    local snapPath = autoSnap(doc, bridgePath, "create", params)
    local typeKey = U.str(params.type or params.object_type)
    if not typeKey then error("缺少参数: type") end
    local objType = CREATE_TYPES[string.lower(typeKey)] or string.lower(typeKey)

    -- 父容器（默认是组件根容器）
    local parent = content
    if params.parent then
        parent = U.resolveTarget({ name = params.parent }, content)
        if not parent then error("父容器不存在: " .. U.str(params.parent)) end
    end

    local pkg = U.pkgOfDoc()
    if not pkg then error("无法获取当前文档所属包") end

    local name = params.name or U.str(params.element_name)
    local index = U.int(params.index)
    local obj = nil
    local createMethod = nil
    local childCountBefore = U.count(U.get(parent, "children"))
    local resErr = nil

    -- ===== 途径一：按资源创建（拖入已有图片/组件/动画等） =====
    local resourceName = params.resource_name
    if resourceName then
        local item = U.findItemByName(params.package_name, resourceName)
        if not item then error("资源不存在: " .. resourceName) end
        local url = nil
        pcall(function() url = item:GetURL() end)
        if url == nil or url == "" then
            pcall(function() url = "ui://" .. item.owner.id .. item.id end)
        end
        if url == nil or url == "" then
            resErr = "无法获取资源 URL: " .. resourceName
        else
            local okInsert, inserted = pcall(function()
                local p = (parent ~= content) and parent or nil
                return doc:InsertObject(url, p, index or -1)
            end)
            if okInsert and inserted then
                obj, createMethod = inserted, "doc:InsertObject"
            else
                resErr = "InsertObject 失败: " .. tostring(inserted)
            end
        end
    end

    -- ===== 途径二：基础类型（NewObject + AddChild） =====
    -- 已实测确认：NewObject 不会自动挂载；id 为只读，AddChild 时才由容器分配。
    -- 因此这里必须且只能 AddChild 一次，属性写入放在挂载之后。
    if (not obj) and (not resourceName) then
        local okNew, newObj = pcall(function()
            return CS.FairyEditor.FObjectFactory.NewObject(pkg, objType)
        end)
        if (not okNew or newObj == nil) then
            local ok3, obj3 = pcall(function()
                return CS.FairyEditor.FObjectFactory.CreateObject(pkg, objType)
            end)
            if ok3 and obj3 then newObj, okNew = obj3, true end
        end
        if newObj == nil then
            error("创建元素失败（类型: " .. objType .. "）: " .. tostring(newObj))
        end

        if name then pcall(function() newObj.name = name end) end

        local okAdd, addErr = false, nil
        if index ~= nil then
            okAdd, addErr = pcall(function() parent:AddChildAt(newObj, index) end)
            if not okAdd then okAdd, addErr = pcall(function() parent:AddChild(newObj) end) end
        else
            okAdd, addErr = pcall(function() parent:AddChild(newObj) end)
        end
        if not okAdd then
            error("挂载元素失败: " .. tostring(addErr))
        end
        obj, createMethod = newObj, "NewObject+AddChild"
    end

    if not obj then
        error("创建元素失败: " .. (resErr or ("不支持的类型 " .. objType)))
    end

    local childCountAfter = U.count(U.get(parent, "children"))
    local objId = U.getStr(obj, "id")

    -- 挂载后 id 才有效；部分类型的 name 可能被重置，这里再写一次
    if name then pcall(function() obj.name = name end) end

    local applied, failed = {}, {}
    if U.isTable(params.props) then
        applied, failed = U.applyProps(obj, params.props)
        -- 少数属性（如文本字号）在对象刚挂载时仍可能失败，失败项重试一次
        if #failed > 0 then
            local retry = {}
            for k, v in pairs(params.props) do
                for _, f in ipairs(failed) do if f.key == k then retry[k] = v end end
            end
            local a2, f2 = U.applyProps(obj, retry)
            for _, k in ipairs(a2) do applied[#applied + 1] = k .. "(retry)" end
            failed = f2
        end
    end

    if U.bool(params.select) ~= false then
        selectOnly(doc, obj)
    end

    U.markDirty(doc, content)
    if resErr then failed[#failed + 1] = { key = "resource", error = resErr } end

    -- 重名检测（诊断用，正常情况下不应出现）
    local nameCount = 0
    if name then
        U.eachChild(parent, function(c)
            if U.getStr(c, "name") == name then nameCount = nameCount + 1 end
        end)
    end

    return {
        created = true,
        id = objId,
        name = U.getStr(obj, "name"),
        type = U.objType(obj),
        parent = U.getStr(parent, "name"),
        index = index,
        appliedCount = #applied,
        applied = applied,
        failed = failed,
        diag = {
            method = createMethod,
            child_count_before = childCountBefore,
            child_count_after = childCountAfter,
            added = childCountAfter - childCountBefore,
            same_name_count = nameCount,
            snapshot = snapPath
        }
    }
end

-- ========== 诊断：执行一段 Lua 片段（仅开发调试用） ==========
-- dev_eval {"code":"return tostring(CS.FairyEditor.FTransition)"}

function E.handleDevEval(params, bridgePath)
    local code = params.code
    if not code then error("缺少参数: code") end

    local content, doc = U.content()
    local env = {
        U = U, CS = CS, App = App,
        doc = doc, content = content,
        pkg = U.pkgOfDoc(),
        math = math, string = string, table = table, os = os,
        pairs = pairs, ipairs = ipairs, next = next, type = type,
        tostring = tostring, tonumber = tonumber, pcall = pcall,
        getmetatable = getmetatable, setmetatable = setmetatable,
        rawget = rawget, rawset = rawset, assert = assert,
        string = string, table = table, math = math, os = os,
        _VERSION = _VERSION,
        error = error, select = select, unpack = unpack or table.unpack,
        json = nil,
    }
    env._G = env

    local chunk, lerr = load(code, "mcp_eval", "t", env)
    if not chunk then error("语法错误: " .. tostring(lerr)) end
    local results = { pcall(chunk) }
    local ok = table.remove(results, 1)
    if not ok then error("执行出错: " .. tostring(results[1])) end

    local out = {}
    for i, v in ipairs(results) do
        local tv = type(v)
        if tv == "userdata" then
            out["r" .. i] = U.str(v)
        elseif tv == "table" then
            out["r" .. i] = U.dictToTable(v)
        else
            out["r" .. i] = v
        end
    end
    out.count = #results
    return out
end

-- ========== 诊断：选择 API ==========
-- dev_probe_selection {"elements":["a","b"]}

function E.handleDevProbeSelection(params, bridgePath)
    local content, doc = U.content()
    local objs = {}
    for _, n in ipairs(params.elements or {}) do
        local o = U.resolveTarget({ name = n }, content)
        if o then objs[#objs + 1] = o end
    end
    if #objs == 0 then error("没有解析到元素") end

    local function selCount()
        local ok, v = pcall(function() return doc:GetSelection() end)
        if not ok or v == nil then return -1 end
        return U.count(v)
    end

    local out = {}
    pcall(function() doc:UnselectAll() end)
    out[#out + 1] = { step = "UnselectAll", count = selCount() }

    local ok1, e1 = pcall(function() doc:SelectObject(objs[1], false, true) end)
    out[#out + 1] = { step = "SelectObject(o,false,true)", ok = ok1,
                      err = (not ok1) and tostring(e1) or nil, count = selCount() }

    pcall(function() doc:UnselectAll() end)
    local ok2, e2 = pcall(function() doc:SelectObject(objs[1], true) end)
    out[#out + 1] = { step = "SelectObject(o,true)", ok = ok2,
                      err = (not ok2) and tostring(e2) or nil, count = selCount() }

    pcall(function() doc:UnselectAll() end)
    local ok3, e3 = pcall(function() doc:SelectObject(objs[1]) end)
    out[#out + 1] = { step = "SelectObject(o)", ok = ok3,
                      err = (not ok3) and tostring(e3) or nil, count = selCount() }

    pcall(function() doc:UnselectAll() end)
    local okL, list = pcall(function()
        local L = CS.System.Collections.Generic.List(CS.FairyEditor.FObject)
        local l = L()
        for _, o in ipairs(objs) do l:Add(o) end
        return l
    end)
    if okL and list ~= nil then
        local ok4, e4 = pcall(function() doc:SetSelection(list) end)
        out[#out + 1] = { step = "SetSelection(List)", ok = ok4,
                          err = (not ok4) and tostring(e4) or nil, count = selCount() }
    else
        out[#out + 1] = { step = "build List", err = tostring(list) }
    end

    -- 功能验证：选中后执行 DeleteSelection，若元素真的被删掉说明选择生效
    if U.bool(params.test_delete) then
        local victim = objs[#objs]
        local nBefore = U.count(U.get(content, "children"))
        pcall(function() doc:UnselectAll() end)
        pcall(function() doc:SelectObject(victim, false, true) end)
        local okDel, errDel = pcall(function() doc:DeleteSelection() end)
        local nAfter = U.count(U.get(content, "children"))
        out[#out + 1] = { step = "SelectObject+DeleteSelection", ok = okDel,
                          err = (not okDel) and tostring(errDel) or nil,
                          n_before = nBefore, n_after = nAfter,
                          deleted = (nAfter < nBefore) }
        U.markDirty(doc, content)
    end

    return { probe = out, elementCount = #objs }
end

-- ========== 诊断：测量 NewObject / AddChild 的挂载行为 ==========
-- dev_create_probe {"type":"graph"}         只 NewObject，不 AddChild
-- dev_create_probe {"type":"graph","add":true}  NewObject 后 AddChild
-- dev_create_probe {"type":"graph","cleanup":true} 结束后删除本次产生的对象

local function childIds(content)
    local t = {}
    U.eachChild(content, function(c)
        local id = U.getStr(c, "id") or ""
        t[id] = (t[id] or 0) + 1
    end)
    return t
end

local function diffIds(before, after)
    local out = {}
    for id, n in pairs(after) do
        if not before[id] then out[#out + 1] = id end
    end
    return out
end

function E.handleDevCreateProbe(params, bridgePath)
    local content, doc = U.content()
    local pkg = U.pkgOfDoc()
    local t = string.lower(U.str(params.type) or "graph")
    local mode = string.lower(U.str(params.mode) or "newobject")

    local n0 = U.count(U.get(content, "children"))
    local ids0 = childIds(content)

    -- mode=xml：测试 FComponent:CreateChild(XML) 的挂载行为
    if mode == "xml" then
        local newId = nil
        pcall(function() newId = content:GetNextId() end)
        if not newId or newId == "" then newId = "probe" .. tostring(os.time()) end
        local xmlErr, okXml, xmlObj = nil, false, nil
        okXml, xmlObj = pcall(function()
            return CS.FairyGUI.Utils.XML.Create(
                string.format('<%s id="%s" name="%s" xy="0,0" size="100,100" />', t, newId, newId))
        end)
        local okChild, child = false, nil
        if okXml and xmlObj then
            okChild, child = pcall(function() return content:CreateChild(xmlObj) end)
        else
            xmlErr = tostring(xmlObj)
        end
        local n1 = U.count(U.get(content, "children"))
        local added1 = diffIds(ids0, childIds(content))
        -- 强制刷新后再看一次
        pcall(function() content:UpdateDisplayList(true) end)
        pcall(function() content:EnsureBoundsCorrect() end)
        pcall(function() if doc.UpdateDisplayList then doc:UpdateDisplayList() end end)
        local n2 = U.count(U.get(content, "children"))
        local added2 = diffIds(ids0, childIds(content))

        local removed = {}
        if U.bool(params.cleanup) then
            local all = {}
            for _, id in ipairs(added2) do all[id] = true end
            for id in pairs(all) do
                local o = U.findById(content, id)
                if o then
                    pcall(function() doc:RemoveObject(o) end)
                    removed[#removed + 1] = id
                end
            end
            U.markDirty(doc, content)
        end
        return {
            mode = "xml", type = t, xml_id = newId,
            ok_xml = okXml, xml_err = xmlErr,
            ok_child = okChild, child_returned = (child ~= nil),
            child_id = child and U.getStr(child, "id") or nil,
            n_before = n0, n_after_call = n1, n_after_refresh = n2,
            added_after_call = added1, added_after_refresh = added2,
            removed = removed,
        }
    end

    -- mode=full：NewObject -> 赋值 id/name -> AddChild，验证是否能正确挂载
    if mode == "full" then
        local nm = U.str(params.name) or "probe_full"
        local okNew2, o = pcall(function()
            return CS.FairyEditor.FObjectFactory.NewObject(pkg, t)
        end)
        local steps = {}
        steps[#steps + 1] = { step = "NewObject", ok = okNew2, is_nil = (o == nil) }
        if o == nil then
            return { mode = "full", type = t, err = tostring(o), steps = steps }
        end
        local nextId = nil
        pcall(function() nextId = content:GetNextId() end)
        steps[#steps + 1] = { step = "GetNextId", id = nextId }
        local okId = pcall(function() o.id = nextId end)
        local okName = pcall(function() o.name = nm end)
        steps[#steps + 1] = { step = "set id", ok = okId, id = U.getStr(o, "id") }
        steps[#steps + 1] = { step = "set name", ok = okName, name = U.getStr(o, "name") }
        local inList0 = false
        pcall(function() local i = content:GetChildIndex(o); inList0 = (i ~= nil and i >= 0) end)
        steps[#steps + 1] = { step = "in list before AddChild", val = inList0 }
        local okAdd, addErr = pcall(function() content:AddChild(o) end)
        local n1 = U.count(U.get(content, "children"))
        local added = diffIds(ids0, childIds(content))
        local inList1 = false
        pcall(function() local i = content:GetChildIndex(o); inList1 = (i ~= nil and i >= 0) end)
        steps[#steps + 1] = { step = "AddChild", ok = okAdd, err = (not okAdd) and tostring(addErr) or nil,
                              n = n1, in_list = inList1, added = added }

        local removed = {}
        if U.bool(params.cleanup) then
            for _, id in ipairs(added) do
                local ob = U.findById(content, id)
                if ob then pcall(function() doc:RemoveObject(ob) end); removed[#removed + 1] = id end
            end
            U.markDirty(doc, content)
        end
        return { mode = "full", type = t, n_before = n0, n_after = n1, steps = steps, removed = removed }
    end

    -- mode=variants：逐个尝试 NewObject 的重载，报告返回对象是否可用（不挂载）
    if mode == "variants" then
        local nm = U.str(params.name) or "probe_v"
        local tries = {
            { sig = "NewObject(pkg,type)", fn = function()
                return CS.FairyEditor.FObjectFactory.NewObject(pkg, t) end },
            { sig = "NewObject(pkg,type,name)", fn = function()
                return CS.FairyEditor.FObjectFactory.NewObject(pkg, t, nm) end },
            { sig = "NewObject(pkg,type,name,0)", fn = function()
                return CS.FairyEditor.FObjectFactory.NewObject(pkg, t, nm, 0) end },
            { sig = "NewObject(pkg,item)", fn = function()
                local pi = U.findItemByName(nil, t)
                return CS.FairyEditor.FObjectFactory.NewObject(pkg, pi) end },
        }
        local out = {}
        for _, tr in ipairs(tries) do
            local ok, o = pcall(tr.fn)
            out[#out + 1] = {
                sig = tr.sig, ok = ok, is_nil = (o == nil),
                id = (o ~= nil) and U.getStr(o, "id") or nil,
                name = (o ~= nil) and U.getStr(o, "name") or nil,
                type = (o ~= nil) and U.objType(o) or nil,
                err = (not ok) and tostring(o) or nil,
            }
        end
        return { mode = "variants", type = t, n_children = n0, tries = out }
    end

    local okNew, newObj = pcall(function()
        return CS.FairyEditor.FObjectFactory.NewObject(pkg, t)
    end)
    local fallbackUsed = false
    if (not okNew or newObj == nil) then
        local ok2, o2 = pcall(function()
            return CS.FairyEditor.FObjectFactory.NewObject(pkg, t, nil, 0)
        end)
        if ok2 and o2 ~= nil then newObj, okNew, fallbackUsed = o2, true, true end
    end

    local objId = newObj and U.getStr(newObj, "id") or nil
    local n1 = U.count(U.get(content, "children"))
    local ids1 = childIds(content)
    local addedByNew = diffIds(ids0, ids1)

    local inList, childIdx = false, nil
    pcall(function()
        local i = content:GetChildIndex(newObj)
        childIdx = i
        if i ~= nil and i >= 0 then inList = true end
    end)

    local n2, addedByAdd = nil, {}
    if U.bool(params.add) then
        pcall(function() content:AddChild(newObj) end)
        n2 = U.count(U.get(content, "children"))
        addedByAdd = diffIds(ids1, childIds(content))
    end

    local removed = {}
    if U.bool(params.cleanup) then
        local all = {}
        for _, id in ipairs(addedByNew) do all[id] = true end
        for _, id in ipairs(addedByAdd) do all[id] = true end
        if objId then all[objId] = true end
        for id in pairs(all) do
            local o = U.findById(content, id)
            if o then
                pcall(function() doc:RemoveObject(o) end)
                removed[#removed + 1] = id
            end
        end
        U.markDirty(doc, content)
    end

    return {
        mode = "newobject",
        type = t,
        ok_new = okNew,
        obj_is_nil = (newObj == nil),
        fallback_used = fallbackUsed,
        obj_id = objId,
        in_list_before_add = inList,
        child_index = childIdx,
        n_before = n0,
        n_after_new = n1,
        n_after_add = n2,
        added_by_new = addedByNew,
        added_by_add = addedByAdd,
        removed = removed,
    }
end

-- ========== 删除 ==========

function E.handleDeleteElement(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "delete", params)
    local obj = U.resolveTarget(params, content)
    local name = U.getStr(obj, "name")
    local id = U.getStr(obj, "id")

    local ok, err = pcall(function() doc:RemoveObject(obj) end)
    if not ok then
        local ok2, err2 = pcall(function() content:RemoveChild(obj, true) end)
        if not ok2 then error("删除失败: " .. U.str(err2)) end
    end
    U.markDirty(doc, content)
    return { deleted = true, name = name, id = id }
end

-- ========== 批量创建 / 批量删除 ==========
-- 一次命令做多件事：减少桥接轮询次数，也减少编辑器视图刷新竞态。

-- create_elements {"items":[{"type":"text","name":"t1","props":{...}}, ...],
--                  "parent":"panel","select_last":true}
function E.handleCreateElements(params, bridgePath)
    local items = params.items or params.elements
    if not U.isTable(items) or #items == 0 then error("缺少参数: items（数组）") end
    autoSnap(U.requireDoc(), bridgePath, "create_batch", params)

    local created, failedItems = {}, {}
    for i, spec in ipairs(items) do
        if not U.isTable(spec) then
            failedItems[#failedItems + 1] = { index = i, error = "元素必须是对象" }
        else
            local sub = {}
            for k, v in pairs(spec) do sub[k] = v end
            sub.auto_snapshot = false
            sub.select = false
            if sub.parent == nil then sub.parent = params.parent end
            local ok, res = pcall(function() return E.handleCreateElement(sub, bridgePath) end)
            if ok and res and res.created then
                created[#created + 1] = {
                    index = i, id = res.id, name = res.name, type = res.type,
                    appliedCount = res.appliedCount, failed = res.failed,
                }
            else
                failedItems[#failedItems + 1] = {
                    index = i, name = spec.name, type = spec.type,
                    error = ok and "创建未返回结果" or tostring(res),
                }
            end
        end
    end

    if U.bool(params.select_last) and #created > 0 then
        local last = created[#created]
        local content, doc = U.content()
        local obj = last.id and U.findById(content, last.id)
        if obj then selectOnly(doc, obj) end
    end

    return {
        createdCount = #created,
        failedCount = #failedItems,
        created = created,
        failed = failedItems,
    }
end

-- delete_elements {"elements":["a","b"],"ids":["n1"],"names":["c"]}
function E.handleDeleteElements(params, bridgePath)
    local objs = U.resolveTargets(params.elements or params.names or params.targets, nil)
    for _, id in ipairs(params.ids or {}) do
        local content = U.content()
        local o = U.findById(content, U.str(id))
        if o then objs[#objs + 1] = o end
    end
    if #objs == 0 then error("没有找到要删除的元素") end
    autoSnap(U.requireDoc(), bridgePath, "delete_batch", params)

    local deleted, failed = {}, {}
    for _, o in ipairs(objs) do
        local name = U.getStr(o, "name")
        local id = U.getStr(o, "id")
        local content, doc = U.content()
        local ok, err = pcall(function() doc:RemoveObject(o) end)
        if not ok then
            ok, err = pcall(function() content:RemoveChild(o, true) end)
        end
        U.markDirty(doc, content)
        if ok then
            deleted[#deleted + 1] = { name = name, id = id }
        else
            failed[#failed + 1] = { name = name, id = id, error = U.str(err) }
        end
    end

    return { deletedCount = #deleted, failedCount = #failed, deleted = deleted, failed = failed }
end

-- ========== 重命名 ==========

function E.handleRenameElement(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "rename", params)
    local obj = U.resolveTarget(params, content)
    local newName = params.new_name or params.name
    if not newName then error("缺少参数: new_name") end

    local oldName = U.getStr(obj, "name")
    local ok, err = U.set(obj, "name", newName)
    if not ok then error("重命名失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    return { renamed = true, old_name = oldName, new_name = newName, id = U.getStr(obj, "id") }
end

-- ========== 层级移动 ==========

function E.handleMoveElement(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "move", params)
    local obj = U.resolveTarget(params, content)
    local parent = U.get(obj, "parent") or content
    local result = { name = U.getStr(obj, "name"), id = U.getStr(obj, "id") }

    local newParent = nil
    if params.parent then
        newParent = U.resolveTarget({ name = params.parent }, content)
    end

    local mode = params.direction or params.mode
    local newIndex = U.int(params.index or params.new_index)

    if newParent ~= nil and newParent ~= parent then
        local idx = newIndex
        if idx == nil then idx = U.count(U.get(newParent, "children")) end
        pcall(function() parent:RemoveChild(obj, false) end)
        local okInsert = pcall(function() newParent:AddChildAt(obj, idx) end)
        if not okInsert then pcall(function() newParent:AddChild(obj) end) end
        result.reparented = true
        result.parent = U.getStr(newParent, "name")
        result.index = idx
    else
        local curIndex = nil
        pcall(function() curIndex = parent:GetChildIndex(obj) end)
        local target = curIndex
        local count = U.count(U.get(parent, "children"))

        if newIndex ~= nil then
            target = newIndex
        elseif mode then
            mode = string.lower(U.str(mode) or "")
            if mode == "up" or mode == "raise" then target = (curIndex or 0) + 1
            elseif mode == "down" or mode == "lower" then target = (curIndex or 0) - 1
            elseif mode == "top" or mode == "front" then target = count - 1
            elseif mode == "bottom" or mode == "back" then target = 0
            else error("未知 direction: " .. U.str(mode)) end
        else
            error("需要提供 direction(up/down/top/bottom)、index 或 parent 之一")
        end

        if target < 0 then target = 0 end
        if target > count - 1 then target = count - 1 end

        local okMove, err = pcall(function() parent:SetChildIndex(obj, target) end)
        if not okMove then error("调整层级失败: " .. U.str(err)) end
        result.from_index = curIndex
        result.to_index = target
    end

    U.markDirty(doc, content)
    return result
end

-- ========== 复制 ==========

--- 在 parent 下创建 src 的一个副本（递归复制子元素）
--- 编辑器没有暴露「按 XML 造对象」的接口，这里用 InsertObject（有资源 URL 时）
--- 或 NewObject+AddChild（基础类型）重建，再逐属性复制。
local function cloneElement(content, doc, pkg, src, parent, index, depth)
    depth = depth or 0
    if depth > 8 then error("复制层级过深（>8 层）") end

    local srcType = U.objType(src)
    local url = U.getStr(src, "resourceURL")
    local obj, method = nil, nil

    if url ~= nil and url ~= "" then
        local okIns, ins = pcall(function()
            local p = (parent ~= content) and parent or nil
            return doc:InsertObject(url, p, index or -1)
        end)
        if okIns and ins then obj, method = ins, "InsertObject" end
    end

    if not obj then
        local okNew, newObj = pcall(function()
            return CS.FairyEditor.FObjectFactory.NewObject(pkg, srcType)
        end)
        if okNew and newObj ~= nil then
            local okAdd, errAdd
            if index ~= nil then
                okAdd, errAdd = pcall(function() parent:AddChildAt(newObj, index) end)
                if not okAdd then okAdd, errAdd = pcall(function() parent:AddChild(newObj) end) end
            else
                okAdd, errAdd = pcall(function() parent:AddChild(newObj) end)
            end
            if not okAdd then error("克隆元素挂载失败: " .. U.str(errAdd)) end
            obj, method = newObj, "NewObject+AddChild"
        end
    end
    if not obj then error("克隆元素失败（类型 " .. U.str(srcType) .. "）") end

    local applied, failed = U.copyProps(src, obj)

    -- 用 NewObject 建的容器型元素需要自己递归复制子元素；
    -- InsertObject 出来的组件实例自带内容，不再递归。
    if method == "NewObject+AddChild" and srcType ~= "image" and srcType ~= "text"
        and srcType ~= "richtext" and srcType ~= "graph" and srcType ~= "loader" then
        local kids = {}
        U.eachChild(src, function(c) kids[#kids + 1] = c end)
        for _, c in ipairs(kids) do
            cloneElement(content, doc, pkg, c, obj, nil, depth + 1)
        end
    end

    return obj, method, applied, failed
end

function E.handleDuplicateElement(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "duplicate", params)
    local obj = U.resolveTarget(params, content)
    local parent = U.get(obj, "parent") or content
    local pkg = U.pkgOfDoc()

    -- 副本插到源元素后面
    local idx = nil
    pcall(function()
        local i = parent:GetChildIndex(obj)
        if i ~= nil and i >= 0 then idx = i + 1 end
    end)

    local before = U.count(U.get(parent, "children"))
    local newObj, method, applied, failed = cloneElement(content, doc, pkg, obj, parent, idx, 0)
    local after = U.count(U.get(parent, "children"))

    -- 命名：默认 <原名>_copy，重名时自动加序号
    local baseName = params.new_name or ((U.getStr(obj, "name") or "element") .. "_copy")
    local finalName = baseName
    local guard = 1
    while U.findByName(parent, finalName) do
        guard = guard + 1
        finalName = baseName .. guard
        if guard > 200 then break end
    end
    pcall(function() newObj.name = finalName end)

    U.markDirty(doc, content)
    if U.bool(params.select) ~= false then selectOnly(doc, newObj) end

    return {
        duplicated = true,
        name = U.getStr(newObj, "name"),
        id = U.getStr(newObj, "id"),
        type = U.objType(newObj),
        method = method,
        added = after - before,
        appliedCount = #applied,
        failed = failed,
    }
end

-- ========== 组 ==========

function E.handleGroupOps(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "group", params)
    local op = string.lower(U.str(params.op or params.action) or "")
    if op == "" then error("缺少参数: op（create/destroy/open/close）") end

    if op == "create" then
        local targets = params.elements or params.names
        local objs = nil
        if targets and #targets > 0 then objs = U.resolveTargets(targets, content) end

        local idsBefore = {}
        U.eachChild(content, function(c) idsBefore[U.getStr(c, "id") or ""] = true end)

        -- 途径一：编辑器原生命令（依赖编辑器选择状态，某些宿主环境下不生效）
        local cmdOk = false
        if objs and #objs > 0 then selectMany(doc, objs) end
        pcall(function() doc:CreateGroup() end)
        local grp = nil
        U.eachChild(content, function(c)
            local id = U.getStr(c, "id") or ""
            if not idsBefore[id] and U.objType(c) == "group" then grp = c end
        end)
        local method = nil
        if grp then
            cmdOk = true
            method = "doc:CreateGroup"
        end

        -- 途径二：退化为「按选中元素包围盒建一个组元素」
        -- 编辑器未暴露 FGroup 的成员管理接口，所以成员关系无法由脚本指定，
        -- 这种情况下返回 membersAssigned=false，由上层决定是否接受。
        if not grp and objs and #objs > 0 then
            local pkg = U.pkgOfDoc()
            local okNew, newGrp = pcall(function()
                return CS.FairyEditor.FObjectFactory.NewObject(pkg, "group")
            end)
            if okNew and newGrp ~= nil then
                local okAdd = pcall(function() content:AddChild(newGrp) end)
                if okAdd then
                    local minX, minY, maxX, maxY = nil, nil, nil, nil
                    for _, o in ipairs(objs) do
                        local x, y = U.getNum(o, "x") or 0, U.getNum(o, "y") or 0
                        local w, h = U.getNum(o, "width") or 0, U.getNum(o, "height") or 0
                        minX = (minX == nil) and x or math.min(minX, x)
                        minY = (minY == nil) and y or math.min(minY, y)
                        maxX = (maxX == nil) and (x + w) or math.max(maxX, x + w)
                        maxY = (maxY == nil) and (y + h) or math.max(maxY, y + h)
                    end
                    pcall(function() newGrp:SetXY(minX or 0, minY or 0) end)
                    pcall(function() newGrp:SetSize((maxX or 0) - (minX or 0), (maxY or 0) - (minY or 0)) end)
                    grp = newGrp
                    method = "NewObject+AddChild(bbox)"
                end
            end
        end

        if not grp then error("创建组失败：既未通过编辑器命令建组，也未提供可用的 elements 列表") end

        local nm = params.name
        if (not nm) and (U.getStr(grp, "name") or "") == "" then
            nm = "group_" .. (U.getStr(grp, "id") or "")
        end
        if nm then pcall(function() grp.name = nm end) end

        U.markDirty(doc, content)
        local n = U.count(U.get(content, "children"))
        local res = {
            op = "create", ok = true, method = method,
            group = U.getStr(grp, "name"),
            id = U.getStr(grp, "id"),
            memberCount = objs and #objs or 0,
            membersAssigned = cmdOk,
            childCount = n,
        }
        if not cmdOk then
            res.note = "当前宿主环境下编辑器选择状态不可用：组只按包围盒创建，成员关系需在编辑器中手工设置；"
                .. "且实测该组元素不会被写入组件 XML（保存/重载后会丢失），建议改用组件或图形做容器"
        end
        return res
    elseif op == "destroy" then
        local target = nil
        if params.id then target = { id = params.id }
        elseif params.name or params.group then target = { name = params.name or params.group } end

        local obj = nil
        if target then obj = U.resolveTarget(target, content) end

        -- 优先走编辑器命令（需要选择状态），失败则直接移除组元素
        local usedCmd = false
        if obj then
            local idsBefore = {}
            U.eachChild(content, function(c) idsBefore[U.getStr(c, "id") or ""] = true end)
            selectOnly(doc, obj)
            pcall(function() doc:DestroyGroup() end)
            -- 编辑器命令依赖选择状态，未必真的生效；用元素是否还在来判断
            local stillThere = false
            U.eachChild(content, function(c)
                if U.getStr(c, "id") == U.getStr(obj, "id") then stillThere = true end
            end)
            if not stillThere then usedCmd = true end
        end
        if not usedCmd and obj then
            local ok, err = pcall(function() doc:RemoveObject(obj) end)
            if not ok then error("解散组失败: " .. U.str(err)) end
        end
        U.markDirty(doc, content)
        return {
            op = "destroy", ok = true,
            group = obj and U.getStr(obj, "name") or nil,
            method = usedCmd and "doc:DestroyGroup" or "doc:RemoveObject",
            note = "组内元素不会被删除，只是去掉分组框",
        }
    elseif op == "open" then
        local g = params.name and U.resolveTarget({ name = params.name }, content) or U.get(doc, "openedGroup")
        if not g then error("没有指定组，也没有当前打开的组") end
        local ok, err = pcall(function() doc:OpenGroup(g) end)
        if not ok then error("打开组失败: " .. U.str(err)) end
        return { op = "open", ok = true, group = U.getStr(g, "name") }
    elseif op == "close" then
        local depth = U.int(params.depth) or 0
        local ok, err = pcall(function() doc:CloseGroup(depth) end)
        if not ok then error("关闭组失败: " .. U.str(err)) end
        return { op = "close", ok = true, depth = depth }
    else
        error("未知 op: " .. op)
    end
end

-- ========== 对齐 / 分布 ==========

function E.handleAlignElements(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "align", params)
    local objs = U.resolveTargets(params.elements or params.names, content)
    if #objs == 0 then error("没有找到目标元素") end
    local mode = string.lower(U.str(params.mode or params.align) or "")
    if mode == "" then error("缺少参数: mode（left/center/right/top/middle/bottom/hcenter/vcenter）") end

    local minX, maxX, minY, maxY = nil, nil, nil, nil
    for _, o in ipairs(objs) do
        local x = U.getNum(o, "x") or 0
        local y = U.getNum(o, "y") or 0
        local w = U.getNum(o, "width") or 0
        local h = U.getNum(o, "height") or 0
        minX = (minX == nil) and x or math.min(minX, x)
        maxX = (maxX == nil) and (x + w) or math.max(maxX, x + w)
        minY = (minY == nil) and y or math.min(minY, y)
        maxY = (maxY == nil) and (y + h) or math.max(maxY, y + h)
    end

    local changed = 0
    for _, o in ipairs(objs) do
        local x = U.getNum(o, "x") or 0
        local y = U.getNum(o, "y") or 0
        local w = U.getNum(o, "width") or 0
        local h = U.getNum(o, "height") or 0
        local nx, ny = x, y
        if mode == "left" then nx = minX
        elseif mode == "right" then nx = maxX - w
        elseif mode == "center" or mode == "hcenter" then nx = (minX + maxX) / 2 - w / 2
        elseif mode == "top" then ny = minY
        elseif mode == "bottom" then ny = maxY - h
        elseif mode == "middle" or mode == "vcenter" then ny = (minY + maxY) / 2 - h / 2
        else error("未知 mode: " .. mode) end
        if nx ~= x then U.set(o, "x", nx) end
        if ny ~= y then U.set(o, "y", ny) end
        changed = changed + 1
    end

    U.markDirty(doc, content)
    return { aligned = true, mode = mode, count = changed }
end

function E.handleDistributeElements(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "distribute", params)
    local objs = U.resolveTargets(params.elements or params.names, content)
    if #objs < 2 then error("至少需要 2 个元素") end
    local axis = string.lower(U.str(params.axis) or "horizontal")

    local items = {}
    for _, o in ipairs(objs) do
        items[#items + 1] = { o = o, x = U.getNum(o, "x") or 0, y = U.getNum(o, "y") or 0,
                              w = U.getNum(o, "width") or 0, h = U.getNum(o, "height") or 0 }
    end

    if axis == "horizontal" or axis == "h" then
        table.sort(items, function(a, b) return a.x < b.x end)
        local total = 0
        for _, it in ipairs(items) do total = total + it.w end
        local firstX = items[1].x
        local lastRight = items[#items].x + items[#items].w
        local gap = (lastRight - firstX - total) / (#items - 1)
        local cursor = firstX
        for _, it in ipairs(items) do
            U.set(it.o, "x", cursor)
            cursor = cursor + it.w + gap
        end
    else
        table.sort(items, function(a, b) return a.y < b.y end)
        local total = 0
        for _, it in ipairs(items) do total = total + it.h end
        local firstY = items[1].y
        local lastBottom = items[#items].y + items[#items].h
        local gap = (lastBottom - firstY - total) / (#items - 1)
        local cursor = firstY
        for _, it in ipairs(items) do
            U.set(it.o, "y", cursor)
            cursor = cursor + it.h + gap
        end
    end

    U.markDirty(doc, content)
    return { distributed = true, axis = axis, count = #items }
end

-- ========== 撤销 / 重做 ==========

function E.handleHistoryUndo(params, bridgePath)
    local doc = U.requireDoc()
    local steps = U.int(params.steps) or 1
    local done = 0
    for i = 1, steps do
        local ok, res = pcall(function() return doc.history:Undo() end)
        if not ok or res ~= true then break end
        done = done + 1
    end
    return { undone = done, requested = steps }
end

function E.handleHistoryRedo(params, bridgePath)
    local doc = U.requireDoc()
    local steps = U.int(params.steps) or 1
    local done = 0
    for i = 1, steps do
        local ok, res = pcall(function() return doc.history:Redo() end)
        if not ok or res ~= true then break end
        done = done + 1
    end
    return { redone = done, requested = steps }
end

-- ========== 文档批量操作 ==========

function E.handleSaveAllDocuments(params, bridgePath)
    local ok, err = pcall(function() App.docView:SaveAllDocuments() end)
    if not ok then error("保存失败: " .. U.str(err)) end
    return { saved = true }
end

function E.handleCloseAllDocuments(params, bridgePath)
    local ok, err = pcall(function() App.docView:CloseAllDocuments() end)
    if not ok then error("关闭失败: " .. U.str(err)) end
    return { closed = true }
end

function E.register(CH)
    -- 自动登记本模块所有 handleXxx，避免新增命令时漏登记
    for k, v in pairs(E) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then
            CH[k] = v
        end
    end
end

return E
