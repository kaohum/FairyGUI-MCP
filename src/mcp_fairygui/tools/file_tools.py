"""文件管理工具 — 创建、移动、删除 FairyGUI 资源"""

import os
import random
import string
import shutil
from pathlib import Path
from typing import Optional, Tuple, List
from fastmcp import FastMCP
import xml.etree.ElementTree as ET


# ---------- 私有工具函数 ----------

def _parse_package_xml(pkg_dir: Path) -> Tuple[ET.ElementTree, ET.Element, ET.Element]:
    """解析 package.xml，返回 (tree, root, resources)。

    Raises:
        FileNotFoundError: package.xml 不存在
        ET.ParseError: XML 格式错误
    """
    package_xml = pkg_dir / "package.xml"
    if not package_xml.exists():
        raise FileNotFoundError(f"package.xml 不存在：{package_xml}")
    tree = ET.parse(package_xml)
    root = tree.getroot()
    resources = root.find("resources")
    if resources is None:
        resources = ET.SubElement(root, "resources")
    return tree, root, resources


def _write_package_xml(pkg_dir: Path, tree: ET.ElementTree) -> None:
    """安全写回 package.xml（先写 .tmp 再 rename）。"""
    package_xml = pkg_dir / "package.xml"
    tmp_path = package_xml.with_suffix(".xml.tmp")
    ET.indent(tree, space="  ")
    tree.write(tmp_path, encoding="utf-8", xml_declaration=False,
               short_empty_elements=True)
    # 修正格式以匹配 FairyGUI 原始风格：
    # 1. 使用双引号 XML 声明  2. 自闭合标签 ` />` → `/>`
    raw = tmp_path.read_text(encoding="utf-8")
    raw = raw.replace(" />", "/>")
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n')
        f.write(raw)
    # 原子替换
    if package_xml.exists():
        os.replace(tmp_path, package_xml)
    else:
        tmp_path.rename(package_xml)


def _generate_unique_id(resources: ET.Element) -> str:
    """生成 5 位 base36 随机 ID，避免与已有冲突。"""
    existing_ids = {res.get("id", "") for res in resources}
    chars = string.ascii_lowercase + string.digits
    for _ in range(100):
        new_id = "".join(random.choices(chars, k=5))
        if new_id not in existing_ids:
            return new_id
    raise RuntimeError("无法生成唯一 ID，已尝试 100 次")


def _normalize_path(path: str) -> str:
    """统一路径格式为 /xxx/ 形式。"""
    path = path.replace("\\", "/").strip()
    if not path.startswith("/"):
        path = "/" + path
    if not path.endswith("/"):
        path = path + "/"
    return path


def _find_resource(resources: ET.Element, name: str) -> Optional[ET.Element]:
    """按 name 属性查找资源元素（精确匹配）。"""
    for res in resources:
        if res.get("name", "") == name:
            return res
    return None


def _scan_references(pkg_dir: Path, resource_id: str) -> List[str]:
    """扫描包内所有 XML 中对该资源 ID 的引用，返回引用文件列表。"""
    refs = []
    for xml_file in pkg_dir.rglob("*.xml"):
        if xml_file.name == "package.xml":
            continue
        try:
            content = xml_file.read_text(encoding="utf-8")
            if resource_id in content:
                rel = xml_file.relative_to(pkg_dir)
                refs.append(str(rel))
        except Exception:
            pass
    return refs


# ---------- 扩展名映射 ----------

_TYPE_EXTENSIONS = {
    "component": ".xml",
    "image": (".png", ".jpg", ".jpeg", ".svg", ".jta"),
    "font": (".fnt", ".ttf", ".otf"),
}


# ---------- 注册工具 ----------

def register(mcp: FastMCP, project_root: Path, ui_project_path: Path):
    """注册文件管理工具"""

    # ========== fg_create_resource 已暂时禁用 ==========
    # @mcp.tool()
    # def fg_create_resource(
    #     package_name: str,
    #     resource_name: str,
    #     resource_type: str,
    #     folder_path: str = "/",
    #     exported: bool = False,
    # ) -> str:
    #     """在包内创建新资源并注册到 package.xml
    #
    #     支持的资源类型：
    #     - component: 创建空组件 XML 文件 + 注册
    #     - image/font: 仅注册到 package.xml（需手动放入文件）
    #     - folder: 创建目录 + 注册
    #
    #     Args:
    #         package_name: 包名称
    #         resource_name: 资源名称（如 MyComp.xml、icon.png）
    #         resource_type: 资源类型 (component/image/font/folder)
    #         folder_path: 所在文件夹路径，默认 "/"
    #         exported: 是否导出，默认 False
    #
    #     Returns:
    #         操作结果
    #     """
    #     # 验证类型
    #     if resource_type not in ("component", "image", "font", "folder"):
    #         return f"错误：不支持的资源类型 '{resource_type}'，可选：component/image/font/folder"
    #
    #     pkg_dir = ui_project_path / "assets" / package_name
    #     if not pkg_dir.exists():
    #         return f"错误：包不存在：{package_name}"
    #
    #     try:
    #         tree, root, resources = _parse_package_xml(pkg_dir)
    #     except Exception as e:
    #         return f"错误：{e}"
    #
    #     folder_path = _normalize_path(folder_path)
    #
    #     # 检查重名
    #     if _find_resource(resources, resource_name) is not None:
    #         return f"错误：资源 '{resource_name}' 已存在于包 '{package_name}'"
    #
    #     # 验证扩展名
    #     if resource_type == "component" and not resource_name.endswith(".xml"):
    #         return f"错误：组件名称必须以 .xml 结尾，如 '{resource_name}.xml'"
    #
    #     if resource_type == "folder":
    #         # folder 的 ID 使用完整路径
    #         folder_full = _normalize_path(folder_path.rstrip("/") + "/" + resource_name)
    #         if _find_resource(resources, resource_name) is not None:
    #             return f"错误：文件夹 '{resource_name}' 已注册"
    #         elem = ET.SubElement(resources, "folder")
    #         elem.set("id", folder_full)
    #         elem.set("name", resource_name)
    #         elem.set("path", folder_path)
    #         # 创建磁盘目录
    #         dir_path = pkg_dir / folder_path.strip("/") / resource_name if folder_path != "/" else pkg_dir / resource_name
    #         dir_path.mkdir(parents=True, exist_ok=True)
    #     else:
    #         new_id = _generate_unique_id(resources)
    #         elem = ET.SubElement(resources, resource_type)
    #         elem.set("id", new_id)
    #         elem.set("name", resource_name)
    #         elem.set("path", folder_path)
    #         if exported:
    #             elem.set("exported", "true")
    #
    #         # component: 创建空模板文件
    #         if resource_type == "component":
    #             if folder_path == "/":
    #                 file_path = pkg_dir / resource_name
    #             else:
    #                 file_path = pkg_dir / folder_path.strip("/") / resource_name
    #             file_path.parent.mkdir(parents=True, exist_ok=True)
    #             if not file_path.exists():
    #                 file_path.write_text(
    #                     '<?xml version="1.0" encoding="utf-8"?>\n<component size="100,100">\n  <displayList>\n  </displayList>\n</component>\n',
    #                     encoding="utf-8",
    #                 )
    #
    #     # 写回
    #     try:
    #         _write_package_xml(pkg_dir, tree)
    #     except Exception as e:
    #         return f"错误：写入 package.xml 失败：{e}"
    #
    #     type_label = {"component": "组件", "image": "图片", "font": "字体", "folder": "文件夹"}
    #     msg = f"成功创建{type_label[resource_type]}: {package_name}/{resource_name} (路径：{folder_path})"
    #     if resource_type in ("image", "font"):
    #         msg += f"\n提示：请手动将文件放入 {pkg_dir / folder_path.strip('/')}"
    #     return msg

    @mcp.tool()
    def fg_move_resource(
        package_name: str,
        resource_name: str,
        new_name: Optional[str] = None,
        new_path: Optional[str] = None,
    ) -> str:
        """移动或重命名包内的资源

        可以同时重命名和移动路径，至少指定 new_name 或 new_path 之一。

        Args:
            package_name: 包名称
            resource_name: 当前资源名称
            new_name: 新名称（含扩展名），不指定则保持原名
            new_path: 新文件夹路径，不指定则保持原路径

        Returns:
            操作结果
        """
        if not new_name and not new_path:
            return "错误：至少需要指定 new_name 或 new_path 之一"

        pkg_dir = ui_project_path / "assets" / package_name
        if not pkg_dir.exists():
            return f"错误：包不存在：{package_name}"

        try:
            tree, root, resources = _parse_package_xml(pkg_dir)
        except Exception as e:
            return f"错误：{e}"

        res_elem = _find_resource(resources, resource_name)
        if res_elem is None:
            return f"错误：资源 '{resource_name}' 不存在于包 '{package_name}'"

        old_path = res_elem.get("path", "/")
        old_name = res_elem.get("name", resource_name)
        target_name = new_name or old_name
        target_path = _normalize_path(new_path) if new_path else old_path

        # 检查目标是否冲突（不与自身比较）
        for res in resources:
            if res is res_elem:
                continue
            if res.get("name", "") == target_name and res.get("path", "/") == target_path:
                return f"错误：目标位置已存在同名资源 '{target_name}' (路径：{target_path})"

        # 移动磁盘文件
        res_type = res_elem.tag
        old_dir = pkg_dir if old_path == "/" else pkg_dir / old_path.strip("/")
        new_dir = pkg_dir if target_path == "/" else pkg_dir / target_path.strip("/")
        old_file = old_dir / old_name
        new_file = new_dir / target_name

        if old_file.exists() and old_file != new_file:
            new_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old_file), str(new_file))

        # 更新 package.xml
        if new_name:
            res_elem.set("name", target_name)
        if new_path:
            res_elem.set("path", target_path)

        try:
            _write_package_xml(pkg_dir, tree)
        except Exception as e:
            return f"错误：写入 package.xml 失败：{e}"

        parts = []
        if new_name and new_name != old_name:
            parts.append(f"重命名：{old_name} → {target_name}")
        if new_path and _normalize_path(new_path) != old_path:
            parts.append(f"移动：{old_path} → {target_path}")
        detail = "；".join(parts) if parts else "无变更"
        return f"成功移动资源：{package_name}/{target_name}\n{detail}"

    @mcp.tool()
    def fg_delete_resource(
        package_name: str,
        resource_name: str,
        force: bool = False,
    ) -> str:
        """删除包内的资源

        默认会先扫描引用，有引用时返回警告；设 force=True 强制删除。

        Args:
            package_name: 包名称
            resource_name: 资源名称
            force: 是否强制删除（跳过引用检查），默认 False

        Returns:
            操作结果
        """
        pkg_dir = ui_project_path / "assets" / package_name
        if not pkg_dir.exists():
            return f"错误：包不存在：{package_name}"

        try:
            tree, root, resources = _parse_package_xml(pkg_dir)
        except Exception as e:
            return f"错误：{e}"

        res_elem = _find_resource(resources, resource_name)
        if res_elem is None:
            return f"错误：资源 '{resource_name}' 不存在于包 '{package_name}'"

        res_id = res_elem.get("id", "")
        res_path = res_elem.get("path", "/")
        res_type = res_elem.tag

        # 引用检查
        if not force and res_id:
            refs = _scan_references(pkg_dir, res_id)
            if refs:
                lines = [f"警告：资源 '{resource_name}' (ID: {res_id}) 被以下文件引用："]
                for ref in refs:
                    lines.append(f"  - {ref}")
                lines.append("\n如需强制删除，请设置 force=True")
                return "\n".join(lines)

        # 从 package.xml 移除
        resources.remove(res_elem)

        # 删除磁盘文件
        if res_type == "folder":
            dir_path = pkg_dir / res_path.strip("/") / resource_name if res_path != "/" else pkg_dir / resource_name
            if dir_path.exists() and dir_path.is_dir():
                # 仅删空目录
                try:
                    dir_path.rmdir()
                except OSError:
                    pass  # 非空目录不强制删
        else:
            file_dir = pkg_dir if res_path == "/" else pkg_dir / res_path.strip("/")
            file_path = file_dir / resource_name
            if file_path.exists():
                file_path.unlink()

        try:
            _write_package_xml(pkg_dir, tree)
        except Exception as e:
            return f"错误：写入 package.xml 失败：{e}"

        return f"成功删除资源：{package_name}/{resource_name} (类型：{res_type})"
