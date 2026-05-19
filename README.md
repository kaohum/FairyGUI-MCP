<div align="center">

# MCP for FairyGUI

**让 AI 助手直接操作 FairyGUI 编辑器，实现 UI 开发自动化**

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

[English](#english) | [中文](#中文)

</div>

---

<a id="中文"></a>

## 概述

MCP for FairyGUI 是一个基于 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) 的工具集，让 AI 编程助手（如 Claude Code、Cursor 等）能够直接与 FairyGUI 编辑器交互。

AI 助手可以浏览 UI 资源、打开和预览组件、截图验证、切换控制器状态、发布 UI 包——全程无需手动操作编辑器。

## 工作原理

```
┌───────────────┐   MCP (stdio)   ┌─────────────────┐   文件轮询    ┌─────────────────┐
│   AI 助手      │◄──────────────► │  Python MCP 服务 │◄───────────►│  FairyGUI 编辑器 │
│ (Claude Code) │                 │   (fastmcp)     │    JSON     │   (Lua 插件)     │
└───────────────┘                 └─────────────────┘             └─────────────────┘
```

**通信流程：**

1. AI 助手调用 MCP 工具 → Python MCP 服务接收请求
2. MCP 服务将 JSON 命令写入 `bridge/commands/` 目录
3. FairyGUI 编辑器中的 Lua 插件每 100ms 轮询命令文件
4. 插件在编辑器内执行命令，将结果写入 `bridge/results/`
5. MCP 服务读取结果，返回给 AI 助手

## 功能特性

### 包与资源管理

| 工具 | 说明 |
|------|------|
| `fg_list_packages` | 列出项目中所有 UI 包（包名、ID、资源数） |
| `fg_get_package_info` | 获取包详情（组件/图片/字体/文件夹列表） |
| `fg_list_resources` | 按类型过滤列出包内资源 |
| `fg_search_component` | 跨包模糊搜索组件 |
| `fg_move_resource` | 移动或重命名包内资源 |
| `fg_delete_resource` | 删除资源（自动扫描引用，支持强制删除） |

### 组件分析

| 工具 | 说明 |
|------|------|
| `fg_read_component` | 读取组件原始 XML 内容 |
| `fg_parse_component` | 解析 XML 为结构化自然语言描述（含控制器、Gear、Relation、动画） |
| `fg_validate_component` | 验证组件规范（XML 格式、属性完整性、命名规范、ID 唯一性） |

### 编辑器交互

| 工具 | 说明 |
|------|------|
| `fg_editor_status` | 检查编辑器和插件连接状态 |
| `fg_editor_activate` | 激活编辑器窗口到前台 |
| `fg_editor_reload` | 刷新项目或指定包的资源 |
| `fg_editor_open_component` | 在编辑器中打开组件进行编辑 |
| `fg_editor_save` | 保存当前打开的组件 |
| `fg_editor_close` | 关闭当前组件 |
| `fg_editor_get_selection` | 获取编辑器中当前选中的元素 |

### 预览与截图

| 工具 | 说明 |
|------|------|
| `fg_editor_preview` | 在预览窗口中显示组件 |
| `fg_editor_start_test` | 启动 F5 预览测试（支持指定设备分辨率，如 iPhone X、iPad Pro） |
| `fg_editor_stop_test` | 停止 F5 预览 |
| `fg_editor_capture_preview` | 截取预览运行中的截图（支持切换设备分辨率） |
| `fg_editor_screenshot` | 截取编辑器全屏或组件画布截图 |

### 控制器操作

| 工具 | 说明 |
|------|------|
| `fg_editor_list_controllers` | 列出当前组件的所有控制器（含页面名称和当前选中页） |
| `fg_editor_switch_controller` | 切换控制器页面（按索引或名称） |

### 发布

| 工具 | 说明 |
|------|------|
| `fg_editor_publish_package` | 发布指定 UI 包 |
| `fg_editor_publish_all` | 发布所有 UI 包 |

### 插件管理

| 工具 | 说明 |
|------|------|
| `fg_editor_reload_plugin` | 热重载命令处理器（无需重启插件） |
| `fg_editor_reload_all_plugins` | 重载所有 FairyGUI 插件 |

## 系统要求

- **Python** 3.10+
- **FairyGUI 编辑器**（Windows 版本）
- MCP 客户端（Claude Code / Cursor / 其他支持 MCP 的工具）
- Windows 操作系统（窗口截图功能依赖 Win32 API）

## 快速开始

### 1. 安装 Python MCP 服务

```bash
cd fairyGUI-MCP
pip install -e .
```

Windows 用户也可以双击 `install.bat`。

### 2. 安装 FairyGUI 编辑器插件

将 `plugin/MCPBridge/` 目录复制到你的 FairyGUI 项目的 `plugins/` 目录下：

```
your-fairygui-project/
└── plugins/
    └── MCPBridge/          ← 复制整个目录
        ├── package.json
        ├── main.lua
        ├── src/
        │   └── command_handler.lua
        └── bridge/
            ├── commands/
            ├── results/
            └── screenshots/
```

打开 FairyGUI 编辑器，控制台出现 `[MCPBridge] 插件已启动` 即表示成功。

### 3. 配置 MCP 客户端

**Claude Code** (`~/.claude/settings.json` 或项目 `.mcp.json`)：

```json
{
  "mcpServers": {
    "fairygui-tools": {
      "command": "python",
      "args": ["-m", "mcp_fairygui.server"],
      "cwd": "/path/to/fairyGUI-MCP",
      "env": {
        "UI_PROJECT_PATH": "/path/to/your/fairygui-project"
      }
    }
  }
}
```

**Cursor** (`.cursor/mcp.json`)：

```json
{
  "mcpServers": {
    "fairygui-tools": {
      "command": "python",
      "args": ["-m", "mcp_fairygui.server"],
      "cwd": "/path/to/fairyGUI-MCP",
      "env": {
        "UI_PROJECT_PATH": "/path/to/your/fairygui-project"
      }
    }
  }
}
```

> `UI_PROJECT_PATH` 是你的 FairyGUI 工程根目录（包含 `assets/` 和 `package.xml` 的目录）。

### 4. 验证连接

在 AI 助手中调用：

```
fg_editor_status
```

应返回：

```
编辑器: 运行中
通信目录: 正常
插件通信: 正常
已加载 X 个 UI 包
```

## 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `UI_PROJECT_PATH` | **是** | FairyGUI UI 工程根目录 |
| `PROJECT_ROOT` | 否 | 项目根目录（自动检测的兜底） |

## 项目结构

```
fairyGUI-MCP/
├── README.md
├── LICENSE
├── pyproject.toml                      # Python 包配置
├── install.bat                         # Windows 安装脚本
├── claude_settings_example.json        # MCP 配置示例
│
├── src/mcp_fairygui/                   # Python MCP 服务
│   ├── server.py                       #   服务入口（路径自动检测）
│   ├── tools/
│   │   ├── package_tools.py            #   包与资源查询
│   │   ├── component_tools.py          #   组件分析（读取/解析/验证）
│   │   ├── editor_tools.py             #   编辑器交互（预览/截图/控制器/发布）
│   │   └── file_tools.py              #   文件管理（移动/删除）
│   ├── parsers/
│   │   ├── xml_parser.py               #   FairyGUI XML 结构化解析器
│   │   └── description_gen.py          #   组件自然语言描述生成器
│   ├── bridge/
│   │   └── command_queue.py            #   命令队列管理器
│   └── utils/
│       └── window_manager.py           #   Windows 窗口管理（激活/截图）
│
└── plugin/MCPBridge/                   # FairyGUI 编辑器插件
    ├── package.json                    #   插件配置
    ├── main.lua                        #   插件入口（定时器轮询 + 日志缓冲）
    ├── src/
    │   └── command_handler.lua         #   命令处理器（编辑器操作实际实现）
    └── bridge/                         #   通信目录
        ├── commands/                   #   MCP → 编辑器
        ├── results/                    #   编辑器 → MCP
        └── screenshots/                #   截图输出
```

## 技术细节

### 通信协议

| 项目 | 说明 |
|------|------|
| 传输层 | 文件系统 JSON 命令/结果队列 |
| 命令格式 | `{ "id": "cmd_xxx", "action": "...", "params": {...} }` |
| 结果格式 | `{ "id": "cmd_xxx", "status": "success"\|"error", "data": {...} }` |
| 轮询间隔 | 100ms（Lua 端 FairyGUI Timers） |
| 默认超时 | 5 秒（发布操作 60-300 秒） |

### Lua 插件

- 基于 FairyGUI 插件系统，随编辑器启动自动加载
- 拦截 `fprint` 全局函数，维护环形日志缓冲区（最多 500 条）
- 持续重置 `runInBackground`，防止窗口失焦后定时器暂停
- 支持热重载信号文件机制，更新 `command_handler.lua` 无需重启

### Python MCP 服务

- 基于 [fastmcp](https://github.com/jlowin/fastmcp) 框架
- 自动检测项目路径（环境变量 → CWD 向上搜索 → 兜底）
- Windows 窗口管理：Win32 API 自动激活编辑器 + PrintWindow 截图

### XML 解析

- 完整 FairyGUI 组件 Schema（控制器、显示列表、Gear、Relation、Transition、扩展属性）
- 结构化 dataclass 模型（`Component`、`Controller`、`DisplayElement` 等）
- 自然语言描述生成器，将组件结构转化为 AI 友好的文档

## 使用示例

### AI 辅助 UI 开发

```
用户：帮我查看 Common 包里有哪些按钮组件

AI 调用: fg_list_resources("Common", "component")
AI 调用: fg_search_component("Button")
→ 列出所有匹配组件，包含 ID、路径、导出状态
```

### 自动化 UI 验证

```
AI 调用: fg_editor_open_component("Build", "BuildLevelUp")
AI 调用: fg_editor_list_controllers()
→ 获取所有控制器和页面

AI 调用: fg_editor_switch_controller("state", page_index=0)
AI 调用: fg_editor_screenshot(target="preview")
→ 截图验证正常状态

AI 调用: fg_editor_switch_controller("state", page_index=1)
AI 调用: fg_editor_screenshot(target="preview")
→ 截图验证 MAX 状态
```

### 组件分析与校验

```
AI 调用: fg_parse_component("Common", "ButtonItem")
→ 生成结构化描述：尺寸、控制器、元素列表、Gear/Relation 配置、动画定义

AI 调用: fg_validate_component("Common", "ButtonItem")
→ 验证：XML 格式、属性完整性、命名规范、ID 唯一性
```

### 批量发布

```
AI 调用: fg_editor_publish_all()
→ 发布所有 UI 包到 Unity 项目
```

## 依赖

### Python（必填）

| 包 | 版本 | 说明 |
|---|------|------|
| `fastmcp` | >=0.1.0 | MCP 服务框架 |
| `pydantic` | >=2.0.0 | 数据校验 |

### Python（可选，Windows 截图功能）

| 包 | 说明 |
|---|------|
| `pywin32` | Win32 API（窗口管理/截图） |
| `Pillow` | 图像处理（PrintWindow 截图转 PNG） |

安装可选依赖：`pip install -e ".[windows]"`

## 常见问题

**Q：显示"插件通信: 超时"**

确保 MCPBridge 插件已加载。检查 FairyGUI 编辑器控制台是否有 `[MCPBridge] 插件已启动`。如果插件未加载，检查 `plugins/MCPBridge/` 目录是否正确放置。

**Q：截图功能不可用**

编辑器全屏截图需要 `pywin32` 和 `Pillow`：`pip install pywin32 Pillow`。组件画布截图由 Lua 插件通过 `GetScreenShot` API 实现，不需要额外依赖。

**Q：F5 预览模式下命令超时**

F5 模式会将 `runInBackground` 设为 `false`。插件会持续重置此标志，但如果编辑器被其他全屏窗口遮挡，仍可能超时。确保编辑器在前台可见。

**Q：支持 macOS/Linux 吗？**

MCP 服务本身跨平台。Lua 插件运行在 FairyGUI 编辑器内（Unity），与操作系统无关。但窗口管理和全屏截图功能依赖 Windows API（`pywin32`），其他平台需要自行实现对应功能。欢迎贡献！

## 贡献

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/amazing-feature`
3. 提交更改：`git commit -m 'Add amazing feature'`
4. 推送分支：`git push origin feature/amazing-feature`
5. 提交 Pull Request

## 致谢

- [FairyGUI](https://www.fairygui.com/) - 优秀的 Unity UI 解决方案
- [fastmcp](https://github.com/jlowin/fastmcp) - Python MCP 框架
- [Model Context Protocol](https://modelcontextprotocol.io/) - AI 工具通信协议

## 许可证

[MIT License](LICENSE)

---

<a id="english"></a>

## Overview

MCP for FairyGUI is a [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) toolset that enables AI coding assistants (Claude Code, Cursor, etc.) to interact directly with the FairyGUI editor — browse UI resources, open and preview components, capture screenshots, switch controller states, and publish packages, all without manual editor operations.

## How It Works

```
┌───────────────┐   MCP (stdio)   ┌─────────────────┐   File Polling  ┌─────────────────┐
│  AI Client    │◄──────────────► │  Python MCP Srv │◄──────────────► │  FairyGUI Editor│
│ (Claude Code) │                 │   (fastmcp)     │     JSON        │   (Lua Plugin)  │
└───────────────┘                 └─────────────────┘                 └─────────────────┘
```

1. AI assistant calls an MCP tool → Python MCP server receives the request
2. MCP server writes a JSON command to `bridge/commands/`
3. Lua plugin inside FairyGUI editor polls for commands every 100ms
4. Plugin executes the command in editor context, writes result to `bridge/results/`
5. MCP server reads the result and returns it to the AI assistant

## Features

- **Package & Resource Management** — List, search, move, and delete UI resources
- **Component Analysis** — Read, parse, and validate component XML
- **Editor Interaction** — Open, save, close components; get selection
- **Preview & Screenshots** — Preview with device support; capture editor or canvas screenshots
- **Controller Operations** — List and switch controller pages
- **Publishing** — Publish individual or all packages
- **Plugin Management** — Hot-reload command handler; reload all plugins

## System Requirements

- **Python** 3.10+
- **FairyGUI Editor** (Windows)
- MCP client (Claude Code / Cursor / any MCP-compatible tool)
- Windows OS (window screenshot features require Win32 API)

## Quick Start

### 1. Install Python MCP Server

```bash
cd fairyGUI-MCP
pip install -e .
```

### 2. Install FairyGUI Editor Plugin

Copy `plugin/MCPBridge/` into your FairyGUI project's `plugins/` directory:

```
your-fairygui-project/
└── plugins/
    └── MCPBridge/
        ├── package.json
        ├── main.lua
        ├── src/
        └── bridge/
```

Open FairyGUI editor and look for `[MCPBridge] Plugin started` in the console.

### 3. Configure MCP Client

```json
{
  "mcpServers": {
    "fairygui-tools": {
      "command": "python",
      "args": ["-m", "mcp_fairygui.server"],
      "cwd": "/path/to/fairyGUI-MCP",
      "env": {
        "UI_PROJECT_PATH": "/path/to/your/fairygui-project"
      }
    }
  }
}
```

### 4. Verify

Call `fg_editor_status` — you should see "Editor: Running, Plugin communication: OK".

## Available Tools (22)

| Tool | Description |
|------|-------------|
| `fg_list_packages` | List all UI packages |
| `fg_get_package_info` | Get detailed package info |
| `fg_list_resources` | List resources by type |
| `fg_search_component` | Search components across packages |
| `fg_read_component` | Read component XML |
| `fg_parse_component` | Parse to structured description |
| `fg_validate_component` | Validate against best practices |
| `fg_move_resource` | Move or rename resource |
| `fg_delete_resource` | Delete resource (with reference check) |
| `fg_editor_status` | Check editor status |
| `fg_editor_activate` | Activate editor window |
| `fg_editor_reload` | Refresh resources |
| `fg_editor_open_component` | Open component |
| `fg_editor_preview` | Preview component |
| `fg_editor_start_test` | Start F5 preview (with device) |
| `fg_editor_stop_test` | Stop F5 preview |
| `fg_editor_capture_preview` | Capture preview screenshot |
| `fg_editor_screenshot` | Capture editor/canvas screenshot |
| `fg_editor_get_selection` | Get selected elements |
| `fg_editor_list_controllers` | List controllers with pages |
| `fg_editor_switch_controller` | Switch controller page |
| `fg_editor_save` | Save component |
| `fg_editor_close` | Close component |
| `fg_editor_publish_package` | Publish a package |
| `fg_editor_publish_all` | Publish all packages |
| `fg_editor_reload_plugin` | Hot-reload command handler |
| `fg_editor_reload_all_plugins` | Reload all plugins |

## Contributing

1. Fork this repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit your changes: `git commit -m 'Add amazing feature'`
4. Push the branch: `git push origin feature/amazing-feature`
5. Submit a Pull Request

## License

[MIT License](LICENSE)
