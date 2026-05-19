"""命令队列管理

管理 MCP 服务和 FairyGUI 插件之间的命令通信
"""

import json
import time
import uuid
from pathlib import Path
from typing import Dict, Any, Optional, Callable


class CommandQueue:
    """命令队列管理器"""

    def __init__(self, bridge_path: Path):
        """初始化

        Args:
            bridge_path: 桥接目录路径
        """
        self.bridge_path = bridge_path
        self.commands_dir = bridge_path / "commands"
        self.results_dir = bridge_path / "results"
        self.screenshots_dir = bridge_path / "screenshots"

        # 确保目录存在
        self._ensure_dirs()

    def _ensure_dirs(self):
        """确保目录存在"""
        self.commands_dir.mkdir(parents=True, exist_ok=True)
        self.results_dir.mkdir(parents=True, exist_ok=True)
        self.screenshots_dir.mkdir(parents=True, exist_ok=True)

    def send_command(
        self,
        action: str,
        params: Dict[str, Any],
        timeout_ms: int = 5000
    ) -> Dict[str, Any]:
        """发送命令

        Args:
            action: 命令类型
            params: 命令参数
            timeout_ms: 超时时间（毫秒）

        Returns:
            命令结果
        """
        # 生成命令 ID
        cmd_id = f"cmd_{uuid.uuid4().hex[:8]}"

        # 创建命令
        command = {
            "id": cmd_id,
            "action": action,
            "params": params,
            "timeout": timeout_ms
        }

        # 写入命令文件
        cmd_file = self.commands_dir / f"{cmd_id}.json"
        try:
            with open(cmd_file, "w", encoding="utf-8") as f:
                json.dump(command, f, ensure_ascii=False, indent=2)
        except Exception as e:
            return {
                "id": cmd_id,
                "status": "error",
                "error": f"写入命令失败: {str(e)}"
            }

        # 等待结果
        result = self._wait_for_result(cmd_id, timeout_ms)

        return result

    def _wait_for_result(self, cmd_id: str, timeout_ms: int) -> Dict[str, Any]:
        """等待命令结果

        Args:
            cmd_id: 命令 ID
            timeout_ms: 超时时间（毫秒）

        Returns:
            命令结果
        """
        result_file = self.results_dir / f"{cmd_id}.json"
        start_time = time.time()
        timeout_sec = timeout_ms / 1000

        while time.time() - start_time < timeout_sec:
            if result_file.exists():
                try:
                    with open(result_file, "r", encoding="utf-8") as f:
                        result = json.load(f)
                    # 清理结果文件
                    try:
                        result_file.unlink()
                    except:
                        pass
                    return result
                except json.JSONDecodeError:
                    # 文件可能还在写入
                    pass
                except Exception:
                    pass

            time.sleep(0.1)

        # 超时，清理命令文件
        cmd_file = self.commands_dir / f"{cmd_id}.json"
        try:
            cmd_file.unlink()
        except:
            pass

        return {
            "id": cmd_id,
            "status": "error",
            "error": f"命令超时 ({timeout_ms}ms)"
        }

    def get_screenshot_path(self, screenshot_name: str) -> Optional[Path]:
        """获取截图文件路径

        Args:
            screenshot_name: 截图名称

        Returns:
            截图文件路径，不存在则返回 None
        """
        if not screenshot_name.endswith(".png"):
            screenshot_name += ".png"

        path = self.screenshots_dir / screenshot_name
        return path if path.exists() else None

    def list_screenshots(self) -> list:
        """列出所有截图

        Returns:
            截图文件列表
        """
        return list(self.screenshots_dir.glob("*.png"))

    def cleanup_old_files(self, max_age_hours: int = 24):
        """清理旧文件

        Args:
            max_age_hours: 最大保留时间（小时）
        """
        max_age_sec = max_age_hours * 3600
        now = time.time()

        for directory in [self.commands_dir, self.results_dir]:
            for file in directory.glob("*.json"):
                if now - file.stat().st_mtime > max_age_sec:
                    try:
                        file.unlink()
                    except:
                        pass