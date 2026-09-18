-- MCPBridge 扩展 · 公共工具模块
-- 提供：安全访问 C# 对象、集合遍历、颜色转换、文档上下文、元素查找、对象信息采集
-- 说明：本模块被 ext 下所有命令模块共用，不依赖 CommandHandler 内部实现细节

local App = App

local U = {}

U.VERSION = "0.1.0"

-- ========== 值转换 ==========

function U.num(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, n = pcall(function() return tonumber(v) end)
    if ok and n then return n end
    return nil
end

function U.str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return tostring(v) end)
    if ok then return s end
    return nil
end

function U.bool(v)
    if v == nil then return nil end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    local s = tostring(v)
    s = string.lower(s)
    if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return nil
end

function U.int(v)
    local n = U.num(v)
    if n == nil then return nil end
    return math.floor(n + 0.5)
end

-- 判断是否为真实 Lua table（排除 userdata）
function U.isTable(v)
    return type(v) == "table"
end

-- ========== 安全访问 C# 对象 ==========

function U.safe(fn, ...)
    return pcall(fn, ...)
end

-- 读取属性，失败返回 nil
function U.get(obj, prop)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if ok then return v end
    return nil
end

function U.set(obj, prop, value)
    if obj == nil then return false, "对象为空" end
    local ok, err = pcall(function() obj[prop] = value end)
    return ok, err
end

function U.getNum(obj, prop)
    return U.num(U.get(obj, prop))
end

function U.getStr(obj, prop)
    local v = U.get(obj, prop)
    if v == nil then return nil end
    return U.str(v)
end

function U.getBool(obj, prop)
    local v = U.get(obj, prop)
    if v == nil then return nil end
    local ok, b = pcall(function() return (v == true) end)
    if ok then return b end
    return U.bool(v)
end

-- 调用实例方法：obj:method(...)
function U.call(obj, method, ...)
    if obj == nil then return false, "对象为空" end
    local args = { ... }
    local argc = select("#", ...)
    local ok, res = pcall(function()
        local f = obj[method]
        return f(obj, unpack(args, 1, argc))
    end)
    if ok then return true, res end
    return false, res
end

-- 调用类型/静态方法：Type.method(...)
function U.scall(typeObj, method, ...)
    if typeObj == nil then return false, "类型为空" end
    local args = { ... }
    local argc = select("#", ...)
    local ok, res = pcall(function()
        local f = typeObj[method]
        return f(unpack(args, 1, argc))
    end)
    if ok then return true, res end
    return false, res
end

-- ========== 集合遍历 ==========

function U.count(list)
    if list == nil then return 0 end
    -- 优先 Count（List/IList），其次 Length（数组，如 MemberInfo[]）
    local ok, n = pcall(function() return list.Count end)
    if ok and type(n) == "number" then return n end
    local ok2, n2 = pcall(function() return list.Length end)
    if ok2 and type(n2) == "number" then return n2 end
    return 0
end

-- 遍历 C# IList/List（索引从 0 开始）
function U.each(list, fn)
    local n = U.count(list)
    for i = 0, n - 1 do
        local ok, item = pcall(function() return list[i] end)
        if ok and item ~= nil then
            fn(item, i)
        end
    end
end

-- 集合 -> Lua 数组
function U.list(list, fn)
    local out = {}
    U.each(list, function(item, i)
        local v = item
        if fn then v = fn(item, i) end
        if v ~= nil then out[#out + 1] = v end
    end)
    return out
end

-- 字典风格：把带 keys 的集合转成 table
function U.dictToTable(d)
    local out = {}
    if d == nil then return out end
    pcall(function()
        local keys = d.Keys
        U.each(keys, function(k)
            local ok, v = pcall(function() return d[k] end)
            if ok then
                out[U.str(k)] = v
            end
        end)
    end)
    return out
end

-- ========== 颜色 ==========

function U.colorToHex(c)
    if c == nil then return nil end
    local ok, res = pcall(function()
        local r = math.floor(c.r * 255 + 0.5)
        local g = math.floor(c.g * 255 + 0.5)
        local b = math.floor(c.b * 255 + 0.5)
        return string.format("#%02X%02X%02X", r, g, b)
    end)
    if ok then return res end
    return nil
end

function U.colorToTable(c)
    if c == nil then return nil end
    local ok, res = pcall(function()
        return {
            r = math.floor(c.r * 255 + 0.5),
            g = math.floor(c.g * 255 + 0.5),
            b = math.floor(c.b * 255 + 0.5),
            a = math.floor(c.a * 100) / 100
        }
    end)
    if ok then return res end
    return nil
end

-- 支持 "#RRGGBB" / "#RRGGBBAA" / "255,0,0" / {r,g,b[,a]}
function U.makeColor(v)
    if v == nil then return nil end

    if type(v) == "table" then
        local r = U.num(v.r) or 0
        local g = U.num(v.g) or 0
        local b = U.num(v.b) or 0
        local a = U.num(v.a)
        if a == nil then a = 1 end
        if r > 1 or g > 1 or b > 1 then
            r, g, b = r / 255, g / 255, b / 255
        end
        local ok, col = pcall(function() return CS.UnityEngine.Color(r, g, b, a) end)
        if ok then return col end
        ok, col = pcall(function() return CS.UnityEngine.Color.__new(r, g, b, a) end)
        if ok then return col end
        return nil
    end

    local s = U.str(v)
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")

    local r, g, b, a = nil, nil, nil, 1

    if s:sub(1, 1) == "#" then
        local hex = s:sub(2)
        if #hex == 6 then
            r = tonumber(hex:sub(1, 2), 16)
            g = tonumber(hex:sub(3, 4), 16)
            b = tonumber(hex:sub(5, 6), 16)
        elseif #hex == 8 then
            r = tonumber(hex:sub(1, 2), 16)
            g = tonumber(hex:sub(3, 4), 16)
            b = tonumber(hex:sub(5, 6), 16)
            a = tonumber(hex:sub(7, 8), 16) / 255
        end
    else
        local parts = {}
        for p in string.gmatch(s, "[^,%s]+") do
            parts[#parts + 1] = tonumber(p)
        end
        if #parts >= 3 then
            r, g, b = parts[1], parts[2], parts[3]
            if #parts >= 4 then a = parts[4] end
        end
    end

    if r == nil or g == nil or b == nil then return nil end

    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end

    local ok, col = pcall(function() return CS.UnityEngine.Color(r, g, b, a) end)
    if ok then return col end
    ok, col = pcall(function() return CS.UnityEngine.Color.__new(r, g, b, a) end)
    if ok then return col end
    return nil
end

-- 应用颜色属性（返回是否成功）
function U.applyColor(obj, prop, value)
    local col = U.makeColor(value)
    if col == nil then return false, "无法解析颜色: " .. U.str(value) end
    local ok, err = U.set(obj, prop, col)
    return ok, err
end

-- ========== 文档与包上下文 ==========

function U.doc()
    return App.activeDoc
end

function U.requireDoc()
    local doc = App.activeDoc
    if not doc then error("没有打开的文档，请先调用 fg_editor_open_component 打开组件") end
    return doc
end

function U.content()
    local doc = U.requireDoc()
    local c = U.get(doc, "content")
    if not c then error("当前文档没有组件内容") end
    return c, doc
end

function U.pkgOfDoc()
    local doc = U.requireDoc()
    local pi = U.get(doc, "packageItem")
    if pi then
        return U.get(pi, "owner")
    end
    return nil
end

function U.pkgByName(name)
    if not name then return nil end
    local pkg = nil
    pcall(function() pkg = App.project:GetPackageByName(name) end)
    if pkg then return pkg end
    pcall(function() pkg = App.project:GetPackageById(name) end)
    return pkg
end

function U.allPackages()
    local out = {}
    pcall(function()
        U.each(App.project.allPackages, function(p)
            out[#out + 1] = { name = U.getStr(p, "name"), id = U.getStr(p, "id"), pkg = p }
        end)
    end)
    return out
end

-- 按 "包名/资源名" 或仅资源名查找包资源 item
--- 资源项的「原始文件名」（带扩展名）
--- 实测 FPackageItem：name 是不带扩展名的显示名，fileName 才带扩展名，
--- 而组件 XML 的 fileName 属性用的是后者。
function U.itemFileName(item)
    if not item then return nil end
    local fn = U.getStr(item, "fileName")
    if fn and fn ~= "" then return fn end
    local f = U.getStr(item, "file")
    if f and f ~= "" then return (f:gsub("\\", "/"):match("([^/]+)$")) or f end
    return U.getStr(item, "name")
end

--- 在指定包（或当前包 → 全项目）里按资源名找 FPackageItem
--- 说明：编辑器没有可靠的按名查找接口（GetItemByName 的签名随版本变化，
--- FindItemByName 在本版本根本不存在），所以一律遍历 pkg.items 兜底，
--- 并且支持传不带扩展名的名字。
function U.findItemByName(pkgName, itemName)
    if not itemName then return nil end
    local want = U.str(itemName)
    if want == "" then return nil end
    local base = want:gsub("%.[%w]+$", "")

    local function scan(pkg)
        if not pkg then return nil end
        local found = nil

        -- 1) 先试官方接口（成功与否都不影响后面的兜底）
        pcall(function() found = pkg:GetItemByName(want) end)
        if not found then pcall(function() found = pkg:GetItemByName(pkg.rootItem, want) end) end
        if found then return found end

        -- 2) 遍历 items（最可靠）：name（无扩展名）与 fileName（带扩展名）都比一次
        U.each(U.get(pkg, "items"), function(it)
            if found then return end
            local n = U.getStr(it, "name")
            local fn = U.getStr(it, "fileName")
            if n == want or fn == want then found = it end
        end)
        if found then return found end

        -- 3) 忽略扩展名再匹配一次
        U.each(U.get(pkg, "items"), function(it)
            if found then return end
            local n = U.getStr(it, "name") or ""
            local fn = U.getStr(it, "fileName") or ""
            if n:gsub("%.[%w]+$", "") == base or fn:gsub("%.[%w]+$", "") == base then found = it end
        end)
        return found
    end

    if pkgName and pkgName ~= "" then
        local pkg = U.pkgByName(pkgName)
        if not pkg then
            -- 包名给了但找不到，退化为按名字在所有包里找
            for _, entry in ipairs(U.allPackages()) do
                local f = scan(entry.pkg)
                if f then return f end
            end
            return nil
        end
        return scan(pkg)
    end

    -- 未指定包：当前文档的包优先，再全项目搜索
    local hit = scan(U.pkgOfDoc())
    if hit then return hit end
    for _, entry in ipairs(U.allPackages()) do
        local f = scan(entry.pkg)
        if f then return f end
    end
    return nil
end

-- ========== 元素查找 ==========

function U.eachChild(content, fn)
    local children = U.get(content, "children")
    U.each(children, fn)
end

function U.findByName(content, name)
    if not name then return nil end
    local obj = nil
    pcall(function() obj = content:GetChild(name) end)
    if obj then return obj end
    U.eachChild(content, function(child)
        if not obj and U.getStr(child, "name") == name then obj = child end
    end)
    return obj
end

function U.findById(content, id)
    if not id then return nil end
    local obj = nil
    pcall(function() obj = content:GetChildById(id) end)
    if obj then return obj end
    U.eachChild(content, function(child)
        if not obj and U.getStr(child, "id") == id then obj = child end
    end)
    return obj
end

-- 支持 {name=} / {id=} / {path="a/b/c"}，返回 obj
function U.resolveTarget(params, content)
    local c = content or U.content()
    if type(params) == "string" then
        local o = U.findByName(c, params)
        if not o then error("元素不存在: " .. params) end
        return o, "name"
    end
    if U.getStr(params, "id") then
        local o = U.findById(c, params.id)
        if not o then error("找不到 id 为 " .. params.id .. " 的元素") end
        return o, "id"
    end
    local nm = U.getStr(params, "name") or U.getStr(params, "element_name")
    if nm then
        local o = U.findByName(c, nm)
        if not o then error("找不到名为 " .. nm .. " 的元素") end
        return o, "name"
    end
    if U.getStr(params, "path") then
        local o = nil
        pcall(function() o = c:GetChildByPath(params.path) end)
        if not o then error("找不到路径 " .. params.path .. " 的元素") end
        return o, "path"
    end
    error("缺少定位参数：需要提供 name / id / path 之一")
end

-- 解析多个目标：接受字符串数组或单个
function U.resolveTargets(params, content)
    local c = content or U.content()
    local list = {}
    if type(params) == "string" then
        list = { params }
    elseif type(params) == "table" then
        if #params > 0 then list = params else list = { params } end
    end
    local objs = {}
    for _, p in ipairs(list) do
        local o = nil
        local ok, res = pcall(function() return U.resolveTarget(p, c) end)
        if ok and res then o = res end
        if o then objs[#objs + 1] = o end
    end
    return objs
end

-- ========== 对象信息采集 ==========

local TEXT_PROPS = { "text", "font", "fontSize", "align", "verticalAlign", "leading", "letterSpacing",
                     "underline", "bold", "italic", "strike", "stroke", "strokeSize", "shadow",
                     "shadowX", "shadowY", "ubbEnabled", "varsEnabled", "autoSize", "singleLine",
                     "clearOnPublish" }
local TEXT_COLOR_PROPS = { "color", "strokeColor", "shadowColor" }

local IMAGE_PROPS = { "flip", "fillOrigin", "fillClockwise", "fillMethod", "fillAmount" }
local LOADER_PROPS = { "url", "align", "verticalAlign", "fill", "shrinkOnly", "autoSize",
                       "playing", "frame", "showErrorSign", "clearOnPublish", "fillOrigin",
                       "fillClockwise", "fillMethod", "fillAmount" }
local GRAPH_PROPS = { "type", "lineSize", "lineColor", "fillColor", "cornerRadius", "sides",
                      "startAngle", "endAngle", "distance", "points", "drawEllipse" }
local SCROLLPANE_PROPS = { "scrollBarDisplay", "scrollBarFlags", "clipSoftnessX", "clipSoftnessY",
                           "pageMode", "bouncebackEffect", "touchEffect", "mouseWheelEnabled",
                           "snapToItem", "decelerationRate", "scrollStep", "hzScrollBarRes", "vtScrollBarRes" }

function U.objType(obj)
    return U.getStr(obj, "objectType")
end

-- 通用几何/基础属性
function U.objBase(obj)
    return {
        id = U.getStr(obj, "id"),
        name = U.getStr(obj, "name"),
        type = U.objType(obj),
        x = U.getNum(obj, "x"),
        y = U.getNum(obj, "y"),
        width = U.getNum(obj, "width"),
        height = U.getNum(obj, "height"),
        scaleX = U.getNum(obj, "scaleX"),
        scaleY = U.getNum(obj, "scaleY"),
        skewX = U.getNum(obj, "skewX"),
        skewY = U.getNum(obj, "skewY"),
        pivotX = U.getNum(obj, "pivotX"),
        pivotY = U.getNum(obj, "pivotY"),
        anchor = U.getBool(obj, "anchor"),
        rotation = U.getNum(obj, "rotation"),
        alpha = U.getNum(obj, "alpha"),
        visible = U.getBool(obj, "visible"),
        grayed = U.getBool(obj, "grayed"),
        enabled = U.getBool(obj, "enabled"),
        touchable = U.getBool(obj, "touchable"),
        touchDisabled = U.getBool(obj, "touchDisabled"),
        locked = U.getBool(obj, "locked"),
        useSourceSize = U.getBool(obj, "useSourceSize"),
        aspectLocked = U.getBool(obj, "aspectLocked"),
        tooltips = U.getStr(obj, "tooltips"),
        blendMode = U.getStr(obj, "blendMode"),
        customData = U.getStr(obj, "customData"),
        groupId = U.getStr(obj, "groupId"),
        sourceWidth = U.getNum(obj, "sourceWidth"),
        sourceHeight = U.getNum(obj, "sourceHeight"),
        resourceURL = U.getStr(obj, "resourceURL"),
    }
end

-- 类型特有属性
function U.typeExtras(obj)
    local t = U.objType(obj)
    local out = {}
    local function gp(list)
        for _, p in ipairs(list) do
            local v = U.get(obj, p)
            if v ~= nil then out[p] = v end
        end
    end
    local function gc(list)
        for _, p in ipairs(list) do
            local c = U.get(obj, p)
            if c ~= nil then out[p] = U.colorToHex(c) end
        end
    end

    if t == "text" or t == "richtext" or t == "inputtext" then
        gp(TEXT_PROPS)
        gc(TEXT_COLOR_PROPS)
    elseif t == "image" or t == "movieclip" then
        gp(IMAGE_PROPS)
        local c = U.get(obj, "color")
        if c ~= nil then out.color = U.colorToHex(c) end
    elseif t == "loader" or t == "loader3D" then
        gp(LOADER_PROPS)
        gc({ "color" })
    elseif t == "graph" then
        gp(GRAPH_PROPS)
        local lineColor = U.get(obj, "lineColor")
        if lineColor ~= nil then out.lineColor = U.colorToHex(lineColor) end
        local fillColor = U.get(obj, "fillColor")
        if fillColor ~= nil then out.fillColor = U.colorToHex(fillColor) end
    elseif t == "component" then
        gp({ "overflow", "scroll", "pageController", "childrenRenderOrder", "apexIndex",
             "reversedMask", "opaque", "text", "icon", "customExtentionId", "remark", "baseNotes" })
        local c = U.get(obj, "bgColor")
        if c ~= nil then out.bgColor = U.colorToHex(c) end
        out.bgColorEnabled = U.getBool(obj, "bgColorEnabled")
        local children = U.get(obj, "children")
        if children then out.childCount = U.count(children) end
    elseif t == "group" then
        gp({ "type", "expertCopy" })
    end

    -- 组件扩展（button/label/combobox/...）通过 extention 代理
    local ext = U.get(obj, "extention")
    if ext then
        local eType = U.getStr(ext, "extendClass") or U.getStr(ext, "objectType")
        if eType then out.extentionType = eType end
        local e = {}
        local names = {}
        if eType == "Button" then
            names = { "mode", "title", "selectedTitle", "icon", "selectedIcon", "sound", "volume",
                      "downEffect", "downEffectValue", "changeStageOnClick", "controller", "page",
                      "titleFontSize", "titleColorSet", "titleFontSizeSet" }
        elseif eType == "Label" then
            names = { "title", "icon", "titleFontSize" }
        elseif eType == "ComboBox" then
            names = { "title", "icon", "visibleItemCount", "caretPosition" }
        elseif eType == "ProgressBar" or eType == "Slider" then
            names = { "titleType", "min", "max", "value", "reverse", "wholeNumbers" }
        elseif eType == "ScrollBar" then
            names = { "display", "keepGripOnEdge" }
        end
        for _, p in ipairs(names) do
            local v = U.get(ext, p)
            if v ~= nil then e[p] = v end
        end
        local tc = U.get(ext, "titleColor")
        if tc ~= nil then e.titleColor = U.colorToHex(tc) end
        if next(e) ~= nil then out.extentionProps = e end
    end

    return out
end

-- 齿轮信息
function U.gearInfo(obj)
    local gears = {}
    local names = {
        [0] = "display", [1] = "xy", [2] = "size", [3] = "look", [4] = "color",
        [5] = "animation", [6] = "text", [7] = "icon", [8] = "display2", [9] = "fontSize"
    }
    for i = 0, 9 do
        local has = false
        pcall(function()
            local g = obj:GetGear(i, false)
            if g ~= nil then has = true end
        end)
        if has then
            local controller = nil
            pcall(function() controller = U.getStr(obj:GetGear(i, false), "controller") end)
            local pageCount = 0
            pcall(function() pageCount = U.count(obj:GetGear(i, false).pages) end)
            gears[#gears + 1] = {
                index = i,
                type = names[i] or tostring(i),
                controller = controller,
                pageCount = pageCount
            }
        end
    end
    return gears
end

local function relationName(t)
    local ok, names = pcall(function() return CS.FairyEditor.FRelationType.Names end)
    if ok and names then
        local i = U.num(t)
        if i and i >= 0 then
            local ok2, v = pcall(function() return names[i] end)
            if ok2 and v then return v end
        end
    end
    return U.str(t)
end

-- 关联信息
function U.relationInfo(obj)
    local rel = U.get(obj, "relations")
    if rel == nil then return {} end
    local out = {}
    local items = U.get(rel, "items")
    U.each(items, function(item, idx)
        local target = U.get(item, "target")
        local types = {}
        pcall(function()
            local v = item.types
            U.each(v, function(tv)
                types[#types + 1] = relationName(tv)
            end)
        end)
        out[#out + 1] = {
            index = idx,
            targetId = U.getStr(item, "targetId"),
            targetName = target and U.getStr(target, "name") or nil,
            types = types,
            percent = U.getBool(item, "percent")
        }
    end)
    return out
end

-- 简要信息（层级树用）
function U.objBrief(obj)
    return {
        id = U.getStr(obj, "id"),
        name = U.getStr(obj, "name"),
        type = U.objType(obj),
        x = U.getNum(obj, "x"),
        y = U.getNum(obj, "y"),
        width = U.getNum(obj, "width"),
        height = U.getNum(obj, "height"),
        visible = U.getBool(obj, "visible"),
        locked = U.getBool(obj, "locked"),
        groupId = U.getStr(obj, "groupId"),
    }
end

-- 详细信息（用于 get_element）
function U.objInfo(obj)
    local info = U.objBase(obj)
    info.extras = U.typeExtras(obj)
    info.gears = U.gearInfo(obj)
    info.relations = U.relationInfo(obj)
    -- 扩展类型（button/label 等）在 objectType 上体现为 "component"，这里给出真实扩展名
    local ext = U.get(obj, "extention")
    if ext then
        local cls = U.getStr(ext, "extendClass")
        if cls then info.extendClass = cls end
    end
    return info
end

-- 递归构建层级树
function U.buildTree(obj, depth, maxDepth)
    local node = U.objBrief(obj)
    node.depth = depth
    local children = U.get(obj, "children")
    local n = U.count(children)
    node.childCount = n
    if n > 0 and (maxDepth == nil or depth < maxDepth) then
        node.children = {}
        U.each(children, function(child)
            if U.objType(child) ~= "group" then
                node.children[#node.children + 1] = U.buildTree(child, depth + 1, maxDepth)
            end
        end)
    end
    return node
end

-- ========== 属性写入（供 set_element_props / create_element 共用） ==========

local SIMPLE = { "name", "x", "y", "width", "height", "scaleX", "scaleY", "skewX", "skewY",
                 "rotation", "alpha", "visible", "grayed", "enabled", "touchable", "touchDisabled",
                 "locked", "aspectLocked", "useSourceSize", "tooltips", "blendMode", "customData" }
local NUMERIC = { x = 1, y = 1, width = 1, height = 1, scaleX = 1, scaleY = 1, skewX = 1, skewY = 1,
                  rotation = 1, alpha = 1 }
local BOOLKEYS = { visible = 1, grayed = 1, enabled = 1, touchable = 1, touchDisabled = 1,
                   locked = 1, aspectLocked = 1, useSourceSize = 1 }

local TEXTKEYS = { "text", "font", "fontSize", "align", "verticalAlign", "leading", "letterSpacing",
                   "underline", "bold", "italic", "strike", "stroke", "strokeSize", "shadow",
                   "shadowX", "shadowY", "ubbEnabled", "varsEnabled", "autoSize", "singleLine",
                   "clearOnPublish" }
local TEXT_NUM = { fontSize = 1, leading = 1, letterSpacing = 1, strokeSize = 1, shadowX = 1, shadowY = 1 }
local TEXT_BOOL = { underline = 1, bold = 1, italic = 1, strike = 1, stroke = 1, shadow = 1,
                    ubbEnabled = 1, varsEnabled = 1, singleLine = 1, clearOnPublish = 1 }
local TEXT_COLOR = { color = 1, strokeColor = 1, shadowColor = 1 }

local IMAGEKEYS = { "flip", "fillMethod", "fillOrigin", "fillAmount", "fillClockwise" }
local IMAGE_NUM = { fillOrigin = 1, fillAmount = 1 }
local IMAGE_BOOL = { fillClockwise = 1 }

local LOADERKEYS = { "url", "icon", "align", "verticalAlign", "fill", "shrinkOnly", "autoSize",
                     "playing", "frame", "showErrorSign", "clearOnPublish" }
local LOADER_NUM = { frame = 1 }
local LOADER_BOOL = { shrinkOnly = 1, autoSize = 1, playing = 1, showErrorSign = 1, clearOnPublish = 1 }

local GRAPHKEYS = { "type", "lineSize", "cornerRadius", "sides", "startAngle", "endAngle",
                    "distance", "drawEllipse" }
local GRAPH_NUM = { lineSize = 1, cornerRadius = 1, sides = 1, startAngle = 1, endAngle = 1, distance = 1 }
local GRAPH_BOOL = { drawEllipse = 1 }
local GRAPH_COLOR = { lineColor = 1, fillColor = 1 }

local COMPKEYS = { "overflow", "scroll", "scrollBarDisplay", "scrollBarFlags", "clipSoftnessX",
                   "clipSoftnessY", "pageController", "childrenRenderOrder", "apexIndex",
                   "reversedMask", "opaque", "bgColorEnabled", "remark", "baseNotes",
                   "hzScrollBarRes", "vtScrollBarRes", "text", "icon" }
local COMP_NUM = { clipSoftnessX = 1, clipSoftnessY = 1, apexIndex = 1, scrollBarFlags = 1 }
local COMP_BOOL = { reversedMask = 1, opaque = 1, bgColorEnabled = 1 }
local COMP_COLOR = { bgColor = 1 }

local GROUPKEYS = { "layout", "lineGap", "columnGap", "expand", "expertCopy" }
local GROUP_NUM = { lineGap = 1, columnGap = 1 }
local GROUP_BOOL = { expand = 1, expertCopy = 1 }

local function listContains(t, k)
    if not t then return false end
    for _, v in ipairs(t) do if v == k then return true end end
    return false
end

local function convVal(key, value, numKeys, boolKeys)
    if numKeys and numKeys[key] then
        local n = U.num(value)
        if n == nil then return nil, "需要数值: " .. key end
        return n, nil
    end
    if boolKeys and boolKeys[key] then
        local b = U.bool(value)
        if b == nil then return nil, "需要布尔值: " .. key end
        return b, nil
    end
    return value, nil
end

local function handlePivot(obj, props, applied, failed)
    local px, py, anchor = props.pivotX, props.pivotY, U.bool(props.anchor)
    if px == nil and py == nil and anchor == nil then return end
    local cx = U.getNum(obj, "pivotX") or 0
    local cy = U.getNum(obj, "pivotY") or 0
    if px ~= nil then cx = U.num(px) end
    if py ~= nil then cy = U.num(py) end
    if anchor == nil then anchor = U.getBool(obj, "anchor") or false end
    local ok, err = pcall(function() obj:SetPivot(cx, cy, anchor) end)
    if ok then applied[#applied + 1] = "pivot" else failed[#failed + 1] = { key = "pivot", error = U.str(err) } end
end

--- 把一组属性写入对象（自动按元素类型路由）
--- @return table applied, table failed
-- 文本类元素在 font 为空时写 fontSize 会触发 C# 空引用异常（FontManager.GetFont(null)），
-- 这里先补一个可用字体。字体来源：当前组件中已有文本元素的字体，其次 UIConfig 默认值。
local _cachedFont = nil
local TEXTISH = { text = 1, richtext = 1, inputtext = 1, label = 1, button = 1, combobox = 1 }

function U.defaultFont()
    if _cachedFont then return _cachedFont end
    local found = nil
    pcall(function()
        local content = U.content()
        local function scan(container, depth)
            if found or depth > 4 then return end
            U.eachChild(container, function(c)
                if found then return end
                local t = U.objType(c)
                if TEXTISH[t] then
                    local f = U.get(c, "font")
                    if f ~= nil and f ~= "" then found = f end
                end
                if not found then scan(c, depth + 1) end
            end)
        end
        scan(content, 0)
    end)
    if not found or found == "" then
        pcall(function() found = CS.FairyGUI.UIConfig.defaultFont end)
    end
    if found and found ~= "" then _cachedFont = found end
    return _cachedFont
end

function U.ensureFont(obj)
    if not obj then return false end
    if not TEXTISH[U.objType(obj)] then return false end
    local f = U.get(obj, "font")
    if f ~= nil and f ~= "" then return false end
    local d = U.defaultFont()
    if not d then return false end
    local ok = U.set(obj, "font", d)
    return ok == true
end


function U.applyProps(obj, props)
    local applied, failed = {}, {}
    local objType = U.objType(obj)

    -- 文本类元素先确保有字体，避免写字号时抛空引用异常
    U.ensureFont(obj)

    for key, value in pairs(props) do
        if key == "props" or key == "target" or key == "type" or key == "parent" then
            -- 结构字段，跳过
        elseif key == "pivotX" or key == "pivotY" or key == "anchor" then
            -- 统一在 handlePivot 处理
        elseif key == "margin" or key == "scrollBarMargin" then
            local m = U.get(obj, key)
            if m and U.isTable(value) then
                local okAll = true
                for _, side in ipairs({ "left", "right", "top", "bottom" }) do
                    if U.num(value[side]) ~= nil then
                        local okSide = U.set(m, side, U.num(value[side]))
                        if not okSide then okAll = false end
                    end
                end
                if okAll then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = "部分边距写入失败" } end
            else
                failed[#failed + 1] = { key = key, error = "该元素没有 margin" }
            end
        elseif listContains(SIMPLE, key) then
            local v, cerr = convVal(key, value, NUMERIC, BOOLKEYS)
            if cerr then failed[#failed + 1] = { key = key, error = cerr }
            else
                local ok, err = U.set(obj, key, v)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            end
        elseif (objType == "text" or objType == "richtext" or objType == "inputtext")
            and (listContains(TEXTKEYS, key) or TEXT_COLOR[key]) then
            if TEXT_COLOR[key] then
                local ok, err = U.applyColor(obj, key, value)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, TEXT_NUM, TEXT_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif (objType == "image" or objType == "movieclip")
            and (listContains(IMAGEKEYS, key) or key == "color") then
            if key == "color" then
                local ok, err = U.applyColor(obj, "color", value)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, IMAGE_NUM, IMAGE_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif objType == "loader" and (listContains(LOADERKEYS, key) or key == "color") then
            if key == "color" then
                local ok, err = U.applyColor(obj, "color", value)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, LOADER_NUM, LOADER_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif objType == "graph" and (listContains(GRAPHKEYS, key) or GRAPH_COLOR[key] or key == "color") then
            if GRAPH_COLOR[key] or key == "color" then
                -- 图形的 color 等价于填充色
                local prop = (key == "color") and "fillColor" or key
                local ok, err = U.applyColor(obj, prop, value)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, GRAPH_NUM, GRAPH_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif objType == "group" and (listContains(GROUPKEYS, key) or key == "layout") then
            if key == "layout" then
                -- 编辑器里 layout 是枚举，先按字符串试，失败再按数值试
                local ok, err = U.set(obj, "layout", value)
                if not ok and type(value) == "string" then
                    local map = { none = 0, horizontal = 1, vertical = 2 }
                    local n = map[string.lower(value)]
                    if n ~= nil then ok, err = U.set(obj, "layout", n) end
                end
                if ok then applied[#applied + 1] = key
                else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, GROUP_NUM, GROUP_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key
                    else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif objType == "component" and (listContains(COMPKEYS, key) or COMP_COLOR[key]) then
            if COMP_COLOR[key] then
                local ok, err = U.applyColor(obj, key, value)
                if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
            else
                local v, cerr = convVal(key, value, COMP_NUM, COMP_BOOL)
                if cerr then failed[#failed + 1] = { key = key, error = cerr }
                else
                    local ok, err = U.set(obj, key, v)
                    if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
                end
            end
        elseif objType == "component" and listContains(TEXTKEYS, key) then
            local ext = U.get(obj, "extention")
            local target, tkey = obj, key
            if ext and key == "text" then
                local okT, val = pcall(function() return ext.title end)
                if okT and val ~= nil then target, tkey = ext, "title" end
            end
            local ok, err = U.set(target, tkey, value)
            if ok then applied[#applied + 1] = key else failed[#failed + 1] = { key = key, error = U.str(err) } end
        else
            local ext = U.get(obj, "extention")
            if ext then
                local ok, err = U.set(ext, key, value)
                if ok then applied[#applied + 1] = key .. "(extention)"
                else failed[#failed + 1] = { key = key, error = "不支持或不匹配的属性（类型: " .. U.str(objType) .. "）" } end
            else
                failed[#failed + 1] = { key = key, error = "不支持的属性（类型: " .. U.str(objType) .. "）" }
            end
        end
    end

    handlePivot(obj, props, applied, failed)
    return applied, failed
end

-- ========== 元素属性快照 / 复制 ==========
-- 把元素的可用属性抽成一张符合 applyProps 口径的 props 表，供复制、克隆、批量对齐使用。

function U.snapshotProps(obj, opts)
    opts = opts or {}
    local t = U.objType(obj)
    local out = {}
    local function take(k)
        local v = U.get(obj, k)
        if v ~= nil then out[k] = v end
    end
    local function takeColor(k)
        local v = U.get(obj, k)
        if v ~= nil then out[k] = U.colorToHex(v) or v end
    end

    for _, k in ipairs(SIMPLE) do
        if k ~= "name" or opts.includeName then take(k) end
    end

    if t == "text" or t == "richtext" or t == "inputtext" then
        for _, k in ipairs(TEXTKEYS) do take(k) end
        for k in pairs(TEXT_COLOR) do takeColor(k) end
    elseif t == "image" or t == "movieclip" then
        for _, k in ipairs(IMAGEKEYS) do take(k) end
        takeColor("color")
    elseif t == "loader" or t == "loader3D" then
        for _, k in ipairs(LOADERKEYS) do take(k) end
        takeColor("color")
    elseif t == "graph" then
        for _, k in ipairs(GRAPHKEYS) do take(k) end
        for k in pairs(GRAPH_COLOR) do takeColor(k) end
    else
        -- component / list / group / 各类扩展组件
        for _, k in ipairs(COMPKEYS) do take(k) end
        for k in pairs(COMP_COLOR) do takeColor(k) end
        if t == "group" then
            for _, k in ipairs(GROUPKEYS) do
                if k ~= "layout" then take(k) end
            end
            take("type")
        end
    end

    -- 组件扩展（button/label/combobox/progressbar/slider/scrollbar）走 extention 代理
    local ext = U.get(obj, "extention")
    if ext then
        local eType = U.getStr(ext, "extendClass") or U.getStr(ext, "objectType")
        local names = {}
        if eType == "Button" then
            names = { "mode", "title", "selectedTitle", "icon", "selectedIcon", "sound", "volume",
                      "downEffect", "downEffectValue", "changeStageOnClick", "controller", "page",
                      "titleFontSize" }
        elseif eType == "Label" then
            names = { "title", "icon", "titleFontSize" }
        elseif eType == "ComboBox" then
            names = { "title", "icon", "visibleItemCount", "caretPosition" }
        elseif eType == "ProgressBar" or eType == "Slider" then
            names = { "titleType", "min", "max", "value", "reverse", "wholeNumbers" }
        elseif eType == "ScrollBar" then
            names = { "display", "keepGripOnEdge" }
        end
        for _, p in ipairs(names) do
            local v = U.get(ext, p)
            if v ~= nil then out[p] = v end
        end
        local tc = U.get(ext, "titleColor")
        if tc ~= nil then out.titleColor = U.colorToHex(tc) or tc end
    end

    -- 清理：只读字段、类型不符的值会让 applyProps 报错，这里先过滤掉
    out.touchDisabled = nil
    out.name = nil
    local numTables = { NUMERIC, TEXT_NUM, IMAGE_NUM, LOADER_NUM, GRAPH_NUM, COMP_NUM, GROUP_NUM }
    local boolTables = { BOOLKEYS, TEXT_BOOL, IMAGE_BOOL, LOADER_BOOL, GRAPH_BOOL, COMP_BOOL, GROUP_BOOL }
    for k, v in pairs(out) do
        local isNum, isBool = false, false
        for _, t2 in ipairs(numTables) do if t2[k] then isNum = true end end
        for _, t2 in ipairs(boolTables) do if t2[k] then isBool = true end end
        if isNum or isBool then
            if isNum and U.num(v) == nil then out[k] = nil
            elseif isBool and U.bool(v) == nil then out[k] = nil end
        elseif v == nil then
            out[k] = nil
        end
    end

    return out
end

--- 把 src 的属性复制到 dst（同类型元素）
function U.copyProps(src, dst, opts)
    if not src or not dst then return {}, {} end
    return U.applyProps(dst, U.snapshotProps(src, opts))
end

-- 标记文档/包被修改
function U.markDirty(doc, content)
    pcall(function() doc:SetModified(true) end)
    pcall(function()
        local pi = U.get(doc, "packageItem")
        if pi then
            local owner = U.get(pi, "owner")
            if owner then owner:SetChanged() end
            pi:SetChanged()
        end
    end)
end

return U
