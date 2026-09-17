# lui M10 设计方案：对话式 AI Agent

> 状态：已实现（2026-09-13）。历史基线：M9（runtests 633 项全绿）+ 单程序分发。
> 当前回归基线：M11（runtests 881 项全绿）。
> R2/R3 滚动模型（overflow auto/scroll + 引擎滚动条 + 横向滚动）已于 2026-09-16 并入引擎。
> R7：CSS 尺寸约束与表现力（`max-width/max-height`、`flex-shrink`、`flex-wrap`、
> `letter-spacing`、`white-space`/`text-overflow:ellipsis`、`box-shadow`）也已并入引擎，
> 见下表与 `docs/设计方案.md` 的 CSS 子集说明；仍不支持 `transform`、`align-self`、
> 伪元素、column 方向的 flex wrap 与 `spread` 扩展。
> 本文给出 `demo/agent` 的定位、Agent 循环结构、工具协议、在线/离线双档与验证结果。

---

## 1. 背景与目标

用 lui 现有能力（XML + CSS 子集 + TS 子集脚本 + 响应式绑定 + 异步 I/O）实现一个
**对话式 AI Agent**：会话界面 + 工具调用（function calling）+ 可选的在线大模型接入。

**目标**
- 展示 lui 能承载的真实应用形态：多轮会话、流式观感、结构化工具步骤、异步链路
- 工具调用（Agent 的核心）在本地确定性执行，可测试、可截图，不依赖外网与密钥
- 在线档接入 OpenAI 兼容 `/chat/completions`，走完整 agent loop（tool_calls → 执行 → 回填 → 终答）
- 纯 lui 实现：不新增引擎能力（除两处必要的小修，见 §5）

**非目标**
- 不做通用编排框架 / 多 Agent 协作 / RAG 向量检索
- 不做真正的流式 token（引擎无 SSE；用打字机模拟流式观感）
- 不做会话持久化（内存态；`ui.storage` 可扩展，未纳入本里程碑）

---

## 2. 现状核查（实现前实测）

实现前对"lui 能否做 Agent"逐项实测，结论与关键证据：

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 异步 agent loop（await 链） | 可用 | `await ui.delay` + `async` 函数在脚本里正常工作 |
| 嵌套响应式写（`m.steps.push(...)` / `m.text = ...`） | 可用，UI 自动刷新 | 深层 reactive 标记 + 安全点批量刷新 |
| `x-for` / `x-if` / `x-show` / `:class` / `x-model` | 全部可用 | 会话列表、步骤卡、条件气泡均用它们表达 |
| TS 子集覆盖度 | 足够 | 60+ 构造逐一实测：闭包、递归、展开、可选链、try/catch、模板串、`Object.keys`、JSON 全通过；缺 `Array.sort` / `lastIndexOf`（未用到） |
| `ui.http.post(url, body, opts)` | **有缺陷**（见 §5） | 动词按 `secure` 而非请求种类选择；`opts.headers` 契约未实现 |
| `ui.http` 在页面脚本中的可见性 | **有缺陷**（见 §5） | IO 懒安装，页面装配不触发，`ui.http` 为 undefined |
| 时间戳 | 缺失 | `ui.now()` 是会话相对毫秒，无法表达"现在几点" |
| `Math.floor/ceil/round` | **有缺陷**（见 §5） | 经 32 位 `Math.Floor/Ceil`，|x| ≥ 2³¹ 静默截断 |
| 引擎 flex 布局 | 有限制 | column 主轴 `flex:1` 不可靠、无 `wrap`；改用固定高度与显式行列 |

---

## 3. 架构

### 3.1 双档共用一套工具与循环

```
用户输入
  │
  ├─ 离线档（默认）：PlanFor(text) → 规则规划器产出 [{tool, args}...]
  │                 → ExecutePlan 顺序执行工具（步骤卡逐个亮起）
  │                 → ComposeAnswer 依工具结果拼装回答 → Typewriter 逐字输出
  │
  └─ 在线档（可选）：BuildMessages + ToolSchema → POST /chat/completions
                    → 解析 tool_calls → 本地执行 → 以 role=tool 回填 → 再问
                    → 循环至模型给出终答（MAX_TURNS 上限）→ Typewriter 输出
                    （失败自动回落离线档并明确提示）
```

两个档位**共用同一套本地工具**（计算器 / 当前时间 / 知识检索），因此工具行为在任何档位下
一致，测试只需覆盖工具本身 + 循环结构。

### 3.2 工具协议（本地注册表）

```js
{ name, label, glyph, desc, params: {k: 'type'}, summary(args), run(args) → string }
```

- `name`：在线档的函数名（发给模型）
- `label/glyph/summary`：UI 步骤卡展示（工具名 + 实参摘要）
- `run`：本地执行，返回字符串结果（在线档以 `role=tool` 回填）
- 计算器是**自研递归下降求值器**（`+ - * / %`、括号、一元正负号），不用 `eval`／`new Function`
  （脚本引擎本就没有），避免注入面

### 3.3 会话数据模型（驱动 UI）

```js
messages: [{ id, role: 'user'|'assistant', text, steps: [{ id, name, label, glyph,
             detail, result, done, error }], pending, error }]
```

XML 侧只用声明式绑定表达：`x-for` 渲染消息、`x-if` 分左右气泡、内层 `x-for` 渲染步骤卡、
`x-text` 输出文本、`x-show` 控制空气泡隐藏、`:text` 显示"生成中…"。逻辑全在 `.ts`。

### 3.4 布局要点（踩坑记录）

- **不用 `flex:1` 撑满 column**：引擎 column 主轴 flex-grow 不可靠（子项会与底栏重叠）。
  会话区与输入区用**固定高度**，与 `todo`/`m7` 等页一致。
- **`x-for` 的克隆保留包裹容器**：`x-for` 元素本身是容器，克隆体在其内部。想横向排列，
  容器自身要 `display:flex`；或直接写死几行（快捷短语即写死两行两列，避开这个坑）。
- **快捷短语不依赖 `wrap`**：引擎 flex 无 wrap，故显式两行。

### 3.5 首屏渲染时机（重要）

问候语在**模块顶层**播种（`Greet()` 直接调用），而不是放进 `onMount`：`onMount` 要等首次
响应式刷新才执行，而 CLI 单次出图只走一遍"脚本求值 → 首轮绑定扫描 → 绘制"，等不到那次
刷新，首屏会是空的。顶层播种使 `messages` 在首轮扫描时就非空（同 `script.ts` 的 `Boot()`）。

---

## 4. 文件清单

| 文件 | 说明 |
| --- | --- |
| `demo/agent.xml` | 页面结构：顶栏 / 状态 / 设置面板 / 快捷短语 / 会话区 / 输入区 |
| `demo/agent.ts` | 全部逻辑：状态、工具、规划器、执行器、打字机、在线 loop |
| `demo/agent-light.css` / `agent-dark.css` | 两主题样式（**各自完整**：宿主只加载同主题那一份） |
| `demo/nav.xml` | 加"智能体"导航按钮 |
| `demo/demo1.lpr` | 注册 `agent` 页：参数、导航高亮列表、截图交互序列 |
| `tests/runtests.lpr` | 12 项 agent 用例 + 头契约 + `ui.time` 回归 |

---

## 5. 实现中发现并修复的引擎缺陷

实现 Agent 时暴露出四个**既有**缺陷（非本功能引入），已一并修复并加回归测试：

| 编号 | 缺陷 | 根因 | 影响 | 修复 |
| --- | --- | --- | --- | --- |
| **AG-1** | `Math.floor/ceil/round` 截断大数 | 直接调用 `Math` 单元的 `Floor/Ceil`，它们返回 **32 位** `Integer` | `Math.round(9801000000)` → `1211065408`（低 32 位），大数计算全错 | 新增 `JsFloor/JsCeil`（基于 `Trunc` 返回 Int64），语义对齐 JS（`floor(-2.5)=-3`、`round(-2.5)=-2`） |
| **AG-2** | HTTP 动词按 `secure` 选择 | `if secure then POST else GET`，与请求种类无关 | **https GET 发成 POST，http POST 发成 GET** | 动词由 `iokHttpPost` 决定，TLS 只决定端口与 `WINHTTP_FLAG_SECURE` |
| **AG-3** | `opts.headers` 契约未实现 | `OptHeaders` 把 `opts` 顶层属性当请求头 | 文档写的 `{headers:{...}}` 里 `Content-Type`/`Authorization` **根本没发出**，还把 `headers`/`timeout` 拼成垃圾头 | 优先取嵌套 `headers` 对象，并排除 `timeout`/`signal` 选项键 |
| **AG-4** | 页面脚本里 `ui.http` 为 undefined | `ui.http/fs/storage` 由 `TXuiScript.IO` **懒安装**；宿主与测试会取 `.IO`，页面装配不会 | 任何页面脚本用 `ui.http` 都报"无法读取 undefined 的属性" | DOM 桥装配时主动 `FScript.IO` 一次 |

**AG-1 / AG-2 / AG-3 都是"静默错误"**：不报错、结果错，最危险。三者都有回归用例锁定。

### 新增运行时能力
- **`ui.time()`**：返回墙钟本地时间字符串（`yyyy-mm-dd hh:nn:ss`）。`ui.now()` 是会话相对
  毫秒，表达不了"现在几点"；Agent 的时间工具需要真实时间戳。

---

## 6. 验证

**自动化（runtests，当前 881 项全绿 / 0 失败）**

agent 页 12 项：
- 整页装配无脚本错误；首屏问候已渲染
- 离线工具回路无错误；流程结束状态=完成；计算结果进入回答（12*(3+4)=84）；步骤卡展示工具名与参数
- 多意图规划命中两次调用（算式 + 时间）；大数乘法不走 32 位截断（99*99=9801）
- 无工具命中时给出兜底提示
- 在线档 agent loop 无错误；`tool_calls` 经本地执行回填后给出终答（注入 fake HTTP 执行器，确定性）

引擎缺陷回归：`ui.time` 返回墙钟串；`opts.headers` 嵌套对象作为请求头发送、选项键不混入。

**端到端（真实 HTTP，非 fake）**
以本地 mock 起一个 OpenAI 兼容 `/chat/completions`，Agent 在线档实测：
- 收到 2 次 POST，`Content-Type: application/json`、`Authorization: Bearer …` 正确发出
- 首轮响应 `tool_calls` 里 `calculator{"expr":"12*7"}` → 本地执行得 `12*7 = 84`
- 结果以 `role=tool` 回填 → 次轮返回终答 → 打字机输出，步骤卡展示工具与结果

**视觉（demo1 截图，浅/深两主题）**
`demo1 agent demo 520x860 shot`：点击快捷短语后走完整回路——用户气泡（右）、工具步骤卡
（含工具名/参数/结果）、助手回答，导航"智能体"高亮，顶栏状态更新。深浅两套配色均核对。
页面同时内嵌进 `npm run single` 的单程序 exe（19 页 / 233.6 KB），空目录可直接出图。

---

## 7. ADR（续 M9，编号 36 起）

| ADR | 决策 | 理由与代价 |
| --- | --- | --- |
| 36 | **Agent 离线档为一等公民**（默认、确定性、可测试/可截图），在线档为可选增强且失败自动回落 | CI 与截图不依赖外网与密钥；工具逻辑两档共用，测试只覆盖一次。代价：离线档是规则规划器，能力有限（明确的演示定位） |
| 37 | **工具一律本地执行**，模型只负责"决定调用什么" | 与 OpenAI function calling 语义一致；安全（模型不直接操作系统），且两档行为一致。代价：工具集需在客户端注册 |
| 38 | **不做内存里造 eval**：计算器自研递归下降求值器 | 脚本引擎无 `eval`；自研求值器可控、无注入面。代价：需自己实现运算符优先级与括号 |
| 39 | **流式输出用打字机模拟**，不接 SSE | 引擎无 SSE 客户端；打字机足以表达"逐字生成"观感且可测试。代价：非真流式（首字延迟=完整响应到达时间） |
| 40 | 布局规避 `flex:1` / `wrap`，用固定高度与显式行列 | 引擎 flex 子集限制已知（见 §3.4）；规避比扩引擎更划算。代价：不同窗口尺寸下不自适应（演示页固定尺寸可接受） |

---

## 8. 已知限制

- 离线规划器是关键词/正则规则，非语义理解；复杂自然语言会落到兜底提示。
- 在线档依赖外网与密钥；未实测真实 OpenAI 端点（用本地 mock 验证协议正确性）。
- 会话不持久化，刷新即清空。
- `ui.http` 无并发上限控制；Agent 场景串行调用，未暴露该问题。
