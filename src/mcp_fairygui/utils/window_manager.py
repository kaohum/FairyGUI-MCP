"""FairyGUI 编辑器窗口管理

通过 Windows API 自动激活编辑器窗口，解决编辑器必须在前台才能运行插件的限制。
支持窗口截图功能。
"""

import time
from pathlib import Path
from typing import Optional

try:
    import win32gui
    import win32con
    import win32ui
    import ctypes
    HAS_WIN32 = True
except ImportError:
    HAS_WIN32 = False

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


class EditorWindowManager:
    """FairyGUI 编辑器窗口管理器"""

    # FairyGUI 编辑器窗口标题关键词（按优先级排序）
    WINDOW_PATTERNS = ["ui_project"]

    def __init__(self):
        self._hwnd: Optional[int] = None

    def find_window(self) -> Optional[int]:
        """查找 FairyGUI 编辑器窗口句柄"""
        if not HAS_WIN32:
            return None

        result = [None]

        def callback(hwnd, _):
            if win32gui.IsWindowVisible(hwnd):
                title = win32gui.GetWindowText(hwnd)
                for pattern in self.WINDOW_PATTERNS:
                    if pattern.lower() in title.lower():
                        result[0] = hwnd
                        return False  # 停止枚举
            return True

        try:
            win32gui.EnumWindows(callback, None)
        except Exception:
            pass

        self._hwnd = result[0]
        return self._hwnd

    def is_running(self) -> bool:
        """检查编辑器是否运行"""
        return self.find_window() is not None

    def is_active(self) -> bool:
        """检查编辑器是否处于前台激活状态"""
        if not HAS_WIN32:
            return False
        hwnd = self._hwnd or self.find_window()
        if not hwnd:
            return False
        try:
            return win32gui.GetForegroundWindow() == hwnd
        except Exception:
            return False

    def activate(self, wait_time: float = 0.5) -> bool:
        """激活编辑器窗口

        Args:
            wait_time: 激活后等待时间(秒)，让编辑器有时间处理

        Returns:
            是否成功激活
        """
        if not HAS_WIN32:
            return False

        hwnd = self._hwnd or self.find_window()
        if not hwnd:
            return False

        try:
            # 如果最小化则恢复
            if win32gui.IsIconic(hwnd):
                win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)

            # Windows 限制：后台进程不能直接 SetForegroundWindow
            # 使用 ShowWindow + BringWindowToTop 组合绕过
            try:
                win32gui.SetForegroundWindow(hwnd)
            except Exception:
                # 备用方案：先最小化再恢复，强制激活
                win32gui.ShowWindow(hwnd, win32con.SW_MINIMIZE)
                time.sleep(0.1)
                win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)

            time.sleep(wait_time)
            return True
        except Exception as e:
            print(f"[MCPBridge] 激活窗口失败: {e}")
            return False

    def ensure_active(self) -> bool:
        """确保编辑器处于激活状态，如不是则自动激活

        Returns:
            是否成功激活或已处于激活状态
        """
        if self.is_active():
            return True
        return self.activate()

    def get_window_title(self) -> Optional[str]:
        """获取编辑器窗口标题"""
        if not HAS_WIN32:
            return None
        hwnd = self._hwnd or self.find_window()
        if not hwnd:
            return None
        try:
            return win32gui.GetWindowText(hwnd)
        except Exception:
            return None

    def capture_screenshot(self, save_path: str) -> bool:
        """截取编辑器窗口截图

        Args:
            save_path: 截图保存路径（含文件名和扩展名）

        Returns:
            是否成功截图
        """
        if not HAS_WIN32 or not HAS_PIL:
            return False

        hwnd = self._hwnd or self.find_window()
        if not hwnd:
            return False

        try:
            # 获取窗口客户区域大小
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            width = right - left
            height = bottom - top

            if width <= 0 or height <= 0:
                return False

            # 使用 PrintWindow 截取窗口（即使被遮挡也能截取）
            hwnd_dc = win32gui.GetWindowDC(hwnd)
            mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
            save_dc = mfc_dc.CreateCompatibleDC()

            bitmap = win32ui.CreateBitmap()
            bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
            save_dc.SelectObject(bitmap)

            # PW_RENDERFULLCONTENT = 2 for better capture
            ctypes.windll.user32.PrintWindow(hwnd, save_dc.GetSafeHdc(), 2)

            # 转换为 PIL Image
            bmpinfo = bitmap.GetInfo()
            bmpstr = bitmap.GetBitmapBits(True)

            img = Image.frombuffer(
                'RGB',
                (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                bmpstr, 'raw', 'BGRX', 0, 1
            )

            # 确保目录存在
            Path(save_path).parent.mkdir(parents=True, exist_ok=True)
            img.save(save_path)

            # 清理资源
            win32gui.DeleteObject(bitmap.GetHandle())
            save_dc.DeleteDC()
            mfc_dc.DeleteDC()
            win32gui.ReleaseDC(hwnd, hwnd_dc)

            return True
        except Exception as e:
            print(f"[MCPBridge] 截图失败: {e}")
            return False


# 全局单例
_manager = EditorWindowManager()


def ensure_editor_active() -> bool:
    """确保编辑器处于激活状态（便捷函数）"""
    return _manager.ensure_active()


def is_editor_running() -> bool:
    """检查编辑器是否运行（便捷函数）"""
    return _manager.is_running()


def activate_editor() -> bool:
    """激活编辑器窗口（便捷函数）"""
    return _manager.activate()


def capture_editor_screenshot(save_path: str) -> bool:
    """截取编辑器窗口截图（便捷函数）"""
    return _manager.capture_screenshot(save_path)
