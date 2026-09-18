# lui

**不写 Pascal 的声明式 GUI 应用框架**：应用只写 XML（结构）+ CSS（样式）+ TS 子集（逻辑），
其余交给**一个可执行文件**——开发、运行、构建、交付都在里面。工作流对标 Electron，
但产物是**单个 exe**（自带页面与组件库），不是"自带运行时的目录"。

引擎本身是 Free Pascal 编写的自绘渲染器（零第三方运行时依赖），但**应用开发者不需要装
Lazarus/FPC，也不会碰到一行 Pascal**。

## 快速开始

```bash
# 拿到运行时：构建它（需要 Lazarus/lazbuild；可用 LAZBUILD 环境变量指定路径）
npm run build:renderer      # → bin/lui.exe（别名 bin/lui-render.exe，同一份二进制）
npm test                    # 单元测试（985 项）

# 回归基线校验（复用已编译测试程序，并核对文档里声明的测试数量）
npm run verify:baseline

# 新建应用（自带组件库运行时，可脱离本仓库单独提交与交付）
bin/lui.exe init myapp
cd myapp

# 开发 → 测试 → 构建 → 交付：全是同一个运行时的命令
run-dev.cmd        # lui dev .      窗口 + 热重载（F5 刷新 / T 切主题 / Esc 退出）
run-test.cmd       # lui check .    逐页脚本自检 + 双主题出图到 out\
run-build.cmd      # lui build .    单文件应用 dist\myapp.exe
run-pack.cmd       # lui pack .     交付目录：应用 exe + 预览图 + README.txt

# 构建出来的应用 exe 本身就是完整 CLI，拷到任意机器都能用
dist\myapp.exe                        # 双击 = 运行应用
dist\myapp.exe -o out.png -t dark     # 出图
dist\myapp.exe --check                # 自检
dist\myapp.exe --list-bundle          # 看包里装了什么
```

`lui build` 不会调用编译器：它把运行时自身复制一份，把应用目录追加到文件尾部，再写一个
48 字节的尾部目录——所以**构建应用不需要 Pascal 工具链**（见 M12 §6）。

## 命令面（一个 exe 走完生命周期）

```
lui <命令> [目录] [选项]       应用生命周期（由应用根下的 lui.json 描述）
lui <页面.xml> [选项]          直接渲染 / 预览某个页面（不依赖清单）
lui                            自包含应用 exe：无参数即运行应用本身

  init [目录]      生成应用骨架      dev [目录]     开发预览（热重载）
  build [目录]     单文件应用        start [目录]   运行应用
  pack [目录]      交付目录          check [目录]   逐页自检（CI 门禁）
  render <页面..>  无头出图          version / help
```

应用描述在 `lui.json`（入口页面、窗口、默认主题、组件库目录、构建输出）：

```jsonc
{
  "name": "myapp",
  "main": "src/main.xml",
  "ui": "ui",
  "window": { "width": 480, "height": 560, "theme": "light", "resizable": true, "center": true },
  "dev":   { "watch": true },
  "build": { "out": "dist", "exclude": ["out", "dist", ".git", "node_modules"] }
}
```

M11 的旧参数（`--init` / `--check` / `--pack`）与"给个 xml 就出图"的老用法全部保留可用：
命令面只是把它们翻译成同一套选项，共用一条执行路径
（见 [M12 设计](docs/M12-Electron式运行时重设计方案.md) §3）。

## 改本项目（引擎侧开发）

```bash
npm run build:renderer                                              # 重编译运行时
bin/lui.exe demo/ui_gallery.xml -o out.png -w 560 -H 980 -t light   # 单页出图
bin/lui.exe demo/ui.xml demo/m7.xml -O out -t both --json           # 批量：双主题
bin/lui.exe demo/ui_gallery.xml                                     # GUI 预览
npm run build                                                       # 运行时 + 测试 + demo 三目标
npm run single                                                      # 单程序版（内嵌演示资源）
```

## 布局

| 目录 | 内容 |
| --- | --- |
| `src/core` `src/css` `src/layout` `src/render` | 引擎：DOM/样式/布局/渲染（GDI 与 GDI+ 后端，SVG 矢量） |
| `src/ui` | 交互/行为/宿主/引擎门面 + `xui_app.pas`（装配门面）+ `xui_appspec.pas`（应用清单与应用根）+ `xui_bundle.pas`（自包含应用容器）+ `xui_embed.pas`（资源内嵌）+ `xui_scaffold.pas`（应用脚手架） |
| `src/script` | TS 子集脚本引擎：解释器 + DOM 桥 + 响应式绑定 + I/O |
| `ui/` | 组件库（`ui-*` 标签；`ui/index.ts` 入口、`templates/` 模板、`theme/` 主题） |
| `scaffold/` | 应用模板：`lui init` 用它生成骨架（`lui.json` + 页面 + 自带 `ui/` 运行时 + `run-*.cmd`） |
| `demo/` | 演示页面（login / list / todo / script / m7 / ui / uildg / uidisp / uinav / **agent**） |
| `tools/renderer` | 运行时主程序（命令面 + GUI + 项目工具链 + 自包含构建）与单程序版工程 |
| `tests/` | 单元测试（`npm test` 运行，当前 985 项）；按主题拆成 `tests/*.inc`，M12/M13 的新增项在 `tests/m12_m13.inc` |

## 文档

- `docs/设计方案.md` —— 总纲（架构 / ADR / 里程碑）
- `docs/M12-Electron式运行时重设计方案.md` —— **Electron 式运行时**：应用清单 / 应用根 / 自包含单文件应用（ADR 48–57）
- `docs/M13-脚本运行时IO补全.md` —— **脚本 I/O 补全**：`ui.exec` 进程执行、`ui.fs` 目录与追加写、Array 查找排序（ADR 58–61）
- `docs/M6-异步设计.md` —— Promise / async-await / 定时器 / 真实 I/O
- `docs/M7-响应式绑定设计方案.md` —— 响应式绑定（Vue 3 对照）
- `docs/M8-组件库设计方案.md` —— 组件库
- `docs/M9-独立渲染器设计方案.md` —— 出图工具与单程序分发（部分决策已被 M12 取代）
- `docs/M10-AI-Agent设计方案.md` —— 对话式 AI Agent（工具调用 / 离线+在线双档）
- `docs/M11-项目脚手架设计方案.md` —— 项目脚手架与开发/测试/打包/交付工具链
- `docs/性能分析与优化.md` —— 两轮热点剖析与优化记录（含 `--bench` 用法与实测数据）
- `docs/测试套件模块化.md` —— 回归测试 include 分组与迁移约定

## 新建应用（`lui init`）

一条命令生成可立即运行、自带组件库运行时的应用：

```bash
lui init myapp                       # 生成 ./myapp（默认 480×560，浅色）
lui init myapp -w 480 -H 560 -t both # 指定视口与主题
lui init myapp --name 我的应用        # 指定名称（默认取目录名）
```

生成的应用：

```
myapp/
  lui.json                应用清单（入口 / 窗口 / 主题 / 组件库 / 构建）
  src/main.xml  src/main.ts  src/main-light.css  src/main-dark.css
  ui/                     组件库运行时（整树复制：index.ts + components/ + templates/ + theme/）
  run-dev.cmd             开发：lui dev .（改 xml/css/ts 自动重载）
  run-test.cmd            测试：lui check . + 双主题出图（有脚本错误退出码 1）
  run-build.cmd           构建：lui build . → dist\<name>.exe
  run-pack.cmd            交付：lui pack . → dist\（exe + 预览图 + 说明）
  README.md               应用说明（含引擎不支持清单）
  .gitignore  out/  dist/
```

**开发 → 测试 → 构建 → 交付**：

```bash
cd myapp
run-dev.cmd      # 开发：预览 + 热重载
run-test.cmd     # 测试：逐页自检（CI 可判定）+ 双主题出图到 out\
run-build.cmd    # 构建：dist\myapp.exe（单文件，自带页面与组件库）
run-pack.cmd     # 交付：dist\（myapp.exe + preview-*.png + README.txt）

# 交付验收：把 dist\ 拷到任意机器（甚至换个工作目录）直接运行
myapp.exe --check
myapp.exe -o out.png -t dark
```

应用自带 `ui/` 运行时，**不依赖 lui 仓库**即可单独提交与交付。运行时路径写在各
`run-*.cmd` 顶部（`set RUNTIME=...`），换机器改那一行；单程序版
`lui-render-single.exe` 也能 `init`，且在空目录即可生成完整应用。

## 打包分发（lui 自身的发布包）

```bash
npm run pack        # 构建 + 组装 dist/lui/ + 压缩 lui-<版本>-win64.zip
```

包内布局：`lui.exe`（别名 `lui-render.exe`）与 `demo1.exe` 在根，`pages/` 含演示页面与
`ui/` 运行时资源，`scaffold/` 是应用模板（`init` 用）。包内的 `lui.exe` 即可直接为用户
生成应用：

```bash
mkdir work && cd work
..\lui.exe init myapp          # 生成自带 ui/ 运行时的完整应用
cd myapp && run-build.cmd      # 构建单文件应用；run-pack.cmd 出交付目录
```

退出码约定（命令面与旧参数一致）：0 成功；1 渲染/运行失败；2 参数错误；3 批量部分失败。
Windows 上 GDI+ 抗锯齿为一等体验；其它平台降级 GDI（见 M9 ADR 33）。

## 已知边界

- 应用侧无 Pascal 依赖；**扩展引擎内建能力**（新元素行为、新渲染后端、新系统能力）仍需改
  引擎 Pascal——与 Electron 里"要加原生模块得写 C++"同一性质（M12 §7）。
- 脚本侧的 I/O 能力面：`ui.http.get/post`、`ui.fs`（读/写/追加/存在/stat/列目录/建目录/删除/改名）、
  `ui.exec.run`（跑外部命令，带 cwd/超时/输出上限/stderr 分流）、`ui.storage`。详见
  [M13](docs/M13-脚本运行时IO补全.md)。
- 单文件产物 = 运行时（约 29 MB）+ 载荷（模板应用约 115 KB）；追加式载荷不适合代码签名。
- 引擎的能力边界（flex 子集、无 transform/animation、单行输入框等）见生成应用里的
  `README.md`「已知边界」一节。
