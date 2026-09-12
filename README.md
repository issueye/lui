# lui

轻量级声明式现代化 Free Pascal UI 渲染引擎与组件库。零第三方运行时依赖，
XML 声明结构 + CSS 子集样式 + TS 子集脚本（响应式绑定，参照 Vue 3）。

## 快速开始

```bash
# 构建（需要 Lazarus/lazbuild；可用 LAZBUILD 环境变量指定路径）
npm run build          # 渲染器 + 单元测试 + Demo 三目标

# 单元测试
npm test

# CLI 渲染任意页面为 PNG（独立渲染器，无需窗口）
npm run render:svg
bin/lui-render.exe demo/ui_gallery.xml -o out.png -w 560 -H 980 -t light

# 批量：多输入 × 双主题
bin/lui-render.exe demo/ui.xml demo/m7.xml -O out -t both --json

# GUI 预览（F5 刷新 / T 切主题 / Esc 退出）
bin/lui-render.exe demo/ui_gallery.xml
```

## 布局

| 目录 | 内容 |
| --- | --- |
| `src/core` `src/css` `src/layout` `src/render` | 引擎：DOM/样式/布局/渲染（GDI 与 GDI+ 后端，SVG 矢量） |
| `src/ui` | 交互/行为/宿主/引擎门面 + `xui_app.pas`（应用装配门面） |
| `src/script` | TS 子集脚本引擎：解释器 + DOM 桥 + 响应式绑定 + I/O |
| `ui/` | 组件库（`ui-*` 标签；`ui/index.ts` 入口、`templates/` 模板、`theme/` 主题） |
| `demo/` | 演示页面（login / list / todo / script / m7 / ui / uildg / uidisp / uinav） |
| `tools/renderer` | 独立渲染器 lui-render（CLI + GUI） |
| `tests/` | 单元测试（`npm test` 运行，当前 633 项） |

## 文档

- `docs/设计方案.md` —— 总纲（架构 / ADR / 里程碑）
- `docs/M6-异步设计.md` —— Promise / async-await / 定时器 / 真实 I/O
- `docs/M7-响应式绑定设计方案.md` —— 响应式绑定（Vue 3 对照）
- `docs/M8-组件库设计方案.md` —— 组件库
- `docs/M9-独立渲染器设计方案.md` —— lui-render 渲染器

## lui-render CLI

```
lui-render <输入.xml|svg> [更多输入...] [选项]
  -o/--output <png>    单文件输出      -O/--outdir <目录>  批量输出目录
  -w/--width, -H/--height              视口尺寸（默认 800×600）
  -t/--theme light|dark|both           主题（both 出双份）
  --json       结果 JSON 汇总（stdout）；日志走 stderr
  --watch      依赖变更自动重跑         --version / --help
```

退出码：0 全部成功；1 渲染/输入错误；2 参数错误；3 批量部分失败。
Windows 上 GDI+ 抗锯齿为一等体验；其它平台降级 GDI（见 M9 ADR 33）。

## 脚本页写法（Vue 3 风格）

```xml
<window>
  <script src="app.ts"/>
  <label x-text="'计数：' + state.n"/>
  <button onclick="OnAdd"/>
</window>
```

```ts
const state = reactive({ n: 0 });
function OnAdd() { state.n = state.n + 1; }   // 只改状态，UI 自动更新
```

支持 `x-if` / `x-for`（含 `x-key` 键控 diff）/ `x-model` / `:class` 对象语法 /
`computed` / `watch` / `onMount` / `component()` 自定义组件（props/slot/回调 props）。
异步：`async/await` + `ui.delay`/`ui.http`/`ui.fs`/`ui.storage`。
