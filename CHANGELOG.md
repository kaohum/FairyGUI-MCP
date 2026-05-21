# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-05-22

### 🎯 Highlights

修复 `fg_editor_select_element` 调用时触发 `Plugin-CustomShadow` 越界报错的问题。深入探查 FairyEditor 内部 API 后确认：右侧检查器面板的渲染源 `Document.inspectingTarget` 是 C# 只读属性（`{ get; private set; }`），其 setter 由编辑器 selectionLayer 鼠标事件链路内部触发，**外部 Lua 完全无法写入**。本次修复采用诚实降级方案：保留 selection 同步能力（画布选中框跟随），明确告知调用方检查器面板需手动点击。

### Changed

- **`fg_editor_select_element`** — 重写 `handleSelectElement`：
  - 选中策略改为 `UnselectAll() + SelectObject(target, true, true)` 组合（独占选中），避开会触发 CustomShadow 越界的 `SetSelection` 旧 API
  - 元素查找简化为 2 种策略：`FComponent:GetChild(name)` 直查，加 `FComponent.children` 列表遍历兜底（删除原 LuaAPI 不存在的 `displayList` / `GetChildren()` 接口）
  - 删除原本的 6 种猜测式刷新代码（`docView:Refresh/Repaint/UpdateInspector`、`doc:Invalidate/RefreshInspector`、deselect-then-reselect、延迟刷新），它们对实际刷新检查器都无效
  - 添加 `docFactory:InvokeDocumentMethod(...)` 反射兜底（试调 `InspectObject` / `Inspect` / `SetInspectingTarget` 等方法名），目前没有匹配的方法名，但保留为前向兼容
  - 新增 `selection_verified` 字段验证 selection 是否真的更新到目标元素
  - 返回值字段重命名：`select_method` / `inspector_refreshed` / `inspector_refresh_method` → `selection_verified` / `inspector_synced` / `inspector_sync_method` / `note`

### Fixed

- **`fg_editor_select_element` 触发 CustomShadow 越界** — 改用 `SelectObject` 替代 `SetSelection`，从源头消除 `inspectingObjectType` / `inspectingTarget` 状态不一致导致的越界。

### Known Issues (重新分类)

- **`Document.inspectingTarget` 不可写**（FairyEditor 私有 API 限制，无解）— `fg_editor_select_element` 只能更新 selection（驱动画布选中框），无法让右侧检查器面板自动同步到所选元素。如需查看属性，必须由人工在编辑器中手动点击元素。这一限制已写入工具描述和 TODO.md。

### Internal

- **探查记录** — 通过临时 `read_select_state` / `select_only` 探查命令对照"用户手动点击"和"MCP 调 SelectObject"的状态差异，确认：
  - 手动点击 propertyBtn → `inspectingTarget=propertyBtn`，`visibleInspectorsCount=9`（含 ButtonPropsPanel 等元素级 inspector）
  - MCP 调 SelectObject → `inspectingTarget=DocContent`（永远是根组件），`visibleInspectorsCount=5`（只有组件级 inspector）
  - 反射查 `Document.inspectingTarget` 属性：`canRead=true, canWrite=false, fieldExists=false`
  - 已尝试的所有路径均无效：直接赋值、`SelectObject`、`SetSelection`、`OpenChild`、`UnselectAll + SelectObject`、`App.Dispatch(SelectionChanged)`、`Document.RefreshInspectors(flags)`

---

## [Unreleased] - 2026-05-21

### 🎯 Highlights

通过对 28 个 MCP 工具进行**逐项红绿测试**（人工复检每个接口的实际行为），发现并修复了 8 个核心 Bug，新增 1 个工具，移除 1 个不可靠工具。

测试报告：22/28 完全通过，3/28 部分修复，1/28 移除。

### Added

- **`fg_editor_select_element`** — 按元素名称在编辑器中选中目标元素，支持 3 种查找策略（`GetChild` / 遍历 `displayList` / 遍历 `GetChildren`）和多种选中 API。
- **路径格式参数支持** — `fg_editor_open_component`、`fg_editor_preview`、`fg_editor_start_test`、`fg_editor_get_component_info` 现在统一支持纯名称（`Button01`）和路径格式（`Buttons/Button01`），与 `fg_read_component` 行为一致。
- **`probe_publish` / `open_publish_settings`** — Lua 内部命令，用于探查发布按钮和打开发布设置对话框（已确认 toolbar 上的 `tbPublish`、`tbPublishSettings`、`tbPublishDesc` 三个按钮）。

### Changed

- **`fg_editor_start_test`** — 在调用 `App.testView:Start(item)` 之前，自动通过 `App.docView:OpenDocument(url, true)` 打开目标组件文档。修复了之前 F5 预览总是运行编辑器当前 activeDoc 而非参数指定组件的问题。
- **`fg_editor_activate`** — Python 侧通过 Win32 API（`SetForegroundWindow`）实际激活编辑器窗口，Lua 侧仅设置 `runInBackground = true`。
- **`fg_editor_reload`** — 单包刷新尝试 5 种策略（`pkg:Touch()`、`pkg:Reload()`、`item:Touch()` all、`project:RefreshPackage()`、延迟 `pkg:Touch()`），返回所有尝试的方法和成功的方法。全量刷新改为异步执行，避免 `App.RefreshProject()` 同步阻塞导致 poll 轮询停止。
- **`fg_editor_publish_package` / `fg_editor_publish_all`** — 发布命令返回后由 Python 侧调用 `ensure_editor_active()` 激活编辑器窗口（防止 `runInBackground` 被发布异步任务覆盖导致通信中断）。
- **`fg_move_resource` / `fg_delete_resource`** — Python 端操作成功后自动发送 `reload` 命令到 Lua 端，编辑器无需手动刷新即可看到资源变化。
- **`fg_editor_capture_preview`** — 重写截图目标查找逻辑（`getTestViewCaptureTarget`），不再使用全局 `GRoot.inst.displayObject`。新增 5 级策略：
  1. `testView.child[0]:GetChild("docContainer")` + 裁剪到设备屏幕坐标
  2. `docContainer` 完整截图
  3. `testView.child[0].displayObject`
  4. `testView.contentPane.displayObject`
  5. `testView.displayObject`
- **`fg_editor_start_test` 返回值** — 新增 `item_name`、`item_id`、`device_found` 字段，便于诊断组件查找和设备匹配状态。

### Fixed

- **Bug-1：组件路径参数不一致** — `findComponentItem()` 辅助函数统一所有组件查找逻辑（包括子目录递归遍历）。
- **Bug-2：`fg_editor_reload` 全量刷新超时** — 改为 `Timers.inst:Add(0.1, 1, ...)` 异步执行，命令立即返回。
- **Bug-3：`fg_editor_start_test` 不打开正确组件** — 加入 `OpenDocument` 步骤。
- **Bug-4：`fg_editor_activate` 未实际激活窗口** — 改用 Win32 API。
- **Bug-5：`publish` 后通信中断** — 发布后通过 Win32 激活窗口保持 Timer 运行。
- **Bug-6：`reload` 单包刷新无视觉变化** — 5 种策略并行尝试。
- **Bug-7：`move/delete_resource` 后编辑器不自动刷新** — 操作成功后自动发送 reload 命令。
- **Bug-8：`capture_preview` 截图包含编辑器 UI** — 通过深度探查 testView 内部结构（含 toolbar、controllerList、docContainer 等子元素），定位到真正的预览容器 `docContainer`，并支持裁剪到设备屏幕区域。

### Removed

- **`fg_editor_reload_all_plugins`** — `PluginSystem.ReloadAll()` 重载机制不可靠（会导致 MCPBridge 自身重启后通信永久中断），且与 `fg_editor_reload_plugin` 功能重叠。

### Internal

- **探查工具增强** — `handleProbePluginApi` 新增 `testView`、`testView_full`、`testView_child0`、`testView_grandchild`、`docContainer`、`docContainer_deep`、`preview_scale`、`publishSettings` 等探查目标。
- **新增 `findComponentItem(pkg, compName)`** — 统一组件查找入口，递归遍历包内子目录。
- **新增 `findDeviceInfo(deviceName)`** — 设备名匹配（搜索 `defaultDevices` 和 `devices`）。
- **新增 `applyTestViewDevice(...)`** — 多策略尝试设备分辨率切换。
- **新增 `getTestViewCaptureTarget(testView)`** — 多策略查找截图目标，返回裁剪信息。
- **新增 `tryPublishViaAPI` / `tryPublishViaToolbar`** — 发布功能的双路径实现。
- **`captureDisplayObject` 支持裁剪参数** — 新增 `cropX/cropY/cropW/cropH` 参数，通过 `texture:GetPixels` + `Texture2D:SetPixels` 实现精确裁剪。

### Known Issues

详见 [TODO.md](./TODO.md)：
- `fg_editor_capture_preview` 截图清晰度受用户手动滚轮缩放影响
- `fg_editor_start_test` 的 `device_name` 设备信息匹配但分辨率切换 API 不生效
- `fg_editor_select_element` 触发 CustomShadow 插件越界报错；检查器面板未自动刷新
