-- MCPBridge 扩展 · 元素属性写入模块
-- 命令:
--   set_element_props   单个元素设置属性
--   set_elements_props  批量设置（多个元素共享同一组属性）
--   set_component_props 设置当前组件自身属性（尺寸/背景/滚动容器等）
--
-- 属性路由逻辑集中在 util.applyProps()，创建元素时也复用同一套规则。

local App = App
local U = dofile(_G._mcpUtilPath)

local Snap = nil
pcall(function()
    Snap = dofile(_G._mcpExtRoot .. "snapshot.lua")
end)

local P = {}

-- 写属性前自动快照（可通过 auto_snapshot=false 关闭）
local function autoSnap(doc, bridgePath, note, params)
    if params and U.bool(params.auto_snapshot) == false then return end
    if not (Snap and Snap.autoSnapshot) then return end
    pcall(function() Snap.autoSnapshot(doc, bridgePath, note) end)
end

function P.handleSetElementProps(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "set_props", params)
    local obj, how = U.resolveTarget(params, content)
    local props = params.props or params
    if not U.isTable(props) then error("缺少属性集合 props") end

    local applied, failed = U.applyProps(obj, props)
    U.markDirty(doc, content)

    return {
        resolved_by = how,
        name = U.getStr(obj, "name"),
        id = U.getStr(obj, "id"),
        type = U.objType(obj),
        applied = applied,
        appliedCount = #applied,
        failed = failed,
        failedCount = #failed,
        after = U.objBase(obj)
    }
end

function P.handleSetElementsProps(params, bridgePath)
    local content, doc = U.content()
    local props = params.props or {}
    local targets = params.elements or params.names or {}
    if #targets == 0 then error("缺少 elements 列表") end

    local out = {}
    for _, t in ipairs(targets) do
        local ok, obj = pcall(function() return U.resolveTarget(t, content) end)
        if ok and obj then
            local applied, failed = U.applyProps(obj, props)
            out[#out + 1] = {
                name = U.getStr(obj, "name"),
                id = U.getStr(obj, "id"),
                type = U.objType(obj),
                appliedCount = #applied,
                failedCount = #failed,
                failed = failed
            }
        else
            out[#out + 1] = { target = t, error = U.str(obj) }
        end
    end
    U.markDirty(doc, content)
    return { elements = out, count = #out }
end

function P.handleSetComponentProps(params, bridgePath)
    local content, doc = U.content()
    autoSnap(doc, bridgePath, "set_component_props", params)
    local props = params.props or params
    local applied, failed = U.applyProps(content, props)

    if props.width ~= nil or props.height ~= nil then
        pcall(function() content:HandleSizeChanged() end)
        pcall(function() content:SetBoundsChangedFlag() end)
    end
    pcall(function() content:UpdateOverflow() end)
    U.markDirty(doc, content)

    local pi = U.get(doc, "packageItem")
    return {
        applied = applied,
        failed = failed,
        component = {
            name = pi and U.getStr(pi, "name") or nil,
            width = U.getNum(content, "width"),
            height = U.getNum(content, "height"),
            overflow = U.getStr(content, "overflow"),
            scroll = U.getStr(content, "scroll"),
            scrollBarDisplay = U.getStr(content, "scrollBarDisplay"),
        }
    }
end

function P.register(CH)
    for k, v in pairs(P) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return P
