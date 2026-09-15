# @@PROJECT_NAME@@

用 [lui](https://github.com/) 渲染的界面工程 —— XML 声明结构、CSS 子集写样式、TypeScript
子集写逻辑（响应式绑定）。本工程由 `lui-render --init` 生成，**自带组件库运行时**（`ui/`），
不依赖 lui 仓库即可开发与交付。

- 生成器：lui-render v@@LUI_VERSION@@（@@DATE@@）
- 入口页面：`src/main.xml`　逻辑：`src/main.ts`　样式：`src/main-light.css` / `src/main-dark.css`
- 视口：@@WIDTH@@×@@HEIGHT@@　主题：@@THEME@@

## 开发 · 测试 · 打包 · 交付

| 命令 | 作用 |
| --- | --- |
| `run-dev.cmd` | 开发预览：GUI 窗口，改 xml/css/ts 自动重载；`F5` 刷新、`T` 切主题、`Esc` 退出 |
| `run-test.cmd` | 测试：逐页脚本自检（`--check`）+ 双主题出图到 `out\`；**任一页脚本报错即退出码 1** |
| `run-pack.cmd` | 交付：组装 `dist\`（渲染器 + `ui/` + 页面 + 预览图 + 说明），整目录拷走即可运行 |

等价的手工命令（脚本只是把它包了一层）：

```bat
:: 预览
%RENDERER% src\main.xml -t light --watch

:: 出图
%RENDERER% src\main.xml -O out -t both -w @@WIDTH@@ -H @@HEIGHT@@ --json

:: 自检（CI 门禁）
%RENDERER% src\main.xml --check

:: 打包交付
%RENDERER% --pack dist src\main.xml -t both --force
```

渲染器路径写在各 `run-*.cmd` 顶部（`set RENDERER=...`）。换机器或换版本时改那一行即可；
单程序版 `lui-render-single.exe` 也可以直接填进去。

## 目录

```
src/
  main.xml          页面结构（组件用 <ui-*> 标签，绑定用 x-* / :prop）
  main.ts           页面逻辑（reactive 状态 + 函数；只改状态，界面自动刷新）
  main-light.css    浅色主题（完整样式表）
  main-dark.css     深色主题（完整样式表）
ui/                 组件库运行时（index.ts + components/ + templates/ + theme/），随工程走
out/                渲染产物（run-test.cmd 生成，已 gitignore）
dist/               交付产物（run-pack.cmd 生成，已 gitignore）
lui-project.json    工程清单（入口 / 视口 / 主题 / 渲染器路径）
```

## 改哪里

**结构**：编辑 `src/main.xml`。组件是 `<ui-*>` 标签（`ui-card` / `ui-button` / `ui-input` /
`ui-switch` / `ui-progress` …，共 40 多个），属性同名 camelCase；完整清单见 `ui/templates/`。

**逻辑**：编辑 `src/main.ts`。规则只有一条 —— **只改状态，别碰 DOM**：

```ts
const state = reactive({ n: 0 });
function OnInc() { state.n = state.n + 1; }   // UI 在安全点自动刷新
```

派生值用 `computed`，副作用用 `watch`，初始化用 `onMount`。

**绑定**（写在 XML 里）：

| 写法 | 含义 |
| --- | --- |
| `text="计数 {{state.n}}"` / `x-text="表达式"` | 文本插值 |
| `x-model="state.draft"` | 双向绑定（原生 input，或组件宿主上） |
| `x-if` / `x-for` + `x-key` | 条件渲染 / 列表（键控复用） |
| `x-show` | 切显隐（`display:none`，保留节点） |
| `x-class="{ done: it.done }"` | 对象语法切类名 |
| `:disabled` / `:percentage` / `:placeholder` | 动态属性（组件传 props） |
| `x-onclick="Fn(it.id)"` | 事件表达式，在页面脚本作用域求值 |
| `onclick="MethodName"` | 先找宿主 published 方法，找不到再回退脚本全局函数 `MethodName` |

**样式**：编辑 `src/main-<theme>.css`。⚠️ 引擎按主题**只加载其中一个**（不是在浅色上叠加
覆盖），所以两个文件都要写全：布局声明一一对应，只有颜色不同。组件外观（含设计 token
`--ui-color-*`）来自 `ui/theme/lui-light.css`（深色再由 `lui-dark.css` 覆盖），宿主会自动加载。

## 已知边界（引擎的不支持清单，写代码时避开）

- flex 子集：**无 `flex-wrap`、无 `flex-shrink`**；主轴不足即溢出，用 `overflow: hidden` 裁剪
- 组件在 flex 行里默认按内容收缩 —— 要占满剩余宽度得显式给容器类加 `flex: 1`
- 无 `transform` / `animation` / `@keyframes`；`transition` 只支持单条规格、只过渡绘制类属性（opacity、颜色、圆角）
- 无 `text-decoration`（别用删除线表达完成态）；文本不支持省略号与下端对齐
- 输入框是单行（无 `textarea`）；无撤销/重做、双击选词、右键菜单
- 滚动：纵向可滚，无横向滚动、无滚动条视觉

## 交付形态

`run-pack.cmd`（即 `lui-render --pack dist ...`）产出的目录：

```
dist/
  lui-render.exe     渲染器副本（或单程序版 lui-render-single.exe）
  ui/                组件库运行时
  pages/             页面及其关联资源（css/ts/include/assets，相对引用原样成立）
  preview-light.png  预览图（-t both 时出双份）
  preview-dark.png
  README.txt         交付说明
```

验收：`cd dist\pages` 后 `..\lui-render.exe main.xml -o out.png` 能出图即交付成立。
