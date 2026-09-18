-- MCPBridge 扩展 · 包 / 组件资源模块
--
-- 背景：FairyEditor 的 Lua API 没有暴露「新建组件」「导入资源」这类编辑命令
-- （pkg:AddItem 各重载均抛空引用），因此这些操作在文件层完成：
--   1. 写组件 XML / 拷贝图片到 assets/<pkg>/
--   2. 在 package.xml 的 <resources> 里登记资源节点
--   3. 触发包刷新
-- 组件节点格式（与工程实例一致）：
--   <component id="n9vo0" name="Component1.xml" path="/" exported="true"/>
--   <image id="i01" name="home-background.png" path="/"/>
--
-- 命令:
--   component_create      新建组件（界面）
--   component_duplicate   复制组件（克隆界面做变体）
--   component_delete      删除组件
--   component_set_size    改组件默认尺寸
--   image_import          导入图片资源
--   package_reload        刷新包

local App = App
local U = dofile(_G._mcpUtilPath)

local P = {}
local CH = nil

-- ---------- 基础 ----------

local function assetsPath()
    local p = nil
    pcall(function() p = App.project.assetsPath end)
    if not p or p == "" then error("无法获取工程 assets 路径") end
    return (p:gsub("/", "\\"))
end

local function pkgOf(name)
    local pkg = nil
    if name and name ~= "" then
        pcall(function() pkg = App.project:GetPackageByName(name) end)
    end
    if not pkg then pkg = U.pkgOfDoc() end
    if not pkg then error("无法定位包" .. (name and ("：" .. tostring(name)) or "")) end
    return pkg
end

local function pkgDir(pkg)
    return assetsPath() .. "\\" .. (U.getStr(pkg, "name") or "")
end

local function pkgXmlPath(pkg)
    return pkgDir(pkg) .. "\\package.xml"
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

local function ensureDir(path)
    if CS.System.IO.Directory.Exists(path) then return true end
    return pcall(function() CS.System.IO.Directory.CreateDirectory(path) end)
end

local function fileExists(path)
    local ok, v = pcall(function() return CS.System.IO.File.Exists(path) end)
    return ok and v == true
end

local function xmlEscape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- 生成一个包内唯一的 8 位资源 id（FGUI 的 id 形如 n9vo0 / i01）
local function newItemId(pkgXmlText, prefix)
    local used = {}
    for id in string.gmatch(pkgXmlText or "", 'id="([^"]+)"') do used[id] = true end
    local alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    for _ = 1, 300 do
        local s = ""
        for _ = 1, 7 do
            local i = math.random(#alphabet)
            s = s .. string.sub(alphabet, i, i)
        end
        local id = prefix .. s
        if not used[id] then return id end
    end
    error("无法生成唯一的资源 id")
end

local function findResourceNode(pkgXmlText, nodeName, resName)
    -- 返回完整标签文本、起止位置
    local pattern = "<" .. nodeName .. "[^>]-name=\"([^\"]*)\"[^>]*/?>"
    local pos = 1
    while true do
        local s, e, nm = string.find(pkgXmlText, pattern, pos)
        if not s then return nil end
        if nm == resName then
            return { s = s, e = e, text = string.sub(pkgXmlText, s, e), name = nm }
        end
        pos = e + 1
    end
end

local function insertResourceNode(pkgXmlText, nodeText)
    local s = string.find(pkgXmlText, "</resources>", 1, true)
    if not s then error("package.xml 里找不到 </resources>") end
    local lineStart = s
    while lineStart > 1 do
        local ch = string.sub(pkgXmlText, lineStart - 1, lineStart - 1)
        if ch == "\n" then break end
        lineStart = lineStart - 1
    end
    local indent = string.match(string.sub(pkgXmlText, lineStart, s - 1), "^%s*") or "    "
    return string.sub(pkgXmlText, 1, lineStart - 1)
        .. indent .. nodeText .. "\n"
        .. string.sub(pkgXmlText, lineStart)
end

local function removeResourceNode(pkgXmlText, nodeName, resName)
    local node = findResourceNode(pkgXmlText, nodeName, resName)
    if not node then return pkgXmlText, false end
    -- 连同缩进和换行一起删掉
    local s = node.s
    while s > 1 do
        local ch = string.sub(pkgXmlText, s - 1, s - 1)
        if ch ~= " " and ch ~= "\t" then break end
        s = s - 1
    end
    local e = node.e
    if string.sub(pkgXmlText, e + 1, e + 1) == "\r" then e = e + 1 end
    if string.sub(pkgXmlText, e + 1, e + 1) == "\n" then e = e + 1 end
    return string.sub(pkgXmlText, 1, s - 1) .. string.sub(pkgXmlText, e + 1), true
end

local function reloadPackage(pkg, bridgePath)
    local tried, ok1 = {}, nil
    pcall(function() pkg:Touch() end)
    tried[#tried + 1] = "pkg:Touch"
    pcall(function() App.project:RefreshPackage(pkg) end)
    tried[#tried + 1] = "project:RefreshPackage"
    if CH and CH.handleReload then
        local ok, _ = pcall(function() CH.handleReload({ package_name = U.getStr(pkg, "name") }, bridgePath) end)
        if ok then ok1 = true end
        tried[#tried + 1] = "reload(action)"
    end
    return tried
end

local function ensureCompName(name)
    if not name or name == "" then error("缺少参数: name") end
    local n = U.str(name)
    if not n:match("%.xml$") then n = n .. ".xml" end
    return n
end

local function normalizeResPath(p)
    if not p or p == "" then return "/" end
    p = U.str(p)
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    if p:sub(-1) ~= "/" then p = p .. "/" end
    return p
end

local function dirOf(pkg, resPath)
    local rel = resPath:gsub("^/", ""):gsub("/$", "")
    local d = pkgDir(pkg)
    if rel ~= "" then d = d .. "\\" .. rel:gsub("/", "\\") end
    return d
end

-- ---------- 命令 ----------

function P.handleComponentCreate(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local compName = ensureCompName(params.name or params.component_name)
    local resPath = normalizeResPath(params.path)

    local dir = dirOf(pkg, resPath)
    ensureDir(dir)
    local file = dir .. "\\" .. compName
    if fileExists(file) then error("组件已存在: " .. resPath .. compName) end

    local w = U.int(params.width) or 1080
    local h = U.int(params.height) or 1920
    local opaque = U.bool(params.opaque)
    if opaque == nil then opaque = false end

    local rootAttrs = string.format('size="%d,%d"', w, h)
    if params.extention then rootAttrs = rootAttrs .. ' extention="' .. xmlEscape(params.extention) .. '"' end

    local xml = '<?xml version="1.0" encoding="utf-8"?>\n'
        .. "<component " .. rootAttrs .. ">\n"
        .. "  <displayList>\n"
        .. "  </displayList>\n"
        .. "</component>"

    local okW, errW = writeText(file, xml)
    if not okW then error(errW) end

    -- 登记到 package.xml
    local pkgXmlFile = pkgXmlPath(pkg)
    local text = readText(pkgXmlFile)
    if not text then
        pcall(function() CS.System.IO.File.Delete(file) end)
        error("无法读取 package.xml: " .. pkgXmlFile)
    end
    if findResourceNode(text, "component", compName) then
        pcall(function() CS.System.IO.File.Delete(file) end)
        error("package.xml 里已登记同名组件: " .. compName)
    end

    local id = newItemId(text, "n")
    local exported = U.bool(params.exported)
    if exported == nil then exported = true end
    local node = string.format('<component id="%s" name="%s" path="%s"%s/>',
        id, xmlEscape(compName), resPath, exported and ' exported="true"' or "")
    local newText = insertResourceNode(text, node)
    local okW2, errW2 = writeText(pkgXmlFile, newText)
    if not okW2 then
        pcall(function() CS.System.IO.File.Delete(file) end)
        error(errW2)
    end

    local tried = reloadPackage(pkg, bridgePath)
    return {
        created = true,
        package = U.getStr(pkg, "name"),
        name = compName:gsub("%.xml$", ""),
        id = id,
        path = resPath,
        file = file,
        url = "ui://" .. (U.getStr(pkg, "id") or "") .. id,
        size = { w, h },
        reload = tried,
    }
end

function P.handleComponentDuplicate(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local srcName = ensureCompName(params.name or params.source)
    local newName = params.new_name or params.target
    if not newName then error("缺少参数: new_name") end
    newName = ensureCompName(newName)

    local srcPath = normalizeResPath(params.source_path)
    local dstPath = normalizeResPath(params.path or params.source_path)

    local srcFile = dirOf(pkg, srcPath) .. "\\" .. srcName
    if not fileExists(srcFile) then error("源组件不存在: " .. srcFile) end
    local dstFile = dirOf(pkg, dstPath) .. "\\" .. newName
    if fileExists(dstFile) then error("目标组件已存在: " .. dstFile) end

    ensureDir(dirOf(pkg, dstPath))
    local okC = pcall(function() CS.System.IO.File.Copy(srcFile, dstFile, false) end)
    if not okC then error("复制组件文件失败") end

    local pkgXmlFile = pkgXmlPath(pkg)
    local text = readText(pkgXmlFile)
    if not text then
        pcall(function() CS.System.IO.File.Delete(dstFile) end)
        error("无法读取 package.xml")
    end
    local id = newItemId(text, "n")
    local node = string.format('<component id="%s" name="%s" path="%s" exported="true"/>',
        id, xmlEscape(newName), dstPath)
    local newText = insertResourceNode(text, node)
    local okW, errW = writeText(pkgXmlFile, newText)
    if not okW then
        pcall(function() CS.System.IO.File.Delete(dstFile) end)
        error(errW)
    end

    local tried = reloadPackage(pkg, bridgePath)
    return {
        duplicated = true,
        package = U.getStr(pkg, "name"),
        source = srcName, name = newName:gsub("%.xml$", ""),
        id = id, file = dstFile,
        url = "ui://" .. (U.getStr(pkg, "id") or "") .. id,
        reload = tried,
    }
end

--- 当前打开的组件信息（用于避免删掉正在编辑的文档）
local function openComponent()
    local doc = App.activeDoc
    if not doc then return nil, nil end
    local pi = U.get(doc, "packageItem")
    if not pi then return nil, nil end
    return U.getStr(pi, "name"), U.getStr(U.get(pi, "owner"), "name")
end

function P.handleComponentDelete(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local compName = ensureCompName(params.name or params.component_name)
    local resPath = normalizeResPath(params.path)

    -- 删掉「正在编辑」的组件文件会让文档进入无效状态，编辑器随后每帧抛空引用
    -- （Player.log 里的 Document.ValidateContent / OnUpdate NullReferenceException）。
    -- 因此先切到同包内的另一个组件，再执行删除。
    local openName, openPkgName = openComponent()
    if openName == compName and openPkgName == U.getStr(pkg, "name") then
        local switchedTo = nil
        if CH and CH.handleOpenComponent then
            local other = nil
            U.each(U.get(pkg, "items"), function(it)
                local n = U.getStr(it, "name")
                if (not other) and n and n:match("%.xml$") and n ~= compName then other = n end
            end)
            if other then
                local ok = pcall(function()
                    CH.handleOpenComponent({
                        package_name = U.getStr(pkg, "name"),
                        component_name = other:gsub("%.xml$", ""),
                    }, bridgePath)
                end)
                if ok then switchedTo = other end
            end
        end
        if switchedTo then
            local t = os.clock()
            while os.clock() - t < 0.6 do end
        else
            -- 同包里没有别的组件可切：关闭当前文档，避免留下无效文档
            pcall(function() App.docView:CloseDocument(App.activeDoc) end)
            local t = os.clock()
            while os.clock() - t < 0.6 do end
        end
    end


    local pkgXmlFile = pkgXmlPath(pkg)
    local text = readText(pkgXmlFile)
    if not text then error("无法读取 package.xml") end
    local newText, removed = removeResourceNode(text, "component", compName)
    if not removed then error("package.xml 里没有该组件: " .. compName) end

    local file = dirOf(pkg, resPath) .. "\\" .. compName
    if not fileExists(file) then
        -- 兜底：在包目录里找同名文件
        local alt = dirOf(pkg, "/") .. "\\" .. compName
        if fileExists(alt) then file = alt end
    end

    local okW, errW = writeText(pkgXmlFile, newText)
    if not okW then error(errW) end
    if fileExists(file) then
        pcall(function() CS.System.IO.File.Delete(file) end)
    end

    local tried = reloadPackage(pkg, bridgePath)
    return {
        deleted = true, package = U.getStr(pkg, "name"),
        name = compName:gsub("%.xml$", ""), file = file, reload = tried,
    }
end

function P.handleComponentSetSize(params, bridgePath)
    local doc = U.requireDoc()
    local path = U.getStr(U.get(doc, "packageItem"), "file")
    if not path or path == "" then error("无法定位当前组件文件") end
    path = path:gsub("/", "\\")

    local w = U.int(params.width)
    local h = U.int(params.height)
    if w == nil or h == nil then error("缺少参数: width / height") end

    -- 先把内容落盘，避免丢改动
    pcall(function() doc:Save() end)
    local t0 = os.clock()
    while os.clock() - t0 < 0.15 do end

    local text = readText(path)
    if not text then error("无法读取组件文件") end
    local oldSize = string.match(text, '<component[^>]-size="([^"]*)"')
    local newText, n = string.gsub(text, '(<component[^>]-size=")[^"]*(")', "%1" .. w .. "," .. h .. "%2", 1)
    if n == 0 then
        newText = string.gsub(text, "<component", '<component size="' .. w .. "," .. h .. '"', 1)
    end
    local okW, errW = writeText(path, newText)
    if not okW then error(errW) end

    pcall(function() doc:DiscardChanges() end)
    local t1 = os.clock()
    while os.clock() - t1 < 0.4 do end

    return { updated = true, file = path, old_size = oldSize, new_size = w .. "," .. h }
end

function P.handleImageImport(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local src = params.source_file or params.source or params.file
    if not src then error("缺少参数: source_file（图片绝对路径）") end
    src = U.str(src):gsub("/", "\\")
    if not fileExists(src) then error("源文件不存在: " .. src) end

    local resPath = normalizeResPath(params.path)
    local fileName = params.name or params.file_name
    if not fileName or fileName == "" then
        fileName = string.match(src, "([^\\]+)$") or "imported.png"
    end
    if not fileName:match("%.[%w]+$") then fileName = fileName .. ".png" end

    local dir = dirOf(pkg, resPath)
    ensureDir(dir)
    local dst = dir .. "\\" .. fileName
    local okC = pcall(function() CS.System.IO.File.Copy(src, dst, true) end)
    if not okC then error("复制图片失败: " .. dst) end

    local pkgXmlFile = pkgXmlPath(pkg)
    local text = readText(pkgXmlFile)
    if not text then error("无法读取 package.xml") end

    local node = findResourceNode(text, "image", fileName)
    local id = nil
    if node then
        id = string.match(node.text, 'id="([^"]*)"')
    else
        id = newItemId(text, "i")
        local newNode = string.format('<image id="%s" name="%s" path="%s"/>', id, xmlEscape(fileName), resPath)
        local okW, errW = writeText(pkgXmlFile, insertResourceNode(text, newNode))
        if not okW then error(errW) end
    end

    local tried = reloadPackage(pkg, bridgePath)
    return {
        imported = true, package = U.getStr(pkg, "name"),
        name = fileName, id = id, path = resPath,
        file = dst, url = "ui://" .. (U.getStr(pkg, "id") or "") .. id,
        replaced = node ~= nil, reload = tried,
    }
end

--- 重新打开当前组件，让编辑器视图从磁盘重建
---
--- 背景：脚本改属性/增删元素绕过了编辑器的命令层，它的视图缓存不会同步。
--- 实测：编辑器在后台时控制台 0 报错，一旦切到前台就会成簇刷
---       Document.OnUpdate NullReferenceException（编辑器自己在补视图时崩）。
--- 触发一次「保存 → 关闭文档 → 重新打开」可以让视图从文件重建，恢复正常。
function P.handleRefreshView(params, bridgePath)
    local doc = App.activeDoc
    if not doc then error("没有打开的文档") end
    local pi = U.get(doc, "packageItem")
    if not pi then error("无法获取当前文档信息") end
    local pkgName = U.getStr(U.get(pi, "owner"), "name")
    local compName = (U.getStr(pi, "name") or ""):gsub("%.xml$", "")
    local fileName = U.getStr(pi, "file")

    local saved = pcall(function() doc:Save() end)
    local t0 = os.clock()
    while os.clock() - t0 < 0.30 do end

    local closed = pcall(function() App.docView:CloseDocument(App.activeDoc) end)
    local t1 = os.clock()
    while os.clock() - t1 < 0.40 do end

    local reopened = false
    if CH and CH.handleOpenComponent and pkgName and compName ~= "" then
        reopened = pcall(function()
            CH.handleOpenComponent({ package_name = pkgName, component_name = compName }, bridgePath)
        end)
    end
    local t2 = os.clock()
    while os.clock() - t2 < 0.50 do end

    local reopenedName = nil
    pcall(function()
        local pi2 = U.get(App.activeDoc, "packageItem")
        reopenedName = U.getStr(pi2, "name")
    end)

    return {
        refreshed = reopenedName ~= nil,
        package = pkgName,
        component = compName,
        saved = saved,
        closed = closed,
        reopened = reopened,
        reopened_name = reopenedName,
        file = fileName,
    }
end

--- 删除资源（文件 + package.xml 登记）
--- resource_delete {"package_name":"package2","resource_name":"a.png"}
--- 只给 name 时会自动在 package.xml 里找节点并推断类型（image/component/movieclip/font/sound/misc…）
function P.handleResourceDelete(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local resName = U.str(params.resource_name or params.name)
    if not resName then error("缺少参数: resource_name") end

    local pkgXmlFile = pkgXmlPath(pkg)
    local text = readText(pkgXmlFile)
    if not text then error("无法读取 package.xml: " .. pkgXmlFile) end

    -- 找到节点，确定类型与所在子目录
    local nodeType, nodePath, nodeText = nil, nil, nil
    for _, t in ipairs({ "image", "component", "movieclip", "font", "sound", "misc",
                         "atlas", "skeleton", "spine", "props", "res" }) do
        local n = findResourceNode(text, t, resName)
        if n then
            nodeType, nodeText = t, n.text
            nodePath = string.match(n.text, 'path="([^"]*)"') or "/"
            break
        end
    end
    if not nodeType then error("package.xml 里找不到资源: " .. resName) end

    local id = string.match(nodeText, 'id="([^"]*)"')

    -- 先删登记再删文件：万一删文件失败，登记已经清掉，包不会指向不存在的文件
    local newText, removed = removeResourceNode(text, nodeType, resName)
    if not removed then error("移除 package.xml 登记失败: " .. resName) end
    local okW, errW = writeText(pkgXmlFile, newText)
    if not okW then error(errW) end

    local dir = dirOf(pkg, nodePath)
    local file = dir .. "\\" .. resName
    local existed = fileExists(file)
    if existed then
        pcall(function() CS.System.IO.File.Delete(file) end)
    end
    -- 允许传 sub_file：同名资源在别的子目录（如 atlas 的 png）
    local subDeleted = {}
    for _, extra in ipairs(params.extra_files or {}) do
        local f2 = pkgDir(pkg) .. "\\" .. U.str(extra):gsub("/", "\\")
        if fileExists(f2) then
            pcall(function() CS.System.IO.File.Delete(f2) end)
            subDeleted[#subDeleted + 1] = f2
        end
    end

    local tried = reloadPackage(pkg, bridgePath)
    return {
        deleted = true,
        package = U.getStr(pkg, "name"),
        resource = resName,
        type = nodeType,
        id = id,
        file = file,
        file_existed = existed,
        extra_deleted = subDeleted,
        reload = tried,
    }
end

function P.handlePackageReload(params, bridgePath)
    local pkg = pkgOf(params.package_name or params.package)
    local tried = reloadPackage(pkg, bridgePath)
    return { reloaded = true, package = U.getStr(pkg, "name"), methods = tried }
end

function P.register(ch)
    CH = ch
    for k, v in pairs(P) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return P
