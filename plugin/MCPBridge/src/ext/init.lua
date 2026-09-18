-- MCPBridge 扩展 · 注册入口
-- 由 command_handler.lua 在首次轮询/热重载时调用：
--   local ext = dofile(basePath .. "/src/ext/init.lua")
--   ext.register(CommandHandler, CommandHandler._extHandlers, basePath)
--
-- 每个命令模块自行 register(CH)，把自己实现的 handler 挂到 CommandHandler 上，
-- 再由本文件统一转换为 action 名登记进 actions 表，使 execute() 能找到它们。

local M = {}

M.VERSION = "0.1.0"

-- 命令模块清单（新增模块在此登记即可被热重载）
local MODULES = {
    "reflect.lua",    -- 反射/探测
    "hierarchy.lua",  -- 层级与元素读取
    "props.lua",      -- 元素/组件属性写入
    "snapshot.lua",   -- 组件快照/回滚
    "editing.lua",    -- 创建/删除/重命名/层级/对齐/组/撤销
    "controllers.lua",-- 控制器与页面
    "packages.lua",   -- 包/组件资源（新建组件、克隆界面、导入图片）
    "xmledit.lua",    -- 组件 XML 直改（补 API 没有暴露的 setter，如换图）
}

-- handleXxx -> xxx_yyy 的 action 名转换
local function toActionName(fname)
    local tail = string.match(fname, "^handle(.*)$")
    if not tail then return nil end
    local snake = string.gsub(tail, "(%u)", function(c) return "_" .. string.lower(c) end)
    snake = string.gsub(snake, "^_", "")
    return snake
end

--- 注册所有扩展模块
--- @param CH table 主 CommandHandler
--- @param actions table action -> handler 映射表（execute 会查这张表）
--- @param pluginPath string 插件根目录（可选，缺失时回退全局/PluginPath）
function M.register(CH, actions, pluginPath)
    local base = pluginPath
    if (base == nil or base == "") then base = _G._mcpPluginPath end
    if (base == nil or base == "") then
        local ok, pp = pcall(function() return PluginPath end)
        if ok and pp then base = pp end
    end
    if base == nil then base = "" end
    if base ~= "" and base:sub(-1) ~= "/" then base = base .. "/" end

    local root = base .. "src/ext/"
    _G._mcpPluginPath = base
    _G._mcpExtRoot = root
    _G._mcpUtilPath = root .. "util.lua"

    local loaded = {}
    local errors = {}

    CH._extHandlers = actions or {}
    local registerInto = CH._extHandlers

    for _, fileName in ipairs(MODULES) do
        local path = root .. fileName
        local ok, res = pcall(function() return dofile(path) end)
        if ok and type(res) == "table" and type(res.register) == "function" then
            local ok2, err2 = pcall(function() res.register(CH) end)
            if ok2 then
                loaded[#loaded + 1] = fileName
            else
                errors[#errors + 1] = { module = fileName, error = tostring(err2) }
            end
        else
            errors[#errors + 1] = { module = fileName, error = tostring(res), path = path }
        end
    end

    -- 扫描 CommandHandler 上所有 handleXxx 函数，登记为 action
    for fname, fn in pairs(CH) do
        if type(fn) == "function" then
            local action = toActionName(fname)
            if action and action ~= "" and registerInto[action] == nil then
                registerInto[action] = fn
            end
        end
    end

    CH.handle_ext_info = function(params, bridgePath)
        local names = {}
        for k in pairs(CH._extHandlers) do names[#names + 1] = k end
        table.sort(names)
        return {
            extVersion = M.VERSION,
            pluginPath = base,
            modules = loaded,
            moduleErrors = errors,
            actions = names,
            actionCount = #names
        }
    end
    registerInto["ext_info"] = CH.handle_ext_info

    local n = 0
    for _ in pairs(CH._extHandlers) do n = n + 1 end

    return { loaded = loaded, errors = errors, actionCount = n }
end

return M
