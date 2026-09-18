-- MCPBridge 扩展 · 组件快照模块（AI 操作的安全网）
-- 说明：FairyEditor 的 ActionHistory 只记录编辑器自身 UI 操作产生的历史项，
-- 通过 Lua 直接改属性不会入栈，因此这里用"组件 XML 文件快照"提供可回滚能力。
-- 命令:
--   component_snapshot  为当前组件创建快照（默认先保存文档）
--   list_snapshots      列出已有快照
--   component_restore   从快照恢复（复制到组件文件后让文档丢弃改动重新加载）
--   delete_snapshot     删除快照

local App = App
local U = dofile(_G._mcpUtilPath)

local S = {}

local MAX_SNAPSHOTS = 30

local function snapshotDir(bridgePath)
    local p = (bridgePath or ""):gsub("/", "\\")
    if p == "" then return nil end
    return p .. "\\snapshots"
end

local function componentFile(doc)
    local pi = U.get(doc, "packageItem")
    if not pi then return nil, nil end
    local f = U.getStr(pi, "file")
    if not f or f == "" then return nil, nil end
    return f:gsub("/", "\\"), pi
end

function S.createSnapshot(doc, bridgePath, note)
    local dir = snapshotDir(bridgePath)
    local file, pi = componentFile(doc)
    if not dir or not file then return nil, "无法定位组件文件" end

    pcall(function()
        if not CS.System.IO.Directory.Exists(dir) then
            CS.System.IO.Directory.CreateDirectory(dir)
        end
    end)

    local pkgName = U.getStr(U.get(pi, "owner"), "name") or "pkg"
    local compName = U.getStr(pi, "name") or "comp"
    local stamp = os.date("%Y%m%d_%H%M%S")
    local safeNote = ""
    if note and note ~= "" then
        safeNote = "_" .. tostring(note):gsub("[^%w%-%_]", "_")
    end
    local target = dir .. "\\" .. pkgName .. "_" .. compName .. "_" .. stamp .. safeNote .. ".xml"

    local ok, err = pcall(function()
        CS.System.IO.File.Copy(file, target, true)
    end)
    if not ok then return nil, "复制失败: " .. U.str(err) end

    -- 清理旧快照（只保留最近 MAX_SNAPSHOTS 个）
    pcall(function()
        local files = CS.System.IO.Directory.GetFiles(dir, "*.xml")
        if files and U.count(files) > MAX_SNAPSHOTS then
            local arr = {}
            U.each(files, function(f) arr[#arr + 1] = f end)
            table.sort(arr, function(a, b) return a > b end)
            for i = MAX_SNAPSHOTS + 1, #arr do
                pcall(function() CS.System.IO.File.Delete(arr[i]) end)
            end
        end
    end)

    return target, nil
end

-- 把当前文档写盘。
-- 快照/回滚都是基于组件 XML 文件做的，而 Lua 直接改的属性只在内存里，
-- 所以必须先 doc:Save() 把内存状态刷到磁盘，否则快照内容会滞后。
function S.flushDoc(doc)
    -- 注意：编辑器的“已修改”标记属性名未暴露（doc.modified 读不到），
    -- 所以这里无脑 Save() —— 对未修改的文档是个廉价空操作。
    local ok = pcall(function() doc:Save() end)
    if not ok then return false, "Save 调用失败" end

    -- Save 落盘是异步的，短暂等待后确认
    local t0 = os.clock()
    while os.clock() - t0 < 0.20 do end

    pcall(function() doc:Save() end)
    local t1 = os.clock()
    while os.clock() - t1 < 0.10 do end
    return true, nil
end

function S.autoSnapshot(doc, bridgePath, note)
    S.flushDoc(doc)
    local target, err = S.createSnapshot(doc, bridgePath, note)
    return target, err
end

-- ========== 命令 ==========

function S.handleComponentSnapshot(params, bridgePath)
    local doc = U.requireDoc()
    local doSave = U.bool(params.save)
    if doSave == nil then doSave = true end
    local saved, saveNote = true, nil
    if doSave then saved, saveNote = S.flushDoc(doc) end

    local target, err = S.createSnapshot(doc, bridgePath, params.note)
    if not target then error(err) end
    return {
        snapshot = target, note = U.str(params.note),
        saved = saved, save_note = saveNote,
        modified = U.getBool(doc, "modified"),
    }
end

function S.handleListSnapshots(params, bridgePath)
    local dir = snapshotDir(bridgePath)
    if not dir then return { snapshots = {}, count = 0 } end
    local out = {}
    pcall(function()
        if not CS.System.IO.Directory.Exists(dir) then return end
        local files = CS.System.IO.Directory.GetFiles(dir, "*.xml")
        U.each(files, function(f)
            local name = tostring(f):match("([^\\]+)$") or tostring(f)
            local size = 0
            pcall(function()
                local info = CS.System.IO.FileInfo(f)
                size = info.Length
            end)
            local t = nil
            pcall(function() t = tostring(CS.System.IO.File.GetLastWriteTime(f)) end)
            out[#out + 1] = { name = name, path = tostring(f), size = size, modified = t }
        end)
    end)
    table.sort(out, function(a, b) return (a.name or "") > (b.name or "") end)
    return { snapshots = out, count = #out }
end

function S.handleComponentRestore(params, bridgePath)
    local doc = U.requireDoc()
    local dir = snapshotDir(bridgePath)
    local file = componentFile(doc)
    if not dir or not file then error("无法定位组件文件") end

    local source = params.snapshot
    if not source or source == "" then
        -- 未指定则取最新快照
        local latest = nil
        pcall(function()
            local files = CS.System.IO.Directory.GetFiles(dir, "*.xml")
            local arr = {}
            U.each(files, function(f) arr[#arr + 1] = tostring(f) end)
            table.sort(arr, function(a, b) return a > b end)
            latest = arr[1]
        end)
        if not latest then error("没有可用快照") end
        source = latest
    else
        local asPath = source
        if not CS.System.IO.File.Exists(asPath) then
            asPath = dir .. "\\" .. source
        end
        if not CS.System.IO.File.Exists(asPath) then
            error("快照不存在: " .. tostring(source))
        end
        source = asPath
    end

    -- 恢复前先给当前状态也留一份快照
    pcall(function() S.createSnapshot(doc, bridgePath, "before_restore") end)

    local ok, err = pcall(function()
        CS.System.IO.File.Copy(source, file, true)
    end)
    if not ok then error("恢复失败: " .. U.str(err)) end

    -- 让文档从磁盘重新加载
    local okDiscard = pcall(function() doc:DiscardChanges() end)
    return { restored = true, from = tostring(source), to = file, discarded = okDiscard }
end

function S.handleDeleteSnapshot(params, bridgePath)
    local dir = snapshotDir(bridgePath)
    local name = params.snapshot or params.name
    if not name then error("缺少参数: snapshot") end
    local path = name
    if not CS.System.IO.File.Exists(path) then path = dir .. "\\" .. name end
    if not CS.System.IO.File.Exists(path) then error("快照不存在: " .. tostring(name)) end
    pcall(function() CS.System.IO.File.Delete(path) end)
    return { deleted = true, snapshot = path }
end

function S.register(CH)
    for k, v in pairs(S) do
        if type(v) == "function" and k:sub(1, 6) == "handle" then CH[k] = v end
    end
end

return S
