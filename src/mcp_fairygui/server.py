"""MCP FairyGUI 服务入口"""

import os
from pathlib import Path
from fastmcp import FastMCP


def _detect_project_root() -> Path:
    """
    自动检测项目根目录。

    优先级：
    1. 环境变量 PROJECT_ROOT（用于特殊情况覆盖）
    2. 从 CWD 向上搜索包含 .mcp.json 的目录
    3. 基于 CWD 作为兜底
    """
    if "PROJECT_ROOT" in os.environ:
        return Path(os.environ["PROJECT_ROOT"])

    # 从 CWD 向上搜索项目根（Claude Code 可能从子目录启动 MCP）
    cwd = Path(os.getcwd()).resolve()
    for parent in [cwd] + list(cwd.parents):
        if (parent / ".mcp.json").exists():
            return parent

    # 兜底：使用 CWD
    return cwd


# 项目路径配置（自动检测）
PROJECT_ROOT = _detect_project_root()
UI_PROJECT_PATH = Path(os.environ.get("UI_PROJECT_PATH", PROJECT_ROOT / "client/ui_project"))
BRIDGE_PATH = UI_PROJECT_PATH / "plugins/MCPBridge/bridge"

# 创建 MCP 服务
mcp = FastMCP("fairygui-tools")

# 导入并注册工具模块
from .tools import package_tools, component_tools, editor_tools, file_tools

# 注册工具
package_tools.register(mcp, PROJECT_ROOT, UI_PROJECT_PATH)
component_tools.register(mcp, PROJECT_ROOT, UI_PROJECT_PATH)
editor_tools.register(mcp, BRIDGE_PATH)
file_tools.register(mcp, PROJECT_ROOT, UI_PROJECT_PATH)


def main():
    """启动 MCP 服务"""
    mcp.run()


if __name__ == "__main__":
    main()
