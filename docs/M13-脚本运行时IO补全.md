# M13 — 脚本运行时 I/O 补全（进程执行 + 文件系统 + 数组工具）

> 状态：已实施（2026-09-17）。基线：M12 完成（runtests 788 项全绿），本次后 807 项。
> ADR 58–61 新增，见 §5。

---

## 1. 为什么要补：一次真实的移植需求

M12 把 lui 变成"只写 XML/CSS/TS 的运行时"之后，第一个真实检验是把 `a_da`
（一个已实现的 AI Agent 桌面工具，Agent 逻辑原本是 ~3600 行 Pascal）改写成纯 TS 应用。
把它的能力逐条对着脚本运行时的 API 面核对，缺口很集中：

| Agent 需要做的事 | lui 原本提供 | 结论 |
| --- | --- | --- |
| 调模型 HTTP | `ui.http.get/post`（工作线程、超时、状态码/正文） | ✅ 够用 |
| 读文件 | `ui.fs.readText` | ✅ |
| 写文件 | `ui.fs.writeText`（整文件覆盖） | ⚠️ 能做替换写，但**做不到追加** |
| 落 JSONL telemetry | — | ❌ 只能读全文→拼接→覆盖写，日志一大就崩 |
| 目录遍历（find 工具） | — | ❌ 没有 listDir，TS 侧无从下手 |
| 建目录 / 判定存在 / 取大小 | — | ❌ stat/exists/mkdir 全无 |
| 原子替换写（edit 工具） | — | ❌ 没有 rename，先删再写会留下"文件已丢"的窗口 |
| **跑命令（bash 工具）** | — | ❌ **完全没有进程执行能力** |
| 挑元素 / 排序（工具、会话、设置） | `map/filter/reduce/forEach/indexOf/includes/push/pop/shift/unshift/splice/slice/join/reverse/concat` | ⚠️ 缺 `find/findIndex/some/every/sort`，只能手写循环 |

也就是说：**HTTP 和基础读写已够，但"跑命令"和"目录/追加/替换写"两块硬缺口让 bash、find、
edit 三个工具根本落不了地**。M13 就是把它们补上，补完再继续移植（ADR 58 的由来）。

---

## 2. 新增能力

### 2.1 `ui.exec.run(cmd, opts?)` — 进程执行

```ts
const r = await ui.exec.run('npm run build', { cwd: 'workspace', timeout: 60000, maxBytes: 65536 });
// r = { ok, exitCode, stdout, stderr, timedOut, truncated, durationMs }
```

| 项 | 语义 |
| --- | --- |
| 命令文本 | 交给系统 shell 解释：Windows `cmd.exe /c`，POSIX `/bin/sh -c`。**引擎不做命令行词法解析**（引号/管道/重定向是 shell 的事） |
| `cwd` | 工作目录；相对路径锚定应用根（§2.3） |
| `timeout` | 毫秒，默认 30000；超时**终止进程**并置 `timedOut=true`、`exitCode=-1` |
| `maxBytes` | stdout / stderr **各自**的上限（默认 64 KiB）；超限继续读掉丢弃并置 `truncated=true` |
| `exitCode` | 真实退出码。**非 0 不算 Promise 失败**——命令跑了就是成功，判定交给调用方 |
| reject 的时机 | 只有"根本跑不起来"（命令为空、进程创建失败）才 reject，错误文本以 `Error: ...` 开头 |

两个实现要点（都是踩过才知道的）：

1. **必须边跑边排空两个管道**。stdout/stderr 各自有缓冲，等进程结束再读会死锁——子进程写满
   管道就永远不退出。循环里同时读两个流，退出后再做一次最终排空。
2. **超时要真的终止**。否则一个卡住的命令会连带锁死整个 Agent 会话（用户看到的"取消"按不动）。
   Windows 上 `Terminate` 只终止直接子进程，孙进程可能存活——这一点与 a_da 的既有实现一致，
   列入已知限制（彻底终止需要 Job Object）。

### 2.2 `ui.fs` 由 2 个方法扩到 9 个

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `readText(path)` | `Promise<string>` | 原有。整文件，原始字节按字符串往返 |
| `writeText(path, text)` | `Promise<void>` | 原有。整文件覆盖/新建 |
| `appendText(path, text)` | `Promise<void>` | **新**。追加到末尾（不存在则创建）——JSONL 落地就靠它 |
| `exists(path)` | `Promise<boolean>` | **新** |
| `stat(path)` | `Promise<{exists,isDir,size,mtimeMs}>` | **新**。路径不存在时 `exists:false`，不 reject |
| `listDir(path)` | `Promise<[{name,isDir,size}]>` | **新**。非递归，名称已排序；递归由调用方自己控制（排除规则属于应用策略） |
| `mkdir(path)` | `Promise<void>` | **新**。多级创建 |
| `remove(path)` | `Promise<boolean>` | **新**。文件或**空**目录；路径本来就不存在返回 `false`（不抛错） |
| `rename(from, to)` | `Promise<void>` | **新**。目标已存在则覆盖——替换写的正确姿势：先写 `.tmp` 再 rename |

设计取舍：

- **为什么 `listDir` 不递归**：递归时要排除哪些目录（`.git`/`node_modules`/`dist`…）是应用
  策略，写进引擎就变成了不可改的约定。引擎给一层，遍历与排除留给应用（`find` 工具就是这么做的）。
- **为什么 `remove` 不提供递归删除**：递归删除是不可逆操作，误用代价高。需要清空一棵树时，
  应用自己从叶子往上删（多几行代码，换一个不可能误伤 API）。
- **`rename` 覆盖目标**是刻意的：Windows 的 `RenameFile` 不覆盖已存在目标，直接用它做替换写
  会失败。实现里先删目标再改名，语义与 POSIX 的 `rename(2)` 对齐。

### 2.3 相对路径锚定应用根（行为变更）

`ui.fs` / `ui.exec.cwd` 的相对路径**在应用根已知时锚定应用根**（`XuiAppRootOverride`，
即 M12 的 ADR 49 基准），否则退回进程当前目录（旧行为）。

为什么写操作也要锚定：读可以"找不到就回退"，**写没有回退的余地**——必须给出确定的落点。
脚本里写 `ui.fs.appendText('logs/events.jsonl', ...)` 时，意图显然是"应用目录下的 logs"，
而不是"碰巧是当前工作目录的某个 logs"。这与 `<svg src>` 那类资源解析用的是同一个基准。

### 2.4 Array 补齐 5 个方法

`find` / `findIndex` / `some` / `every` / `sort`（原地排序，可带比较函数；无比较函数时按
字符串比较，与 JS 一致）。语义细节与 JS 对齐：空数组 `some=false`、`every=true`、
`find=undefined`、`findIndex=-1`；`sort` 用插入排序实现，**稳定**。

---

## 3. 实现落点

| 文件 | 变更 |
| --- | --- |
| `src/script/xui_script_io.pas` | `TXuiIoKind` 新增 8 个种类（7 个 fs 操作 + `iokExec`）；`TXuiIoRequest` 增 `Path2/Cmd/Cwd/MaxBytes`；`TXuiIoResult` 增 `ExitCode/StdOut/StdErr/TimedOut/Truncated/DurationMs/Flag/Value/MTime/IsDir/Items`（并加构造/析构管理 `Items`）；新增 `FsExecute` 与 `ExecExecute`（含管道排空循环）；`NativeFs` 按名分派 9 个方法；新增 `NativeExec` 与 `MakeExecResult/MakeStatResult/MakeListResult`；`Install` 注册新 API |
| `src/script/xui_js_runtime.pas` | `FArrayProto` 注册并实现 `find/findIndex/some/every/sort` |
| `src/ui/xui_appspec.pas` | 新增 `XuiAppPathResolve`（写操作用的确定解析，区别于 `XuiAppResourcePath` 的"找不到就回退"） |

**分层没有被破坏**：新增的 fs/exec 都走既有的 I/O 工作线程 + 完成队列 + Promise 管线，
仍然满足 ADR 14/18 的铁律——工作线程只做系统调用，跨线程只传原始数据，JS 值只在主线程
（`PumpCompletions`）构造与 settle。引擎 UI 线程在跑命令期间不会卡（这是必须的：Agent 跑
`npm install` 时界面还要能点"取消"）。

---

## 4. 验收

`tests/runtests.lpr` 新增 `TestIoFsAndExec`（19 项，含"失败时打印实际输出"的诊断助手）：

| 覆盖 | 用例 |
| --- | --- |
| 追加写 | `writeText` + `appendText` 三次后内容为 `l1\nl2\nl3`（JSONL 可落地） |
| exists/stat | 存在与不存在的路径分别 true/false；`size` 与真实字节数一致；`mtimeMs > 0` |
| mkdir + listDir | 多级创建；列表含名称/是否目录且已排序；子目录可再遍历；不存在的目录 reject |
| rename | 覆盖已存在目标后内容为新值、源文件消失（替换写成立） |
| remove | 删存在文件返回 true、再删返回 false、`exists` 变 false |
| 应用根锚定 | 相对路径落在应用根下（磁盘上可见），不是当前工作目录 |
| exec 基本 | `echo` → `exitCode=0`、stdout 命中、未超时未截断；`exit /b 3` → `ok=true, exitCode=3` |
| exec 流分离 | `echo ... 1>&2` → 落在 stderr，stdout 为空 |
| exec 超时 | `ping -n 6` + `timeout:250` → `timedOut=true, exitCode=-1` |
| exec 上限 | 400 行输出 + `maxBytes:64` → `truncated=true` 且 stdout ≤ 64 字节 |
| exec cwd | 指定工作目录后正常执行 |
| exec 空命令 | Promise reject（不是引擎级异常，调用方能 catch） |
| Array | find/findIndex/some/every/sort，含比较函数、默认字符串排序、空数组语义 |

结果：**807 通过 / 0 失败**。

---

## 5. ADR 58–61

| ADR | 决策 | 理由与代价 |
| --- | --- | --- |
| **58 引擎提供 `ui.exec.run`，不做命令白名单** | 进程执行作为引擎能力暴露（与 Electron 的 `child_process` 同性质）；"哪些命令允许跑"由应用的策略与审批决定 | 引擎无法知道每个应用的业务边界，白名单只会给人虚假安全感（真实门禁是审批 + cwd 沙箱 + 超时）；代价：能力本身很强，应用侧策略写错就是安全缺口——所以 a_da 那类应用必须保留自己的 Policy 与审批 |
| **59 exec 的失败语义分离** | "跑不起来"（空命令/创建进程失败）→ reject；"跑起来了但结果不好"（非 0 退出码、超时、截断）→ 正常 resolve，用字段回报 | 前者是编程错误，后者是命令的正常结果。若把非 0 退出码也当 reject，调用方就得在 catch 里区分两类失败，反而容易掩盖真问题。代价：调用方必须显式检查 `exitCode/timedOut` |
| **60 fs 操作的粒度交给应用** | 只提供一层 `listDir` 与非递归 `remove`；递归遍历、排除规则、递归删除都留给应用 | 排除规则（`.git`/`node_modules`）与"删一棵树"的授权都属于应用策略；引擎硬编码会变成不可改的约定（且递归删除误用不可逆）。代价：应用侧多写十几行 |
| **61 写操作路径必须确定** | 新增 `XuiAppPathResolve`：有应用根就锚定，没有就按进程当前目录；与 `XuiAppResourcePath` 的"找不到回退"分开 | 读可以回退，写不能：必须给出确定落点。两个函数分开命名，是为了让"这里会不会回退"在调用处一眼可见。代价：两个相近的解析函数需要靠文档区分（已在单元头注释里写明） |

---

## 6. 已知限制

1. **进程树终止**：Windows 上 `Terminate` 只终止直接子进程，孙进程（如 `cmd` 启动的 exe）可能
   存活。彻底终止需要 Job Object，列入后续增强。与 a_da 既有实现的限制一致。
2. **输出只有上限截断，没有流式**：一次拿到最终结果；交互式命令（需要 stdin、长驻输出）不适合
   （没有 stdin 写入、没有增量回调）。
3. **编码**：进程输出按原始字节回传。Windows 控制台的 OEM 码页输出（中文乱码）与 a_da 原实现
   面对的是同一个问题，未在引擎层解决（可后续加 `encoding` 选项）。
4. **文件名列表不含时间戳**：`listDir` 只给名称/类型/大小，避免每个目录项都做一次 stat；
   需要 mtime 时对单项调 `ui.fs.stat`。
5. **HTTP 仍无 SSE/流式**（M6 的既有边界），所以"模型流式输出"只能靠打字机模拟（M10 ADR 40）。
