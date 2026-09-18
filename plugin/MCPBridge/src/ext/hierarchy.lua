-- MCPBridge 扩展 · 层级/元素读取模块
-- 命令:
--   get_hierarchy       读取当前组件的完整层级树
--   get_element         读取单个元素的基础/扩展属性、齿轮、关联
--   get_element_batch   批量读取多个元素
--   set_selection       设置编辑器选中（支持多选）
--   get_selection_detail 读取当前选中元素的详细属性
--   list_children       列出某个容器元素的直接子级

local App = App
local U = dofile(_G._mcpUtilPath)

local H = {}

-- 当前组件的自我描述
local function componentSummary(content, doc)
    local pi = U.get(doc, "packageItem")
    local pkgName = nil
    local itemName = nil
    if pi then
        local owner = U.get(pi, "owner")
        if owner then pkgName = U.getStr(owner, "name") end
        itemName = U.getStr(pi, "name")
    end
    local info = {
        package = pkgName,
        name = itemName,
        width = U.getNum(content, "width"),
        height = U.getNum(content, "height"),
        overflow = U.getStr(content, "overflow"),
        scroll = U.getStr(content, "scroll"),
        exported = pi and U.getBool(pi, "exported") or nil,
        numChildren = U.getNum(content, "numChildren") or U.count(U.get(content, "children")),
        isModified = U.getBool(doc, "isModified"),
        docURL = U.getStr(doc, "docURL"),
    }
    return info
end

function H.handleGetHierarchy(params, bridgePath)
    local content, doc = U.content()
    local maxDepth = U.int(params.max_depth)
    local includeGroups = U.bool(params.include_groups)
    if includeGroups == nil then includeGroups = true end

    local children = {}
    U.eachChild(content, function(child, i)
        local t = U.objType(child)
        if t == "group" and not includeGroups then return end
        local node = U.buildTree(child, 1, maxDepth)
        node.index = i
        children[#children + 1] = node
    end)

    -- 组信息
    local groups = {}
    U.eachChild(content, function(child)
        if U.objType(child) == "group" then
            groups[#groups + 1] = {
                id = U.getStr(child, "id"),
                name = U.getStr(child, "name"),
                type = U.getStr(child, "type"),
                expertCopy = U.getBool(child, "expertCopy"),
                memberCount = U.count(U.get(child, "members")),
            }
        end
    end)

    local controllers = {}
    U.each(U.get(content, "controllers"), function(c)
        controllers[#controllers + 1] = {
            name = U.getStr(c, "name"),
            selectedIndex = U.getNum(c, "selectedIndex"),
            pageCount = U.getNum(c, "pageCount"),
            exported = U.getBool(c, "exported"),
        }
    end)

    local transitions = {}
    local trans = U.get(content, "transitions")
    if trans then
        U.each(U.get(trans, "items"), function(t)
            transitions[#transitions + 1] = {
                name = U.getStr(t, "name"),
                frameRate = U.getNum(t, "frameRate"),
                itemCount = U.count(U.get(t, "items")),
                autoPlay = U.getBool(t, "autoPlay"),
            }
        end)
    end

    return {
        component = componentSummary(content, doc),
        controllers = controllers,
        transitions = transitions,
        groups = groups,
        children = children,
        childCount = #children,
    }
end

function H.handleGetElement(params, bridgePath)
    local content = U.content()
    local obj, how = U.resolveTarget(params, content)
    local typeFilter = U.getStr(params, "section")  -- base/extras/gears/relations，空表示全部

    local res = { resolved_by = how }
    if typeFilter == "extras" then
        res.extras = U.typeExtras(obj)
    elseif typeFilter == "gears" then
        res.gears = U.gearInfo(obj)
    elseif typeFilter == "relations" then
        res.relations = U.relationInfo(obj)
    else
        res.element = U.objInfo(obj)
        local parent = U.get(obj, "parent")
        res.parent = parent and { id = U.getStr(parent, "id"), name = U.getStr(parent, "name") } or nil
        res.index = U.num(U.get(parent, "children") and 0 or nil)
        pcall(function() res.index = parent:GetChildIndex(obj) end)
    end
    return res
end

function H.handleGetElementBatch(params, bridgePath)
    local content = U.content()
    local targets = params.elements or params.names or {}
    local out = {}
    for _, t in ipairs(targets) do
        local ok, obj = pcall(function() return U.resolveTarget(t, content) end)
        if ok and obj then
            out[#out + 1] = U.objInfo(obj)
        else
            out[#out + 1] = { error = U.str(obj), target = t }
        end
    end
    return { elements = out, count = #out }
end

function H.handleSetSelection(params, bridgePath)
    local content, doc = U.content()
    local objs = U.resolveTargets(params.elements or params.names or params.element_name, content)
    if #objs == 0 then
        pcall(function() doc:UnselectAll() end)
        return { selected = {}, count = 0, cleared = true }
    end

    pcall(function() doc:UnselectAll() end)
    if #objs == 1 then
        local ok, err = pcall(function() doc:SelectObject(objs[1], true, true) end)
        if not ok then error("选中失败: " .. tostring(err)) end
    else
        local arrType = typeof(CS.System.Collections.Generic.List(CS.FairyEditor.FObject))
        for _, o in ipairs(objs) do
            pcall(function() doc:SelectObject(o, false, true) end)
        end
        arrType = nil
    end

    local names = {}
    U.each(doc:GetSelection(), function(o) names[#names + 1] = U.getStr(o, "name") end)
    return { selected = names, count = #names }
end

function H.handleGetSelectionDetail(params, bridgePath)
    local doc = U.requireDoc()
    local out = {}
    U.each(doc:GetSelection(), function(o)
        out[#out + 1] = U.objInfo(o)
    end)
    return { elements = out, count = #out }
end

function H.handleListChildren(params, bridgePath)
    local content, doc = U.content()
    local parent = content
    if params and (params.name or params.id or params.path) then
        parent = U.resolveTarget(params, content)
    end
    local children = {}
    U.eachChild(parent, function(child, i)
        local b = U.objBrief(child)
        b.index = i
        children[#children + 1] = b
    end)
    return {
        parent = { id = U.getStr(parent, "id"), name = U.getStr(parent, "name"), type = U.objType(parent) },
        children = children,
        count = #children
    }
end

function H.register(CH)
    for k, v in pairs(H) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return H
