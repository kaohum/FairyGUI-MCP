"""组件描述生成器

将 Component 对象转换为自然语言描述
"""

from typing import List, Optional
from .xml_parser import (
    Component, Controller, DisplayElement, Transition,
    GearConfig, RelationConfig, ExtensionProps, TransitionItem
)


class DescriptionGenerator:
    """组件描述生成器"""

    def generate(self, component: Component, component_name: str = "Component") -> str:
        """生成组件描述

        Args:
            component: 组件对象
            component_name: 组件名称

        Returns:
            自然语言描述
        """
        lines = []

        # 标题
        lines.append(f"# 组件描述: {component_name}")
        lines.append("")

        # 基础属性
        lines.extend(self._generate_basic_props(component))
        lines.append("")

        # 控制器
        if component.controllers:
            lines.extend(self._generate_controllers(component.controllers))
            lines.append("")

        # 显示列表
        if component.display_list:
            lines.extend(self._generate_display_list(component.display_list))
            lines.append("")

        # 扩展属性
        if component.extension:
            lines.extend(self._generate_extension(component.extension))
            lines.append("")

        # 动画
        if component.transitions:
            lines.extend(self._generate_transitions(component.transitions))

        return "\n".join(lines)

    def _generate_basic_props(self, component: Component) -> List[str]:
        """生成基础属性描述"""
        lines = ["## 基础属性", ""]

        lines.append(f"- **尺寸**: {component.size[0]} x {component.size[1]}")

        if component.extention:
            lines.append(f"- **扩展类型**: {component.extention}")

        if component.pivot:
            pivot_desc = self._describe_pivot(component.pivot)
            lines.append(f"- **中心点**: {component.pivot[0]}, {component.pivot[1]} ({pivot_desc})")

        if component.anchor:
            lines.append(f"- **锚点**: 是")

        lines.append(f"- **不透明**: {'是' if component.opaque else '否'}")

        return lines

    def _describe_pivot(self, pivot: tuple) -> str:
        """描述中心点位置"""
        x, y = pivot
        if x == 0 and y == 0:
            return "左上角"
        elif x == 0.5 and y == 0.5:
            return "居中"
        elif x == 1 and y == 1:
            return "右下角"
        elif x == 0.5 and y == 0:
            return "顶部居中"
        elif x == 0.5 and y == 1:
            return "底部居中"
        elif x == 0 and y == 0.5:
            return "左侧居中"
        elif x == 1 and y == 0.5:
            return "右侧居中"
        else:
            return "自定义"

    def _generate_controllers(self, controllers: List[Controller]) -> List[str]:
        """生成控制器描述"""
        lines = [f"## 控制器定义 ({len(controllers)} 个)", ""]

        for i, ctrl in enumerate(controllers, 1):
            # 标题
            title_parts = [f"### {i}. {ctrl.name} 控制器"]
            if ctrl.exported:
                title_parts.append("[导出]")
            if ctrl.alias:
                title_parts.append(f"别名: '{ctrl.alias}'")
            lines.append(" ".join(title_parts))
            lines.append("")

            # 页面
            if ctrl.pages:
                lines.append("**页面定义:**")
                for page in ctrl.pages:
                    remark = page.get("remark", "")
                    remark_str = f" ({remark})" if remark else ""
                    lines.append(f"  - 索引 {page['index']}: {page['name']}{remark_str}")
                lines.append("")

            # 默认页
            lines.append(f"**默认页:** {ctrl.selected}")

            # 动作
            if ctrl.actions:
                lines.append("")
                lines.append("**控制器动作:**")
                for action in ctrl.actions:
                    action_desc = self._describe_action(action)
                    lines.append(f"  - {action_desc}")

            lines.append("")

        return lines

    def _describe_action(self, action: dict) -> str:
        """描述控制器动作"""
        action_type = action.get("type", "")

        if action_type == "change_page":
            from_page = action.get("fromPage", "")
            to_page = action.get("toPage", "")
            target = action.get("objectId", "")
            controller = action.get("controller", "")
            target_page = action.get("targetPage", "")

            desc = f"切换页面: 从 [{from_page}] 到 [{to_page}]"
            if target:
                desc += f", 目标对象 {target}"
            if controller:
                desc += f" 的控制器 '{controller}'"
            if target_page:
                desc += f" 切换到页 {target_page}"
            return desc

        elif action_type == "play_transition":
            from_page = action.get("fromPage", "")
            to_page = action.get("toPage", "")
            transition = action.get("transition", "")
            stop_on_exit = action.get("stopOnExit", "false") == "true"

            desc = f"播放动画: 从 [{from_page}] 到 [{to_page}], 动画 '{transition}'"
            if stop_on_exit:
                desc += ", 退出时停止"
            return desc

        return f"类型: {action_type}, 参数: {action}"

    def _generate_display_list(self, elements: List[DisplayElement]) -> List[str]:
        """生成显示列表描述"""
        lines = [f"## 显示列表 ({len(elements)} 个元素)", ""]

        for i, elem in enumerate(elements, 1):
            lines.extend(self._describe_element(elem, i))
            lines.append("")

        return lines

    def _describe_element(self, elem: DisplayElement, index: int) -> List[str]:
        """描述显示元素"""
        lines = []

        # 标题
        type_desc = self._get_type_description(elem.element_type)
        lines.append(f"### {index}. [{elem.element_type}] {elem.name or '(未命名)'}")
        lines.append("")

        # 基本信息
        lines.append(f"- **ID**: {elem.id}")
        lines.append(f"- **位置**: ({elem.xy[0]}, {elem.xy[1]})")

        if elem.size[0] > 0 or elem.size[1] > 0:
            lines.append(f"- **尺寸**: {elem.size[0]} x {elem.size[1]}")

        # 元素特有属性
        type_specific = self._describe_type_specific(elem)
        if type_specific:
            lines.extend(type_specific)

        # Gear
        if elem.gear:
            lines.append("")
            lines.append("**Gear 配置:**")
            for gear in elem.gear:
                gear_desc = self._describe_gear(gear)
                lines.append(f"  - {gear_desc}")

        # Relation
        if elem.relations:
            lines.append("")
            lines.append("**Relation 关系:**")
            for rel in elem.relations:
                rel_desc = self._describe_relation(rel)
                lines.append(f"  - {rel_desc}")

        return lines

    def _get_type_description(self, elem_type: str) -> str:
        """获取元素类型描述"""
        descriptions = {
            "image": "图片",
            "text": "文本",
            "loader": "加载器",
            "list": "列表",
            "component": "子组件",
            "graph": "图形",
            "group": "分组"
        }
        return descriptions.get(elem_type, elem_type)

    def _describe_type_specific(self, elem: DisplayElement) -> List[str]:
        """描述元素特有属性"""
        lines = []
        attrs = elem.attributes

        if elem.element_type == "image":
            if "src" in attrs:
                lines.append(f"- **资源 ID**: {attrs['src']}")
            if "color" in attrs and attrs["color"] != "#ffffff":
                lines.append(f"- **颜色**: {attrs['color']}")
            if "fillMethod" in attrs:
                lines.append(f"- **填充方法**: {attrs['fillMethod']}")
            if "fillAmount" in attrs:
                lines.append(f"- **填充量**: {attrs['fillAmount']}%")

        elif elem.element_type == "text":
            if "text" in attrs:
                lines.append(f"- **文本内容**: \"{attrs['text']}\"")
            if "font" in attrs:
                lines.append(f"- **字体**: {attrs['font']}")
            if "fontSize" in attrs:
                lines.append(f"- **字号**: {attrs['fontSize']}")
            if "color" in attrs:
                lines.append(f"- **颜色**: {attrs['color']}")
            if "align" in attrs or "vAlign" in attrs:
                align = attrs.get("align", "left")
                v_align = attrs.get("vAlign", "top")
                lines.append(f"- **对齐**: {align} / {v_align}")
            if "autoSize" in attrs:
                lines.append(f"- **自动尺寸**: {attrs['autoSize']}")
            if "ubb" in attrs and attrs["ubb"] == "true":
                lines.append(f"- **UBB 富文本**: 是")
            if "vars" in attrs and attrs["vars"] == "true":
                lines.append(f"- **变量替换**: 是")

        elif elem.element_type == "loader":
            if "url" in attrs:
                lines.append(f"- **URL**: {attrs['url']}")
            if "fill" in attrs:
                lines.append(f"- **填充模式**: {attrs['fill']}")

        elif elem.element_type == "list":
            if "layout" in attrs:
                lines.append(f"- **布局**: {attrs['layout']}")
            if "defaultItem" in attrs:
                lines.append(f"- **默认项**: {attrs['defaultItem']}")
            if "overflow" in attrs:
                lines.append(f"- **溢出处理**: {attrs['overflow']}")

        elif elem.element_type == "component":
            if "src" in attrs:
                lines.append(f"- **组件引用**: {attrs['src']}")
            if "pkg" in attrs:
                lines.append(f"- **所属包**: {attrs['pkg']}")

        return lines

    def _describe_gear(self, gear: GearConfig) -> str:
        """描述 Gear 配置"""
        gear_names = {
            "gearDisplay": "显示控制",
            "gearDisplay2": "二级显示控制",
            "gearXY": "位置控制",
            "gearSize": "尺寸控制",
            "gearLook": "外观控制",
            "gearColor": "颜色控制",
            "gearIcon": "图标控制",
            "gearText": "文本控制",
            "gearFontSize": "字号控制"
        }

        name = gear_names.get(gear.gear_type, gear.gear_type)
        parts = [f"{name} (控制器: {gear.controller})"]

        if gear.pages:
            parts.append(f"页面: {gear.pages}")
        if gear.values:
            parts.append(f"值: {gear.values}")
        if gear.default:
            parts.append(f"默认: {gear.default}")

        return ", ".join(parts)

    def _describe_relation(self, rel: RelationConfig) -> str:
        """描述 Relation 配置"""
        target = rel.target if rel.target else "组件本身"
        side_pair = self._describe_side_pair(rel.side_pair)
        return f"相对于 {target}: {side_pair}"

    def _describe_side_pair(self, side_pair: str) -> str:
        """描述 sidePair"""
        descriptions = {
            "center-center,middle-middle": "居中对齐",
            "width-width,height-height": "填充",
            "left-left,top-top": "左上角对齐",
            "right-right,bottom-bottom": "右下角对齐",
            "left-left": "左边对齐",
            "right-right": "右边对齐",
            "top-top": "顶部对齐",
            "bottom-bottom": "底部对齐",
        }

        if side_pair in descriptions:
            return descriptions[side_pair]

        # 解析自定义关系
        parts = side_pair.split(",")
        result = []
        for part in parts:
            if "-" in part:
                src, dst = part.split("-")
                result.append(f"{src}对齐到{dst}")

        return ", ".join(result) if result else side_pair

    def _generate_extension(self, extension: ExtensionProps) -> List[str]:
        """生成扩展属性描述"""
        lines = [f"## {extension.extension_type} 扩展属性", ""]

        for key, value in extension.properties.items():
            lines.append(f"- **{key}**: {value}")

        return lines

    def _generate_transitions(self, transitions: List[Transition]) -> List[str]:
        """生成动画描述"""
        lines = [f"## 动画定义 ({len(transitions)} 个)", ""]

        for trans in transitions:
            lines.append(f"### 动画: {trans.name}")
            lines.append("")

            if trans.auto_play:
                repeat_desc = "无限循环" if trans.auto_play_repeat == -1 else f"重复 {trans.auto_play_repeat} 次"
                lines.append(f"- **自动播放**: 是 ({repeat_desc})")
            else:
                lines.append(f"- **自动播放**: 否")

            lines.append(f"- **帧率**: {trans.frame_rate}")

            if trans.items:
                lines.append("")
                lines.append(f"**动画帧 ({len(trans.items)} 个):**")
                lines.append("")

                for item in trans.items:
                    item_desc = self._describe_transition_item(item)
                    lines.append(f"  - {item_desc}")

            lines.append("")

        return lines

    def _describe_transition_item(self, item: TransitionItem) -> str:
        """描述动画项"""
        parts = [f"帧 {item.time}: [{item.item_type}]"]

        if item.target:
            parts.append(f"目标 {item.target}")

        if item.tween:
            parts.append(f"从 [{item.start_value}] 到 [{item.end_value}]")
            parts.append(f"时长 {item.duration}")
            if item.ease != "Linear":
                parts.append(f"缓动 {item.ease}")
            if item.repeat == -1:
                parts.append("无限重复")
            elif item.repeat > 0:
                parts.append(f"重复 {item.repeat} 次")
            if item.yoyo:
                parts.append("往返")
        else:
            if item.start_value:
                parts.append(f"值 [{item.start_value}]")

        return " ".join(parts)