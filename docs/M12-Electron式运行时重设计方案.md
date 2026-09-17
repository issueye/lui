# M12 — Electron 式运行时重设计方案

> 状态：已实现（2026-09-17）。本文是 M12 的设计依据与验收说明。
> 取代关系：ADR 48–57 新增；**ADR 30/31/34/41/42/44 被本方案取代或收窄**（见 §9）。

---

## 1. 目标：把 lui 从"引擎 + 工具"变成"运行时 + 应用"

### 1.1 用户要的是什么

> 本项目应该设计为类似 Electron 这样的 GUI 框架，通过提供 xml css ts 的方式，而不需要再写
> pascal 代码。提供开发、运行、打包、二进制一套的单独二进制运行时程序。

拆成四条硬要求：

| # | 要求 | 含义 |
| --- | --- | --- |
| G1 | **不写 Pascal** | 应用开发者只交付 `lui.json` + `.xml` + `.css` + `.ts`；不需要装 Lazarus/FPC，不需要理解 `TXuiHost`/`TXuiBehavior` |
| G2 | **单一二进制运行时** | 开发、运行、构建、交付都由**同一个可执行文件**提供，没有第二套 CLI |
| G3 | **开发/运行/打包/二进制成套** | `dev`（热重载预览）、`start`（运行）、`build`（单文件应用）、`pack`（交付目录）是同一个工具的命令，不是四套脚本 |
| G4 | **应用即产物** | 构建结果是**一个自带页面与组件库的 exe**：拷到任意机器双击即运行 |

### 1.2 与 Electron 的对照

| 维度 | Electron | lui（M12 之后） |
| --- | --- | --- |
| 应用描述 | `package.json`（`main` 指向入口 js） | `lui.json`（`main` 指向入口 xml） |
| 开发者写的语言 | HTML/CSS/JS | XML/CSS/TS 子集 |
| 运行时 | Node + Chromium | 单 exe（引擎 + 组件库 + CLI） |
| 开发模式 | `electron .` | `lui dev .` |
| 生产运行 | `electron .`（同一份代码） | `lui start .`（开发/生产同一份页面） |
| 打包 | electron-builder / asar → 自带 Node 的可执行目录 | `lui build .` → 单文件 exe（载荷追加在运行时尾部） |
| 应用根 | `app.getAppPath()` | 清单所在目录（或自包含 exe 的解包根） |
| 相对路径基准 | 一律相对应用根 | 一律相对应用根（ADR 49） |

差异的关键在打包：Electron 的产物是"自带运行时的目录"，lui 的产物是**一个文件**——
因为 lui 的引擎本身就是单个 exe，把应用资源追加到它尾部即可，不需要复制一整个运行时树。

---

## 2. 改造前的实际状态（为什么不能只改文档）

M11 结束时已经是"XML/CSS/TS 可写、不用写 Pascal"，但离 Electron 式还有五处结构性缺口：

| 缺口 | 现象 | 根因 |
| --- | --- | --- |
| 工程不是运行时概念 | `lui-project.json` 只是"这是 lui 工程"的标记，运行时不读它；入口/视口/主题硬编码在 `run-*.cmd` 里 | 没有清单驱动 |
| 路径基准不统一 | `<include>`/`<script src>` 相对入口 xml；`ui.include`/`templateFile` 相对脚本；`<svg src>` 相对**当前工作目录** | 没有"应用根"这一概念 |
| 交付物必须 `cd` | `--pack` 产物要 `cd dist\pages` 才能跑 | 同上：相对 CWD 解析 |
| 单文件应用需要 FPC | 只有 lui 自己能用 `-dLUI_EMBED` + 重编译把资源编进 exe | 内嵌是**构建期**行为（ADR 34） |
| 命令面是选项不是动词 | `--init/--check/--pack` 挂在渲染器上，"开发/运行"没有对应的命令 | ADR 41 的代价 |

M12 就是把这五条一次性抹平。

---

## 3. 命令面（G2/G3）

一个可执行文件、两层用法。运行时文件名同时提供 `lui.exe`（规范名）与 `lui-render.exe`
（兼容别名，同一份二进制）。

```
lui <命令> [目录] [选项]          应用生命周期（清单驱动）
lui <页面.xml> [选项]             直接渲染/预览某个页面（无清单，旧用法不变）
lui                               自包含应用 exe：无参数即运行应用本身
```

| 命令 | 作用 | 等价旧参数 |
| --- | --- | --- |
| `lui init [目录]` | 生成应用骨架（含自带 `ui/` 与 `lui.json`） | `--init <目录>` |
| `lui dev [目录]` | 开发：窗口 + 热重载（F5/T/Esc） | 无（旧版是 `run-dev.cmd` 里手拼 `--watch`） |
| `lui start [目录]` | 运行应用（同 dev，不自动监听） | 无 |
| `lui build [目录]` | 构建单文件应用 → `dist/<name>.exe` | 无（**新增能力**） |
| `lui pack [目录]` | 交付目录：应用 exe + 预览图 + README | `--pack`（旧形态已收窄，见 §9） |
| `lui check [目录]` | 逐页自检，有脚本错误退出码 1 | `--check <页面...>` |
| `lui render <页面...>` | 无头出图（PNG） | 直接给 xml 路径（旧默认行为） |
| `lui version` / `lui help` | 版本 / 帮助 | `-V` / `-h` |

应用类命令可覆盖清单里的值：`-w/-H/-t/--out/--exe/--json/-v`。

**实现要点：命令只是"参数翻译层"。** `NormalizeArgv` 把 `lui dev myapp` 翻译成
`<entry> --watch --app-root myapp -t dark -w 640 -H 900`，然后交给原有的
`ParseCommandLine`。因此新命令与 M11 旧参数**共用一条执行路径**，不存在两套解析逻辑
各自演化的可能（这是 ADR 52 的核心，也是本次改造风险最低的部分）。

两个防撞细节：

- 第一个参数在磁盘上存在（哪怕叫 `render`）→ 一律按"输入文件"处理，命令解析让路。
- `lui .` / `lui myapp`（给一个目录）→ 等价 `lui start <目录>`，对齐 `electron .`。

---

## 4. 应用清单 `lui.json`（ADR 48/49）

应用根下放清单，运行时真的读它——入口、窗口、组件库目录、构建输出全在里面。

```jsonc
{
  "name": "myapp",              // 产物名 dist/myapp.exe、默认标题
  "displayName": "我的应用",     // 窗口标题（优先于 name）
  "version": "0.1.0",           // 进交付说明
  "main": "src/main.xml",       // 入口页面（应用根相对）
  "ui": "ui",                   // 组件库目录（可改名）
  "window": {
    "width": 480, "height": 560,
    "theme": "light",           // dev/构建的默认主题
    "title": "",                // 显式标题（优先于 displayName）
    "resizable": true, "center": true
  },
  "styles": ["src/base.css"],   // 与主题无关的附加样式（无条件加载）
  "dev":   { "watch": true },   // dev 是否自动监听
  "build": {
    "out": "dist",
    "exclude": ["out", "dist", ".git", "node_modules"],
    "assets": ["assets/logo.png"]   // 强制打进包的文件（一般不需要）
  }
}
```

设计约束：**清单里不许有"没人读"的字段**。上面每个字段都有明确消费者——

| 字段 | 消费者 |
| --- | --- |
| `name` | `build` 产物名、`pack` 说明 |
| `displayName`/`window.title` | 预览窗标题（`TRenderViewerForm`） |
| `version` | `pack` 的 README |
| `main` | `Entry`（dev/start/check/build/pack/render 的默认输入） |
| `ui` | `TXuiApp.FindRepoRoot` → 组件库目录名 |
| `window.width/height/theme` | 预览窗口客户区、构建默认主题 |
| `window.resizable/center` | 预览窗 `BorderStyle`/`Position` |
| `styles` | `TXuiApp.ConfigureStyles` 附加样式表 |
| `dev.watch` | `lui dev` 是否注入 `--watch` |
| `build.out/exclude/assets` | `lui build`/`pack` 的输出目录与载荷收集 |

兼容：没有 `lui.json` 时回落到 M11 的 `lui-project.json`（`entry`/`viewport`/`theme` 字段
一一映射，并给出迁移提示）；两者都没有时按目录约定推导默认值——**"给个目录就能跑"
这条老能力保留**。清单存在但语法错误则明确失败（`Load` 返回 False），不用默认值静默跑出
一个"看起来对"的应用。

---

## 5. 应用根与路径解析统一（ADR 49）

这是本次改造里**真正解决老问题**的一条。

**规则**：应用根 = 清单所在目录（自包含 exe 则是载荷解包根）。所有相对引用锚定它。

```pascal
XuiAppRootOverride      // 全局：自包含 exe 的挂载根 / CLI --app-root / 清单所在目录
XuiAppSpec.PathOf(rel)  // 应用根相对 → 绝对
XuiAppResourcePath(rel) // 资源解析：先按应用根试；未命中回落旧语义（CWD）
```

落地到各处的解析基准：

| 资源 | M11 之前 | M12 |
| --- | --- | --- |
| 入口 XML | 命令行给的路径（相对 CWD） | 清单 `main`（应用根相对）或命令行 |
| `<include src>` / `<script src>` | 入口文档目录 | 同（已是应用根内，无需改） |
| `ui.include` / `templateFile` | 当前脚本目录 | 同（同上） |
| `<svg src="assets/x.svg">` | **当前工作目录** | **应用根优先**，未命中回落 CWD |
| 组件库 `ui/` | 从 CWD/exe 目录向上找 `ui/index.ts` | 应用根优先，再向上找，再内嵌根 |
| 组件库主题 CSS | 同上 | 同上（含清单自定义的 `ui` 目录名） |

**效果**：交付目录不再需要 `cd`，应用根之外的任何工作目录都能跑通。验收用测试固定住了
（`TestAppSpec` 的 `XuiAppResourcePath` 用例 + 端到端冒烟从 `/tmp` 运行应用 exe）。

---

## 6. 自包含应用：不写 Pascal 也能出单文件（ADR 50/51）

### 6.1 为什么不能沿用 M9 的内嵌方案

M9 的单程序分发是"把资源 Base64 编成 Pascal 常量再链接"（ADR 34）。它能工作，但**只有
lui 自己的构建流程能用**——用户工程要出单文件就必须装 FPC 重编译，与 G1 直接冲突。

### 6.2 追加式载荷

`lui build` 做的事情只有三件：

1. 把**运行时 exe 自己**（`ParamStr(0)`）复制一份到 `dist/<name>.exe.lui-tmp`；
2. 把应用目录下的文件按原样**追加**到文件末尾；
3. 写 TOC 与 48 字节尾部目录，再把 tmp 原子重命名为 `dist/<name>.exe`。

```
[运行时 exe 原始字节][载荷：各文件原样字节][TOC][尾部 48 字节]
 尾部 = PayloadOffset:UInt64 | PayloadSize:UInt64 | FileCount:UInt32 | TocSize:UInt32
      | FormatVersion:UInt32 | Flags:UInt32 | Fingerprint:UInt32 | Reserved:UInt32
      | magic 'LUIBNDL1'(8B)
```

- **对 PE 安全**：镜像之外（节表之外）的尾部数据不参与加载，这是自解压包的成熟做法。
- **不需要编译器**：打包器就是运行时自己，构建应用的过程中一次也不会调用 FPC。
- **不用 zip/zlib**：零依赖约束下自带压缩不划算——载荷在 100 KB 量级，而 exe 本体 29 MB，
  压缩载荷省不到 0.5%。用 CRC32 做完整性校验即可。
- **不可复现的风险点被消掉**：TOC 按调用方给的顺序排列，同一份输入两次构建指纹一致
  （测试固定）。

启动时（`xui_bundle.XuiBundleMountSelf` → `xui_embed.XuiEmbedInstallFromFile`）：
读自身尾部 48 字节 → 校验 magic 与"三段长度自洽" → 读 TOC → 按内容指纹解包到
`%TEMP%\lui-embed-app<指纹>\`（带 `.lui-embed-ready` 就绪标记，失败落半包也不会被误用）
→ 把解包根设为应用根。因为复用 `xui_embed` 的挂载实现，**缓存重用、原子性、`LUI_EMBED_DIR`
覆盖这些语义只有一份代码**（这是把两档资源来源做进同一个单元、而不是各写一套的原因）。

之后：

- 双击 exe → `NormalizeArgv` 发现"无参数 + 自带载荷" → 等价 `lui start`，开窗运行；
- `app.exe -o a.png` / `--check` / `--list-bundle` → 注入自己的入口页后按 CLI 处理。

### 6.3 载荷里装什么

`CollectTree` 走"整树拷贝 + 排除"：默认排除 `out/`、`dist/`、`.git/`、`node_modules/`、
点开头目录、`*.exe`、`*.lui-tmp`，其余全部进包（`build.exclude` 可加，`build.assets` 可强制加）。

**为什么不是"按引用精确收集"**：精确收集要求在打包期重现引擎的全部引用规则
（`<include>`、`<script src>`、同名 css 约定、`<svg src>`、脚本里 `ui.fs` 拼出来的路径、
运行时才决定的路径），漏一条就是交付后才发现的缺文件；整树拷贝与用户对"应用目录"的
直觉一致，新加 `data.json`、`fonts/` 也自动进包。代价是包略大（模板应用 64 个文件 / 115 KB）。

---

## 7. "不写 Pascal"的边界（诚实清单）

M12 之后**应用开发者**不需要 Pascal，但要说清边界在哪：

| 事项 | 谁负责 |
| --- | --- |
| 页面结构 / 样式 / 逻辑 / 组件 | 应用开发者，写 XML / CSS / TS |
| 事件处理 | 脚本全局函数（`onclick="Fn"`）或 `x-onclick="expr"`；M12 起不再依赖 Pascal 宿主方法 |
| 内置元素行为 | 引擎内建（label/button/input/svg）——**想加新内置元素仍需改引擎 Pascal** |
| 组件库扩展 | 用 TS 写组件（`component({...})`，见 M8），不需要 Pascal |
| 窗口/输入/IME/渲染后端 | 运行时（已编译好，用户不接触） |
| 打包/分发 | `lui build` / `lui pack` |

仍然存在的 Pascal 依赖：**只有"扩展引擎内建能力"这一类**（新增元素行为、新增渲染后端、
新增系统能力）。这属于"框架开发"而非"应用开发"，与 Electron 里"要加个原生模块得写 C++"
同一性质。事件解析链（ADR 4）里"宿主 published 方法"那一档保留在引擎内（demo1 与引擎
自测仍在用），但**应用侧不再需要它**，文档与模板都只教脚本函数。

---

## 8. ADR 48–57

| ADR | 决策 | 理由与代价 |
| --- | --- | --- |
| **48 应用清单驱动** | 应用根下的 `lui.json` 是应用的唯一权威描述（入口/窗口/主题/组件库/构建），运行时真的读它；旧清单 `lui-project.json` 只读兼容 | "工程"从文件约定变成运行时概念，`.cmd` 不再需要与模板同步常量；代价：新增一份清单格式与解析（自研扁平 JSON 读取器，零依赖） |
| **49 应用根即路径基准** | 引入显式的应用根，所有相对引用锚定它；`<svg src>` 等历史 CWD 依赖改为"应用根优先，未命中回落 CWD" | 根治"交付目录必须 cd"与"换工作目录就跑不起来"；回落保证单页渲染的老用法零变化。代价：多一个全局 `XuiAppRootOverride` 与一次清单读盘 |
| **50 追加式自包含应用** | `lui build` = 复制运行时自身 + 追加应用文件 + 写 TOC/尾部目录；**不在构建期调用编译器** | 兑现"应用开发者不装 Pascal"这一条；产物是单文件，拷走即用。代价：产物 = 运行时大小 + 载荷（约 29 MB，其中引擎是固定成本）；尾部数据对签名工具不友好（当前不签名） |
| **51 载荷解包复用内嵌挂载** | 尾部载荷与 M9 的 Base64 内嵌共用 `xui_embed` 的挂载实现（指纹缓存 + 就绪标记 + 原子性） | 缓存与失败恢复语义只有一份实现、一处修复；后安装者覆盖先安装者，于是"单程序版运行时构建出的应用"也不冲突。代价：`xui_embed` 多一档"文件载荷"来源 |
| **52 命令只做参数翻译** | `lui <命令>` 在 `NormalizeArgv` 里翻译成既有选项序列，复用 `ParseCommandLine` | 新旧两套调用面共用一条执行路径，行为不会漂移；旧参数继续可用（无损回退）。代价：命令层需要处理"命令名与文件名撞车"的歧义（磁盘上存在即让路） |
| **53 载荷用整树拷贝 + 排除** | 收集应用载荷时整树拷贝并按排除名单过滤，不做"按引用精确收集" | 不会漏文件（漏文件是交付后才暴露的故障）；与用户对目录的直觉一致。代价：包里可能带上用不到的小文件 |
| **54 清单里不留死字段** | 清单每个字段都必须有消费者，否则不加（`pack.zip` 之类未实现的字段一律不写进模板） | 声明了没人读的配置比没有更糟：用户改了没效果，会怀疑整个工具。代价：加字段前必须先接好消费路径 |
| **55 模板与应用共用同一份清单名** | `lui.json` 既是模板目录标记，也是应用清单（`MarkerFile`） | 一个名字一套语义，`init` 的"是否 lui 工程"判定与运行时的"应用根"判定不会打架。代价：应用目录里不能有别的同名文件（本来就该如此） |
| **56 构建产物原子替换** | 先写 `<输出>.lui-tmp`，成功后再重命名；输出目录由打包函数自己创建；异常一律转成可读 `AErr` | 半成品不该留在 `dist/` 里被双击；打包失败要给"哪里失败了"而不是 `EFCreateError` 栈。代价：需要一个临时文件的生命周期管理 |
| **57 运行时可执行文件双名** | 构建同时产出 `bin/lui.exe`（规范名）与 `bin/lui-render.exe`（兼容别名），同一份二进制 | 命令面叫 `lui`，文件名也叫 `lui` 更顺；仓库脚本与既有工程仍按旧名引用，改名不会连带打断它们。代价：`bin/` 下多一份 29 MB 副本（仅构建产物，不入库） |

---

## 9. 与既有 ADR 的关系

| 旧 ADR | 处置 |
| --- | --- |
| 30（lui-render 定位为通用工具） | **取代**：运行时身份从"出图工具"升级为"应用运行时"，出图降为 `render` 子命令 |
| 31（CLI 规范收敛：`-h` 独占帮助等） | **保留**：所有旧选项语义不变，命令面是叠加而非替换 |
| 32（退出码分级 + `--json`） | **保留并扩展**：命令面沿用同一套退出码（0 成功 / 1 运行失败 / 2 参数错误 / 3 批量部分失败） |
| 34（单程序分发 = 构建期 Base64 内嵌 + 运行时解包，不做内存 VFS） | **收窄**：仍是 lui 自身分发方式与"内存 VFS 不做"的结论；但**应用打包改用 ADR 50 的追加式载荷**，因为它不需要编译器 |
| 41（渲染器兼作项目工具链入口） | **取代**：入口从"渲染器附带选项"改为"运行时命令面"，职责冲突消失 |
| 42（生成即自包含：模板同级 `ui/` 整树复制） | **保留并延续**：`ui/` 仍随应用走，并被 `lui build` 打进载荷 |
| 44（模板定位三态链） | **保留**：`init` 仍按 仓库 → exe 目录 → 内嵌根 三态查找；标记文件改为 `lui.json` |
| 47（控制台输出统一安全路径） | **保留**：所有新增命令输出仍走 `xui_console` |

保留的语义资产：ADR 2（flex 子集布局）、13（TS 子集方言）、19/21（响应式批量刷新）、
20（XML 直接解释）、22–29（组件协议 / 双向绑定 / 浮层 / CSS 变量 / 模板外置 / 表单校验）、
35（资源发现单一来源）、43（`init` 只写不改不删）、45（`.cmd` 纯 ASCII）、46（退出码即门禁）。

---

## 10. 实现清单

| 文件 | 变更 |
| --- | --- |
| `src/ui/xui_appspec.pas` | **新增**：`lui.json` 解析（自研扁平 JSON）、应用根定位、`PathOf`/`Entry`/`Pages`/`UiIndex`、`XuiAppRootOverride`、`XuiAppResourcePath` |
| `src/ui/xui_bundle.pas` | **新增**：容器读写（`Probe`/`List`/`Entries`/`Mount`/`MountSelf`/`Build`）、CRC32、48 字节尾部、原子替换、异常转可读错误 |
| `src/ui/xui_embed.pas` | 挂载实现抽出"资源来源"档（内存 / 文件载荷），新增 `XuiEmbedInstallFromFile`；`ReadAsset` 按档取字节 |
| `src/ui/xui_app.pas` | `FindRepoRoot` 加入应用根优先与清单自定义的 `ui` 目录名；`ConfigureStyles` 加载清单 `styles`（带去重） |
| `src/ui/xui_widget.pas` | `<svg src>` 解析改走 `XuiAppResourcePath`（应用根优先） |
| `src/ui/xui_scaffold.pas` | 标记文件改 `lui.json`；占位符 `@@RUNTIME@@`/`@@RUNTIME_POSIX@@`/`@@EXE_NAME@@`；结果里回填 `Name` |
| `tools/renderer/lui_render.lpr` | 命令面 `NormalizeArgv` + `HasExplicitInput`；`RunBuild`/`RunPackApp`/`CollectTree`/`BuildSelfContainedApp`/`ListBundleAssets`；自包含 exe 启动即装配应用根；预览窗接清单标题/可缩放/居中 |
| `scaffold/*` | `lui.json` 模板；`run-dev/run-test/run-build/run-pack.cmd` 改为命令面；README 重写 |
| `scripts/build.js` | 构建后产出 `bin/lui.exe` 别名 |
| `tests/runtests.lpr` | 新增 `TestAppSpec`、`TestBundle`；`TestScaffold` 跟随清单变更 |

---

## 11. 验收

| 验收项 | 方式 | 结果 |
| --- | --- | --- |
| 清单解析全部字段 | `TestAppSpec`（name/displayName/title/main/ui/window/styles/dev/build + 旧清单兼容 + 默认值 + 语法错误拒绝 + 应用根向上查找 + 资源解析） | 通过 |
| 容器字节保真 | `TestBundle`（二进制含 NUL/CRLF/高位字节逐字节还原、子目录结构、缺失文件跳过、指纹可复现、截断/篡改拒绝、拒绝覆盖自身、临时文件不残留、挂载幂等） | 通过 |
| 单元测试全量 | `tests/runtests.exe` | **788 通过 / 0 失败**（M11 时为 708） |
| 端到端：生成 → 自检 → 构建 | `lui init` → `lui check` → `lui build` | 通过，产物 63 文件 / 113 KB |
| 端到端：交付目录 | `lui pack` → `dist/`（exe + 双主题预览 + README） | 通过，预览图 420×580（取自清单） |
| **脱离工程目录运行** | 从 `%TEMP%` 运行 `dist/demo.exe --check` / `-o out.png` / `--list-bundle` | 通过（旧版必须 `cd pages`） |
| 渲染正确性 | 查看应用 exe 导出的浅色/深色 PNG | 组件库、样式、脚本绑定、主题全部正确 |
| 开发模式 | `lui dev .chk/app3` 起窗并保持（5s 超时kill） | 通过 |

---

## 12. 已知限制与后续

**限制**

1. 产物大小 = 运行时（约 29 MB）+ 载荷。运行时是固定成本（引擎 + LCL + GDI+ 后端），
   要进一步减小需要剥离调试信息或换更小的 RTL 配置。
2. 追加式载荷对代码签名不友好（签名后不能再改文件尾部）。当前不签名，若将来要签名，
   需要改成"签名前打包"或"载荷作为资源节"。
3. 运行 Windows-only 的 GDI+ 后端时，应用只在 Windows 可用（沿用 ADR 33 的取舍）。
4. 载荷默认不压缩；资源体量大的应用（大量图片）会线性放大产物。
5. `lui pack` 不产出 zip；需要 zip 的用系统工具打包 `dist/`。
6. 清单的 `build.assets` 只支持应用根下的文件（不支持目录整树强制包含，目录走
   `build.exclude` 的反向操作即可满足）。

**后续可做**

- `lui build --compress`：按块压载荷（自研 LZ77 或链接 FPC 自带 zstream），换来更小产物。
- `lui dev` 的改动推送：目前依赖引擎 `HotReload` 的 FileAge 轮询（250ms 节流），
  可换成目录监视 API 降低延迟。
- `lui build --target`：交叉构建（需先有其它平台的运行时 exe）。
- 应用图标与版本资源：给产物 exe 写入 icon/version（需要改 PE 资源节，与签名同一类问题）。
- 原生模块/插件接口：让"扩展引擎"不必改引擎自身（对应 §7 里剩下的那类 Pascal 依赖）。
