-- MCPBridge 主入口
-- 为 MCP 服务提供 FairyGUI 编辑器交互能力

---@type CS.FairyEditor.App
local App = App

-- 插件路径
local bridgePath = PluginPath .. "/bridge"

-- ========== fprint 拦截（日志缓冲区） ==========
-- 环形缓冲区，最多保留 500 条
local _logBuffer = {}
local _logBufferMax = 500
local _originalFprint = fprint

-- 替换全局 fprint，写入缓冲区同时保留原始输出
fprint = function(...)
    _originalFprint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    local msg = table.concat(parts, "\t")
    local entry = {
        time = os.date("%H:%M:%S"),
        level = "info",
        message = msg
    }
    table.insert(_logBuffer, entry)
    -- 超出上限时移除最旧的
    if #_logBuffer > _logBufferMax then
        table.remove(_logBuffer, 1)
    end
end

-- 暴露给 command_handler 使用
_G._mcpLogBuffer = _logBuffer

-- 命令处理模块（用 pcall 保护，防止语法错误导致插件崩溃）
local loadOk, CommandHandler = pcall(function()
    return dofile(PluginPath .. "/src/command_handler.lua")
end)
if not loadOk then
    fprint("[MCPBridge] ✗ 加载 command_handler.lua 失败: " .. tostring(CommandHandler))
    CommandHandler = nil
end

-- 定时器回调引用
local timerCallback = nil

-- 调试计数器
local pollCount = 0

-- 重载信号文件路径
local reloadSignalPath = bridgePath:gsub("/", "\\") .. "\\reload_signal"

-- 初始化
local function init()
    if not CommandHandler then
        fprint("[MCPBridge] 插件启动失败: command_handler 未加载")
        return
    end

    -- 允许后台运行，确保定时器在窗口不在前台时仍能轮询
    CS.UnityEngine.Application.runInBackground = true

    -- 创建通信目录
    CommandHandler.initBridge(bridgePath)

    -- 使用 Timers 实现轮询 (每 0.1 秒检查一次)
    timerCallback = function()
        -- 每次轮询都重新设置 runInBackground
        -- F5/Preview 模式会频繁覆盖此值，必须持续重置
        CS.UnityEngine.Application.runInBackground = true

        pollCount = pollCount + 1
        -- 每 50 次（约 5 秒）打印一次状态
        if pollCount % 50 == 0 then
            fprint("[MCPBridge] 轮询运行中，已检查 " .. pollCount .. " 次")
        end

        -- 检查热重载信号
        if CS.System.IO.File.Exists(reloadSignalPath) then
            pcall(function()
                CS.System.IO.File.Delete(reloadSignalPath)
            end)
            local ok, newHandler = pcall(function()
                return dofile(PluginPath .. "/src/command_handler.lua")
            end)
            if ok and newHandler then
                CommandHandler = newHandler
                CommandHandler.initBridge(bridgePath)
                fprint("[MCPBridge] ✓ 命令处理器已热重载")
            else
                fprint("[MCPBridge] ✗ 热重载失败: " .. tostring(newHandler))
            end
        end

        CommandHandler.poll(bridgePath)
    end
    CS.FairyGUI.Timers.inst:Add(0.1, 0, timerCallback)

    fprint("[MCPBridge] 插件已启动")
    fprint("[MCPBridge] 轮询路径: " .. bridgePath)
end

-- 清理
function onDestroy()
    -- 移除定时器
    if timerCallback then
        CS.FairyGUI.Timers.inst:Remove(timerCallback)
        timerCallback = nil
    end
    fprint("[MCPBridge] 插件已停止")
end

-- 启动
init()