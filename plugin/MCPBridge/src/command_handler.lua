-- MCPBridge 命令处理器
-- 处理来自 MCP 服务的命令并返回结果

local CommandHandler = {}

-- 已处理的命令 ID 集合（防止重复处理）
local processedCommands = {}

-- ========== 辅助函数 ==========

-- 辅助函数：从 C# Dictionary 获取值
local function getDictValue(dict, key)
    local value = nil
    pcall(function()
        value = dict:get_Item(key)
    end)
    return value
end

-- 辅助函数：将 C# Dictionary/Hashtable 转换为 Lua table
local function csharpToLua(obj)
    if obj == nil then return nil end

    local t = type(obj)
    if t == "string" or t == "number" or t == "boolean" then
        return obj
    end

    -- 检查是否是 C# Dictionary/Hashtable
    if obj.Keys then
        local result = {}
        local enumerator = obj.Keys:GetEnumerator()
        while enumerator:MoveNext() do
            local key = enumerator.Current
            local value = obj:get_Item(key)
            result[key] = csharpToLua(value)
        end
        return result
    end

    return obj
end

-- 辅助函数：使用 GetScreenShot 截取 DisplayObject 并保存为 PNG
-- 支持可选的裁剪区域（cropX, cropY, cropW, cropH）
-- 返回 true 表示成功，false 表示失败
local function captureDisplayObject(displayObj, screenshotPath, scale, cropX, cropY, cropW, cropH)
    scale = scale or 1
    -- 调用 GetScreenShot 获取 Texture2D
    local texture = displayObj:GetScreenShot(nil, scale)
    if not texture then
        error("GetScreenShot 返回 nil，无法截取")
    end

    -- 调试：打印实际返回的 texture 尺寸 vs displayObject 尺寸
    pcall(function()
        fprint(string.format("[MCPBridge] DisplayObject %sx%s, Texture %sx%s",
            tostring(displayObj.width or 0), tostring(displayObj.height or 0),
            tostring(texture.width or 0), tostring(texture.height or 0)))
    end)

    local ok, err = pcall(function()
        local saveTexture = texture
        local needCrop = cropX and cropY and cropW and cropH

        if needCrop then
            -- 创建裁剪后的纹理
            -- Unity Texture2D 的 Y 轴是从下到上，需要翻转
            local texH = texture.height
            local cropYFlipped = texH - cropY - cropH
            local pixels = texture:GetPixels(math.floor(cropX), math.floor(cropYFlipped),
                math.floor(cropW), math.floor(cropH))
            local cropped = CS.UnityEngine.Texture2D(math.floor(cropW), math.floor(cropH))
            cropped:SetPixels(pixels)
            cropped:Apply()
            saveTexture = cropped
            fprint(string.format("[MCPBridge] 裁剪到 %dx%d at (%d,%d)",
                math.floor(cropW), math.floor(cropH), math.floor(cropX), math.floor(cropY)))
        end

        -- 编码为 PNG
        local pngBytes = CS.UnityEngine.ImageConversion.EncodeToPNG(saveTexture)
        -- 写入文件
        CS.System.IO.File.WriteAllBytes(screenshotPath, pngBytes)

        -- 释放裁剪纹理
        if needCrop then
            CS.UnityEngine.Object.Destroy(saveTexture)
        end
    end)

    -- 释放 Texture2D
    CS.UnityEngine.Object.Destroy(texture)

    if not ok then
        error("截图保存失败: " .. tostring(err))
    end
    return true
end

-- ========== 初始化 ==========

-- 初始化通信目录
function CommandHandler.initBridge(bridgePath)
    -- 转换路径分隔符（Windows 兼容）
    bridgePath = bridgePath:gsub("/", "\\")
    local dirs = {"\\commands", "\\results", "\\screenshots"}
    for _, dir in ipairs(dirs) do
        local fullPath = bridgePath .. dir
        -- 使用 C# System.IO 创建目录
        if not CS.System.IO.Directory.Exists(fullPath) then
            CS.System.IO.Directory.CreateDirectory(fullPath)
        end
    end
    fprint("[MCPBridge] 通信目录已初始化: " .. bridgePath)
end

-- ========== 轮询 ==========

-- 轮询命令
function CommandHandler.poll(bridgePath)
    -- 转换路径分隔符（Windows 兼容）
    local commandsDir = bridgePath:gsub("/", "\\") .. "\\commands"

    -- 检查目录是否存在
    if not CS.System.IO.Directory.Exists(commandsDir) then
        return
    end

    -- 遍历命令文件
    local files = CS.System.IO.Directory.GetFiles(commandsDir, "*.json")
    if not files or files.Length == 0 then
        return
    end

    fprint("[MCPBridge] 发现 " .. files.Length .. " 个待处理命令")

    for i = 0, files.Length - 1 do
        local filePath = files[i]
        local fileName = CS.System.IO.Path.GetFileNameWithoutExtension(filePath)

        -- 跳过已处理的命令
        if processedCommands[fileName] then
            goto continue
        end

        -- 读取并执行命令
        local success, content = pcall(function()
            local f = io.open(filePath, "r")
            if f then
                local txt = f:read("*a")
                f:close()
                return txt
            end
            return nil
        end)

        if success and content then
            -- 调试：打印原始内容
            fprint("[MCPBridge] 原始内容长度: " .. #content)
            fprint("[MCPBridge] 原始内容: " .. string.sub(content, 1, 200))

            -- 解析 JSON
            local jsonOk, cmd = pcall(function()
                return CS.FairyEditor.JsonUtil.DecodeJson(content)
            end)

            if not jsonOk then
                fprint("[MCPBridge] JSON 解析失败: " .. tostring(cmd))
            end

            if jsonOk and cmd then
                -- FairyGUI 的 JsonUtil.DecodeJson 返回 C# Dictionary
                local action = nil
                local cmdId = nil
                local params = {}

                -- 遍历 Keys 集合获取值
                if cmd.Keys then
                    local enumerator = cmd.Keys:GetEnumerator()
                    while enumerator:MoveNext() do
                        local key = enumerator.Current
                        local value = nil
                        pcall(function()
                            value = cmd:get_Item(key)
                        end)
                        if key == "action" then action = value end
                        if key == "id" then cmdId = value end
                        if key == "params" then params = csharpToLua(value) or {} end
                    end
                end

                fprint("[MCPBridge] 收到命令: " .. (action or "unknown"))

                -- 执行命令
                local result = CommandHandler.execute(cmd, bridgePath)

                -- 写入结果
                CommandHandler.writeResult(bridgePath, fileName, result)

                -- 命令执行完毕后重置 runInBackground
                -- 确保即使 F5 等模式在 handler 内部覆盖了此值，也能恢复
                CS.UnityEngine.Application.runInBackground = true

                -- 标记为已处理
                processedCommands[fileName] = true

                -- 清理旧记录（保留最近 100 个）
                local count = 0
                for _ in pairs(processedCommands) do count = count + 1 end
                if count > 100 then
                    processedCommands = {}
                end
            end
        end

        -- 删除命令文件
        pcall(function()
            CS.FairyEditor.IOUtil.DeleteFile(filePath, false)
        end)

        ::continue::
    end
end

-- ========== 命令执行 ==========

-- 执行命令
function CommandHandler.execute(cmd, bridgePath)
    -- FairyGUI 的 JsonUtil.DecodeJson 返回 C# Dictionary
    local action = getDictValue(cmd, "action")
    local rawParams = getDictValue(cmd, "params") or {}
    local cmdId = getDictValue(cmd, "id")

    -- 将 params 转换为 Lua table
    local params = csharpToLua(rawParams)

    -- 命令处理器映射
    local handlers = {
        ["activate"] = CommandHandler.handleActivate,
        ["reload"] = CommandHandler.handleReload,
        ["open_component"] = CommandHandler.handleOpenComponent,
        ["preview"] = CommandHandler.handlePreview,
        ["screenshot"] = CommandHandler.handleScreenshot,
        ["get_selection"] = CommandHandler.handleGetSelection,
        ["save"] = CommandHandler.handleSave,
        ["close"] = CommandHandler.handleClose,
        ["get_component_info"] = CommandHandler.handleGetComponentInfo,
        ["list_packages"] = CommandHandler.handleListPackages,
        ["list_components"] = CommandHandler.handleListComponents,
        ["start_test"] = CommandHandler.handleStartTest,
        ["stop_test"] = CommandHandler.handleStopTest,
        ["switch_device"] = CommandHandler.handleSwitchDevice,
        ["capture_preview"] = CommandHandler.handleCapturePreview,
        ["list_devices"] = CommandHandler.handleListDevices,
        ["switch_controller"] = CommandHandler.handleSwitchController,
        ["list_controllers"] = CommandHandler.handleListControllers,
        ["select_element"] = CommandHandler.handleSelectElement,
        ["probe_plugin_api"] = CommandHandler.handleProbePluginApi,
        ["probe_publish"] = CommandHandler.handleProbePublish,
        ["open_publish_settings"] = CommandHandler.handleOpenPublishSettings,
        ["publish_package"] = CommandHandler.handlePublishPackage,
        ["publish_all"] = CommandHandler.handlePublishAll,
        -- 日志管理（暂未启用）
        -- ["get_logs"] = CommandHandler.handleGetLogs,
        -- ["clear_logs"] = CommandHandler.handleClearLogs,
        -- ["probe_logs"] = CommandHandler.handleProbeLogs,
    }

    local handler = handlers[action]
    if not handler then
        return {
            id = cmdId,
            status = "error",
            error = "未知命令: " .. (action or "nil")
        }
    end

    -- 执行处理器
    local success, result = pcall(function()
        return handler(params, bridgePath)
    end)

    if success then
        return {
            id = cmdId,
            status = "success",
            data = result
        }
    else
        return {
            id = cmdId,
            status = "error",
            error = tostring(result)
        }
    end
end

-- 写入结果
function CommandHandler.writeResult(bridgePath, cmdId, result)
    local resultPath = bridgePath:gsub("/", "\\") .. "\\results\\" .. cmdId .. ".json"

    -- 手动构建 JSON 字符串
    local function tableToJson(t, indent)
        indent = indent or 0
        local spaces = string.rep("  ", indent)
        local nextSpaces = string.rep("  ", indent + 1)

        if type(t) ~= "table" then
            if type(t) == "string" then
                -- 转义特殊字符
                local escaped = t
                    :gsub("\\", "\\\\")
                    :gsub('"', '\\"')
                    :gsub("\n", "\\n")
                    :gsub("\r", "\\r")
                    :gsub("\t", "\\t")
                return '"' .. escaped .. '"'
            elseif type(t) == "number" or type(t) == "boolean" then
                return tostring(t)
            else
                return "null"
            end
        end

        -- 检查是否是数组
        local isArray = true
        local maxIndex = 0
        for k, v in pairs(t) do
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxIndex then maxIndex = k end
        end

        if isArray and maxIndex > 0 then
            local parts = {}
            for i = 1, maxIndex do
                parts[#parts + 1] = nextSpaces .. tableToJson(t[i], indent + 1)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "]"
        else
            local parts = {}
            for k, v in pairs(t) do
                local keyStr = type(k) == "string" and k or tostring(k)
                parts[#parts + 1] = nextSpaces .. '"' .. keyStr .. '": ' .. tableToJson(v, indent + 1)
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "}"
        end
    end

    local success, err = pcall(function()
        local content = tableToJson(result)
        local f = io.open(resultPath, "w")
        if f then
            f:write(content)
            f:close()
        else
            fprint("[MCPBridge] 无法写入结果文件: " .. resultPath)
        end
    end)

    if not success then
        fprint("[MCPBridge] 写入结果失败: " .. tostring(err))
    end
end

-- ========== 命令处理器实现 ==========

-- 激活编辑器
function CommandHandler.handleActivate(params, bridgePath)
    -- Lua 侧无法直接激活窗口，Python 端通过 Win32 API 负责激活
    -- 此处仅设置 runInBackground 确保定时器持续运行
    local ok, err = pcall(function()
        CS.UnityEngine.Application.runInBackground = true
    end)
    if ok then
        return { activated = false, reason = "Lua cannot activate window; Python Win32 handles activation", runInBackground = true }
    else
        return { activated = false, reason = "failed to set runInBackground: " .. tostring(err) }
    end
end

-- 刷新资源
function CommandHandler.handleReload(params, bridgePath)
    if params.package_name then
        local pkg = App.project:GetPackageByName(params.package_name)
        if pkg then
            -- FIX-1: 逐级尝试所有刷新方式，不再在第一次成功 pcall 后停止
            -- pkg:Touch() 可能返回成功但编辑器无视觉变化，需要组合多种方式
            local methodsAttempted = {}
            local methodsSucceeded = {}

            -- 方式1: pkg:Touch() — 标记包为需要刷新
            local ok1 = pcall(function() pkg:Touch() end)
            table.insert(methodsAttempted, "pkg:Touch()")
            if ok1 then
                table.insert(methodsSucceeded, "pkg:Touch()")
                fprint("[MCPBridge] reload: pkg:Touch() ok")
            end

            -- 方式2: pkg:Reload()（如果存在）
            local ok2 = pcall(function() pkg:Reload() end)
            table.insert(methodsAttempted, "pkg:Reload()")
            if ok2 then
                table.insert(methodsSucceeded, "pkg:Reload()")
                fprint("[MCPBridge] reload: pkg:Reload() ok")
            end

            -- 方式3: 遍历 pkg.items 并对每个 item 调用 Touch()
            local ok3 = pcall(function()
                local items = pkg.items
                if items and items.Count > 0 then
                    for i = 0, items.Count - 1 do
                        local item = items[i]
                        pcall(function() item:Touch() end)
                    end
                end
            end)
            table.insert(methodsAttempted, "item:Touch() all")
            if ok3 then
                table.insert(methodsSucceeded, "item:Touch() all")
                fprint("[MCPBridge] reload: item:Touch() on all items ok")
            end

            -- 方式4: App.project:RefreshPackage(pkg)
            local ok4 = pcall(function() App.project:RefreshPackage(pkg) end)
            table.insert(methodsAttempted, "project:RefreshPackage")
            if ok4 then
                table.insert(methodsSucceeded, "project:RefreshPackage")
                fprint("[MCPBridge] reload: project:RefreshPackage() ok")
            end

            -- 方式5: 延迟 0.2s 后再执行一次 Touch()（给编辑器时间处理前面的标记）
            local ok5 = pcall(function()
                CS.FairyGUI.Timers.inst:Add(0.2, 1, function()
                    pcall(function() pkg:Touch() end)
                    fprint("[MCPBridge] reload: delayed pkg:Touch() executed")
                end)
            end)
            table.insert(methodsAttempted, "delayed pkg:Touch()")
            if ok5 then
                table.insert(methodsSucceeded, "delayed pkg:Touch()")
                fprint("[MCPBridge] reload: delayed pkg:Touch() scheduled")
            end

            local anySucceeded = #methodsSucceeded > 0
            return {
                reloaded = anySucceeded,
                package = params.package_name,
                methods_attempted = table.concat(methodsAttempted, "; "),
                methods_succeeded = table.concat(methodsSucceeded, "; "),
                note = anySucceeded and "已尝试多种刷新方式，请检查编辑器是否有视觉变化"
                        or "所有刷新方式均不可用"
            }
        else
            error("包不存在: " .. params.package_name)
        end
    else
        -- 全量刷新：使用定时器异步执行，避免阻塞主线程和 poll 轮询
        -- 立即返回成功，让调用方知道命令已接收
        CS.FairyGUI.Timers.inst:Add(0.1, 1, function()
            fprint("[MCPBridge] 正在执行 App.RefreshProject...")
            pcall(function()
                App.RefreshProject()
            end)
            fprint("[MCPBridge] App.RefreshProject 完成")
        end)
        return { reloaded = true, async = true, message = "全量刷新已异步触发" }
    end
end

-- 辅助函数：在包中查找组件（支持路径和纯名称）
-- 路径格式：Buttons/Button01 或 Button01
local function findComponentItem(pkg, compName)
    -- 纯名称查找（向后兼容）
    local item = pkg:FindItemByName(compName)
    if item then return item end

    -- 尝试带 .xml 后缀
    item = pkg:GetItemByFileName(pkg.rootItem, compName .. ".xml")
    if item then return item end

    -- 路径格式：递归遍历 rootItem 匹配完整路径
    local pathParts = {}
    for part in compName:gmatch("[^/]+") do
        table.insert(pathParts, part)
    end

    if #pathParts > 1 then
        local fileName = pathParts[#pathParts] .. ".xml"
        local dirParts = {}
        for i = 1, #pathParts - 1 do
            table.insert(dirParts, pathParts[i])
        end

        -- 递归遍历查找
        local function searchInFolder(parentItem, dirIndex)
            if dirIndex > #dirParts then
                -- 已在目标目录，查找文件
                return pkg:GetItemByFileName(parentItem, fileName)
            end
            -- 查找当前层级的目录
            local targetDir = dirParts[dirIndex]
            if parentItem and parentItem.children then
                for i = 0, parentItem.children.Count - 1 do
                    local child = parentItem.children[i]
                    if child and child.type == "folder" and child.name == targetDir then
                        return searchInFolder(child, dirIndex + 1)
                    end
                end
            end
            return nil
        end

        item = searchInFolder(pkg.rootItem, 1)
        if item then return item end
    end

    return nil
end

-- 打开组件
function CommandHandler.handleOpenComponent(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 打开文档
    local url = item:GetURL()
    App.docView:OpenDocument(url, true)

    return {
        opened = true,
        url = url,
        name = item.name,
        path = item.path
    }
end

-- 预览组件
function CommandHandler.handlePreview(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 显示预览
    App.ShowPreview(item)

    return {
        previewing = true,
        url = item:GetURL(),
        name = item.name
    }
end

-- 截图
function CommandHandler.handleScreenshot(params, bridgePath)
    local target = params.target or "editor"
    local saveName = params.save_name or ("screenshot_" .. os.time())
    local scale = params.scale or 1

    local screenshotPath = bridgePath:gsub("/", "\\") .. "\\screenshots\\" .. saveName .. ".png"

    if target == "preview" then
        -- 使用 GetScreenShot 精确截取当前打开组件的画布渲染
        local doc = App.activeDoc
        if not doc then
            error("没有打开的文档，无法截取组件画布")
        end
        local content = doc.content
        if not content then
            error("文档内容为空")
        end
        local displayObj = content.displayObject
        if not displayObj then
            error("组件 displayObject 为空")
        end

        -- 收集调试信息
        local debugInfo = {}
        table.insert(debugInfo, "content_size=" .. content.width .. "x" .. content.height)
        table.insert(debugInfo, "dobj_size=" .. displayObj.width .. "x" .. displayObj.height)
        pcall(function()
            local b = displayObj:GetBounds(nil)
            table.insert(debugInfo, "dobj_bounds=" .. b.x .. "," .. b.y .. "," .. b.width .. "," .. b.height)
        end)
        pcall(function()
            if displayObj.numChildren then
                table.insert(debugInfo, "dobj_children=" .. displayObj.numChildren)
                for i = 0, math.min(displayObj.numChildren - 1, 5) do
                    local child = displayObj:GetChildAt(i)
                    if child then
                        table.insert(debugInfo, "child" .. i .. "=" .. child.width .. "x" .. child.height)
                    end
                end
            end
        end)

        captureDisplayObject(displayObj, screenshotPath, scale)

        local debugText = table.concat(debugInfo, "|")
        return {
            screenshot = saveName .. ".png",
            path = screenshotPath,
            captured = true,
            debug = debugText
        }
    else
        -- target="editor": 返回标记，由 Python 端使用 Win32 API 截取全屏
        return {
            screenshot = saveName .. ".png",
            path = screenshotPath,
            captured = false,
            use_python_capture = true,
            message = "editor 模式由 Python 端截取"
        }
    end
end

-- 获取选中元素
function CommandHandler.handleGetSelection(params, bridgePath)
    local doc = App.activeDoc
    if not doc then
        return { selection = {}, message = "没有打开的文档" }
    end

    local selection = doc:GetSelection()
    local result = {}

    if selection and selection.Count > 0 then
        for i = 0, selection.Count - 1 do
            local obj = selection[i]
            if obj then
                table.insert(result, {
                    id = obj.id or "",
                    name = obj.name or "",
                    type = obj.objectType or "unknown"
                })
            end
        end
    end

    return { selection = result, count = #result }
end

-- 保存文档
function CommandHandler.handleSave(params, bridgePath)
    local doc = App.activeDoc
    if doc then
        doc:Save()
        return { saved = true }
    end
    return { saved = false, message = "没有打开的文档" }
end

-- 关闭文档
function CommandHandler.handleClose(params, bridgePath)
    local doc = App.activeDoc
    if doc then
        App.docView:CloseDocument(doc)
        return { closed = true }
    end
    return { closed = false, message = "没有打开的文档" }
end

-- 获取组件信息
function CommandHandler.handleGetComponentInfo(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    return {
        name = item.name,
        id = item.id,
        type = item.type,
        width = item.width,
        height = item.height,
        path = item.path,
        url = item:GetURL(),
        exported = item.exported
    }
end

-- 列出所有包
function CommandHandler.handleListPackages(params, bridgePath)
    local packages = {}
    local allPackages = App.project.allPackages

    if allPackages then
        for i = 0, allPackages.Count - 1 do
            local pkg = allPackages[i]
            table.insert(packages, {
                name = pkg.name,
                id = pkg.id,
                path = pkg.basePath
            })
        end
    end

    return { packages = packages, count = #packages }
end

-- 列出包内组件
function CommandHandler.handleListComponents(params, bridgePath)
    local pkgName = params.package_name
    if not pkgName then
        error("缺少参数: package_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local components = {}
    local items = pkg.items

    if items then
        for i = 0, items.Count - 1 do
            local item = items[i]
            if item.type == "component" then
                table.insert(components, {
                    name = item.name,
                    id = item.id,
                    path = item.path,
                    width = item.width,
                    height = item.height,
                    exported = item.exported
                })
            end
        end
    end

    return { components = components, count = #components, package = pkgName }
end

-- ========== 预览测试命令 ==========

-- 辅助函数：从适配设置中查找设备信息
-- 返回 { resolutionX, resolutionY, found, scaleMode, screenMatchMode } 或 nil
local function findDeviceInfo(deviceName)
    if not deviceName then return nil end

    local adaptSettings = App.project:GetSettings("Adaptation")
    if not adaptSettings then return nil end

    local function searchInList(devices)
        if not devices then return nil end
        for i = 0, devices.Count - 1 do
            local dev = devices[i]
            if dev.name == deviceName then
                return dev
            end
        end
        return nil
    end

    local dev = searchInList(adaptSettings.defaultDevices) or searchInList(adaptSettings.devices)
    if dev then
        return {
            resolutionX = dev.resolutionX,
            resolutionY = dev.resolutionY,
            found = true,
            scaleMode = adaptSettings.scaleMode,
            screenMatchMode = adaptSettings.screenMatchMode,
            designX = adaptSettings.designResolutionX,
            designY = adaptSettings.designResolutionY
        }
    end
    return nil
end

-- 辅助函数：探查 testView 运行时的内部结构（用于调试设备切换和截图）
local function probeTestViewInternals(testView)
    local info = {}
    table.insert(info, "type=" .. tostring(testView:GetType()))
    table.insert(info, "running=" .. tostring(testView.running))
    table.insert(info, "visible=" .. tostring(testView.visible))
    table.insert(info, "size=" .. testView.width .. "x" .. testView.height)
    table.insert(info, "viewSize=" .. (testView.viewWidth or 0) .. "x" .. (testView.viewHeight or 0))
    table.insert(info, "numChildren=" .. tostring(testView.numChildren))

    -- 遍历子元素
    for i = 0, (testView.numChildren or 0) - 1 do
        local child = testView:GetChildAt(i)
        if child then
            local childInfo = string.format(
                "child%d: name=%s type=%s size=%dx%d visible=%s",
                i, child.name or "", tostring(child:GetType()),
                child.width, child.height, tostring(child.visible)
            )
            table.insert(info, childInfo)
        end
    end

    -- 探查内部属性
    local internalProps = {
        "stage", "Stage", "_stage", "content", "Content", "_content",
        "contentPane", "ContentPane", "_contentPane",
        "mainContainer", "_mainContainer", "viewPanel", "_viewPanel",
        "frame", "Frame",
        "displayObject", "DisplayObject", "_displayObject",
        "viewWidth", "viewHeight", "ViewWidth", "ViewHeight",
    }
    for _, prop in ipairs(internalProps) do
        local ok, val = pcall(function() return testView[prop] end)
        if ok and val ~= nil then
            local vtype = type(val)
            local vstr = tostring(val)
            if vtype == "userdata" then
                pcall(function()
                    vstr = string.format("%s (%.0fx%.0f)", tostring(val:GetType()), val.width, val.height)
                end)
            end
            table.insert(info, prop .. "=" .. vstr .. " [" .. vtype .. "]")
        end
    end

    -- 探查内部方法
    local internalMethods = {
        "SetSize", "setSize", "SetScale", "setScale",
        "Refresh", "refresh", "Repaint", "repaint",
        "UpdateSize", "updateSize", "ApplyDevice", "applyDevice",
    }
    for _, method in ipairs(internalMethods) do
        local ok, val = pcall(function() return testView[method] end)
        if ok and val ~= nil then
            table.insert(info, method .. "=[method:" .. type(val) .. "]")
        end
    end

    return table.concat(info, "\n")
end

-- 辅助函数：保存 testView 原始尺寸/缩放（用于恢复）
local mTestViewState = nil

local function saveTestViewState(testView)
    if mTestViewState then return end  -- 已保存，不重复
    mTestViewState = {
        viewWidth = testView.viewWidth or testView.width or 0,
        viewHeight = testView.viewHeight or testView.height or 0,
        width = testView.width or 0,
        height = testView.height or 0,
    }
    -- 保存 contentPane 状态
    pcall(function()
        local cp = testView.contentPane
        if cp then
            mTestViewState.cpWidth = cp.width
            mTestViewState.cpHeight = cp.height
            mTestViewState.cpScaleX = cp.scaleX or 1
            mTestViewState.cpScaleY = cp.scaleY or 1
        end
    end)
    fprint("[MCPBridge] 已保存 testView 原始状态: " ..
        string.format("view=%dx%d, content=%.0fx%.0f",
            mTestViewState.viewWidth, mTestViewState.viewHeight,
            mTestViewState.cpWidth or 0, mTestViewState.cpHeight or 0))
end

local function restoreTestViewState(testView)
    if not mTestViewState then return end
    pcall(function()
        if mTestViewState.viewWidth > 0 then
            testView.viewWidth = mTestViewState.viewWidth
        end
        if mTestViewState.viewHeight > 0 then
            testView.viewHeight = mTestViewState.viewHeight
        end
    end)
    -- 恢复 contentPane 状态
    pcall(function()
        local cp = testView.contentPane
        if cp and mTestViewState.cpWidth then
            cp:SetSize(mTestViewState.cpWidth, mTestViewState.cpHeight)
            cp:SetScale(mTestViewState.cpScaleX, mTestViewState.cpScaleY)
        end
    end)
    fprint("[MCPBridge] 已恢复 testView 原始状态")
    mTestViewState = nil
end

-- 辅助函数：设置 testView 的预览设备分辨率
-- Bug1 修复：绝对不调用 GRoot.inst:SetContentScaleFactor()，只影响 testView.contentPane
-- 返回 succeeded, methodsList
local function applyTestViewDevice(testView, resX, resY, scaleMode, screenMatchMode)
    local succeeded = false
    local methods = {}

    -- 策略1: 获取 contentPane 并设置其尺寸（最精确，只影响预览内容）
    local contentPane = nil
    pcall(function() contentPane = testView.contentPane end)
    if not contentPane then pcall(function() contentPane = testView.ContentPane end) end

    if contentPane then
        local ok1 = pcall(function()
            contentPane:SetSize(resX, resY)
        end)
        table.insert(methods, "contentPane:SetSize(" .. resX .. "," .. resY .. ")")
        if ok1 then succeeded = true end
    end

    -- 策略2: 设置 contentPane 的缩放比
    if contentPane and not succeeded then
        local adaptSettings = App.project:GetSettings("Adaptation")
        local designX = 0
        local designY = 0
        pcall(function()
            designX = adaptSettings.designResolutionX or 0
            designY = adaptSettings.designResolutionY or 0
        end)
        if designX > 0 and designY > 0 then
            local scaleX = resX / designX
            local scaleY = resY / designY
            local ok2 = pcall(function()
                contentPane:SetScale(scaleX, scaleY)
            end)
            table.insert(methods, "contentPane:SetScale(" .. string.format("%.3f", scaleX) .. "," .. string.format("%.3f", scaleY) .. ")")
            if ok2 then succeeded = true end
        end
    end

    -- 策略3: 设置 testView 的 viewWidth/viewHeight
    if not succeeded then
        local ok3 = pcall(function()
            testView.viewWidth = resX
            testView.viewHeight = resY
        end)
        table.insert(methods, "testView.viewWidth/Height=" .. resX .. "x" .. resY)
        if ok3 then succeeded = true end
    end

    -- 策略4: 设置 testView 的 size（SetSize）
    if not succeeded then
        local ok4 = pcall(function()
            testView:SetSize(resX, resY)
        end)
        table.insert(methods, "testView:SetSize(" .. resX .. "," .. resY .. ")")
        if ok4 then succeeded = true end
    end

    -- 策略5: 通过内部 Stage 设置（testView 独立的 stage，不影响编辑器全局 GRoot）
    if not succeeded then
        local stage = nil
        pcall(function() stage = testView.stage end)
        if not stage then pcall(function() stage = testView.Stage end) end

        if stage then
            local ok5 = pcall(function()
                stage:SetSize(resX, resY)
            end)
            table.insert(methods, "stage:SetSize(" .. resX .. "," .. resY .. ")")
            if ok5 then succeeded = true end
        end
    end

    -- 注意：策略6（GRoot.inst:SetContentScaleFactor）已删除，它会缩放整个编辑器UI

    fprint("[MCPBridge] 设备切换结果: succeeded=" .. tostring(succeeded) .. ", methods=[" .. table.concat(methods, "], [") .. "]")
    return succeeded, table.concat(methods, "; ")
end

-- 辅助函数：获取 testView 的预览内容 displayObject（用于精确截图）
-- 策略优先级：
--   1. testView.child[0]:GetChild("docContainer") - 整个预览容器，配合裁剪到模拟设备区域
--   2. testView 第一个子元素的 displayObject（整个预览面板，含编辑器UI）
--   3. contentPane.displayObject
--   4. testView.displayObject（回退）
-- 返回值：displayObject, source, [cropX, cropY, cropW, cropH] - 裁剪信息（可选）
local function getTestViewCaptureTarget(testView)
    -- 策略1（最优）: docContainer + 裁剪到模拟设备屏幕
    if testView.numChildren and testView.numChildren > 0 then
        local child0 = nil
        pcall(function() child0 = testView:GetChildAt(0) end)
        if child0 then
            local docContainer = nil
            pcall(function() docContainer = child0:GetChild("docContainer") end)
            if docContainer and docContainer.numChildren > 0 then
                local deviceScreen = nil
                pcall(function() deviceScreen = docContainer:GetChildAt(0) end)
                if deviceScreen then
                    local dobj = nil
                    pcall(function() dobj = docContainer.displayObject end)
                    if dobj then
                        -- deviceScreen 在 docContainer 内的子元素的真实偏移
                        -- 通过 deviceScreen 自身坐标 + 它内部第一个子元素的偏移得到
                        local cropX = deviceScreen.x or 0
                        local cropY = deviceScreen.y or 0
                        if deviceScreen.numChildren and deviceScreen.numChildren > 0 then
                            local inner = nil
                            pcall(function() inner = deviceScreen:GetChildAt(0) end)
                            if inner then
                                cropX = cropX + (inner.x or 0)
                                cropY = cropY + (inner.y or 0)
                            end
                        end
                        local cropW = deviceScreen.width or 0
                        local cropH = deviceScreen.height or 0
                        fprint(string.format("[MCPBridge] 截图目标(docContainer + crop): %sx%s at (%s,%s)",
                            tostring(cropW), tostring(cropH),
                            tostring(cropX), tostring(cropY)))
                        return dobj, "docContainer_cropped", cropX, cropY, cropW, cropH
                    end
                end
            end
        end
    end

    -- 策略2: docContainer 整体（含设备外灰色区域）
    if testView.numChildren and testView.numChildren > 0 then
        local child0 = nil
        pcall(function() child0 = testView:GetChildAt(0) end)
        if child0 then
            local docContainer = nil
            pcall(function() docContainer = child0:GetChild("docContainer") end)
            if docContainer then
                local dobj = nil
                pcall(function() dobj = docContainer.displayObject end)
                if dobj then
                    return dobj, "docContainer"
                end
            end
        end
    end

    -- 策略3（旧逻辑）: testView.child[0].displayObject
    if testView.numChildren and testView.numChildren > 0 then
        local child = nil
        pcall(function() child = testView:GetChildAt(0) end)
        if child then
            local dobj = nil
            pcall(function() dobj = child.displayObject end)
            if dobj then
                return dobj, "child0_" .. tostring(child.name)
            end
        end
    end

    -- 策略4: contentPane.displayObject
    local contentPane = nil
    pcall(function() contentPane = testView.contentPane end)
    if not contentPane then pcall(function() contentPane = testView.ContentPane end) end

    if contentPane then
        local dobj = nil
        pcall(function() dobj = contentPane.displayObject end)
        if dobj then
            return dobj, "contentPane"
        end
    end

    -- 策略5: testView.displayObject（最后回退）
    local dobj = nil
    pcall(function() dobj = testView.displayObject end)
    if dobj then
        return dobj, "testView_displayObject"
    end

    return nil, "none"
end

-- 启动预览测试（F5）
-- FIX-1: device_name 通过延迟定时器 + 多策略设置设备分辨率
-- FIX-2: 组件大于 testView 可视区域时自动调整 testView 尺寸
function CommandHandler.handleStartTest(params, bridgePath)
    local pkgName = params.package_name
    local compName = params.component_name
    local deviceName = params.device_name

    if not pkgName or not compName then
        error("缺少参数: package_name 或 component_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    local item = findComponentItem(pkg, compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 如果 testView 已在运行，先停止再重新启动，避免缓存状态导致显示上一次的组件
    local testView = App.testView
    if testView and testView.running then
        fprint("[MCPBridge] testView 正在运行，先停止再重新启动")
        testView:Stop()
    end

    -- F5 预览运行的是编辑器当前打开的组件（activeDoc），而非 Start 参数指定的组件
    -- 因此必须先打开目标组件文档，确保 activeDoc 指向正确组件
    local url = item:GetURL()
    App.docView:OpenDocument(url, true)

    -- 启动 F5 预览测试
    App.testView:Start(item)
    -- F5 模式会设置 runInBackground = false，导致窗口失焦后定时器停止
    -- 启动后立即重置，确保后续命令能正常轮询
    CS.UnityEngine.Application.runInBackground = true

    -- FIX-1: 如果指定了设备，通过延迟定时器切换分辨率
    -- testView:Start 是异步的，立即设置可能不生效
    local currentDevice = "default"
    local resX = 0
    local resY = 0
    local deviceFound = false

    if deviceName then
        local devInfo = findDeviceInfo(deviceName)
        if devInfo and devInfo.found then
            resX = devInfo.resolutionX
            resY = devInfo.resolutionY
            currentDevice = deviceName
            deviceFound = true

            -- FIX-2: 增加延迟到 0.5s，确保 testView:Start 内部初始化完成
            CS.FairyGUI.Timers.inst:Add(0.5, 1, function()
                local tv = App.testView
                if tv and tv.running then
                    -- 保存原始状态以便恢复
                    saveTestViewState(tv)
                    applyTestViewDevice(tv, resX, resY, devInfo.scaleMode, devInfo.screenMatchMode)
                else
                    fprint("[MCPBridge] testView 未运行，无法设置设备分辨率")
                end
            end)
        else
            -- 设备未找到，打印所有可用设备名称用于调试
            fprint("[MCPBridge] 设备未找到: '" .. deviceName .. "'")
            local adaptSettings = App.project:GetSettings("Adaptation")
            if adaptSettings then
                if adaptSettings.defaultDevices then
                    for i = 0, adaptSettings.defaultDevices.Count - 1 do
                        local dev = adaptSettings.defaultDevices[i]
                        fprint("[MCPBridge]  默认设备[" .. i .. "]: '" .. dev.name .. "' (" .. dev.resolutionX .. "x" .. dev.resolutionY .. ")")
                    end
                end
                if adaptSettings.devices then
                    for i = 0, adaptSettings.devices.Count - 1 do
                        local dev = adaptSettings.devices[i]
                        fprint("[MCPBridge]  自定义设备[" .. i .. "]: '" .. dev.name .. "' (" .. dev.resolutionX .. "x" .. dev.resolutionY .. ")")
                    end
                end
            end
        end
    end

    -- FIX-2: 如果组件尺寸大于 testView 可视区域，调整 testView 尺寸确保组件完整可见
    local compW = item.width or 0
    local compH = item.height or 0

    CS.FairyGUI.Timers.inst:Add(0.5, 1, function()
        local tv = App.testView
        if not tv or not tv.running then return end
        if compW <= 0 or compH <= 0 then return end

        local viewW = tv.viewWidth > 0 and tv.viewWidth or tv.width
        local viewH = tv.viewHeight > 0 and tv.viewHeight or tv.height
        if viewW <= 0 or viewH <= 0 then return end

        if compW > viewW or compH > viewH then
            pcall(function()
                tv.viewWidth = compW
                tv.viewHeight = compH
            end)
            fprint("[MCPBridge] 组件(" .. compW .. "x" .. compH .. ")大于预览区域(" .. viewW .. "x" .. viewH .. ")，已调整 testView 尺寸")
        end
    end)

    return {
        started = true,
        item_name = item.name,
        item_id = item.id,
        component = compName,
        package = pkgName,
        component_size = { width = compW, height = compH },
        device = currentDevice,
        device_found = deviceFound,
        resolutionX = resX,
        resolutionY = resY
    }
end

-- 停止预览测试
function CommandHandler.handleStopTest(params, bridgePath)
    local testView = App.testView
    if testView and testView.running then
        -- 恢复设备切换前的原始尺寸/缩放
        restoreTestViewState(testView)
        testView:Stop()
        -- 停止 F5 后重置 runInBackground，确保编辑器恢复正常后台运行
        CS.UnityEngine.Application.runInBackground = true
        return { stopped = true }
    end
    return { stopped = false, message = "预览未运行" }
end

-- 切换设备分辨率
function CommandHandler.handleSwitchDevice(params, bridgePath)
    local deviceName = params.device_name

    if not deviceName then
        error("缺少参数: device_name")
    end

    local testView = App.testView
    if not testView or not testView.running then
        error("预览未运行，请先调用 start_test")
    end

    -- 保存原始状态（如果还未保存）
    saveTestViewState(testView)

    local devInfo = findDeviceInfo(deviceName)
    if not devInfo or not devInfo.found then
        error("设备未找到: " .. deviceName)
    end

    local resX = devInfo.resolutionX
    local resY = devInfo.resolutionY
    local _, methods = applyTestViewDevice(testView, resX, resY, devInfo.scaleMode, devInfo.screenMatchMode)

    return {
        switched = true,
        device = deviceName,
        resolutionX = resX,
        resolutionY = resY,
        methods = methods
    }
end

-- 截取预览截图
-- FIX-3: 使用 getTestViewCaptureTarget 精确定位截图目标，而非 GRoot.inst 全屏
function CommandHandler.handleCapturePreview(params, bridgePath)
    local saveName = params.save_name or ("preview_" .. os.time())
    local deviceName = params.device_name
    local scale = params.scale or 1

    local testView = App.testView
    if not testView or not testView.running then
        error("预览未运行，请先调用 start_test")
    end

    -- 如果指定了设备，先切换
    if deviceName then
        CommandHandler.handleSwitchDevice({ device_name = deviceName }, bridgePath)
        saveName = saveName .. "_" .. deviceName:gsub(" ", "_")
    end

    local screenshotPath = bridgePath:gsub("/", "\\") .. "\\screenshots\\" .. saveName .. ".png"

    -- FIX-3: 精确截图 -- 使用 getTestViewCaptureTarget 查找最佳截图目标
    -- 返回值可能包含裁剪信息（cropX, cropY, cropW, cropH）
    local captureObj, captureSource, cropX, cropY, cropW, cropH = getTestViewCaptureTarget(testView)
    if not captureObj then
        error("无法获取预览渲染对象")
    end

    captureDisplayObject(captureObj, screenshotPath, scale, cropX, cropY, cropW, cropH)

    return {
        captured = true,
        screenshot = saveName .. ".png",
        path = screenshotPath,
        capture_source = captureSource
    }
end

-- 列出可用设备
function CommandHandler.handleListDevices(params, bridgePath)
    local adaptSettings = App.project:GetSettings("Adaptation")
    if not adaptSettings then
        error("无法获取适配设置")
    end

    local devices = {}

    -- 默认设备
    if adaptSettings.defaultDevices then
        for i = 0, adaptSettings.defaultDevices.Count - 1 do
            local dev = adaptSettings.defaultDevices[i]
            table.insert(devices, {
                name = dev.name,
                resolutionX = dev.resolutionX,
                resolutionY = dev.resolutionY,
                source = "default"
            })
        end
    end

    -- 自定义设备
    if adaptSettings.devices then
        for i = 0, adaptSettings.devices.Count - 1 do
            local dev = adaptSettings.devices[i]
            table.insert(devices, {
                name = dev.name,
                resolutionX = dev.resolutionX,
                resolutionY = dev.resolutionY,
                source = "custom"
            })
        end
    end

    -- 当前适配设置
    local scaleMode = adaptSettings.scaleMode or "unknown"
    local screenMathMode = adaptSettings.screenMatchMode or "unknown"
    local designX = adaptSettings.designResolutionX or 0
    local designY = adaptSettings.designResolutionY or 0

    return {
        devices = devices,
        count = #devices,
        scaleMode = scaleMode,
        screenMatchMode = screenMathMode,
        designResolution = { x = designX, y = designY }
    }
end

-- ========== 控制器操作命令 ==========

-- 切换控制器状态
function CommandHandler.handleSwitchController(params, bridgePath)
    local controllerName = params.controller_name
    local pageIndex = params.page_index
    local pageName = params.page_name

    if not controllerName then
        error("缺少参数: controller_name")
    end

    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    local component = doc.content
    if not component then
        error("无法获取文档组件")
    end

    -- 从 controllers 集合中按名称查找
    local ctrl = nil
    local ctrls = component.controllers
    if ctrls then
        for i = 0, ctrls.Count - 1 do
            local c = ctrls[i]
            if c.name == controllerName then
                ctrl = c
                break
            end
        end
    end

    if not ctrl then
        error("控制器不存在: " .. controllerName)
    end

    local oldIndex = ctrl.selectedIndex
    local totalPages = ctrl.pageCount

    if pageName then
        -- 按页名称切换：从 XML 解析页面名称匹配索引
        local pkgName = ""
        local compName = ""
        pcall(function()
            pkgName = doc.packageItem.owner.name
            compName = doc.packageItem.name:gsub("%.xml$", "")
        end)
        error("page_name 暂不支持在编辑器端使用，请使用 page_index 代替（可先用 list_controllers 获取页面索引）")
    elseif pageIndex ~= nil then
        -- 按页索引切换
        if pageIndex < 0 or pageIndex >= totalPages then
            error("页索引超出范围: " .. pageIndex .. "（总页数: " .. totalPages .. "）")
        end
        ctrl.selectedIndex = pageIndex
    else
        error("缺少参数: page_index 或 page_name")
    end

    return {
        switched = true,
        controller = controllerName,
        oldIndex = oldIndex,
        newIndex = ctrl.selectedIndex,
        totalPages = totalPages
    }
end

-- 列出控制器
function CommandHandler.handleListControllers(params, bridgePath)
    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    local content = doc.content
    if not content then
        error("无法获取文档组件")
    end

    local ctrls = content.controllers
    if not ctrls then
        return { controllers = {}, count = 0, component = doc.displayTitle or "unknown" }
    end

    local controllers = {}

    for i = 0, ctrls.Count - 1 do
        local ctrl = ctrls[i]
        table.insert(controllers, {
            name = ctrl.name,
            selectedIndex = ctrl.selectedIndex,
            pageCount = ctrl.pageCount,
            alias = ctrl.alias or "",
            exported = ctrl.exported or false
        })
    end

    -- 获取包名和组件名，供 Python 侧从 XML 补充页面名称
    local pkgName = ""
    local compName = ""
    local ok, _ = pcall(function()
        pkgName = doc.packageItem.owner.name
        compName = doc.packageItem.name:gsub("%.xml$", "")
    end)

    return {
        controllers = controllers,
        count = #controllers,
        component = doc.displayTitle or "unknown",
        package_name = pkgName,
        component_name = compName
    }
end

-- ========== 选择元素命令 (NEW-1) ==========

-- 在编辑器中选中指定元素
function CommandHandler.handleSelectElement(params, bridgePath)
    local elementName = params.element_name

    if not elementName then
        error("缺少参数: element_name")
    end

    local doc = App.activeDoc
    if not doc then
        error("没有打开的文档")
    end

    local content = doc.content
    if not content then
        error("无法获取文档组件")
    end

    -- 策略1: 直接在 content 的子元素中查找
    local targetChild = nil
    local found = false

    pcall(function()
        targetChild = content:GetChild(elementName)
    end)
    if targetChild then
        found = true
    end

    -- 策略2: 如果直接查找失败，遍历 displayList（编辑器侧的显示列表）
    if not found then
        pcall(function()
            local displayList = content.displayList
            if displayList then
                for i = 0, displayList.Count - 1 do
                    local child = displayList[i]
                    if child and child.name == elementName then
                        targetChild = child
                        found = true
                        break
                    end
                end
            end
        end)
    end

    -- 策略3: 遍历所有子元素
    if not found then
        pcall(function()
            local children = content:GetChildren()
            if children then
                for i = 0, children.Length - 1 do
                    local child = children[i]
                    if child and child.name == elementName then
                        targetChild = child
                        found = true
                        break
                    end
                end
            end
        end)
    end

    if not found then
        error("元素不存在: " .. elementName)
    end

    -- 设置选中
    local selectOk = false
    local selectMethod = "none"
    local refreshOk = false
    local refreshMethod = "none"

    -- 方式1: doc:SetSelection
    pcall(function()
        doc:SetSelection(targetChild)
        selectOk = true
        selectMethod = "doc:SetSelection"
    end)

    -- 方式2: doc:Select
    if not selectOk then
        pcall(function()
            doc:Select(targetChild)
            selectOk = true
            selectMethod = "doc:Select"
        end)
    end

    -- 方式3: 通过 selectionController 选中
    if not selectOk then
        pcall(function()
            doc:SetSelection(targetChild, false)
            selectOk = true
            selectMethod = "doc:SetSelection(obj, false)"
        end)
    end

    if not selectOk then
        error("无法选中元素: " .. elementName .. "（选中 API 不可用）")
    end

    -- FIX-4: 选中后触发检查器面板刷新
    -- 尝试多种刷新方式，确保检查器面板更新

    -- 方式A: docView 相关刷新 API
    pcall(function()
        if App.docView and App.docView.Refresh then
            App.docView:Refresh()
            refreshOk = true
            refreshMethod = "docView:Refresh()"
        end
    end)

    if not refreshOk then
        pcall(function()
            if App.docView and App.docView.Repaint then
                App.docView:Repaint()
                refreshOk = true
                refreshMethod = "docView:Repaint()"
            end
        end)
    end

    if not refreshOk then
        pcall(function()
            if App.docView and App.docView.UpdateInspector then
                App.docView:UpdateInspector()
                refreshOk = true
                refreshMethod = "docView:UpdateInspector()"
            end
        end)
    end

    -- 方式B: doc 相关刷新 API
    if not refreshOk then
        pcall(function()
            if doc.Invalidate then
                doc:Invalidate()
                refreshOk = true
                refreshMethod = "doc:Invalidate()"
            end
        end)
    end

    if not refreshOk then
        pcall(function()
            if doc.RefreshInspector then
                doc:RefreshInspector()
                refreshOk = true
                refreshMethod = "doc:RefreshInspector()"
            end
        end)
    end

    -- 方式C: 尝试通过取消选中再重新选中来触发刷新
    if not refreshOk then
        pcall(function()
            doc:SetSelection(nil)
            CS.FairyGUI.Timers.inst:Add(0.05, 1, function()
                pcall(function() doc:SetSelection(targetChild) end)
            end)
            refreshOk = true
            refreshMethod = "deselect-then-reselect"
        end)
    end

    -- 方式D: 最终兜底 - 延迟刷新
    if not refreshOk then
        pcall(function()
            CS.FairyGUI.Timers.inst:Add(0.1, 1, function()
                pcall(function()
                    if App.docView and App.docView.Refresh then
                        App.docView:Refresh()
                    end
                end)
            end)
            refreshOk = true
            refreshMethod = "delayed docView:Refresh()"
        end)
    end

    return {
        selected = true,
        element_name = elementName,
        select_method = selectMethod,
        inspector_refreshed = refreshOk,
        inspector_refresh_method = refreshMethod
    }
end

-- ========== 插件管理命令 ==========

-- 探查插件管理 API
function CommandHandler.handleProbePluginApi(params, bridgePath)
    local found = {}
    local target = params.target or "overview"

    if target == "overview" then
        -- 探查 App 上与插件相关的属性
        local appProps = {
            "pluginManager", "PluginManager", "pluginMgr", "PluginMgr",
            "plugins", "Plugins", "pluginSystem", "PluginSystem",
            "luaEnv", "LuaEnv", "luaManager", "LuaManager",
        }

        for _, prop in ipairs(appProps) do
            local ok, val = pcall(function() return App[prop] end)
            if ok and val ~= nil then
                table.insert(found, {
                    path = "App." .. prop,
                    valtype = type(val),
                    value = tostring(val)
                })
            end
        end

    elseif target == "pluginManager" then
        -- 深入探查 App.pluginManager 的属性和方法
        local mgr = App.pluginManager
        local props = {
            "allPlugins", "plugins", "loadedPlugins", "pluginList",
            "count", "Count",
            "ReloadAll", "Reload", "ReloadPlugin",
            "LoadPlugin", "UnloadPlugin",
            "LoadAll", "StopAll", "RestartAll",
            "Dispose",
        }

        for _, prop in ipairs(props) do
            local ok, val = pcall(function() return mgr[prop] end)
            if ok and val ~= nil then
                table.insert(found, {
                    path = "pluginManager." .. prop,
                    valtype = type(val),
                    value = tostring(val)
                })
            end
        end

        -- 探查 allPlugins 中的第一个插件信息
        local ok, plugins = pcall(function() return mgr.allPlugins end)
        if ok and plugins then
            local pcount = plugins.Count
            table.insert(found, { path = "allPlugins.Count", valtype = "number", value = tostring(pcount) })

            if pcount > 0 then
                local p0 = plugins[0]
                local infoProps = {"name", "id", "path", "enabled", "loaded", "running",
                                   "version", "desc", "author",
                                   "Reload", "reload", "Restart", "restart",
                                   "Start", "start", "Stop", "stop",
                                   "Load", "load", "Unload", "unload"}
                for _, ip in ipairs(infoProps) do
                    local ok2, val2 = pcall(function() return p0[ip] end)
                    if ok2 and val2 ~= nil then
                        table.insert(found, {
                            path = "pluginInfo[0]." .. ip,
                            valtype = type(val2),
                            value = tostring(val2)
                        })
                    end
                end
            end
        end

    elseif target == "luaManager" then
        -- 探查 LuaManager
        local ok, lm = pcall(function() return CS.FairyEditor.LuaManager end)
        if ok and lm then
            local props = {
                "inst", "Instance", "instance",
                "Reload", "reload", "ReloadAll", "reloadAll",
                "RestartAll", "restartAll",
                "LoadScript", "loadScript",
                "DoFile", "doFile",
            }
            for _, prop in ipairs(props) do
                local ok2, val = pcall(function() return lm[prop] end)
                if ok2 and val ~= nil then
                    table.insert(found, {
                        path = "LuaManager." .. prop,
                        valtype = type(val),
                        value = tostring(val)
                    })
                end
            end
        end

    elseif target == "console" then
        -- 探查控制台/日志相关 API
        local csTypes = {
            "Console", "OutputPanel", "LogManager", "OutputManager",
            "TraceManager", "MessageManager", "OutputView",
        }
        for _, t in ipairs(csTypes) do
            local ok, val = pcall(function() return CS.FairyEditor[t] end)
            if ok and val ~= nil then
                table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
            end
        end

    elseif target == "console_deep" then
        -- 深入探查 CS.FairyEditor.Console 实例
        local console = CS.FairyEditor.Console
        if not console then
            table.insert(found, { path = "CS.FairyEditor.Console", valtype = "nil", value = "not found" })
        else
            -- 获取 inst 单例
            local inst = nil
            local ok, v = pcall(function() return console.inst end)
            if ok and v ~= nil then inst = v end

            local obj = inst or console
            local prefix = inst and "Console.inst" or "Console"

            local subProps = {
                "logs", "Logs", "items", "Items", "messages", "Messages",
                "entries", "Entries", "records", "Records", "list", "List",
                "GetLogs", "getLogs", "GetMessages", "getMessages", "GetEntries", "GetItems",
                "Clear", "clear", "ClearAll", "clearAll", "ClearLogs", "Reset",
                "Count", "count", "length", "Length",
                "view", "View", "panel", "Panel", "content", "Content",
            }
            for _, sp in ipairs(subProps) do
                local ok2, val2 = pcall(function() return obj[sp] end)
                if ok2 and val2 ~= nil then
                    local vtype = type(val2)
                    local vstr = tostring(val2)
                    -- 如果是集合，尝试获取 Count
                    if vtype == "table" and val2.Count ~= nil then
                        local ok3, cnt = pcall(function() return val2.Count end)
                        if ok3 then vstr = vstr .. " [Count=" .. tostring(cnt) .. "]" end
                    end
                    table.insert(found, { path = prefix .. "." .. sp, valtype = vtype, value = vstr })
                end
            end
        end

    elseif target == "pluginSystem" then
        -- 探查 PluginSystem
        local ok, ps = pcall(function() return CS.FairyEditor.PluginSystem end)
        if ok and ps then
            local props = {
                "inst", "Instance", "instance",
                "Reload", "reload", "ReloadAll", "reloadAll",
                "Restart", "restart", "RestartAll", "restartAll",
                "LoadAll", "loadAll",
            }
            for _, prop in ipairs(props) do
                local ok2, val = pcall(function() return ps[prop] end)
                if ok2 and val ~= nil then
                    table.insert(found, {
                        path = "PluginSystem." .. prop,
                        valtype = type(val),
                        value = tostring(val)
                    })
                end
            end
        end

    elseif target == "preview_scale" then
        -- 探查预览缩放相关属性
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                -- 探查 contentScaler 控件
                local scaler = nil
                pcall(function() scaler = child0:GetChild("contentScaler") end)
                if scaler then
                    local props = {"value", "title", "text", "selected", "selectedIndex"}
                    for _, p in ipairs(props) do
                        local ok, val = pcall(function() return scaler[p] end)
                        if ok and val ~= nil then
                            table.insert(found, { path = "contentScaler." .. p, value = tostring(val) })
                        end
                    end
                end

                -- 探查 docContainer 内部元素的缩放
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer and docContainer.numChildren > 0 then
                    table.insert(found, {
                        path = "docContainer",
                        value = string.format("%sx%s, scaleX=%s, scaleY=%s",
                            tostring(docContainer.width or 0), tostring(docContainer.height or 0),
                            tostring(docContainer.scaleX or 1), tostring(docContainer.scaleY or 1))
                    })
                    local devCont = nil
                    pcall(function() devCont = docContainer:GetChildAt(0) end)
                    if devCont then
                        table.insert(found, {
                            path = "deviceContainer",
                            value = string.format("%sx%s, scaleX=%s, scaleY=%s, x=%s, y=%s",
                                tostring(devCont.width or 0), tostring(devCont.height or 0),
                                tostring(devCont.scaleX or 1), tostring(devCont.scaleY or 1),
                                tostring(devCont.x or 0), tostring(devCont.y or 0))
                        })
                    end
                end
            end
        end

    elseif target == "docContainer_deep" then
        -- 探查 docContainer.child[0] 里面的内容
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer and docContainer.numChildren > 0 then
                    local devCont = nil
                    pcall(function() devCont = docContainer:GetChildAt(0) end)
                    if devCont then
                        local n = devCont.numChildren or 0
                        table.insert(found, {
                            path = "docContainer.child[0]",
                            value = string.format("name=%s, %sx%s, numChildren=%d",
                                tostring(devCont.name or ""),
                                tostring(devCont.width or 0),
                                tostring(devCont.height or 0), n)
                        })
                        for i = 0, math.min(n - 1, 10) do
                            local gc = nil
                            pcall(function() gc = devCont:GetChildAt(i) end)
                            if gc then
                                table.insert(found, {
                                    path = "deviceContainer.child[" .. i .. "]",
                                    value = string.format("name=%s, %sx%s at (%s,%s)",
                                        tostring(gc.name or ""),
                                        tostring(gc.width or 0), tostring(gc.height or 0),
                                        tostring(gc.x or 0), tostring(gc.y or 0))
                                })
                            end
                        end
                    end
                end
            end
        end

    elseif target == "docContainer" then
        -- 探查 docContainer 内部结构（找到模拟设备区域）
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child0 = nil
            pcall(function() child0 = tv:GetChildAt(0) end)
            if child0 then
                local docContainer = nil
                pcall(function() docContainer = child0:GetChild("docContainer") end)
                if docContainer then
                    local n = docContainer.numChildren or 0
                    table.insert(found, { path = "docContainer.numChildren", value = tostring(n) })
                    for i = 0, math.min(n - 1, 14) do
                        local gc = nil
                        pcall(function() gc = docContainer:GetChildAt(i) end)
                        if gc then
                            table.insert(found, {
                                path = "docContainer.child[" .. i .. "]",
                                value = string.format("name=%s, %sx%s at (%s,%s)",
                                    tostring(gc.name or ""),
                                    tostring(gc.width or 0), tostring(gc.height or 0),
                                    tostring(gc.x or 0), tostring(gc.y or 0))
                            })
                        end
                    end
                end
            end
        end

    elseif target == "testView_grandchild" then
        -- 探查 testView.child[0] 内部的所有子元素
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child = nil
            pcall(function() child = tv:GetChildAt(0) end)
            if child and child.numChildren then
                local n = child.numChildren
                table.insert(found, { path = "child0.numChildren", value = tostring(n) })
                for i = 0, math.min(n - 1, 14) do
                    local gc = nil
                    pcall(function() gc = child:GetChildAt(i) end)
                    if gc then
                        table.insert(found, {
                            path = "child0.child[" .. i .. "]",
                            value = string.format("name=%s, %dx%d at (%d,%d)",
                                tostring(gc.name or ""), gc.width or 0, gc.height or 0,
                                gc.x or 0, gc.y or 0)
                        })
                    end
                end
            end
        end

    elseif target == "testView_child0" then
        -- 探查 testView 第一个子元素（被预览的组件）
        local tv = App.testView
        if tv and tv.numChildren and tv.numChildren > 0 then
            local child = nil
            pcall(function() child = tv:GetChildAt(0) end)
            if child then
                local props = {
                    "name", "x", "y", "width", "height", "scaleX", "scaleY",
                    "displayObject", "numChildren", "asCom", "AsCom",
                }
                for _, p in ipairs(props) do
                    local ok, val = pcall(function() return child[p] end)
                    if ok and val ~= nil then
                        table.insert(found, { path = "child0." .. p, valtype = type(val), value = tostring(val) })
                    end
                end
                -- 如果 displayObject 存在，深入一层
                local dobj = nil
                pcall(function() dobj = child.displayObject end)
                if dobj then
                    local sp = {"x", "y", "width", "height", "name", "scaleX", "scaleY"}
                    for _, p in ipairs(sp) do
                        local ok, val = pcall(function() return dobj[p] end)
                        if ok and val ~= nil then
                            table.insert(found, { path = "child0.displayObject." .. p, valtype = type(val), value = tostring(val) })
                        end
                    end
                end
            end
        end

    elseif target == "testView_full" then
        -- 深入探查 testView 内部结构
        local tv = App.testView
        if tv then
            local props = {
                "running", "visible", "contentPane", "ContentPane",
                "stage", "Stage", "displayObject", "DisplayObject",
                "view", "View", "panel", "Panel", "container", "Container",
                "viewWidth", "viewHeight", "width", "height",
                "scaleX", "scaleY", "scale",
                "x", "y", "name",
                "numChildren", "GetChildAt", "GetChild",
                "rootView", "RootView", "host", "Host",
                "parent", "Parent",
                "GetScreenShot", "GetBounds",
                "viewport", "Viewport", "frame", "Frame",
                "preview", "Preview", "previewWindow", "PreviewWindow",
                "tester", "Tester",
                "originSize", "size",
                "testView", "innerView",
            }
            for _, p in ipairs(props) do
                local ok, val = pcall(function() return tv[p] end)
                if ok and val ~= nil then
                    table.insert(found, { path = "testView." .. p, valtype = type(val), value = tostring(val) })
                    -- 如果是对象，深入一层
                    if type(val) == "userdata" or type(val) == "table" then
                        local subProps = {"displayObject", "x", "y", "width", "height", "name", "scaleX", "scaleY", "numChildren", "parent"}
                        for _, sp in ipairs(subProps) do
                            local ok2, sv = pcall(function() return val[sp] end)
                            if ok2 and sv ~= nil then
                                table.insert(found, { path = "testView." .. p .. "." .. sp, valtype = type(sv), value = tostring(sv) })
                            end
                        end
                    end
                end
            end
        end

    elseif target == "testView" then
        -- 探查 App.testView 相关 API
        local tvProps = {"testView", "TestView", "previewView", "PreviewView"}
        for _, pName in ipairs(tvProps) do
            local ok, tv = pcall(function() return App[pName] end)
            if ok and tv ~= nil then
                table.insert(found, { path = "App." .. pName, valtype = type(tv), value = tostring(tv) })
                -- 探查 testView 的属性和方法
                local methods = {
                    "running", "Running", "visible", "Visible",
                    "Start", "start", "Run", "run", "Show", "show",
                    "Stop", "stop", "Close", "close", "Hide", "hide",
                    "item", "Item", "content", "Content",
                    "component", "Component",
                }
                for _, m in ipairs(methods) do
                    local ok2, val2 = pcall(function() return tv[m] end)
                    if ok2 and val2 ~= nil then
                        table.insert(found, {
                            path = "App." .. pName .. "." .. m,
                            valtype = type(val2),
                            value = tostring(val2)
                        })
                    end
                end
            end
        end

        -- 探查 App 上的测试/预览相关方法
        local appMethods = {
            "StartTest", "startTest", "RunTest", "runTest",
            "TestPreview", "testPreview",
            "ShowTestView", "showTestView",
            "StartPreview", "startPreview",
        }
        for _, m in ipairs(appMethods) do
            local ok, val = pcall(function() return App[m] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. m, valtype = type(val), value = tostring(val) })
            end
        end
    elseif target == "publishSettings" then
        -- 探查发布设置相关 API
        local pubProps = {
            "publishView", "PublishView", "publishSettings", "PublishSettings",
            "showPublishDialog", "ShowPublishDialog", "openPublishDialog", "OpenPublishDialog",
            "publishDialog", "PublishDialog", "publishPanel", "PublishPanel",
        }
        for _, prop in ipairs(pubProps) do
            local ok, val = pcall(function() return App[prop] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. prop, valtype = type(val), value = tostring(val) })
            end
        end
        -- 尝试调用发布设置相关方法
        local pubMethods = {
            "showPublishView", "ShowPublishView", "openPublishSettings", "OpenPublishSettings",
            "showPublishDialog", "ShowPublishDialog", "openPublishPanel", "OpenPublishPanel",
        }
        for _, method in ipairs(pubMethods) do
            local ok, val = pcall(function() return App[method] end)
            if ok and val ~= nil then
                table.insert(found, { path = "App." .. method, valtype = type(val), value = tostring(val) })
            end
        end
        -- 尝试 CS.FairyEditor 中发布相关的类
        local pubTypes = {
            "PublishView", "PublishDialog", "PublishSettings", "PublishDialogBase",
        }
        for _, t in ipairs(pubTypes) do
            local ok, val = pcall(function() return CS.FairyEditor[t] end)
            if ok and val ~= nil then
                table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
            end
        end

    end

    return { found_apis = found, count = #found, target = target }
end

-- 重载所有插件
function CommandHandler.handleReloadAllPlugins(params, bridgePath)
    local results = {}

    -- 探查可用的插件管理 API
    local apiFound = {}
    local mgr = nil

    -- 尝试多种路径获取 pluginManager
    local mgrPaths = {
        "App.pluginManager", "App.PluginManager", "App.pluginMgr",
        "CS.FairyEditor.PluginSystem.inst",
        "CS.FairyEditor.PluginSystem.Instance",
    }
    for _, path in ipairs(mgrPaths) do
        local ok, val = pcall(function()
            local parts = {}
            for p in path:gmatch("[^.]+") do
                table.insert(parts, p)
            end
            local obj = _G
            for _, p in ipairs(parts) do
                if obj == _G and p == "App" then
                    obj = App
                elseif obj == _G and p == "CS" then
                    obj = CS
                elseif obj == CS and p == "FairyEditor" then
                    obj = CS.FairyEditor
                else
                    obj = obj[p]
                end
            end
            return obj
        end)
        if ok and val ~= nil then
            mgr = val
            table.insert(apiFound, path)
        end
    end

    -- 获取所有插件信息
    local pluginNames = {}
    if mgr then
        local ok, plugins = pcall(function() return mgr.allPlugins end)
        if ok and plugins then
            for i = 0, plugins.Count - 1 do
                local p = plugins[i]
                table.insert(pluginNames, p.name)
            end
        end
    end
    table.insert(results, "loaded plugins: " .. table.concat(pluginNames, ", "))
    table.insert(results, "api found: " .. table.concat(apiFound, ", "))

    -- 尝试直接调用 ReloadAll（不延迟），让 pcall 捕获错误
    local methodUsed = "none"
    local reloadOk = false

    -- 方式1: PluginSystem.inst:ReloadAll()
    local ok1, err1 = pcall(function()
        local ps = CS.FairyEditor.PluginSystem
        if ps and ps.inst then
            ps.inst:ReloadAll()
            methodUsed = "PluginSystem.inst:ReloadAll()"
            reloadOk = true
        elseif ps and ps.Instance then
            ps.Instance:ReloadAll()
            methodUsed = "PluginSystem.Instance:ReloadAll()"
            reloadOk = true
        end
    end)
    if ok1 and reloadOk then
        fprint("[MCPBridge] ReloadAll via PluginSystem succeeded")
    elseif not ok1 then
        fprint("[MCPBridge] ReloadAll via PluginSystem failed: " .. tostring(err1))
    end

    -- 方式2: App.pluginManager:ReloadAll()
    if not reloadOk then
        local ok2, _ = pcall(function()
            if mgr then
                mgr:ReloadAll()
                methodUsed = "pluginManager:ReloadAll()"
                reloadOk = true
            end
        end)
        if ok2 and reloadOk then
            fprint("[MCPBridge] ReloadAll via pluginManager succeeded")
        end
    end

    -- 方式3: 遍历所有插件逐个 Reload
    if not reloadOk and mgr then
        local ok3, _ = pcall(function()
            local plugins = mgr.allPlugins
            if plugins then
                for i = 0, plugins.Count - 1 do
                    local p = plugins[i]
                    pcall(function() p:Reload() end)
                end
                methodUsed = "per-plugin Reload()"
                reloadOk = true
            end
        end)
        if ok3 and reloadOk then
            fprint("[MCPBridge] ReloadAll via per-plugin Reload succeeded")
        end
    end

    -- 方式4: 定时器延迟执行（作为兜底）
    if not reloadOk then
        CS.FairyGUI.Timers.inst:Add(0.8, 1, function()
            fprint("[MCPBridge] Fallback: scheduled PluginSystem.ReloadAll in timer...")
            pcall(function()
                local ps = CS.FairyEditor.PluginSystem
                if ps and ps.inst then
                    ps.inst:ReloadAll()
                end
            end)
        end)
        methodUsed = "PluginSystem.ReloadAll (delayed 0.8s fallback)"
    end

    table.insert(results, "method: " .. methodUsed)
    table.insert(results, "immediate_result: " .. tostring(reloadOk))

    return {
        reloaded = reloadOk or methodUsed:find("fallback") ~= nil,
        method = methodUsed,
        details = results,
        warning = reloadOk and "all plugins reloaded, MCPBridge will re-initialize"
                  or "direct reload failed, fallback timer scheduled"
    }
end

-- ========== 发布命令 ==========

-- 内部函数：尝试通过直接 API 发布
local function tryPublishViaAPI(pkgNames)
    local ok1, _ = pcall(function() App.project:Publish() end)
    if ok1 then return true, "project:Publish()" end

    local ok2, _ = pcall(function() App:Publish() end)
    if ok2 then return true, "App:Publish()" end

    local ok3, _ = pcall(function() App:DoPublish() end)
    if ok3 then return true, "App:DoPublish()" end

    local ok4, _ = pcall(function() App:Export() end)
    if ok4 then return true, "App:Export()" end

    local ok5, _ = pcall(function() App.project:Export() end)
    if ok5 then return true, "project:Export()" end

    return false, "no direct API found"
end

-- 内部函数：尝试通过工具栏按钮点击发布
local function tryPublishViaToolbar()
    local toolbar = nil
    pcall(function() toolbar = App.mainView.toolbar end)
    if not toolbar then
        return false, "toolbar not found"
    end

    local buttonNames = {
        "tbPublish", "tbPublishDesc", "btnPublish", "btnPublishDesc",
        "tbPublishAll", "btnPublishAll", "tbExport", "btnExport",
    }

    for _, btnName in ipairs(buttonNames) do
        local btn = nil
        local hasBtn, _ = pcall(function() btn = toolbar:GetChild(btnName) end)
        if hasBtn and btn then
            local clickParams = {{true, true}, {false, false}, {true, false}, {false, true}}
            for _, cp in ipairs(clickParams) do
                local clickOk, _ = pcall(function() btn:FireClick(cp[1], cp[2]) end)
                if clickOk then
                    CS.UnityEngine.Application.runInBackground = true
                    return true, "FireClick(" .. tostring(cp[1]) .. "," .. tostring(cp[2]) .. ") on " .. btnName
                end
            end
        end
    end

    return false, "no publish button found in toolbar"
end

-- 打开发布设置对话框
function CommandHandler.handleOpenPublishSettings(params, bridgePath)
    -- 探查 CS.FairyEditor.PublishSettings 的方法
    local found = {}
    local settingsClass = CS.FairyEditor.PublishSettings
    if settingsClass then
        -- 尝试各种打开方法
        local methods = {
            "Show", "show", "Open", "open", "ShowDialog", "showDialog",
            "ShowSettings", "showSettings", "OpenDialog", "openDialog",
            "ShowWindow", "showWindow", "OpenWindow", "openWindow",
            "ShowPanel", "showPanel", "OpenPanel", "openPanel",
            "ShowSettingsWindow", "OpenSettingsWindow",
            "inst", "Instance", "instance",
        }
        for _, m in ipairs(methods) do
            local ok, val = pcall(function() return settingsClass[m] end)
            if ok and val ~= nil then
                table.insert(found, { path = "PublishSettings." .. m, valtype = type(val), value = tostring(val) })
            end
        end
    end

    -- 尝试点击 tbPublishSettings 按钮
    local toolbar = App.mainView.toolbar
    if toolbar then
        local btn = nil
        pcall(function() btn = toolbar:GetChild("tbPublishSettings") end)
        if btn then
            local clickParams = {{true, true}, {false, false}, {true, false}, {false, true}}
            for _, cp in ipairs(clickParams) do
                local clickOk, _ = pcall(function() btn:FireClick(cp[1], cp[2]) end)
                if clickOk then
                    table.insert(found, { method = "FireClick", params = tostring(cp[1])..","..tostring(cp[2]), button = "tbPublishSettings", success = true })
                    break
                end
            end
        else
            table.insert(found, { error = "tbPublishSettings button not found" })
        end
    end

    return { found = found, count = #found }
end

-- 探查发布相关 API
function CommandHandler.handleProbePublish(params, bridgePath)
    local found = {}

    -- App 上的发布相关属性和方法
    local appProps = {
        "publishView", "PublishView", "publishSettings", "PublishSettings",
        "showPublishDialog", "ShowPublishDialog", "showPublishView", "ShowPublishView",
        "openPublishDialog", "OpenPublishDialog", "publishDialog", "PublishDialog",
        "publishPanel", "PublishPanel", "openPublishSettings", "OpenPublishSettings",
    }
    for _, prop in ipairs(appProps) do
        local ok, val = pcall(function() return App[prop] end)
        if ok and val ~= nil then
            table.insert(found, { path = "App." .. prop, valtype = type(val), value = tostring(val) })
        end
    end

    -- CS.FairyEditor 中的发布相关类
    local csTypes = {
        "PublishView", "PublishDialog", "PublishSettings", "PublishDialogBase",
        "Publish", "PublishHandler", "PublishManager",
    }
    for _, t in ipairs(csTypes) do
        local ok, val = pcall(function() return CS.FairyEditor[t] end)
        if ok and val ~= nil then
            table.insert(found, { path = "CS.FairyEditor." .. t, valtype = type(val), value = tostring(val) })
        end
    end

    -- 工具栏上所有子元素
    local toolbar = nil
    pcall(function() toolbar = App.mainView.toolbar end)
    if toolbar then
        table.insert(found, { path = "toolbar.childCount", valtype = "number", value = tostring(toolbar.numChildren or 0) })
        if toolbar.numChildren then
            for i = 0, math.min(toolbar.numChildren - 1, 30) do
                local child = toolbar:GetChildAt(i)
                if child then
                    table.insert(found, { path = "toolbar.child[" .. i .. "].name", valtype = "string", value = child.name })
                end
            end
        end
    end

    return { found_apis = found, count = #found }
end

-- 发布指定包
function CommandHandler.handlePublishPackage(params, bridgePath)
    local pkgName = params.package_name
    if not pkgName then error("缺少参数: package_name") end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then error("包不存在: " .. pkgName) end

    local globalSettings = App.project:GetSettings("Publish")
    local exportPath = "unknown"
    pcall(function() exportPath = globalSettings and globalSettings.path or "" end)

    local apiOk, apiMethod = tryPublishViaAPI({pkgName})
    if apiOk then
        return {
            published = true, package = pkgName, path = exportPath, method = apiMethod,
            message = string.format("已触发发布（包 '%s' 存在，路径: %s）", pkgName, exportPath),
            warning = "发布按钮会发布所有包，无法单独发布指定包"
        }
    end

    local toolbarOk, toolbarMethod = tryPublishViaToolbar()
    if toolbarOk then
        -- 发布后激活编辑器窗口（临时方案，防止 runInBackground 被覆盖）
        CS.UnityEngine.Application.runInBackground = true
        return {
            published = true, package = pkgName, path = exportPath, method = toolbarMethod,
            message = string.format("已触发发布（包 '%s' 存在，路径: %s）", pkgName, exportPath),
            warning = "发布按钮会发布所有包，无法单独发布指定包"
        }
    end

    return {
        published = false, package = pkgName, path = exportPath,
        reason = "no working publish method found",
        api_tried = apiMethod, toolbar_tried = toolbarMethod,
        message = "发布失败: 无法找到可用的发布方法"
    }
end

-- 发布所有包
function CommandHandler.handlePublishAll(params, bridgePath)
    local globalSettings = nil
    pcall(function() globalSettings = App.project:GetSettings("Publish") end)
    local exportPath = "unknown"
    pcall(function() exportPath = globalSettings and globalSettings.path or "" end)

    local allPackages = App.project.allPackages
    if not allPackages or allPackages.Count == 0 then error("项目中没有包") end

    local totalCount = allPackages.Count
    local packageNames = {}
    for i = 0, allPackages.Count - 1 do
        table.insert(packageNames, allPackages[i].name)
    end

    -- 确保发布后保持后台运行
    CS.UnityEngine.Application.runInBackground = true

    local apiOk, apiMethod = tryPublishViaAPI(packageNames)
    if apiOk then
        return {
            total = totalCount, published = totalCount, failed = 0,
            packages = packageNames, path = exportPath, method = apiMethod,
            message = string.format("已触发所有 %d 个包的发布（路径: %s）", totalCount, exportPath)
        }
    end

    local toolbarOk, toolbarMethod = tryPublishViaToolbar()
    if toolbarOk then
        -- 发布后激活编辑器窗口（临时方案，防止 runInBackground 被覆盖）
        CS.UnityEngine.Application.runInBackground = true
        return {
            total = totalCount, published = totalCount, failed = 0,
            packages = packageNames, path = exportPath, method = toolbarMethod,
            message = string.format("已触发所有 %d 个包的发布（路径: %s）", totalCount, exportPath)
        }
    end

    return {
        total = totalCount, published = 0, failed = totalCount,
        packages = packageNames, path = exportPath,
        reason = "no working publish method found",
        api_tried = apiMethod, toolbar_tried = toolbarMethod,
        message = "发布失败: 无法找到可用的发布方法"
    }
end

-- ========== 日志管理命令 ==========

-- 获取编辑器日志（从 main.lua 的 fprint 拦截缓冲区读取）
function CommandHandler.handleGetLogs(params, bridgePath)
    local buf = _G._mcpLogBuffer
    if not buf then
        return { total = 0, logs = {}, returned = 0, start_index = 0, note = "日志缓冲区未初始化" }
    end

    local maxCount = params.max_count or 100
    local level = params.level or "all"

    local total = #buf
    local logs = {}
    local count = 0
    local startIdx = math.max(1, total - maxCount + 1)

    for i = startIdx, total do
        if count >= maxCount then break end
        local entry = buf[i]
        if entry and (level == "all" or entry.level == level) then
            table.insert(logs, {
                time = entry.time or "",
                level = entry.level or "info",
                message = entry.message or ""
            })
            count = count + 1
        end
    end

    return {
        total = total,
        logs = logs,
        returned = count,
        start_index = startIdx
    }
end

-- 清空编辑器日志（清空 fprint 拦截缓冲区）
function CommandHandler.handleClearLogs(params, bridgePath)
    local buf = _G._mcpLogBuffer
    if not buf then
        return { cleared = false, note = "日志缓冲区未初始化" }
    end

    local oldCount = #buf
    for i = #buf, 1, -1 do
        table.remove(buf, i)
    end

    return {
        cleared = true,
        method = "buffer:clear()",
        cleared_count = oldCount
    }
end

-- 深度探查日志存储位置
function CommandHandler.handleProbeLogs(params, bridgePath)
    local result = {}
    local target = params.target or "consoleview"

    if target == "consoleview" then
        local cv = App.consoleView
        if not cv then
            return { error = "App.consoleView is nil" }
        end
        local props = {
            "items","Items","logs","Logs","messages","Messages","list","List",
            "content","Content","text","Text","data","Data",
            "GetLogs","getLogs","GetItems","getItems","GetMessages",
            "Clear","clear","ClearAll","clearAll","ClearLogs",
            "count","Count","length","Length",
            "view","View","logList","LogList",
        }
        for _, name in ipairs(props) do
            local ok, v = pcall(function() return cv[name] end)
            if ok and v ~= nil then
                local vstr = tostring(v)
                local vtype = type(v)
                if vtype == "table" or vtype == "userdata" then
                    local ok2, c = pcall(function() return v.Count end)
                    if ok2 and c ~= nil then vstr = vstr .. " [Count=" .. tostring(c) .. "]" end
                end
                table.insert(result, { name = "consoleView."..name, valtype = vtype, value = vstr })
            end
        end

    elseif target == "fprint_source" then
        local found = {}

        local ok, fp = pcall(function() return fprint end)
        if ok and fp then
            table.insert(found, { name = "fprint", valtype = type(fp), value = tostring(fp) })
        end

        local appMethods = {"Log","log","Print","print","AddLog","addLog","Write","write","Trace","trace"}
        for _, m in ipairs(appMethods) do
            local ok2, v = pcall(function() return App[m] end)
            if ok2 and v ~= nil then
                table.insert(found, { name = "App."..m, valtype = type(v), value = tostring(v) })
            end
        end

        for _, cls in ipairs({"LogManager","OutputManager","TraceManager"}) do
            local ok2, inst = pcall(function()
                local c = CS.FairyEditor[cls]
                return c and c.inst
            end)
            if ok2 and inst ~= nil then
                for _, col in ipairs({"items","Items","logs","Logs","list","List","messages","Messages"}) do
                    local ok3, v = pcall(function() return inst[col] end)
                    if ok3 and v ~= nil then
                        local cnt = 0
                        pcall(function()
                            local c = v.Count
                            if type(c) == "number" then cnt = c
                            elseif c ~= nil then cnt = tonumber(tostring(c)) or 0 end
                        end)
                        table.insert(found, {
                            name = cls..".inst."..col,
                            valtype = type(v),
                            value = tostring(v),
                            count = cnt
                        })
                    end
                end
            end
        end

        return { found = found }
    end

    return { probes = result }
end

return CommandHandler
