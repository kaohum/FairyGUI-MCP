# TODO

已知问题与待解决任务列表。

## 🔴 高优先级（影响核心功能）

### 1. `fg_editor_capture_preview` 截图清晰度问题

**现状**：
- 已修复包含编辑器 UI 的问题（用 `docContainer` + 坐标裁剪）
- 但截图分辨率受用户在编辑器中手动**鼠标滚轮缩放**的当前状态影响
- 用户缩小预览时截图很模糊，放大时可能溢出

**期望**：
- 截图前自动调整预览到合适大小（既能截全，又能清晰）
- 或者用更高的 `scale` 参数补偿

**已尝试方案（失败）**：
- 在截图前调用 `docContainer:SetScale(fitScale, fitScale)` — 会影响整个编辑器渲染

**待探查**：
- 编辑器内 `contentScaler` 控件（`testView.child[0]:GetChild("contentScaler")`）的工作机制
- 鼠标滚轮事件如何触发预览缩放
- testView 是否有独立的 `previewScale` 或 `zoomLevel` 属性
- 是否可通过修改某个属性而不影响编辑器全局

### 2. `fg_editor_start_test` 的 `device_name` 分辨率切换

**现状**：
- 设备信息匹配成功（如 P40 Pro 2640x1200）
- 返回值显示 `device_found: true`
- 但 testView 内部分辨率没有实际切换

**已尝试方案（失败）**：
- `CS.FairyGUI.GRoot.inst:SetContentScaleFactor(...)` — 会缩放整个编辑器
- `testView.contentPane:SetSize(...)` — testView.contentPane 为 nil
- `testView.viewWidth = w; testView.viewHeight = h` — 不生效
- `testView:SetSize(...)` — 不生效
- `testView.stage:SetSize(...)` — testView.stage 为 nil

**待探查**：
- 通过编辑器界面操作（点击设备下拉框）后用 `probe_plugin_api` 比对前后状态变化
- testView 内部可能通过事件系统切换设备（不是直接调 API）
- 联系 FairyGUI 作者获取确切 API

### 3. `fg_editor_select_element` 触发 CustomShadow 插件越界报错

**现状**：
- 元素能选中（`doc:SetSelection(targetChild)` 不报错）
- 但触发 `Plugin-CustomShadow` 在 `OnUpdate` 中越界报错
- 检查器面板未自动刷新

**报错堆栈**：
```
[string "Plugin-CustomShadow"]:294: in function <[string "Plugin-CustomShadow"]:243>
at FairyEditor.App.OnUpdate ()
```

CustomShadow 插件在 OnUpdate 中读取 `doc.inspectingObjectType` 和 `doc.inspectingTarget`，可能在我们手动 SetSelection 后某个内部状态不一致。

**已尝试方案（失败）**：
- 用 `List<GObject>` 封装传入 SetSelection — Lua xLua 类型映射困难

**待探查**：
- FairyGUI 编辑器手动点击元素时调用的真正 API（可能是 `doc:OnElementClick` 之类的）
- `doc.inspectingTarget` 应该如何同步设置
- 是否需要通过 `App.docView` 而非 `doc` 来触发选中

## 🟡 中优先级（增强功能）

### 4. 新增 `fg_editor_open_publish_settings` 接口

**已验证可行**：
- `App.mainView.toolbar:GetChild("tbPublishSettings"):FireClick(true, true)` 能打开发布设置对话框

**待实现**：
- 添加为正式 MCP 工具（当前只是探查代码）
- 提供关闭对话框的方式（通过模拟点击关闭按钮或 `Esc`）

### 5. 错误信息标准化

**现状**：错误信息散落在 Lua 各 handler 中，格式不统一。

**期望**：
- 统一错误码体系
- Lua 侧 `pcall` 捕获后返回结构化错误对象（含 type、message、stack）
- Python 侧根据错误类型给出针对性建议

### 6. 单元测试覆盖

**现状**：所有验证依赖人工复检。

**期望**：
- 自动化测试套件（启动编辑器 → 执行命令 → 断言结果）
- CI 集成（GitHub Actions）

## 🟢 低优先级（优化）

### 7. `probe_plugin_api` 的探查目标过多

当前探查目标集中在 `command_handler.lua` 的 `handleProbePluginApi` 函数中，已经有 12+ 个 target。

**建议**：
- 拆分到独立的 `probe.lua` 文件
- 或改为通用反射查询接口（传入路径表达式）

### 8. 文档完善

- 补充每个工具的使用示例
- FairyGUI 编辑器内部 API 的探查发现整理为开发者文档
- 故障排查指南（FAQ）

### 9. `fg_editor_capture_preview` 增加 scale 参数文档说明

`scale` 参数当前默认为 1，可以提高到 2 或 4 以获得更清晰的截图。需要在文档中说明清楚。

## 🔵 已完成

- ✅ 路径格式参数统一
- ✅ `reload` 全量刷新超时修复
- ✅ `start_test` 自动打开组件
- ✅ `activate` 通过 Win32 API 激活
- ✅ `publish` 不再中断通信
- ✅ `reload` 单包刷新（5 种策略）
- ✅ `move/delete_resource` 自动刷新编辑器
- ✅ `capture_preview` 排除编辑器 UI（裁剪到设备屏幕）
- ✅ 新增 `select_element` 工具
- ✅ 移除不可靠的 `reload_all_plugins`

## 📚 探查发现的关键 FairyGUI 编辑器 API

```
App.testView (FairyEditor.View.TestView)
└── child[0] (FairyGUI.GComponent, 1624x933, 整个预览面板)
    ├── n21                  # 背景层
    ├── adaptation           # 适配标签 (47x19 at (10,7))
    ├── device               # 设备下拉 (197x20 at (442,6))
    ├── screenMatch          # 屏幕适配 (142x20 at (203,6))
    ├── contentScaler        # 缩放控件 (20x20 at (92,6))
    ├── controllerList       # 控制器列表 (1619x25 at (3,35))
    ├── docContainer         # 预览内容容器 (1622x868 at (1,64)) ★
    │   └── child[0]         # 设备屏幕容器（尺寸随设备/缩放变化）
    ├── n22                  # 缩放手柄 (12x12 at (1611,920))
    ├── landscape, portrait  # 横竖屏切换
    └── n38, n39             # 其他控件

App.mainView.toolbar
├── viewScale               # child[0]
├── tbCreateCom             # child[1]
├── tbCreateButton          # child[2]
├── tbSave, tbSaveAll       # child[3,4]
├── tbCreateFont, tbImport  # child[7,8]
├── tbPublish               # child[10] ★ 发布按钮
├── tbTest                  # child[11]
├── tbCreateMc              # child[12]
├── tbCreateComboBox/...    # child[14-17]
├── tbCanvas                # child[18]
├── tbPublishSettings       # child[19] ★ 发布设置
├── tbPublishDesc           # child[20] ★ 发布描述
├── branches, lang          # child[22-24]
├── tbStopTest, tbReload    # child[25,26]
├── tbBranch, tbLang        # child[27,28]
└── tbSearch                # child[29]
```
