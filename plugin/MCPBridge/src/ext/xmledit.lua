-- MCPBridge 扩展 · 组件 XML 直改模块
--
-- 有些属性编辑器根本没暴露 setter（实测）：
--   element.resourceURL  → "cannot set resourceURL, no such field"
--   FImage 类表只有 UnderlyingSystemType，实例 metatable 的 __index 是 function，无法枚举成员
-- 于是「给已有元素换图」只能走文件层：改组件 XML 里该元素节点的 src / fileName，再让文档重载。
-- 组件 XML 里的写法（实测）：
--   <image id="n1" name="character" src="i02" fileName="swordman-lead.png" xy="..." size="..."/>
--   ↑ src = 资源在 package.xml 里的 id，fileName = 资源原始文件名
--
-- 命令:
--   element_set_resource   修改元素的资源引用（换图/换动画/换关联组件）
--   element_xml            导出元素在组件 XML 里的节点原文（排查用）

local App = App
local U = dofile(_G._mcpUtilPath)

local X = {}

-- ---------- 文件层基础 ----------

local function componentFile(doc)
    local pi = U.get(doc, "packageItem")
    if not pi then return nil end
    local f = U.getStr(pi, "file")
    if not f or f == "" then return nil end
    return f:gsub("/", "\\"), pi
end

local function readText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if s and s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
    return s
end

local function writeText(path, text)
    local f = io.open(path, "wb")
    if not f then return false, "无法写入: " .. tostring(path) end
    f:write(text)
    f:close()
    return true
end

--- 先把内存改动刷盘，再读组件 XML
local function loadFlushed(doc)
    local path = componentFile(doc)
    if not path then error("无法定位当前组件的 XML 文件") end
    pcall(function() doc:Save() end)
    local t = os.clock()
    while os.clock() - t < 0.20 do end
    local text = readText(path)
    if not text then error("无法读取组件文件: " .. path) end
    return path, text
end

--- 写回并让文档重载
local function commit(doc, path, text)
    local ok, err = writeText(path, text)
    if not ok then error(err) end
    pcall(function() doc:DiscardChanges() end)
    local t = os.clock()
    while os.clock() - t < 0.45 do end
    return true
end

--- 找到 id="xxx" 所在的那个 XML 标签的范围（返回 body 起止，不含尖括号）
local function findNode(text, id)
    local needle = 'id="' .. id .. '"'
    local p = string.find(text, needle, 1, true)
    if not p then return nil end
    -- 往回找标签名与 '<'
    local s = p
    while s > 1 do
        local ch = string.sub(text, s, s)
        if ch == "<" then break end
        if ch == ">" then return nil end        -- 越过了上一个标签，说明格式异常
        s = s - 1
    end
    local name = string.match(string.sub(text, s + 1, p), "^([%w_]+)")
    -- 向后找标签结束
    local e = p
    local depth = 0
    while e <= #text do
        local ch = string.sub(text, e, e)
        if ch == ">" then break end
        e = e + 1
    end
    if e > #text then return nil end
    local selfClose = string.sub(text, e - 1, e - 1) == "/"
    local innerS, innerE = s + 1, e - 1
    if selfClose then innerE = e - 2 end
    return {
        tagStart = s, tagEnd = e,
        nameStart = s + 1, nameEnd = p - 1,   -- 标签名 + 其它属性（到 id 之前）
        tag = name, selfClose = selfClose,
        body = string.sub(text, s + 1, e),
        inner = string.sub(text, innerS, innerE),
    }
end

--- 在属性串里替换/插入 key="value"
local function upsertAttr(inner, key, value)
    local pattern = "(" .. key .. '=")([^"]*)(")'
    if string.find(inner, pattern) then
        local out, n = string.gsub(inner, pattern, "%1" .. value .. "%3", 1)
        if n > 0 then return out end
    end
    return inner:gsub("/%s*$", "") .. " " .. key .. '="' .. value .. '"'
end

local function xmlEscape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- ---------- 命令 ----------

--- 修改元素的资源引用
--- element_set_resource {"name":"icon","resource_name":"logo.png","package_name":"package2"}
--- element_set_resource {"id":"n1","resource_url":"ui://qjrdnvgji03"}   也可直接用 ui:// url
function X.handleElementSetResource(params, bridgePath)
    local content, doc = U.content()
    local obj = U.resolveTarget(params, content)
    local id = U.getStr(obj, "id")
    if not id or id == "" then error("该元素没有 id，无法在 XML 里定位") end

    -- 解析目标资源
    local resId, resFile, label = nil, nil, nil
    if params.resource_url then
        local url = U.str(params.resource_url)
        -- ui://<pkgId><itemId>
        resId = string.match(url, "^ui://%w%w%w%w%w%w%w%w(.+)$") or string.match(url, "^ui://(.+)$")
        local item = nil
        pcall(function()
            local pkg = U.pkgOfDoc()
            U.each(U.get(pkg, "items"), function(it)
                if (not item) and U.getStr(it, "id") == resId then item = it end
            end)
        end)
        if item then resFile = U.getStr(item, "name") end
        label = url
    elseif params.resource_name then
        local item = U.findItemByName(params.package_name, U.str(params.resource_name))
        if not item then error("资源不存在: " .. U.str(params.resource_name)) end
        resId = U.getStr(item, "id")
        -- XML 的 fileName 用「带扩展名」的原始文件名（item.fileName）
        resFile = U.itemFileName(item)
        label = resFile
    else
        error("缺少参数: resource_name（或 resource_url）")
    end

    if not resId or resId == "" then error("无法解析资源 id") end

    local before = U.getStr(obj, "resourceURL")
    local path, text = loadFlushed(doc)
    local node = findNode(text, id)
    if not node then error("组件 XML 里找不到元素 id=" .. id .. "（请先保存一次文档再试）") end

    local inner = node.inner
    inner = upsertAttr(inner, "src", xmlEscape(resId))
    if resFile and resFile ~= "" then inner = upsertAttr(inner, "fileName", xmlEscape(resFile)) end

    local newTag = "<" .. inner .. (node.selfClose and "/>" or ">")
    local newText = string.sub(text, 1, node.tagStart - 1) .. newTag .. string.sub(text, node.tagEnd + 1)
    commit(doc, path, newText)

    -- 回读确认
    local after = nil
    pcall(function()
        local content2 = U.content()
        local o2 = U.findById(content2, id)
        after = o2 and U.getStr(o2, "resourceURL") or nil
    end)

    return {
        updated = true,
        element = U.getStr(obj, "name"),
        id = id,
        tag = node.tag,
        resource = label,
        src_id = resId,
        file_name = resFile,
        before_url = before,
        after_url = after,
        file = path,
    }
end

--- 导出元素在组件 XML 里的原文（按当前磁盘内容）
function X.handleElementXml(params, bridgePath)
    local content, doc = U.content()
    local obj = U.resolveTarget(params, content)
    local id = U.getStr(obj, "id")
    if not id or id == "" then error("该元素没有 id") end
    local path, text = loadFlushed(doc)
    local node = findNode(text, id)
    if not node then error("组件 XML 里找不到元素 id=" .. id) end
    return {
        id = id, tag = node.tag, xml = node.body, file = path,
        name = U.getStr(obj, "name"),
    }
end

function X.register(CH)
    for k, v in pairs(X) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return X
