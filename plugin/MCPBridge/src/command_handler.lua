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
-- 返回 true 表示成功，false 表示失败
local function captureDisplayObject(displayObj, screenshotPath, scale)
    scale = scale or 1
    -- 调用 GetScreenShot 获取 Texture2D
    local texture = displayObj:GetScreenShot(nil, scale)
    if not texture then
        error("GetScreenShot 返回 nil，无法截取")
    end

    local ok, err = pcall(function()
        -- 编码为 PNG
        local pngBytes = CS.UnityEngine.ImageConversion.EncodeToPNG(texture)
        -- 写入文件
        CS.System.IO.File.WriteAllBytes(screenshotPath, pngBytes)
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
        ["probe_plugin_api"] = CommandHandler.handleProbePluginApi,
        ["reload_all_plugins"] = CommandHandler.handleReloadAllPlugins,
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
    -- 尝试激活窗口
    -- 注意：Unity 应用可能无法直接激活自己
    return { activated = true }
end

-- 刷新资源
function CommandHandler.handleReload(params, bridgePath)
    if params.package_name then
        local pkg = App.project:GetPackageByName(params.package_name)
        if pkg then
            pkg:Touch()
            return { reloaded = true, package = params.package_name }
        else
            error("包不存在: " .. params.package_name)
        end
    else
        App.RefreshProject()
        return { reloaded = true }
    end
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

    local item = pkg:FindItemByName(compName)
    if not item then
        -- 尝试带 .xml 后缀
        item = pkg:GetItemByFileName(pkg.rootItem, compName .. ".xml")
    end

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

    local item = pkg:FindItemByName(compName)
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

    local item = pkg:FindItemByName(compName)
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

-- 启动预览测试（F5）
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

    local item = pkg:FindItemByName(compName)
    if not item then
        error("组件不存在: " .. compName)
    end

    -- 启动 F5 预览测试
    App.testView:Start(item)
    -- F5 模式会设置 runInBackground = false，导致窗口失焦后定时器停止
    -- 启动后立即重置，确保后续命令能正常轮询
    CS.UnityEngine.Application.runInBackground = true

    -- 如果指定了设备，切换分辨率
    local currentDevice = "default"
    local resX = 0
    local resY = 0

    if deviceName then
        local adaptSettings = App.project:GetSettings("Adaptation")
        if adaptSettings then
            -- 在默认设备和自定义设备中查找
            local found = false

            -- 搜索默认设备
            if adaptSettings.defaultDevices then
                for i = 0, adaptSettings.defaultDevices.Count - 1 do
                    local dev = adaptSettings.defaultDevices[i]
                    if dev.name == deviceName then
                        resX = dev.resolutionX
                        resY = dev.resolutionY
                        found = true
                        break
                    end
                end
            end

            -- 搜索自定义设备
            if not found and adaptSettings.devices then
                for i = 0, adaptSettings.devices.Count - 1 do
                    local dev = adaptSettings.devices[i]
                    if dev.name == deviceName then
                        resX = dev.resolutionX
                        resY = dev.resolutionY
                        found = true
                        break
                    end
                end
            end

            if found then
                CS.FairyGUI.GRoot.inst:SetContentScaleFactor(resX, resY)
                currentDevice = deviceName
            else
                fprint("[MCPBridge] 设备未找到: " .. deviceName .. "，使用默认设备")
            end
        end
    end

    return {
        started = true,
        component = compName,
        package = pkgName,
        device = currentDevice,
        resolutionX = resX,
        resolutionY = resY
    }
end

-- 停止预览测试
function CommandHandler.handleStopTest(params, bridgePath)
    local testView = App.testView
    if testView and testView.running then
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

    local adaptSettings = App.project:GetSettings("Adaptation")
    if not adaptSettings then
        error("无法获取适配设置")
    end

    local resX = 0
    local resY = 0
    local found = false

    -- 搜索默认设备
    if adaptSettings.defaultDevices then
        for i = 0, adaptSettings.defaultDevices.Count - 1 do
            local dev = adaptSettings.defaultDevices[i]
            if dev.name == deviceName then
                resX = dev.resolutionX
                resY = dev.resolutionY
                found = true
                break
            end
        end
    end

    -- 搜索自定义设备
    if not found and adaptSettings.devices then
        for i = 0, adaptSettings.devices.Count - 1 do
            local dev = adaptSettings.devices[i]
            if dev.name == deviceName then
                resX = dev.resolutionX
                resY = dev.resolutionY
                found = true
                break
            end
        end
    end

    if not found then
        error("设备未找到: " .. deviceName)
    end

    CS.FairyGUI.GRoot.inst:SetContentScaleFactor(resX, resY)

    return {
        switched = true,
        device = deviceName,
        resolutionX = resX,
        resolutionY = resY
    }
end

-- 截取预览截图
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
        local switchResult = CommandHandler.handleSwitchDevice({ device_name = deviceName }, bridgePath)
        saveName = saveName .. "_" .. deviceName:gsub(" ", "_")
    end

    local screenshotPath = bridgePath:gsub("/", "\\") .. "\\screenshots\\" .. saveName .. ".png"

    -- 使用 GetScreenShot 截取预览渲染
    -- testView 运行时，GRoot 下有预览内容
    local groot = CS.FairyGUI.GRoot.inst
    if groot and groot.displayObject then
        captureDisplayObject(groot.displayObject, screenshotPath, scale)
    else
        error("无法获取预览渲染对象")
    end

    return {
        captured = true,
        screenshot = saveName .. ".png",
        path = screenshotPath
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
    local screenMathMode = adaptSettings.screenMathMode or "unknown"
    local designX = adaptSettings.designResolutionX or 0
    local designY = adaptSettings.designResolutionY or 0

    return {
        devices = devices,
        count = #devices,
        scaleMode = scaleMode,
        screenMathMode = screenMathMode,
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
    end

    return { found_apis = found, count = #found, target = target }
end

-- 重载所有插件
function CommandHandler.handleReloadAllPlugins(params, bridgePath)
    local results = {}

    -- 获取所有插件信息
    local mgr = App.pluginManager
    local plugins = mgr.allPlugins
    local pluginNames = {}
    if plugins then
        for i = 0, plugins.Count - 1 do
            local p = plugins[i]
            table.insert(pluginNames, p.name)
        end
    end
    table.insert(results, "loaded plugins: " .. table.concat(pluginNames, ", "))

    -- 通过定时器延迟执行 ReloadAll（给结果写入和读取留出时间）
    -- 注意：ReloadAll 会销毁并重建所有插件（包括 MCPBridge 自身）
    CS.FairyGUI.Timers.inst:Add(0.8, 1, function()
        fprint("[MCPBridge] 正在执行 PluginSystem.ReloadAll...")
        local ok, err = pcall(function()
            local ps = CS.FairyEditor.PluginSystem
            if ps and ps.inst then
                ps.inst:ReloadAll()
            elseif ps and ps.Instance then
                ps.Instance:ReloadAll()
            else
                fprint("[MCPBridge] PluginSystem.inst not found")
            end
        end)
        if not ok then
            fprint("[MCPBridge] ReloadAll failed: " .. tostring(err))
        end
    end)

    table.insert(results, "ReloadAll scheduled (0.8s delay)")
    return {
        reloaded = true,
        method = "PluginSystem.ReloadAll",
        details = results,
        warning = "all plugins will be reloaded, MCPBridge will re-initialize"
    }
end

-- ========== 发布命令 ==========

-- 发布指定包
-- 注意：FairyGUI 的发布按钮会发布所有包，无法单独发布
-- 此函数会触发发布操作，但实际会发布所有包
function CommandHandler.handlePublishPackage(params, bridgePath)
    local pkgName = params.package_name

    if not pkgName then
        error("缺少参数: package_name")
    end

    local pkg = App.project:GetPackageByName(pkgName)
    if not pkg then
        error("包不存在: " .. pkgName)
    end

    -- 获取全局发布设置
    local globalSettings = App.project:GetSettings("Publish")
    local exportPath = globalSettings and globalSettings.path or ""

    -- 点击工具栏发布按钮
    local success, err = pcall(function()
        local toolbar = App.mainView.toolbar
        if not toolbar then
            error("无法获取工具栏")
        end

        local publishBtn = toolbar:GetChild("tbPublishDesc")
        if not publishBtn then
            error("找不到发布按钮 (tbPublishDesc)")
        end

        -- 点击发布按钮
        publishBtn:FireClick(true, true)
    end)

    if success then
        return {
            published = true,
            package = pkgName,
            path = exportPath,
            method = "FireClick on tbPublishDesc",
            message = string.format("已触发发布（包 '%s' 存在，路径: %s）", pkgName, exportPath),
            warning = "发布按钮会发布所有包，无法单独发布指定包"
        }
    else
        error("发布失败: " .. tostring(err))
    end
end

-- 发布所有包
function CommandHandler.handlePublishAll(params, bridgePath)
    -- 获取全局发布设置
    local globalSettings = App.project:GetSettings("Publish")
    local exportPath = globalSettings and globalSettings.path or ""

    local allPackages = App.project.allPackages
    if not allPackages or allPackages.Count == 0 then
        error("项目中没有包")
    end

    local totalCount = allPackages.Count

    -- 点击工具栏发布按钮
    local success, err = pcall(function()
        local toolbar = App.mainView.toolbar
        if not toolbar then
            error("无法获取工具栏")
        end

        local publishBtn = toolbar:GetChild("tbPublishDesc")
        if not publishBtn then
            error("找不到发布按钮 (tbPublishDesc)")
        end

        -- 点击发布按钮（会发布所有包）
        publishBtn:FireClick(true, true)
    end)

    if success then
        -- 收集所有包名
        local packageNames = {}
        for i = 0, allPackages.Count - 1 do
            table.insert(packageNames, allPackages[i].name)
        end

        return {
            total = totalCount,
            published = totalCount,
            failed = 0,
            packages = packageNames,
            path = exportPath,
            method = "FireClick on tbPublishDesc",
            message = string.format("已触发所有 %d 个包的发布（路径: %s）", totalCount, exportPath)
        }
    else
        error("发布失败: " .. tostring(err))
    end
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

    -- 直接清空 table（修改同一个引用，main.lua 中的 _logBuffer 同步清空）
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
        -- 探查 App.consoleView 的属性和方法
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
        -- 探查 fprint 函数的来源，以及 LogManager/OutputManager 的 inst
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