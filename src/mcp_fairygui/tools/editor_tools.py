"""编辑器交互工具 - 通过文件轮询与 FairyGUI 插件通信

在线操作（需要编辑器运行）：
- 预览、截图、刷新资源、打开组件编辑、获取选中元素、保存/关闭
- 发送命令前会自动激活编辑器窗口
"""

import json
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional, Literal, Dict, Any
from fastmcp import FastMCP
from ..utils.window_manager import ensure_editor_active, is_editor_running, capture_editor_screenshot


# 全局变量
_bridge_path: Path = None


def register(mcp: FastMCP, bridge_path: Path):
    """注册编辑器交互工具"""
    global _bridge_path
    _bridge_path = bridge_path

    @mcp.tool()
    def fg_editor_activate() -> str:
        """激活 FairyGUI 编辑器窗口

        将 FairyGUI 编辑器置于前台（通过 Win32 API）。
        注意：需要 FairyGUI 编辑器正在运行且 MCPBridge 插件已加载。

        Returns:
            操作结果
        """
        # Win32 API 激活窗口（Python 侧负责）
        ensure_editor_active()

        # Lua 侧设置 runInBackground
        result = _send_command("activate", {})
        if result.get("status") == "success":
            return "编辑器已激活（通过 Win32 API）"
        return _format_result(result, "编辑器激活命令已发送")

    @mcp.tool()
    def fg_editor_reload(package_name: Optional[str] = None) -> str:
        """刷新 FairyGUI 资源

        重新加载项目或指定包的资源。

        Args:
            package_name: 要刷新的包名，不指定则刷新整个项目

        Returns:
            操作结果
        """
        result = _send_command("reload", {"package_name": package_name})
        if package_name:
            return _format_result(result, f"包 '{package_name}' 刷新命令已发送")
        return _format_result(result, "项目刷新命令已发送")

    @mcp.tool()
    def fg_editor_open_component(package_name: str, component_name: str) -> str:
        """打开组件进行编辑

        在 FairyGUI 编辑器中打开指定的组件。

        Args:
            package_name: 包名
            component_name: 组件名（不含 .xml 后缀）

        Returns:
            操作结果，包括组件的 URL 和路径
        """
        result = _send_command("open_component", {
            "package_name": package_name,
            "component_name": component_name
        })

        if result.get("status") == "success":
            data = result.get("data", {})
            return f"已打开组件: {package_name}/{component_name}\nURL: {data.get('url', 'N/A')}\n路径: {data.get('path', 'N/A')}"

        return _format_result(result, f"打开 {package_name}/{component_name}")

    @mcp.tool()
    def fg_editor_preview(package_name: str, component_name: str) -> str:
        """预览组件

        在 FairyGUI 编辑器的预览窗口中显示组件。

        Args:
            package_name: 包名
            component_name: 组件名

        Returns:
            操作结果
        """
        result = _send_command("preview", {
            "package_name": package_name,
            "component_name": component_name
        })

        if result.get("status") == "success":
            return f"正在预览组件: {package_name}/{component_name}\n提示：使用 fg_editor_screenshot 可以截取预览窗口"

        return _format_result(result, f"预览 {package_name}/{component_name}")

    @mcp.tool()
    def fg_editor_screenshot(
        target: Literal["editor", "preview"] = "editor",
        save_name: Optional[str] = None
    ) -> str:
        """截取 FairyGUI 编辑器截图

        Args:
            target: 截图目标
                - "editor": 截取整个编辑器窗口
                - "preview": 截取预览窗口（需要先调用 fg_editor_preview）
            save_name: 保存文件名（不含扩展名），不指定则自动生成时间戳文件名

        Returns:
            截图文件路径
        """
        if not save_name:
            save_name = f"screenshot_{int(time.time())}"

        # 确保截图目录存在
        screenshots_dir = _bridge_path / "screenshots"
        screenshots_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = screenshots_dir / f"{save_name}.png"

        if target == "editor":
            # 全屏截图：使用 Python 端 Windows API
            ensure_editor_active()
            time.sleep(0.3)

            if capture_editor_screenshot(str(screenshot_path)):
                return f"截图已保存: {screenshot_path}\n文件名: {save_name}.png"
            else:
                return "截图失败: 无法捕获编辑器窗口，请确认编辑器正在运行"
        else:
            # 组件画布截图：使用 Lua 插件 GetScreenShot
            result = _send_command("screenshot", {
                "target": "preview",
                "save_name": save_name
            }, timeout_ms=10000)

            if result.get("status") == "success":
                data = result.get("data", {})
                path = data.get("path", str(screenshot_path))
                debug = data.get("debug", "")
                msg = f"截图已保存: {path}\n文件名: {save_name}.png"
                if debug:
                    msg += f"\n调试信息:\n{debug}"
                return msg

            return f"截图失败: {result.get('error', '未知错误')}"

    @mcp.tool()
    def fg_editor_get_selection() -> str:
        """获取当前选中的元素

        返回 FairyGUI 编辑器中当前选中的元素列表。

        Returns:
            选中元素的列表，包括 ID、名称和类型
        """
        result = _send_command("get_selection", {})

        if result.get("status") == "success":
            data = result.get("data", {})
            selection = data.get("selection", [])
            count = data.get("count", 0)

            if count == 0:
                return "当前没有选中任何元素"

            lines = [f"当前选中 {count} 个元素:"]
            for i, item in enumerate(selection, 1):
                lines.append(f"  {i}. {item.get('name', 'N/A')}")
                lines.append(f"     ID: {item.get('id', 'N/A')}, 类型: {item.get('type', 'N/A')}")

            return "\n".join(lines)

        return f"获取选中失败: {result.get('error', '未知错误')}"

    @mcp.tool()
    def fg_editor_start_test(
        package_name: str,
        component_name: str,
        device_name: Optional[str] = None
    ) -> str:
        """启动 F5 预览模式

        在 FairyGUI 编辑器中启动预览测试，支持指定设备分辨率进行适配预览。

        Args:
            package_name: 包名
            component_name: 组件名（不含 .xml 后缀）
            device_name: 设备名称（可选），如 "iPhone X"、"iPad Pro" 等，不指定则使用默认分辨率

        Returns:
            预览状态、当前设备和分辨率信息
        """
        params = {
            "package_name": package_name,
            "component_name": component_name
        }
        if device_name:
            params["device_name"] = device_name

        result = _send_command("start_test", params, timeout_ms=10000)

        if result.get("status") == "success":
            data = result.get("data", {})
            item_name = data.get("item_name", component_name)
            item_id = data.get("item_id", "")
            device = data.get("device", "default")
            device_found = data.get("device_found", True)
            res_x = data.get("resolutionX", 0)
            res_y = data.get("resolutionY", 0)
            methods = data.get("methods", "")
            lines = [f"预览已启动: {package_name}/{item_name} (id={item_id})"]
            if device_name:
                if device_found:
                    lines.append(f"设备: {device} ({res_x}x{res_y})")
                    if methods:
                        lines.append(f"切换方法: {methods}")
                else:
                    lines.append(f"警告: 设备 '{device_name}' 未找到，使用默认分辨率。可用设备请使用 fg_editor_list_devices 查询")
            lines.append("提示: 使用 fg_editor_capture_preview 截图，fg_editor_stop_test 停止预览")
            return "\n".join(lines)

        return _format_result(result, f"启动预览 {package_name}/{component_name}")

    @mcp.tool()
    def fg_editor_capture_preview(
        save_name: Optional[str] = None,
        device_name: Optional[str] = None
    ) -> str:
        """截取预览窗口截图

        截取当前预览运行中的截图。可选指定设备名称，会先切换到该设备分辨率再截图。

        Args:
            save_name: 保存文件名（不含扩展名），不指定则自动生成
            device_name: 设备名称（可选），指定则先切换到该设备分辨率再截图

        Returns:
            截图文件路径
        """
        if not save_name:
            save_name = f"preview_{int(time.time())}"

        # 通过 Lua 插件截取预览渲染（支持设备切换）
        params = {"save_name": save_name}
        if device_name:
            params["device_name"] = device_name

        result = _send_command("capture_preview", params, timeout_ms=10000)

        if result.get("status") == "success":
            data = result.get("data", {})
            path = data.get("path", "")
            filename = data.get("screenshot", f"{save_name}.png")
            capture_source = data.get("capture_source", "unknown")
            lines = [f"预览截图已保存: {path}", f"文件名: {filename}"]
            lines.append(f"截图目标: {capture_source}")
            return "\n".join(lines)

        return f"截图失败: {result.get('error', '未知错误')}"

    @mcp.tool()
    def fg_editor_stop_test() -> str:
        """停止预览模式

        停止 FairyGUI 编辑器中正在运行的 F5 预览测试。

        Returns:
            操作结果
        """
        result = _send_command("stop_test", {})

        if result.get("status") == "success":
            data = result.get("data", {})
            if data.get("stopped"):
                return "预览已停止"
            return "预览未在运行"

        return _format_result(result, "停止预览")

    @mcp.tool()
    def fg_editor_switch_controller(
        controller_name: str,
        page_index: Optional[int] = None,
        page_name: Optional[str] = None
    ) -> str:
        """切换控制器状态

        切换当前打开组件中指定控制器的选中页。page_index 和 page_name 二选一。
        如果使用 page_name，会先从组件 XML 解析页面名称映射到索引。

        Args:
            controller_name: 控制器名称
            page_index: 目标页索引（从 0 开始）
            page_name: 目标页名称（与 page_index 二选一）

        Returns:
            切换结果，包括旧页和新页信息
        """
        # 如果用 page_name，先从 list_controllers 获取 XML 页面信息来解析索引
        if page_name is not None and page_index is None:
            list_result = _send_command("list_controllers", {})
            if list_result.get("status") == "success":
                data = list_result.get("data", {})
                pkg = data.get("package_name", "")
                comp = data.get("component_name", "")
                if pkg and comp:
                    page_map = _get_controller_pages_from_xml(pkg, comp, controller_name)
                    if page_name in page_map:
                        page_index = page_map[page_name]
                    else:
                        available = ", ".join(page_map.keys()) if page_map else "无"
                        return f"页面不存在: '{page_name}'（控制器: {controller_name}）\n可用页面: {available}"

        if page_index is None:
            return "缺少参数: 需要 page_index 或有效的 page_name"

        params = {"controller_name": controller_name, "page_index": page_index}
        result = _send_command("switch_controller", params)

        if result.get("status") == "success":
            data = result.get("data", {})
            old_idx = data.get("oldIndex", "?")
            new_idx = data.get("newIndex", "?")
            total = data.get("totalPages", "?")
            return f"控制器 '{controller_name}' 已切换: 页 {old_idx} → {new_idx}, 共 {total} 页"

        return _format_result(result, f"切换控制器 {controller_name}")

    @mcp.tool()
    def fg_editor_list_controllers() -> str:
        """列出当前组件的所有控制器

        获取当前打开组件中的所有控制器及其页面信息。

        Returns:
            控制器列表，包括名称、页面数、当前选中页
        """
        result = _send_command("list_controllers", {})

        if result.get("status") == "success":
            data = result.get("data", {})
            controllers = data.get("controllers", [])
            comp_name = data.get("component", "unknown")
            pkg_name = data.get("package_name", "")
            component_name = data.get("component_name", "")

            if not controllers:
                return f"组件 '{comp_name}' 没有控制器"

            # 从 XML 补充页面名称和默认页
            xml_pages = {}
            xml_selected = {}
            if pkg_name and component_name:
                xml_pages = _get_all_controller_pages_from_xml(pkg_name, component_name)
                xml_selected = _get_controller_saved_selected_from_xml(pkg_name, component_name)

            lines = [f"组件 '{comp_name}' 共 {len(controllers)} 个控制器:", ""]
            for i, ctrl in enumerate(controllers, 1):
                name = ctrl.get("name", "?")
                selected = ctrl.get("selectedIndex", 0)
                page_count = ctrl.get("pageCount", 0)
                alias = ctrl.get("alias", "")

                header = f"### {i}. {name}"
                if alias:
                    header += f" ({alias})"
                header += f" - 当前页: {selected}, 共{page_count}页"
                saved_sel = xml_selected.get(name)
                if saved_sel is not None and saved_sel != selected:
                    header += f" (XML默认: {saved_sel})"
                lines.append(header)

                # 显示页面详情
                pages = xml_pages.get(name, {})
                for j in range(page_count):
                    page_name_str = pages.get(j, f"page{j}")
                    marker = " <--" if j == selected else ""
                    lines.append(f"   [{j}] {page_name_str}{marker}")
                lines.append("")

            return "\n".join(lines)

        return _format_result(result, "列出控制器")

    @mcp.tool()
    def fg_editor_select_element(element_name: str) -> str:
        """在编辑器中选中指定元素

        在当前打开的组件中选中指定名称的元素。选中后可在编辑器中查看其属性。

        Args:
            element_name: 要选中的元素名称（如 "title", "bg"）

        Returns:
            选中结果
        """
        result = _send_command("select_element", {
            "element_name": element_name
        })

        if result.get("status") == "success":
            data = result.get("data", {})
            select_method = data.get("select_method", "unknown")
            inspector_refreshed = data.get("inspector_refreshed", False)
            refresh_method = data.get("inspector_refresh_method", "none")
            lines = [f"已选中元素: {element_name}", f"选中方法: {select_method}"]
            if inspector_refreshed:
                lines.append(f"检查器刷新: 已触发 ({refresh_method})")
            else:
                lines.append("检查器刷新: 未触发（请手动点击检查器面板）")
            return "\n".join(lines)

        return f"选中元素失败: {result.get('error', '未知错误')}"

    @mcp.tool()
    def fg_editor_save() -> str:
        """保存当前打开的组件

        保存 FairyGUI 编辑器中当前活动的组件文档。

        Returns:
            操作结果
        """
        result = _send_command("save", {})
        return _format_result(result, "组件已保存")

    @mcp.tool()
    def fg_editor_close() -> str:
        """关闭当前打开的组件

        关闭 FairyGUI 编辑器中当前活动的组件文档。

        Returns:
            操作结果
        """
        result = _send_command("close", {})
        return _format_result(result, "组件已关闭")

    @mcp.tool()
    def fg_editor_reload_plugin() -> str:
        """热重载 MCPBridge 插件的命令处理器

        重新加载 command_handler.lua，无需手动在编辑器中重启插件。
        适用于修改了 command_handler.lua 后立即生效。
        注意：main.lua 的修改仍需手动重载插件。

        Returns:
            操作结果
        """
        signal_path = _bridge_path / "reload_signal"

        try:
            signal_path.parent.mkdir(parents=True, exist_ok=True)
            signal_path.write_text("reload", encoding="utf-8")
        except Exception as e:
            return f"创建重载信号失败: {e}"

        # 等待信号被处理（插件每100ms轮询一次）
        time.sleep(1.0)

        if signal_path.exists():
            return "重载信号已发送，但可能未被处理（编辑器是否在前台？）"

        # 验证插件仍可通信
        test_result = _send_command("list_packages", {}, timeout_ms=3000)
        if test_result.get("status") == "success":
            return "命令处理器已热重载成功"
        else:
            return "重载信号已处理，但通信验证失败，请检查 command_handler.lua 是否有语法错误"




    @mcp.tool()
    def fg_editor_status() -> str:
        """检查编辑器和插件状态

        检查 FairyGUI 编辑器是否正在运行，以及 MCPBridge 插件是否正常工作。

        Returns:
            状态信息
        """
        lines = []

        # 检查编辑器窗口
        if is_editor_running():
            lines.append("编辑器: 运行中")
        else:
            lines.append("编辑器: 未运行")
            lines.append("请先启动 FairyGUI 编辑器")
            return "\n".join(lines)

        # 检查 bridge 目录是否存在
        if not _bridge_path.exists():
            lines.append(f"通信目录: 不存在 ({_bridge_path})")
            lines.append("请确保 MCPBridge 插件已加载")
            return "\n".join(lines)

        lines.append("通信目录: 正常")

        # 尝试发送测试命令
        result = _send_command("list_packages", {}, timeout_ms=3000)

        if result.get("status") == "success":
            data = result.get("data", {})
            package_count = data.get("count", 0)
            lines.append("插件通信: 正常")
            lines.append(f"已加载 {package_count} 个 UI 包")
        elif "timeout" in result.get("error", "").lower():
            lines.append("插件通信: 超时")
            lines.append("可能原因: MCPBridge 插件未加载")
        else:
            lines.append(f"插件通信: 异常 - {result.get('error', '未知错误')}")

        return "\n".join(lines)

    @mcp.tool()
    def fg_editor_publish_package(package_name: str) -> str:
        """发布指定的 UI 包

        将指定的 FairyGUI UI 包发布到 Unity 项目。
        发布路径由 FairyGUI 项目设置中的全局发布设置决定。
        注意：FairyGUI 发布按钮会发布所有包，无法单独发布指定包。

        Args:
            package_name: 要发布的包名称

        Returns:
            发布结果，包括包名和发布路径
        """
        result = _send_command("publish_package", {
            "package_name": package_name
        }, timeout_ms=60000)  # 发布可能需要较长时间

        if result.get("status") == "success":
            data = result.get("data", {})
            if data.get("published"):
                # 发布后激活编辑器窗口（防止 runInBackground 被覆盖导致通信中断）
                ensure_editor_active()
                msg = f"发布已触发: {data.get('package', package_name)}\n路径: {data.get('path', 'N/A')}\n方法: {data.get('method', 'unknown')}"
                if data.get("warning"):
                    msg += f"\n警告: {data['warning']}"
                return msg
            else:
                reason = data.get("reason", "未知原因")
                return f"发布失败: {reason}\n请尝试在编辑器中手动发布"

        return f"发布失败: {result.get('error', '未知错误')}"

    @mcp.tool()
    def fg_editor_publish_all() -> str:
        """发布所有 UI 包

        将项目中所有的 FairyGUI UI 包发布到 Unity 项目。
        发布路径由 FairyGUI 项目设置中的全局发布设置决定。

        Returns:
            发布结果，包括成功/失败的包数量和详细信息
        """
        result = _send_command("publish_all", {}, timeout_ms=300000)  # 5分钟超时

        if result.get("status") == "success":
            data = result.get("data", {})
            total = data.get("total", 0)
            published = data.get("published", 0)
            failed = data.get("failed", 0)
            path = data.get("path", "N/A")

            if published > 0:
                # 发布后激活编辑器窗口（防止 runInBackground 被覆盖导致通信中断）
                ensure_editor_active()
                lines = [f"发布已触发: {published}/{total} 个包"]
                lines.append(f"发布路径: {path}")
                lines.append(f"方法: {data.get('method', 'unknown')}")

                lines.append(f"\n涉及的包:")
                for pkg in data.get("packages", []):
                    lines.append(f"  - {pkg}")

                return "\n".join(lines)
            else:
                reason = data.get("reason", "未知原因")
                lines = [f"发布失败: {reason}"]
                lines.append("请尝试在编辑器中手动发布（菜单: 项目 > 发布）")
                return "\n".join(lines)

        return f"发布失败: {result.get('error', '未知错误')}"

    # @mcp.tool()  # 暂时禁用
    def fg_editor_get_logs(
        max_count: int = 100,
        level: Optional[str] = None
    ) -> str:
        """获取 FairyGUI 编辑器日志

        获取 FairyGUI 编辑器控制台中的日志记录。

        Args:
            max_count: 返回的最大日志数量（默认 100）
            level: 日志级别过滤（info/warn/error/all），默认返回全部级别（all）

        Returns:
            日志列表，包含时间戳、级别、消息
        """
        params = {"max_count": max_count}
        if level:
            params["level"] = level

        result = _send_command("get_logs", params, timeout_ms=10000)

        if result.get("status") == "success":
            data = result.get("data", {})
            total = data.get("total", 0)
            logs = data.get("logs", [])
            returned = data.get("returned", 0)

            lines = [f"获取到 {returned}/{total} 条日志:\n"]

            for log in logs:
                time_str = log.get("time", "")
                level_str = log.get("level", "info")
                msg = log.get("message", "")
                # 截断过长消息
                if len(msg) > 200:
                    msg = msg[:200] + "..."
                lines.append(f"[{level_str}] {time_str}  {msg}")

            return "\n".join(lines)

        return f"获取日志失败: {result.get('error', '未知错误')}"

    # @mcp.tool()  # 暂时禁用
    def fg_editor_clear_logs() -> str:
        """清空 FairyGUI 编辑器日志

        清空 FairyGUI 编辑器控制台中的所有日志记录。
        注意：清空操作为异步执行（fire-and-forget），命令立即返回成功，
        实际清空在约 50ms 后完成，不保证在返回前完成。

        Returns:
            操作结果
        """
        result = _send_command("clear_logs", {}, timeout_ms=5000)

        if result.get("status") == "success":
            data = result.get("data", {})
            cleared = data.get("cleared", False)
            method = data.get("method", "unknown")
            return f"日志已清空 (方法: {method})" if cleared else "清空失败"

        return f"清空日志失败: {result.get('error', '未知错误')}"


def _send_command(action: str, params: Dict[str, Any], timeout_ms: int = 5000) -> Dict[str, Any]:
    """发送命令到 FairyGUI 插件

    通过文件队列实现进程间通信：
    1. 自动激活编辑器窗口（确保插件能运行）
    2. MCP 服务写入命令文件到 commands/ 目录
    3. FairyGUI 插件轮询并执行命令
    4. 插件写入结果文件到 results/ 目录
    5. MCP 服务读取结果并返回

    Args:
        action: 命令类型
        params: 命令参数
        timeout_ms: 超时时间（毫秒）

    Returns:
        命令执行结果
    """
    if not is_editor_running():
        return {
            "id": "none",
            "status": "error",
            "error": "FairyGUI 编辑器未运行，请先启动编辑器"
        }
    # 生成唯一命令 ID
    cmd_id = f"cmd_{uuid.uuid4().hex[:8]}"

    # 创建命令对象
    command = {
        "id": cmd_id,
        "action": action,
        "params": params,
        "timeout": timeout_ms
    }

    # 确保通信目录存在
    commands_dir = _bridge_path / "commands"
    results_dir = _bridge_path / "results"

    try:
        commands_dir.mkdir(parents=True, exist_ok=True)
        results_dir.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        return {
            "id": cmd_id,
            "status": "error",
            "error": f"无法创建通信目录: {str(e)}"
        }

    # 写入命令文件
    cmd_file = commands_dir / f"{cmd_id}.json"
    try:
        with open(cmd_file, "w", encoding="utf-8") as f:
            json.dump(command, f, ensure_ascii=False, indent=2)
    except Exception as e:
        return {
            "id": cmd_id,
            "status": "error",
            "error": f"无法写入命令文件: {str(e)}"
        }

    # 等待结果
    result_file = results_dir / f"{cmd_id}.json"
    start_time = time.time()
    timeout_sec = timeout_ms / 1000

    while time.time() - start_time < timeout_sec:
        time.sleep(0.1)  # 每 100ms 检查一次

        if result_file.exists():
            try:
                with open(result_file, "r", encoding="utf-8") as f:
                    result = json.load(f)

                # 清理结果文件
                try:
                    result_file.unlink()
                except Exception:
                    pass

                return result

            except json.JSONDecodeError:
                continue
            except Exception:
                continue

    # 超时
    # 清理命令文件
    try:
        cmd_file.unlink()
    except Exception:
        pass

    return {
        "id": cmd_id,
        "status": "error",
        "error": f"命令超时 ({timeout_ms}ms) - 请检查 FairyGUI 编辑器是否正在运行"
    }


def _format_result(result: Dict[str, Any], success_msg: str) -> str:
    """格式化返回结果

    Args:
        result: 命令结果
        success_msg: 成功时的消息

    Returns:
        格式化后的消息
    """
    if result.get("status") == "success":
        data = result.get("data", {})
        if data:
            # 如果有额外数据，附加到成功消息
            extra_info = []
            for key, value in data.items():
                if value is not None and value != "":
                    extra_info.append(f"  {key}: {value}")
            if extra_info:
                return f"{success_msg}\n" + "\n".join(extra_info)
        return success_msg
    else:
        error = result.get("error", "未知错误")
        return f"操作失败: {error}"


def _get_controller_saved_selected_from_xml(package_name: str, component_name: str) -> Dict[str, int]:
    """从组件 XML 解析控制器保存的默认选中页

    Returns:
        {controller_name: saved_selected_index}
    """
    xml_content = _read_component_xml(package_name, component_name)
    if not xml_content:
        return {}

    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError:
        return {}

    result = {}
    for ctrl in root.findall("controller"):
        name = ctrl.get("name", "")
        selected = ctrl.get("selected", "")
        if name and selected.isdigit():
            result[name] = int(selected)

    return result


def _get_all_controller_pages_from_xml(package_name: str, component_name: str) -> Dict[str, Dict[int, str]]:
    """从组件 XML 解析所有控制器的页面名称

    Returns:
        {controller_name: {page_index: page_name}}
    """
    xml_content = _read_component_xml(package_name, component_name)
    if not xml_content:
        return {}

    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError:
        return {}

    result = {}
    for ctrl in root.findall("controller"):
        name = ctrl.get("name", "")
        pages_str = ctrl.get("pages", "")
        if not pages_str:
            continue
        pages = pages_str.split(",")
        page_map = {}
        for i in range(0, len(pages), 2):
            if i + 1 < len(pages):
                page_map[i // 2] = pages[i + 1]

        # 用 remark 补充空页名（pages 中 name 为空时，remark 提供可读标签）
        for remark in ctrl.findall("remark"):
            page = remark.get("page", "")
            value = remark.get("value", "")
            if page.isdigit() and value:
                page_idx = int(page)
                if not page_map.get(page_idx):
                    page_map[page_idx] = value

        result[name] = page_map

    return result


def _get_controller_pages_from_xml(package_name: str, component_name: str, controller_name: str) -> Dict[str, int]:
    """从组件 XML 解析指定控制器的页面名称到索引映射

    Returns:
        {page_name: page_index}
    """
    all_pages = _get_all_controller_pages_from_xml(package_name, component_name)
    pages = all_pages.get(controller_name, {})
    return {name: idx for idx, name in pages.items()}


def _read_component_xml(package_name: str, component_name: str) -> Optional[str]:
    """读取组件 XML 文件内容"""
    from ..server import UI_PROJECT_PATH

    pkg_dir = UI_PROJECT_PATH / "assets" / package_name
    if not pkg_dir.exists():
        return None

    # 从 package.xml 查找组件路径
    package_xml = pkg_dir / "package.xml"
    if package_xml.exists():
        try:
            tree = ET.parse(package_xml)
            root = tree.getroot()
            resources = root.find("resources")
            if resources:
                for res in resources:
                    if res.tag == "component" and res.get("name", "").replace(".xml", "") == component_name:
                        res_path = res.get("path", "").strip("/")
                        if res_path:
                            comp_file = pkg_dir / res_path / f"{component_name}.xml"
                            if comp_file.exists():
                                return comp_file.read_text(encoding="utf-8")
                        break
        except Exception:
            pass

    # 直接尝试
    comp_file = pkg_dir / f"{component_name}.xml"
    if comp_file.exists():
        return comp_file.read_text(encoding="utf-8")

    return None