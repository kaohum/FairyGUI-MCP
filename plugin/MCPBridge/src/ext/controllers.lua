-- MCPBridge 扩展 · 控制器（Controller）模块
--
-- 已实测的 FairyEditor.FController API（xLua）：
--   属性: name / exported / pageCount / selectedIndex / selectedPage / changing / parent
--   方法: AddPage(name) / AddPageAt(name, index) / RemovePageAt(index)
--         GetPageNames() -> List<string> / SetSelectedIndex(index)
--   注意: 本版本没有 GetPageName / SetPageName / alias 相关接口，
--         页面改名通过 RemovePageAt + AddPageAt 原位重建实现。
--
-- 命令:
--   controller_list            列出控制器及全部页面
--   controller_create          新建控制器（可同时初始化页面）
--   controller_delete          删除控制器
--   controller_rename          重命名控制器
--   controller_set             切换当前页（索引或页名）
--   controller_add_page        新增页面（可指定插入位置）
--   controller_remove_page     删除页面
--   controller_rename_page     重命名页面
--   controller_reorder_page    调整页面顺序
--   controller_export          设置/取消“导出到代码”

local App = App
local U = dofile(_G._mcpUtilPath)

local C = {}

-- ---------- 基础工具 ----------

local function ctrls(content)
    return U.get(content, "controllers")
end

-- content.controllers 是可能含 null 空洞的 List，统一过滤成 Lua 数组（1 基）
local function ctrlArray(content)
    local out = {}
    U.each(ctrls(content), function(c) out[#out + 1] = c end)
    return out
end

local function ctrlKey(ctrl)
    return U.str(ctrl) or ""
end

local function ctrlByName(content, name)
    if not name then return nil end
    for _, c in ipairs(ctrlArray(content)) do
        if U.getStr(c, "name") == name then return c end
    end
    return nil
end

local function ctrlAt(content, index)
    local i = U.int(index)
    if i == nil or i < 0 then return nil end
    return ctrlArray(content)[i + 1]
end

-- GetPageNames() 返回的元素形如 "0:p_home"（<索引>:<页名>），这里剥掉索引前缀。
-- 页名本身可能含冒号，所以只在“冒号前全是数字”时剥离。
local function cleanPageName(s)
    s = U.str(s) or ""
    local head, rest = string.match(s, "^(%d+):(.*)$")
    if head then return rest end
    return s
end

local function pageNames(ctrl)
    local out = {}
    local ok, list = pcall(function() return ctrl:GetPageNames() end)
    if ok and list ~= nil then
        U.each(list, function(n, i)
            out[#out + 1] = { index = i, name = cleanPageName(n) }
        end)
    end
    return out
end

local function pageIndexOf(ctrl, pageName)
    local want = U.str(pageName)
    for _, p in ipairs(pageNames(ctrl)) do
        if p.name == want then return p.index end
    end
    return nil
end

local function describe(ctrl)
    local idx = U.getNum(ctrl, "selectedIndex")
    local sel = nil
    pcall(function() sel = ctrl.selectedPage end)
    return {
        name = U.getStr(ctrl, "name"),
        exported = U.getBool(ctrl, "exported") or false,
        selectedIndex = idx,
        selectedPage = U.str(sel),
        pageCount = U.getNum(ctrl, "pageCount") or 0,
        pages = pageNames(ctrl),
    }
end

local function resolveCtrl(content, params)
    params = params or {}
    local name = params.name or params.controller or params.controller_name
    if name then
        local c = ctrlByName(content, name)
        if c then return c end
        -- 名字找不到时，若给了 index 就按索引兜底
    end
    if params.index ~= nil then
        local c = ctrlAt(content, params.index)
        if c then return c end
        error("控制器索引不存在: " .. U.str(params.index))
    end
    if not name then error("缺少参数: name（控制器名）或 index") end
    error("控制器不存在: " .. U.str(name))
end

-- ---------- 命令 ----------

function C.handleControllerList(params, bridgePath)
    local content = U.content()
    local out = {}
    local arr = ctrlArray(content)
    for i, c in ipairs(arr) do
        local d = describe(c)
        d.index = i - 1
        out[#out + 1] = d
    end
    local rawCount = U.count(U.get(content, "controllers")) or 0
    local res = {
        count = #arr,
        controllers = out,
        rawCount = rawCount,
        holes = rawCount - #arr,
    }
    if res.holes > 0 then
        res.warning = "content.controllers 里有 " .. res.holes
            .. " 个 null 空洞（历史失败调用遗留），会导致基础插件 list_controllers 崩溃；"
            .. "执行 controller_persist 触发一次组件重载即可清掉"
    end
    return res
end

function C.handleControllerCreate(params, bridgePath)
    local content, doc = U.content()
    local name = params.name or params.controller
    if not name then error("缺少参数: name") end
    if ctrlByName(content, name) then error("控制器已存在: " .. U.str(name)) end

    -- AddController 的真实签名（从异常栈里读出来的）：
    --   FComponent.AddController(FairyEditor.FController controller, bool applyNow)
    -- 逐个形式实测结论：
    --   AddController({})        ✔ 真正新建（xLua 会把空表转成非空 FController）
    --   AddController({}, true)  ✔ 同上
    --   AddController("name")    ✘ invalid arguments
    --   AddController(nil)       ✘ NullReferenceException
    --   AddController()          ✘ invalid arguments
    -- 关键：**失败的调用也会往 content.controllers 里塞一个 null 空洞**，
    -- 空洞会让基础插件的 list_controllers 直接崩，所以这里只调用确定可用的那一种形式。
    local before = {}
    for _, c in ipairs(ctrlArray(content)) do before[ctrlKey(c)] = true end

    local okAdd, addErr = pcall(function() content:AddController({}) end)
    if not okAdd then
        error("新建控制器失败: " .. string.sub(U.str(addErr) or "", 1, 200))
    end

    local ctrl = nil
    for _, c in ipairs(ctrlArray(content)) do
        if not before[ctrlKey(c)] then ctrl = c end
    end
    if not ctrl then error("新建控制器失败：未能在列表中定位新建的控制器") end

    local steps = {}
    local function step(label, okk, e)
        steps[#steps + 1] = { step = label, ok = okk, error = (not okk) and U.str(e) or nil }
    end

    step("set name", U.set(ctrl, "name", name))
    if params.exported ~= nil then step("set exported", U.set(ctrl, "exported", U.bool(params.exported))) end

    -- 页面：未指定时给一页默认页
    local pages = params.pages
    if not U.isTable(pages) or #pages == 0 then
        pages = (params.page ~= nil) and { params.page } or { "page0" }
    end
    local added = {}
    for _, p in ipairs(pages) do
        local okAdd, errAdd = pcall(function() ctrl:AddPage(U.str(p)) end)
        added[#added + 1] = { name = U.str(p), ok = okAdd, error = (not okAdd) and U.str(errAdd) or nil }
    end

    pcall(function() ctrl:SetSelectedIndex(0) end)
    U.markDirty(doc, content)

    local info = describe(ctrl)
    info.steps = steps
    info.pagesAdded = added
    return info
end

function C.handleControllerDelete(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local info = describe(ctrl)
    local ok, err = pcall(function() content:RemoveController(ctrl) end)
    if not ok then error("删除控制器失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    return { deleted = true, name = info.name, pageCount = info.pageCount }
end

function C.handleControllerRename(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local newName = params.new_name or params.to
    if not newName then error("缺少参数: new_name") end
    if ctrlByName(content, newName) then error("控制器名已被占用: " .. U.str(newName)) end
    local old = U.getStr(ctrl, "name")
    local ok, err = U.set(ctrl, "name", newName)
    if not ok then error("重命名失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    return { renamed = true, old_name = old, new_name = U.getStr(ctrl, "name") }
end

function C.handleControllerSet(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local idx = U.int(params.page_index)
    if idx == nil and params.page_name ~= nil then
        idx = pageIndexOf(ctrl, params.page_name)
        if idx == nil then error("页面不存在: " .. U.str(params.page_name)) end
    end
    if idx == nil and params.page ~= nil then idx = U.int(params.page) end
    if idx == nil then error("缺少参数: page_index 或 page_name") end

    local total = U.getNum(ctrl, "pageCount") or 0
    if idx < 0 or idx >= total then
        error("页索引超出范围: " .. idx .. "（总页数: " .. total .. "）")
    end

    local old = U.getNum(ctrl, "selectedIndex")
    local ok, err = pcall(function() ctrl:SetSelectedIndex(idx) end)
    if not ok then ok, err = U.set(ctrl, "selectedIndex", idx) end
    if not ok then error("切换页面失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    return {
        switched = true,
        controller = U.getStr(ctrl, "name"),
        old_index = old,
        new_index = U.getNum(ctrl, "selectedIndex"),
        total_pages = total,
    }
end

function C.handleControllerAddPage(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local page = params.page_name or params.page_new or params.page
    if page == nil then error("缺少参数: page_name") end
    page = U.str(page)
    if pageIndexOf(ctrl, page) ~= nil then error("页面已存在: " .. page) end

    local idx = U.int(params.page_index or params.at)
    local ok, err
    if idx ~= nil then
        ok, err = pcall(function() ctrl:AddPageAt(page, idx) end)
    else
        ok, err = pcall(function() ctrl:AddPage(page) end)
    end
    if not ok then error("新增页面失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    local d = describe(ctrl)
    d.added_page = page
    d.added_at = idx
    return d
end

function C.handleControllerRemovePage(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local idx = U.int(params.page_index)
    if idx == nil and params.page_name ~= nil then
        idx = pageIndexOf(ctrl, params.page_name)
        if idx == nil then error("页面不存在: " .. U.str(params.page_name)) end
    end
    if idx == nil then error("缺少参数: page_index 或 page_name") end

    local total = U.getNum(ctrl, "pageCount") or 0
    if idx < 0 or idx >= total then error("页索引超出范围: " .. idx) end
    if total <= 1 then error("至少要保留一个页面，无法删除") end

    local removedName = nil
    for _, p in ipairs(pageNames(ctrl)) do
        if p.index == idx then removedName = p.name end
    end

    local ok, err = pcall(function() ctrl:RemovePageAt(idx) end)
    if not ok then error("删除页面失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    local d = describe(ctrl)
    d.removed_page = U.str(removedName)
    d.removed_index = idx
    return d
end

function C.handleControllerRenamePage(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local idx = U.int(params.page_index)
    if idx == nil and params.old_name ~= nil then
        idx = pageIndexOf(ctrl, params.old_name)
        if idx == nil then error("页面不存在: " .. U.str(params.old_name)) end
    end
    if idx == nil then error("缺少参数: page_index（或 old_name）") end
    local newName = params.new_name or params.to
    if not newName then error("缺少参数: new_name") end
    newName = U.str(newName)
    if pageIndexOf(ctrl, newName) ~= nil then error("页面名已存在: " .. newName) end

    -- 本版本没有 SetPageName，采用原位重建
    local oldName = nil
    for _, p in ipairs(pageNames(ctrl)) do
        if p.index == idx then oldName = p.name end
    end
    local ok1, err1 = pcall(function() ctrl:RemovePageAt(idx) end)
    if not ok1 then error("重命名页面失败（删除旧页时出错）: " .. U.str(err1)) end
    local ok2, err2 = pcall(function() ctrl:AddPageAt(newName, idx) end)
    if not ok2 then
        -- 回滚：把旧页加回去
        pcall(function() ctrl:AddPageAt(U.str(oldName), idx) end)
        error("重命名页面失败（插入新页时出错）: " .. U.str(err2))
    end

    U.markDirty(doc, content)
    local d = describe(ctrl)
    d.renamed_index = idx
    d.old_page = U.str(oldName)
    d.new_page = newName
    d.note = "页面改名通过原位重建实现，原页面上的齿轮绑定可能需要重新设置"
    return d
end

function C.handleControllerReorderPage(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local from = U.int(params.page_index or params.from)
    local to = U.int(params.to or params.target_index)
    if from == nil or to == nil then error("缺少参数: from / to（页索引）") end

    local total = U.getNum(ctrl, "pageCount") or 0
    if from < 0 or from >= total then error("from 越界: " .. from) end
    if to < 0 then to = 0 end
    if to > total - 1 then to = total - 1 end
    if from == to then return { reordered = false, reason = "from == to" } end

    local names = pageNames(ctrl)
    local moving = names[from + 1] and names[from + 1].name
    if not moving then error("无法读取待移动页面名") end

    local ok1, err1 = pcall(function() ctrl:RemovePageAt(from) end)
    if not ok1 then error("移动失败（删除原页）: " .. U.str(err1)) end
    local ok2, err2 = pcall(function() ctrl:AddPageAt(moving, to) end)
    if not ok2 then error("移动失败（插入新位置）: " .. U.str(err2)) end

    U.markDirty(doc, content)
    local d = describe(ctrl)
    d.moved = { from = from, to = to, page = moving }
    return d
end

function C.handleControllerExport(params, bridgePath)
    local content, doc = U.content()
    local ctrl = resolveCtrl(content, params)
    local exported = U.bool(params.exported)
    if exported == nil then exported = true end
    local ok, err = U.set(ctrl, "exported", exported)
    if not ok then error("设置导出标记失败: " .. U.str(err)) end
    U.markDirty(doc, content)
    return { controller = U.getStr(ctrl, "name"), exported = U.getBool(ctrl, "exported") }
end

-- ---------- XML 持久化 ----------
-- 背景：编辑器对 FController 的 name / pages 赋值只改内存，doc:Save() 落盘时
-- 写出来的是空壳（<controller name="" pages="" selected="-1"/>）。
-- 组件 XML 里控制器的格式（已用官方解析器与工程实例核对）：
--   <controller name="c1" alias="" exported="false" selected="0" pages="0,p0,1,p1"/>
--   pages 是 (页id, 页名) 成对拼接
-- 因此这里直接改 XML 文件再让文档重载，得到可持久化的控制器。

local function componentFilePath(doc)
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
    if not s then return nil end
    -- 去掉 UTF-8 BOM
    if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
    return s
end

local function writeText(path, text)
    local f = io.open(path, "wb")
    if not f then return false, "无法写入: " .. tostring(path) end
    f:write(text)
    f:close()
    return true
end

local function xmlEscape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return s
end

--- 把当前文档里的控制器状态写成 XML 片段
local function buildControllerXml(list)
    local parts = {}
    for _, c in ipairs(list) do
        local pairs_ = {}
        local idx = 0
        for _, p in ipairs(c.pages or {}) do
            pairs_[#pairs_ + 1] = tostring(idx)
            pairs_[#pairs_ + 1] = U.str(p) or ""
            idx = idx + 1
        end
        local attrs = {
            'name="' .. xmlEscape(c.name or "") .. '"',
            'pages="' .. xmlEscape(table.concat(pairs_, ",")) .. '"',
            'selected="' .. tostring(c.selected or 0) .. '"',
        }
        if c.alias and c.alias ~= "" then
            table.insert(attrs, 1, 'alias="' .. xmlEscape(c.alias) .. '"')
        end
        if c.exported then
            table.insert(attrs, 'exported="true"')
        end
        parts[#parts + 1] = "  <controller " .. table.concat(attrs, " ") .. "/>"
    end
    return parts
end

--- 用新的控制器块替换 XML 文本里的控制器块
local function replaceControllerBlocks(text, newLines)
    -- 匹配 <controller .../> 或 <controller ...> ... </controller>
    local spans = {}
    local pos = 1
    while true do
        local s = string.find(text, "<controller", pos, true)
        if not s then break end
        -- 找到该标签的结束位置
        local gt = string.find(text, ">", s, true)
        if not gt then break end
        local selfClose = (string.sub(text, gt - 1, gt - 1) == "/")
        local e = gt
        if not selfClose then
            local closeS, closeE = string.find(text, "</controller>", gt, true)
            if closeS then e = closeE end
        end
        -- 连同前面的缩进与换行一起替换
        local lineStart = s
        while lineStart > 1 do
            local ch = string.sub(text, lineStart - 1, lineStart - 1)
            if ch == "\n" or ch == "\r" then break end
            lineStart = lineStart - 1
        end
        spans[#spans + 1] = { s = lineStart, e = e }
        pos = e + 1
    end

    if #spans == 0 then
        -- 没有控制器节点：插到 <component ...> 之后
        local s, e = string.find(text, "<component[^>]*>")
        if not s then return nil, "未找到 <component> 根节点" end
        local block = ""
        if #newLines > 0 then block = "\n" .. table.concat(newLines, "\n") end
        return string.sub(text, 1, e) .. block .. string.sub(text, e + 1), nil
    end

    -- 用第一段到最末段整体替换（保留中间可能存在的其他节点？控制器是连续的，这里直接整体替换）
    local first, last = spans[1], spans[#spans]
    -- 把最后一段后面的换行也吃掉，避免留下空行
    if string.sub(text, last.e + 1, last.e + 1) == "\r" then last.e = last.e + 1 end
    if string.sub(text, last.e + 1, last.e + 1) == "\n" then last.e = last.e + 1 end
    local newBlock = table.concat(newLines, "\n")
    local out = string.sub(text, 1, first.s - 1) .. newBlock .. "\n" .. string.sub(text, last.e + 1)
    -- 清理可能产生的连续空行
    if #newLines == 0 then
        out = out:gsub("\n\n+", "\n")
    end
    return out, nil
end

function C.handleControllerPersist(params, bridgePath)
    local content, doc = U.content()
    local path, pi = componentFilePath(doc)
    if not path then error("无法定位当前组件的 XML 文件") end

    -- 1. 先把内存状态尽量落盘（元素改动等）
    pcall(function() doc:Save() end)
    local wait0 = os.clock()
    while os.clock() - wait0 < 0.15 do end

    -- 2. 采集内存中的控制器状态
    local list = {}
    for _, c in ipairs(ctrlArray(content)) do
        local d = describe(c)
        local names = {}
        for _, p in ipairs(pageNames(c)) do names[#names + 1] = p.name end
        list[#list + 1] = {
            name = d.name or "",
            alias = d.alias,
            exported = d.exported,
            selected = d.selectedIndex or 0,
            pages = names,
        }
    end

    -- 3. 改 XML
    local text = readText(path)
    if not text then error("无法读取组件文件: " .. path) end
    local newLines = buildControllerXml(list)
    local patched, err = replaceControllerBlocks(text, newLines)
    if not patched then error(err) end
    local okW, errW = writeText(path, patched)
    if not okW then error(errW) end

    -- 4. 让文档从磁盘重载，确认生效
    pcall(function() doc:DiscardChanges() end)
    local wait1 = os.clock()
    while os.clock() - wait1 < 0.50 do end

    local after = {}
    for _, c in ipairs(ctrlArray(U.content())) do
        local d = describe(c)
        local names = {}
        for _, p in ipairs(pageNames(c)) do names[#names + 1] = p.name end
        after[#after + 1] = { name = d.name, pageCount = d.pageCount, pages = names }
    end

    local res = {
        persisted = true,
        file = path,
        controllerCount = #list,
        written = list,
        readBack = after,
    }
    if #after ~= #list then
        res.note = "重载尚未完成，请稍后用 controller_list 复核"
    end
    return res
end

function C.register(CH)
    for k, v in pairs(C) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then
            CH[k] = v
        end
    end
end

return C
