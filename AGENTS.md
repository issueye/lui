# AGENTS.md - lui 渲染器与应用运行时

## 项目定位与架构哲学

`lui` 是**不写 Pascal 的声明式 GUI 框架与轻量级应用运行时**：
- **上层应用契约**：应用只编写 XML（结构布局）+ CSS（层叠样式）+ TS 子集（响应式与业务逻辑），免装 Lazarus/FPC，零 Pascal 代码；
- **底层自绘引擎**：引擎本体基于 Free Pascal / Lazarus 纯自绘开发（GDI / GDI+ 双后端，原生 SVG 路径栅格化，零第三方 C/C++ 运行时依赖）；
- **一体化单文件分发**：运行时自身即是构建器与打包器，可将应用 XML/CSS/TS 资源与运行时直接拼装为独立的绿色单文件 `.exe`（无需安装运行时或附带海量运行库）。

---

## 核心系统分层与代码约定

| 子系统目录 | 职责与技术边界 | 开发与修改准则 |
| :--- | :--- | :--- |
| `src/core/` | DOM 树节点、样式基类、几何类型、基础数据结构 | 保持极简纯粹，避免在此引入平台相关的 GUI 句柄或高层业务逻辑 |
| `src/css/` | CSS 词法解析、规则特异性计算、选择器匹配与继承 | 语法解析严格防崩；注意半透明与 Alpha 混合逻辑，避免脏状态扩散 |
| `src/layout/` | Flex 弹性盒、流式与绝对定位布局计算引擎 | 保证断行、尺寸测量与边距计算的幂等性与一致性 |
| `src/render/` | GDI / GDI+ 后端渲染、文本测量、SVG 矢量绘制 | 保证双后端文字换行与对齐口径严格一致；必须正确闭合路径与释放绘图句柄 |
| `src/script/` | TS 子集解释器、DOM 桥接、响应式双向绑定与受控 I/O | 严格沙箱隔离；向脚本暴露的能力必须通过 `RegisterNative` 受控注入 |
| `src/ui/` | 引擎门面、控件行为、窗口宿主、应用清单与内嵌容器 | 连接底层自绘与上层应用配置（`lui.json`）；无边框窗口需正确处理拖拽与缩放 |
| `tools/renderer/` | `lui.exe` 命令行入口、GUI 预览窗、依赖热重载与单文件打包器 | 保证命令行模式与 GUI 模式平滑切换，支持 `--check` 与无头渲染 `-o` |
| `ui/` | 内置标准组件库（`ui-*` 系列控件模板、脚本与双主题 CSS） | 遵循组件隔离原则，样式命名使用 BEM 规范；提供浅色/暗色完整覆盖 |

---

## 安全边界与隔离准则

1. **Native 暴露受控**：
   - 动态 TS 脚本只能访问宿主显式注册的 `ui.*` 命名空间 API；
   - 严禁将 Pascal 裸指针、原始窗口句柄（HWND）或未经验证的任意系统底层调用直接泄露给脚本。
2. **内存与资源生命周期**：
   - 图像、字体（`PGpFont`）、画刷（`PGpBrush`）、画笔（`PGpPen`）与裁剪栈必须在退出作用域前严格释放或放入安全生命周期的缓存；
   - 页面热重载时必须彻底清空上一版本的脚本全局状态、事件绑定与动态 DOM，根治内存泄漏与状态串扰。
3. **无边框与系统消息规范**：
   - 无边框窗口（`frameless: true`）的拖动与边缘缩放采用 Windows 标准非客户区消息分发机制（`WM_NCLBUTTONDOWN` + `HTCAPTION` / `HTBOTTOMRIGHT`）；
   - 在向系统交出鼠标捕获前，必须先行调用 `ReleaseCapture`，严禁产生鼠标事件捕获悬挂。

---

## 强制开发工作流程

每次开始修改 `lui` 引擎之前必须：
1. 阅读本文档与 `docs/设计方案.md`，明确改动影响的子系统与向后兼容性要求；
2. 确认当前基线测试（`npm test` 当前 978+ 测试）全绿；
3. 禁止为了让某单个测试或 UI 特例通过而破坏通用 CSS 解析、布局盒模型或渲染管道。

完成实现之后必须：
1. **构建运行时**：执行 `npm run build:renderer`（或 `node scripts/build.js renderer`），确保编译 0 错误、0 致命警告；
2. **全量单元测试**：执行 `npm test`，确保全部测试用例 100% 通过；
3. **无头出图与自检验证**：
   - 单页出图测试：`bin\lui.exe demo/ui_gallery.xml -o out\gallery.png`；
   - 页面自检测试：`bin\lui.exe --check demo\ui.xml`；
4. **小步提交**：提交信息使用标准语义化动词开头（`feat:`, `fix:`, `refactor:`, `perf:` 等），并详细注明行为变化。

---

## 推荐验证命令汇总

```bash
# 1. 编译 lui 运行时核心（更新 bin/lui.exe 与 bin/lui-render.exe）
node scripts/build.js renderer

# 2. 运行完整单元测试集（978 项）
npm test

# 3. 运行测试基线核验
npm run verify:baseline

# 4. 预览与无头渲染验证
bin\lui.exe demo\ui.xml -o out\test.png -t both
bin\lui.exe --check demo\ui.xml
```
