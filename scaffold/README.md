# @@PROJECT_NAME@@

用 [lui](https://github.com/) 写的界面应用 —— XML 声明结构、CSS 子集写样式、TypeScript
子集写逻辑（响应式绑定）。**不需要写任何 Pascal**：应用由根目录下的 `lui.json` 描述，
其余全部由随附的运行时（一个可执行文件）负责。

本工程由 `lui init` 生成，**自带组件库运行时**（`ui/`），不依赖 lui 仓库即可开发、构建与交付。

- 生成器：lui v@@LUI_VERSION@@（@@DATE@@）
- 入口页面：`src/main.xml`　逻辑：`src/main.ts`　样式：`src/main-light.css` / `src/main-dark.css`
- 视口：@@WIDTH@@×@@HEIGHT@@　默认主题：@@DEV_THEME@@
- 运行时：`@@RUNTIME_POSIX@@`（各 `run-*.cmd` 顶部也有这份路径，换机器改那一行）

## 开发 · 测试 · 构建 · 交付

| 命令 | 作用 |
| --- | --- |
| `run-dev.cmd` | 开发预览：窗口 + 热重载，改 xml/css/ts 自动生效；`F5` 刷新、`T` 切主题、`Esc` 退出 |
| `run-test.cmd` | 测试：逐页脚本自检 + 双主题出图到 `out\`；**任一页脚本报错即退出码 1**（可直接进 CI） |
| `run-build.cmd` | 构建：产出 `dist\@@PROJECT_NAME@@.exe` —— 单文件应用，拷到任意机器双击即运行 |
| `run-pack.cmd` | 交付：`dist\` 里放好应用 exe + 预览图 + 交付说明，整个目录可打包发走 |

脚本只是把运行时命令包了一层。等价的手工命令：

```bat
%RUNTIME% dev .                        :: 开发预览（`lui start .` 则只运行不监听）
%RUNTIME% check .                      :: 自检全部页面（退出码 1 = 有脚本错误）
%RUNTIME% render src\main.xml -o a.png -t dark    :: 无头出图
%RUNTIME% build .                      :: 单文件应用 → dist\@@PROJECT_NAME@@.exe
%RUNTIME% pack . -t both               :: 交付目录（exe + 预览图 + README）
```

运行时路径写在各 `run-*.cmd` 顶部（`set RUNTIME=...`）。换机器或换版本时改那一行即可。

构建出来的应用 exe 本身就是一个完整 CLI（不需要额外带运行时）：

```bat
dist\@@PROJECT_NAME@@.exe                  :: 双击 = 运行应用
dist\@@PROJECT_NAME@@.exe -o a.png -t dark :: 出图
dist\@@PROJECT_NAME@@.exe --check          :: 自检
dist\@@PROJECT_NAME@@.exe --list-bundle    :: 看这个包里到底装了什么
```

## 目录

```
lui.json            应用清单：入口 / 窗口 / 主题 / 组件库 / 构建（运行时读的就是它）
src/
  main.xml          页面结构（组件用 <ui-*> 标签，绑定用 x-* / :prop）
  main.ts           页面逻辑（reactive 状态 + 函数；只改状态，界面自动刷新）
  main-light.css    浅色主题（完整样式表）
  main-dark.css     深色主题（完整样式表）
ui/                 组件库运行时（index.ts + components/ + templates/ + theme/），随应用走
out/                渲染产物（run-test.cmd 生成，已 gitignore）
dist/               构建产物：应用 exe / 预览图 / 交付说明（已 gitignore）
```

`lui.json` 里能改的东西：

```jsonc
{
  "main": "src/main.xml",          // 入口页面
  "ui": "ui",                      // 组件库目录（换名也行）
  "window": { "width": 480, "height": 560, "theme": "light",
              "title": "", "resizable": true, "center": true },
  "dev":   { "watch": true },      // dev 是否自动重载
  "build": { "out": "dist",        // 构建输出目录
             "exclude": ["out", "dist", ".git", "node_modules"],
             "assets": ["assets/logo.png"] }   // 强制打进包的文件（一般不需要）
}
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
| `onclick="Fn"` | 脚本全局函数（引擎内建事件优先，其次是它） |

**样式**：编辑 `src/main-<theme>.css`。⚠️ 引擎按主题**只加载其中一个**（不是在浅色上叠加
覆盖），所以两个文件都要写全：布局声明一一对应，只有颜色不同。组件外观（含设计 token
`--ui-color-*`）来自 `ui/theme/lui-light.css`（深色再由 `lui-dark.css` 覆盖），宿主会自动加载。

想加一份多页共用的基础样式，就在 `lui.json` 的 `styles` 里列出（与主题无关，无条件加载）：

```json
"styles": ["src/base.css"]
```

## 已知边界（引擎的不支持清单，写代码时避开）

- flex 子集：**无 `flex-wrap`、无 `flex-shrink`**；主轴不足即溢出，用 `overflow: hidden` 裁剪
- 组件在 flex 行里默认按内容收缩 —— 要占满剩余宽度得显式给容器类加 `flex: 1`
- 无 `transform` / `animation` / `@keyframes`；`transition` 只支持单条规格、只过渡绘制类属性（opacity、颜色、圆角）
- 无 `text-decoration`（别用删除线表达完成态）；文本不支持省略号与下端对齐
- 输入框是单行（无 `textarea`）；无撤销/重做、双击选词、右键菜单
- 滚动：纵向可滚，无横向滚动、无滚动条视觉
- 脚本是 TS 子集：无 `import` / `export`（用 `<script src>` 与 `ui.include()` 组织）、无正则、无 `Date`/`Map`/`Set`
- 脚本能用的系统能力：`ui.http.get/post`（JSON/文本，带超时）、`ui.fs`（读/写/追加/存在/stat/
  列目录/建目录/删除/改名）、`ui.exec.run`（跑外部命令，带 cwd/超时/输出上限）、`ui.storage`
  （键值持久化）。相对路径锚定应用根（`lui.json` 所在目录）
- `ui.exec.run` 只负责"能跑命令"，**允许跑什么由你的应用自己把关**：需要审批/白名单/沙箱的
  场景请在 TS 里实现（参考 a_da 的 Policy + 审批设计）

## 交付形态

`run-pack.cmd` 产出的目录：

```
dist/
  @@PROJECT_NAME@@.exe       自包含应用（运行时 + 页面 + 组件库都在里面）
  preview-light.png          预览图（-t both 时出双份）
  preview-dark.png
  README.txt                 交付说明
```

整个目录拷到任意 Windows 机器即可运行，目标机器不需要装 Pascal、Lazarus 或任何运行时。
