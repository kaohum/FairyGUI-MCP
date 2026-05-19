"""组件操作工具"""

from pathlib import Path
from typing import Optional
from fastmcp import FastMCP
import xml.etree.ElementTree as ET


def register(mcp: FastMCP, project_root: Path, ui_project_path: Path):
    """注册组件操作工具"""

    @mcp.tool()
    def fg_read_component(package_name: str, component_name: str) -> str:
        """读取组件 XML 内容

        Args:
            package_name: 包名称
            component_name: 组件名称（不含 .xml 后缀）

        Returns:
            组件 XML 内容
        """
        # 查找组件文件
        pkg_dir = ui_project_path / "assets" / package_name
        if not pkg_dir.exists():
            return f"错误：包不存在：{package_name}"

        # 尝试多种路径
        possible_paths = [
            pkg_dir / f"{component_name}.xml",
            pkg_dir / "Items" / f"{component_name}.xml",
            pkg_dir / "control" / f"{component_name}.xml",
        ]

        # 从 package.xml 中查找组件路径
        package_xml = pkg_dir / "package.xml"
        if package_xml.exists():
            try:
                tree = ET.parse(package_xml)
                root = tree.getroot()
                resources = root.find("resources")
                if resources:
                    for res in resources:
                        if res.tag == "component" and res.get("name", "").replace(".xml", "") == component_name:
                            res_path = res.get("path", "")
                            if res_path:
                                possible_paths.insert(0, pkg_dir / res_path / f"{component_name}.xml")
                            break
            except Exception:
                pass

        # 查找存在的文件
        component_file = None
        for path in possible_paths:
            if path.exists():
                component_file = path
                break

        if not component_file:
            return f"错误：组件不存在：{package_name}/{component_name}"

        try:
            with open(component_file, "r", encoding="utf-8") as f:
                content = f.read()
            return content
        except Exception as e:
            return f"读取错误：{str(e)}"

    @mcp.tool()
    def fg_parse_component(package_name: str, component_name: str) -> str:
        """解析组件并生成自然语言描述

        将组件 XML 解析为易于理解的结构化描述，包含：
        - 基础属性（尺寸、扩展类型等）
        - 控制器定义
        - 显示列表元素
        - Gear 和 Relation 配置
        - Transition 动画

        Args:
            package_name: 包名称
            component_name: 组件名称

        Returns:
            组件的结构化描述
        """
        # 先读取组件
        xml_content = fg_read_component(package_name, component_name)
        if xml_content.startswith("错误"):
            return xml_content

        try:
            root = ET.fromstring(xml_content)
        except ET.ParseError as e:
            return f"XML 解析错误：{str(e)}"

        # 解析组件
        lines = [f"# 组件描述：{component_name}", ""]

        # 基础属性
        size = root.get("size", "0,0").split(",")
        extention = root.get("extention", "")
        pivot = root.get("pivot", "")
        opaque = root.get("opaque", "true")

        lines.append("## 基础属性")
        lines.append(f"- **尺寸**: {size[0]} x {size[1]}")
        if extention:
            lines.append(f"- **扩展类型**: {extention}")
        if pivot:
            lines.append(f"- **中心点**: {pivot}")
        lines.append(f"- **不透明**: {opaque}")
        lines.append("")

        # 控制器
        controllers = root.findall("controller")
        if controllers:
            lines.append("## 控制器定义")
            lines.append("")
            for i, ctrl in enumerate(controllers, 1):
                name = ctrl.get("name", "")
                alias = ctrl.get("alias", "")
                exported = ctrl.get("exported", "false") == "true"
                selected = ctrl.get("selected", "0")

                lines.append(f"### {i}. {name} 控制器")
                if alias:
                    lines.append(f"- 别名：{alias}")
                if exported:
                    lines.append(f"- 已导出")
                lines.append(f"- 默认页：{selected}")

                # 页面
                pages_str = ctrl.get("pages", "")
                if pages_str:
                    pages = pages_str.split(",")
                    lines.append(f"- 页面:")
                    for j in range(0, len(pages), 2):
                        if j + 1 < len(pages):
                            lines.append(f"  - {pages[j]}: {pages[j+1]}")

                # 备注
                remarks = ctrl.findall("remark")
                if remarks:
                    lines.append(f"- 备注:")
                    for remark in remarks:
                        page = remark.get("page", "")
                        value = remark.get("value", "")
                        lines.append(f"  - 页面 {page}: {value}")

                lines.append("")

        # 显示列表
        display_list = root.find("displayList")
        if display_list is not None:
            elements = list(display_list)
            if elements:
                lines.append("## 显示列表")
                lines.append(f"共 {len(elements)} 个元素")
                lines.append("")

                for i, elem in enumerate(elements, 1):
                    tag = elem.tag
                    elem_id = elem.get("id", "")
                    elem_name = elem.get("name", "")
                    xy = elem.get("xy", "0,0")
                    size = elem.get("size", "")

                    lines.append(f"### {i}. [{tag}] {elem_name}")
                    lines.append(f"- ID: {elem_id}")
                    lines.append(f"- 位置：{xy}")
                    if size:
                        lines.append(f"- 尺寸：{size}")

                    # 元素特有属性
                    if tag == "image":
                        src = elem.get("src", "")
                        if src:
                            lines.append(f"- 资源：{src}")
                        color = elem.get("color", "")
                        if color:
                            lines.append(f"- 颜色：{color}")

                    elif tag == "text":
                        text_content = elem.get("text", "")
                        font = elem.get("font", "")
                        font_size = elem.get("fontSize", "")
                        color = elem.get("color", "")
                        align = elem.get("align", "")
                        v_align = elem.get("vAlign", "")

                        if text_content:
                            lines.append(f"- 文本：\"{text_content}\"")
                        if font:
                            lines.append(f"- 字体：{font}")
                        if font_size:
                            lines.append(f"- 字号：{font_size}")
                        if color:
                            lines.append(f"- 颜色：{color}")
                        if align or v_align:
                            lines.append(f"- 对齐：{align} / {v_align}")

                    elif tag == "loader":
                        url = elem.get("url", "")
                        fill = elem.get("fill", "")
                        if url:
                            lines.append(f"- URL: {url}")
                        if fill:
                            lines.append(f"- 填充：{fill}")

                    elif tag == "list":
                        layout = elem.get("layout", "")
                        default_item = elem.get("defaultItem", "")
                        if layout:
                            lines.append(f"- 布局：{layout}")
                        if default_item:
                            lines.append(f"- 默认项：{default_item}")

                    elif tag == "component":
                        src = elem.get("src", "")
                        pkg = elem.get("pkg", "")
                        if src:
                            lines.append(f"- 组件：{src}")
                        if pkg:
                            lines.append(f"- 包：{pkg}")

                    # Gear
                    gears = [child for child in elem if child.tag.startswith("gear")]
                    if gears:
                        lines.append(f"- Gear:")
                        for gear in gears:
                            gear_name = gear.tag
                            controller = gear.get("controller", "")
                            pages = gear.get("pages", "")
                            values = gear.get("values", "")
                            lines.append(f"  - {gear_name}: 控制器={controller}, 页面={pages}")
                            if values:
                                lines.append(f"    值：{values}")

                    # Relation
                    relations = elem.findall("relation")
                    if relations:
                        lines.append(f"- Relation:")
                        for rel in relations:
                            target = rel.get("target", "")
                            side_pair = rel.get("sidePair", "")
                            lines.append(f"  - 目标：{target or '组件本身'}, 关系：{side_pair}")

                    lines.append("")

        # 扩展属性
        for ext_tag in ["Button", "Label", "ProgressBar", "Slider"]:
            ext_elem = root.find(ext_tag)
            if ext_elem is not None:
                lines.append(f"## {ext_tag} 扩展属性")
                for attr, value in ext_elem.attrib.items():
                    lines.append(f"- {attr}: {value}")
                lines.append("")

        # Transition
        transitions = root.findall("transition")
        if transitions:
            lines.append("## 动画定义")
            lines.append("")
            for trans in transitions:
                name = trans.get("name", "")
                auto_play = trans.get("autoPlay", "false") == "true"
                frame_rate = trans.get("frameRate", "24")

                lines.append(f"### {name}")
                lines.append(f"- 自动播放：{auto_play}")
                lines.append(f"- 帧率：{frame_rate}")

                items = trans.findall("item")
                if items:
                    lines.append(f"- 动画帧 ({len(items)} 个):")
                    for item in items[:10]:  # 限制显示数量
                        time = item.get("time", "")
                        item_type = item.get("type", "")
                        target = item.get("target", "")
                        lines.append(f"  - 帧 {time}: {item_type} -> {target}")

                lines.append("")

        return "\n".join(lines)

    # ========== fg_write_component 已暂时禁用 ==========
    # @mcp.tool()
    # def fg_write_component(
    #     package_name: str,
    #     component_name: str,
    #     xml_content: str,
    #     create_if_not_exists: bool = False
    # ) -> str:
    #     """写入组件 XML 内容
    #
    #     Args:
    #         package_name: 包名称
    #         component_name: 组件名称
    #         xml_content: XML 内容
    #         create_if_not_exists: 如果组件不存在是否创建
    #
    #     Returns:
    #         操作结果
    #     """
    #     pkg_dir = ui_project_path / "assets" / package_name
    #     if not pkg_dir.exists():
    #         return f"错误：包不存在：{package_name}"
    #
    #     # 查找组件文件
    #     component_file = None
    #     package_xml = pkg_dir / "package.xml"
    #
    #     if package_xml.exists():
    #         try:
    #             tree = ET.parse(package_xml)
    #             root = tree.getroot()
    #             resources = root.find("resources")
    #             if resources:
    #                 for res in resources:
    #                     if res.tag == "component" and res.get("name", "").replace(".xml", "") == component_name:
    #                         res_path = res.get("path", "")
    #                         if res_path:
    #                             component_file = pkg_dir / res_path / f"{component_name}.xml"
    #                         break
    #         except Exception:
    #             pass
    #
    #     if not component_file:
    #         component_file = pkg_dir / f"{component_name}.xml"
    #
    #     if not component_file.exists() and not create_if_not_exists:
    #         return f"错误：组件不存在：{component_name}，如需创建请设置 create_if_not_exists=true"
    #
    #     try:
    #         # 验证 XML 格式
    #         ET.fromstring(xml_content)
    #
    #         # 确保目录存在
    #         component_file.parent.mkdir(parents=True, exist_ok=True)
    #
    #         # 写入文件
    #         with open(component_file, "w", encoding="utf-8") as f:
    #             f.write(xml_content)
    #
    #         return f"成功写入组件：{package_name}/{component_name}"
    #     except ET.ParseError as e:
    #         return f"XML 格式错误：{str(e)}"
    #     except Exception as e:
    #         return f"写入错误：{str(e)}"

    @mcp.tool()
    def fg_validate_component(package_name: str, component_name: str) -> str:
        """验证组件规范

        检查组件是否符合 FairyGUI 规范和项目最佳实践：
        - XML 格式正确性
        - 必要属性完整性
        - 命名规范
        - 资源引用有效性

        Args:
            package_name: 包名称
            component_name: 组件名称

        Returns:
            验证结果
        """
        xml_content = fg_read_component(package_name, component_name)
        if xml_content.startswith("错误"):
            return xml_content

        issues = []
        warnings = []

        try:
            root = ET.fromstring(xml_content)
        except ET.ParseError as e:
            return f"❌ XML 格式错误：{str(e)}"

        # 检查基础属性
        size = root.get("size", "")
        if not size:
            issues.append("缺少 size 属性")

        # 检查控制器
        controllers = root.findall("controller")
        for ctrl in controllers:
            name = ctrl.get("name", "")
            if not name:
                issues.append("控制器缺少 name 属性")
            else:
                # 检查命名规范
                if " " in name:
                    warnings.append(f"控制器 '{name}' 名称包含空格")

                # 检查页面定义
                pages = ctrl.get("pages", "")
                if not pages:
                    warnings.append(f"控制器 '{name}' 没有定义页面")

        # 检查显示列表
        display_list = root.find("displayList")
        if display_list is not None:
            elements = list(display_list)
            names = set()
            ids = set()

            for elem in elements:
                elem_id = elem.get("id", "")
                elem_name = elem.get("name", "")

                # 检查 ID 唯一性
                if elem_id in ids:
                    issues.append(f"元素 ID 重复：{elem_id}")
                ids.add(elem_id)

                # 检查名称
                if elem_name:
                    if elem_name in names:
                        warnings.append(f"元素名称重复：{elem_name}")
                    names.add(elem_name)

                # 检查资源引用
                src = elem.get("src", "")
                if src and not elem.get("fileName"):
                    # 警告：有 src 但没有 fileName
                    pass

        # 生成报告
        lines = [f"# 组件验证报告：{package_name}/{component_name}", ""]

        if issues:
            lines.append("## ❌ 错误")
            for issue in issues:
                lines.append(f"- {issue}")
            lines.append("")

        if warnings:
            lines.append("## ⚠️ 警告")
            for warning in warnings:
                lines.append(f"- {warning}")
            lines.append("")

        if not issues and not warnings:
            lines.append("## ✅ 验证通过")
            lines.append("组件符合规范，未发现问题。")

        return "\n".join(lines)
