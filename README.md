# lui

轻量级声明式现代化 Free Pascal UI 渲染引擎与组件库。零第三方运行时依赖，
XML 声明结构 + CSS 子集样式 + TS 子集脚本（响应式绑定，参照 Vue 3）。

## 快速开始

```bash
# 构建（需要 Lazarus/lazbuild；可用 LAZBUILD 环境变量指定路径）
npm run build          # 渲染器 + 单元测试 + Demo 三目标

# 单元测试
npm test

# 回归基线校验（复用已编译测试程序，并核对文档中的测试数量）
npm run verify:baseline

# 新建一个自己的工程（开发 / 测试 / 打包 / 交付 一次到位）
npm run init -- myapp
cd myapp
run-dev.cmd            # 开发预览（F5 刷新 / T 切主题 / Esc 退出，改文件自动重载）
run-test.cmd           # 测试：逐页脚本自检 + 双主题出图到 out\
run-pack.cmd           # 打包成交付目录 dist\（整目录拷走即可运行）

# CLI 渲染任意页面为 PNG（独立渲染器，无需窗口）
npm run render:svg
bin/lui-render.exe demo/ui_gallery.xml -o out.png -w 560 -H 980 -t light

# 批量：多输入 × 双主题
bin/lui-render.exe demo/ui.xml demo/m7.xml -O out -t both --json

# 脚本自检（CI 门禁：任一页有脚本错误则退出码 1）
bin/lui-render.exe src/main.xml --check

# GUI 预览（F5 刷新 / T 切主题 / Esc 退出）
bin/lui-render.exe demo/ui_gallery.xml
```

## 布局

| 目录 | 内容 |
| --- | --- |
| `src/core` `src/css` `src/layout` `src/render` | 引擎：DOM/样式/布局/渲染（GDI 与 GDI+ 后端，SVG 矢量） |
| `src/ui` | 交互/行为/宿主/引擎门面 + `xui_app.pas`（装配门面）+ `xui_embed.pas`（资源内嵌）+ `xui_scaffold.pas`（项目脚手架） |
| `src/script` | TS 子集脚本引擎：解释器 + DOM 桥 + 响应式绑定 + I/O |
| `ui/` | 组件库（`ui-*` 标签；`ui/index.ts` 入口、`templates/` 模板、`theme/` 主题） |
| `scaffold/` | 项目模板：`lui-render --init` 用它生成工程骨架（含自带 `ui/` 运行时） |
| `demo/` | 演示页面（login / list / todo / script / m7 / ui / uildg / uidisp / uinav / **agent**） |
| `tools/renderer` | 独立渲染器 lui-render（CLI + GUI + 项目工具链）与单程序版工程 |
| `tests/` | 单元测试（`npm test` 运行，当前 722 项） |

## 文档

- `docs/设计方案.md` —— 总纲（架构 / ADR / 里程碑）
- `docs/M6-异步设计.md` —— Promise / async-await / 定时器 / 真实 I/O
- `docs/M7-响应式绑定设计方案.md` —— 响应式绑定（Vue 3 对照）
- `docs/M8-组件库设计方案.md` —— 组件库
- `docs/M9-独立渲染器设计方案.md` —— lui-render 渲染器
- `docs/M10-AI-Agent设计方案.md` —— 对话式 AI Agent（工具调用 / 离线+在线双档）
- `docs/M11-项目脚手架设计方案.md` —— 项目脚手架与开发/测试/打包/交付工具链
- `docs/测试套件模块化.md` —— 回归测试 include 分组与迁移约定

## 新建工程（`lui-render --init`）

一条命令生成可立即运行、且自带组件库运行时的工程：

```bash
lui-render --init myapp                       # 生成 ./myapp（默认 480×560，浅色）
lui-render --init myapp -w 480 -H 560 -t both # 指定视口与主题
lui-render --init myapp --name 我的应用        # 指定工程名（默认取目录名）
```

生成的工程：

```
myapp/
  src/main.xml  src/main.ts  src/main-light.css  src/main-dark.css
  ui/                     组件库运行时（整树复制：index.ts + components/ + templates/ + theme/）
  run-dev.cmd             开发：GUI 预览，改 xml/css/ts 自动重载
  run-test.cmd            测试：--check 自检 + 双主题出图（有脚本错误退出码 1）
  run-pack.cmd            打包：组装 dist\ 交付目录
  lui-project.json        工程清单      README.md      工程说明（含引擎不支持清单）
  .gitignore  out/  dist/
```

**开发 → 测试 → 打包 → 交付**：

```bash
cd myapp
run-dev.cmd      # 开发：预览 + 热重载（F5 刷新 / T 切主题 / Esc 退出）
run-test.cmd     # 测试：逐页自检（CI 可判定）+ 双主题出图到 out\
run-pack.cmd     # 打包 → dist\（渲染器 + ui/ + pages/ + 预览图 + README.txt）

# 交付验收：dist\ 拷到任意机器，进入 pages\ 后运行
..\lui-render.exe main.xml -o out.png
```

工程自带 `ui/` 运行时，**不依赖 lui 仓库**即可单独提交与交付。渲染器路径写在各
`run-*.cmd` 顶部（`set RENDERER=...`），换机器改那一行；单程序版
`lui-render-single.exe` 也能 `--init`，且在空目录即可生成完整工程。

## lui-render CLI

```
lui-render <输入.xml|svg> [更多输入...] [选项]
  -o/--output <png>    单文件输出      -O/--outdir <目录>  批量输出目录
  -w/--width, -H/--height              视口尺寸（默认 800×600）
  -t/--theme light|dark|both           主题（both 出双份）
  --json       结果 JSON 汇总（stdout）；日志走 stderr
  --bench <N>  渲染后重复 N 次完整重排并输出耗时（性能基准）
  --watch      依赖变更自动重跑         --version / --help
  --list-embedded  列出 exe 内嵌资源    --add-page <xml>  输出页面资源清单（供打包）

项目工具链（M11）:
  --init <目录> [--name 名] [-w -H -t] [--force]   生成工程骨架（只写不改不删）
  --check <输入...>                                脚本自检；有错退出码 1（CI 门禁）
  --pack <目录> <输入...> [-t] [--force]           组装交付目录
```

退出码：0 全部成功；1 渲染/输入错误；2 参数错误；3 批量部分失败。
Windows 上 GDI+ 抗锯齿为一等体验；其它平台降级 GDI（见 M9 ADR 33）。

## 打包分发

```bash
npm run pack        # 构建 + 组装 dist/lui/ + 压缩 lui-<版本>-win64.zip
```

包内布局：`lui-render.exe` / `demo1.exe` 在根，`pages/` 含演示页面与 `ui/` 运行时资源，
`scaffold/` 是项目模板（`--init` 用），`ui/` 是组件库运行时。`cd pages` 后运行
`..\demo1.exe login` 或 `..\lui-render.exe ui.xml -o out.png`。

包内的 `lui-render.exe` 即可直接为用户生成工程（模板与 `ui/` 都在包里）：

```bash
mkdir work && cd work
..\lui-render.exe --init myapp      # 生成自带 ui/ 运行时的完整工程
cd myapp && run-test.cmd            # 自检 + 出图；run-pack.cmd 出交付目录
```

打包时含两条冒烟：① `pages/` 工作目录出图；② `--init` 生成工程并出图（同时校验生成的
`run-*.cmd` 里渲染器路径指向包内 exe）。

## 单程序分发（资源内嵌）

```bash
npm run single      # 生成内嵌资源 → 编译 → 冒烟，产出 bin/lui-render-single.exe
```

把演示页面（xml/css/ts/svg）与 `ui/` 组件库运行时（组件脚本 + 模板 + 主题）一并编码进
可执行文件，产出一个**不依赖任何外部文件**的 `lui-render-single.exe`（约 28 MB）。
拷到任意目录即可出图，无需携带 `ui/` 与 `pages/`：

```bash
lui-render-single.exe ui_gallery.xml -o out.png -w 560 -H 980 -t light   # 页面名直接来自内嵌集
lui-render-single.exe --list-embedded                                    # 查看内嵌了哪些资源
```

设计要点（见 M9 ADR 34）：

- **磁盘优先的超集语义**：命令行给的文件若在磁盘上存在则直接用磁盘文件，内嵌资源只在
  找不到时参与解析。因此同一个 exe 既能渲染内嵌演示页，也能渲染任意外部 XML（改工作区
  文件立即生效，不必重新内嵌）。
- **解包而非虚拟文件系统**：运行时按内容指纹把资源解包到 `%TEMP%\lui-embed-<指纹>`
  （带就绪标记，仅首次运行解包），再走引擎既有文件访问路径，因此相对引用、`<include>`、
  `<script src>`、组件模板、SVG、依赖热重载全部照旧可用。
- **资源发现单一来源**：打包脚本调用渲染器自身的 `--add-page` 解析每页的关联资源
  （同名 css/ts、`nav-*.css`、`<include src>`、`<script src>`），规则与引擎同源，不重复维护。
- **可定制**：`node scripts/embed.js --pages demo/login.xml,demo/ui_gallery.xml` 只内嵌指定页。

单程序版同样内嵌了 `scaffold/` 模板与 `ui/` 运行时，因此**在空目录里也能直接开新工程**：

```bash
lui-render-single.exe --init myapp       # 不需要任何外部文件
cd myapp && run-test.cmd
```

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

## 对话式 AI Agent（demo/agent）

用 lui 现有能力实现的多轮会话 + 工具调用应用，演示完整的 agent 回路。

```bash
bin/lui-render.exe demo/agent.xml -o agent.png -w 460 -H 780 -t light   # CLI 出图
demo/demo1.exe agent demo   # GUI：点快捷短语走完整工具回路
```

- **离线档（默认）**：内置规则规划器解析意图 → 顺序调用工具 → 据结果拼装回答，再用打字机
  逐字输出。纯本地、确定性，无需网络与密钥，CI/截图都走这一档。
- **在线档（可选）**：填入 OpenAI 兼容端点（设置面板），走真正的 agent loop——
  `tool_calls` → 本地执行 → 以 `role=tool` 回填 → 循环至终答；失败自动回落离线档。
- **工具本地执行**：计算器（自研表达式求值器，非 `eval`）/ 当前时间 / 知识检索。

## 脚本页写法（Vue 3 风格）

支持 `x-if` / `x-for`（含 `x-key` 键控 diff）/ `x-model` / `:class` 对象语法 /
`computed` / `watch` / `onMount` / `component()` 自定义组件（props/slot/回调 props）。
异步：`async/await` + `ui.delay`/`ui.http`/`ui.fs`/`ui.storage`。
