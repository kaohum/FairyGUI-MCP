"""FairyGUI 组件 XML 解析器"""

import xml.etree.ElementTree as ET
from typing import Dict, List, Any, Optional, Tuple
from dataclasses import dataclass, field


@dataclass
class Controller:
    """控制器定义"""
    name: str
    pages: List[Dict[str, str]] = field(default_factory=list)
    selected: int = 0
    alias: str = ""
    exported: bool = False
    actions: List[Dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "pages": self.pages,
            "selected": self.selected,
            "alias": self.alias,
            "exported": self.exported,
            "actions": self.actions
        }


@dataclass
class GearConfig:
    """Gear 配置"""
    gear_type: str
    controller: str
    pages: str = ""
    values: str = ""
    default: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "gear_type": self.gear_type,
            "controller": self.controller,
            "pages": self.pages,
            "values": self.values,
            "default": self.default
        }


@dataclass
class RelationConfig:
    """Relation 配置"""
    target: str
    side_pair: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "target": self.target,
            "side_pair": self.side_pair
        }


@dataclass
class DisplayElement:
    """显示元素"""
    element_type: str  # image, text, loader, list, component, graph, group
    id: str
    name: str
    xy: Tuple[int, int]
    size: Tuple[int, int]
    attributes: Dict[str, Any] = field(default_factory=dict)
    gear: List[GearConfig] = field(default_factory=list)
    relations: List[RelationConfig] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "element_type": self.element_type,
            "id": self.id,
            "name": self.name,
            "xy": self.xy,
            "size": self.size,
            "attributes": self.attributes,
            "gear": [g.to_dict() for g in self.gear],
            "relations": [r.to_dict() for r in self.relations]
        }


@dataclass
class TransitionItem:
    """动画项"""
    time: int
    item_type: str
    target: str
    tween: bool = False
    start_value: str = ""
    end_value: str = ""
    duration: int = 0
    ease: str = "Linear"
    repeat: int = 0
    yoyo: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {
            "time": self.time,
            "item_type": self.item_type,
            "target": self.target,
            "tween": self.tween,
            "start_value": self.start_value,
            "end_value": self.end_value,
            "duration": self.duration,
            "ease": self.ease,
            "repeat": self.repeat,
            "yoyo": self.yoyo
        }


@dataclass
class Transition:
    """动画定义"""
    name: str
    auto_play: bool = False
    auto_play_repeat: int = 0
    frame_rate: int = 24
    options: int = 0
    items: List[TransitionItem] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "auto_play": self.auto_play,
            "auto_play_repeat": self.auto_play_repeat,
            "frame_rate": self.frame_rate,
            "options": self.options,
            "items": [item.to_dict() for item in self.items]
        }


@dataclass
class ExtensionProps:
    """扩展属性"""
    extension_type: str  # Button, Label, ProgressBar, Slider, ComboBox
    properties: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "extension_type": self.extension_type,
            "properties": self.properties
        }


@dataclass
class Component:
    """组件定义"""
    size: Tuple[int, int]
    extention: Optional[str] = None
    pivot: Optional[Tuple[float, float]] = None
    anchor: bool = False
    opaque: bool = True
    controllers: List[Controller] = field(default_factory=list)
    display_list: List[DisplayElement] = field(default_factory=list)
    transitions: List[Transition] = field(default_factory=list)
    extension: Optional[ExtensionProps] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "size": self.size,
            "extention": self.extention,
            "pivot": self.pivot,
            "anchor": self.anchor,
            "opaque": self.opaque,
            "controllers": [c.to_dict() for c in self.controllers],
            "display_list": [e.to_dict() for e in self.display_list],
            "transitions": [t.to_dict() for t in self.transitions],
            "extension": self.extension.to_dict() if self.extension else None
        }


class ComponentParser:
    """FairyGUI 组件 XML 解析器"""

    def parse(self, xml_content: str) -> Component:
        """解析组件 XML 内容

        Args:
            xml_content: XML 字符串

        Returns:
            Component 对象
        """
        root = ET.fromstring(xml_content)
        return self._parse_component(root)

    def parse_file(self, file_path: str) -> Component:
        """解析组件 XML 文件

        Args:
            file_path: XML 文件路径

        Returns:
            Component 对象
        """
        tree = ET.parse(file_path)
        root = tree.getroot()
        return self._parse_component(root)

    def _parse_component(self, root: ET.Element) -> Component:
        """解析组件根元素"""
        # 基础属性
        size = self._parse_size(root.get("size", "0,0"))
        extention = root.get("extention")
        pivot = self._parse_pivot(root.get("pivot")) if root.get("pivot") else None
        anchor = root.get("anchor", "false").lower() == "true"
        opaque = root.get("opaque", "true").lower() == "true"

        component = Component(
            size=size,
            extention=extention,
            pivot=pivot,
            anchor=anchor,
            opaque=opaque
        )

        # 解析控制器
        for ctrl_elem in root.findall("controller"):
            component.controllers.append(self._parse_controller(ctrl_elem))

        # 解析显示列表
        display_list = root.find("displayList")
        if display_list is not None:
            for elem in display_list:
                component.display_list.append(self._parse_element(elem))

        # 解析动画
        for trans_elem in root.findall("transition"):
            component.transitions.append(self._parse_transition(trans_elem))

        # 解析扩展属性
        component.extension = self._parse_extension(root)

        return component

    def _parse_size(self, size_str: str) -> Tuple[int, int]:
        """解析尺寸"""
        parts = size_str.split(",")
        return (int(parts[0]), int(parts[1]))

    def _parse_pivot(self, pivot_str: str) -> Tuple[float, float]:
        """解析中心点"""
        parts = pivot_str.split(",")
        return (float(parts[0]), float(parts[1]))

    def _parse_xy(self, xy_str: str) -> Tuple[int, int]:
        """解析位置"""
        parts = xy_str.split(",")
        return (int(parts[0]), int(parts[1]))

    def _parse_controller(self, elem: ET.Element) -> Controller:
        """解析控制器"""
        ctrl = Controller(
            name=elem.get("name", ""),
            alias=elem.get("alias", ""),
            exported=elem.get("exported", "false").lower() == "true",
            selected=int(elem.get("selected", "0"))
        )

        # 解析页面
        pages_str = elem.get("pages", "")
        if pages_str:
            pages = pages_str.split(",")
            for i in range(0, len(pages), 2):
                if i + 1 < len(pages):
                    page_info = {
                        "index": pages[i],
                        "name": pages[i + 1]
                    }
                    ctrl.pages.append(page_info)

        # 解析备注
        for remark in elem.findall("remark"):
            page = remark.get("page")
            value = remark.get("value")
            for p in ctrl.pages:
                if p["index"] == page:
                    p["remark"] = value

        # 解析动作
        for action in elem.findall("action"):
            action_info = dict(action.attrib)
            ctrl.actions.append(action_info)

        return ctrl

    def _parse_element(self, elem: ET.Element) -> DisplayElement:
        """解析显示元素"""
        tag = elem.tag
        attrs = dict(elem.attrib)

        # 提取通用属性
        elem_id = attrs.pop("id", "")
        elem_name = attrs.pop("name", "")
        xy = self._parse_xy(attrs.pop("xy", "0,0"))
        size = self._parse_size(attrs.pop("size", "0,0"))

        element = DisplayElement(
            element_type=tag,
            id=elem_id,
            name=elem_name,
            xy=xy,
            size=size,
            attributes=attrs
        )

        # 解析子元素（Gear, Relation）
        for child in elem:
            if child.tag.startswith("gear"):
                element.gear.append(self._parse_gear(child))
            elif child.tag == "relation":
                element.relations.append(self._parse_relation(child))

        return element

    def _parse_gear(self, elem: ET.Element) -> GearConfig:
        """解析 Gear 配置"""
        return GearConfig(
            gear_type=elem.tag,
            controller=elem.get("controller", ""),
            pages=elem.get("pages", ""),
            values=elem.get("values", ""),
            default=elem.get("default", "")
        )

    def _parse_relation(self, elem: ET.Element) -> RelationConfig:
        """解析 Relation 配置"""
        return RelationConfig(
            target=elem.get("target", ""),
            side_pair=elem.get("sidePair", "")
        )

    def _parse_transition(self, elem: ET.Element) -> Transition:
        """解析动画"""
        trans = Transition(
            name=elem.get("name", ""),
            auto_play=elem.get("autoPlay", "false").lower() == "true",
            auto_play_repeat=int(elem.get("autoPlayRepeat", "0")),
            frame_rate=int(elem.get("frameRate", "24")),
            options=int(elem.get("options", "0"))
        )

        for item_elem in elem.findall("item"):
            trans.items.append(self._parse_transition_item(item_elem))

        return trans

    def _parse_transition_item(self, elem: ET.Element) -> TransitionItem:
        """解析动画项"""
        return TransitionItem(
            time=int(elem.get("time", "0")),
            item_type=elem.get("type", ""),
            target=elem.get("target", ""),
            tween=elem.get("tween", "false").lower() == "true",
            start_value=elem.get("startValue", ""),
            end_value=elem.get("endValue", ""),
            duration=int(elem.get("duration", "0")),
            ease=elem.get("ease", "Linear"),
            repeat=int(elem.get("repeat", "0")),
            yoyo=elem.get("yoyo", "false").lower() == "true"
        )

    def _parse_extension(self, root: ET.Element) -> Optional[ExtensionProps]:
        """解析扩展属性"""
        extension_tags = ["Button", "Label", "ProgressBar", "Slider", "ComboBox"]

        for tag in extension_tags:
            ext_elem = root.find(tag)
            if ext_elem is not None:
                return ExtensionProps(
                    extension_type=tag,
                    properties=dict(ext_elem.attrib)
                )

        return None