/* lui 对话式 AI Agent 演示：工具调用 + 本地规划器 + 可选在线 LLM
   ------------------------------------------------------------------
   逻辑只改 state，UI 由 x-* 绑定自动刷新（ADR 19/21）。两种运行档位共用同一套
   工具与循环结构：

   - 离线档（默认，纯本地、确定性、可测试/可截图）：内置规则规划器解析意图 →
     顺序调用工具 → 据工具结果拼装回答。无需网络与密钥，CI 与 demo 截图走这一档。
   - 在线档（可选）：OpenAI 兼容 /chat/completions。把工具声明发给模型，
     解析返回的 tool_calls → 本地执行 → 以 role=tool 回填 → 循环至模型给出终答
     （真正的 agent loop）。未配置端点或请求失败时自动回落离线档并明确提示。

   工具一律在本地执行（计算器为自研表达式求值器，非 eval），故两种档位下工具行为一致。 */

/* ---------- 响应式状态 ---------- */

const state = reactive({
  messages: [],          // { id, role, text, steps[], pending, error }
  draft: "",             // 输入框（x-model 双向）
  busy: false,           // 生成中：禁用发送、显示“思考中”
  online: false,         // 是否启用在线 LLM
  status: "就绪",        // 顶部状态文案
  seq: 0,                // 消息自增 id
  cfg: {
    show: false,         // 设置面板展开
    baseUrl: "https://api.openai.com/v1",
    model: "gpt-4o-mini",
    apiKey: ""
  }
});

/* ---------- 工具（本地执行，两档共用） ---------- */

/* 安全表达式求值：递归下降，支持 + - * / % 与括号、一元正负号。
   不引入 eval/new Function（脚本引擎也没有），避免注入面。 */
function EvalExpr(input: string): number {
  const s = String(input);
  let i = 0;

  function skip(): void {
    while (i < s.length && (s.charAt(i) === " " || s.charAt(i) === "\t")) { i = i + 1; }
  }
  function parseNumber(): number {
    skip();
    const start = i;
    while (i < s.length && "0123456789.".indexOf(s.charAt(i)) >= 0) { i = i + 1; }
    if (i === start) { throw "表达式里缺少数字"; }
    return parseFloat(s.substring(start, i));
  }
  function parseFactor(): number {
    skip();
    if (s.charAt(i) === "(") {
      i = i + 1;
      const v = parseExpr();
      skip();
      if (s.charAt(i) === ")") { i = i + 1; } else { throw "括号不匹配"; }
      return v;
    }
    if (s.charAt(i) === "-") { i = i + 1; return -parseFactor(); }
    if (s.charAt(i) === "+") { i = i + 1; return parseFactor(); }
    return parseNumber();
  }
  function parseTerm(): number {
    let v = parseFactor();
    skip();
    while (i < s.length && "*/%".indexOf(s.charAt(i)) >= 0) {
      const op = s.charAt(i);
      i = i + 1;
      const r = parseFactor();
      if (op === "*") { v = v * r; }
      else if (op === "/") { v = v / r; }
      else { v = v % r; }
      skip();
    }
    return v;
  }
  function parseExpr(): number {
    let v = parseTerm();
    skip();
    while (i < s.length && "+-".indexOf(s.charAt(i)) >= 0) {
      const op = s.charAt(i);
      i = i + 1;
      const r = parseTerm();
      if (op === "+") { v = v + r; }
      else { v = v - r; }
      skip();
    }
    return v;
  }

  const value = parseExpr();
  skip();
  if (i < s.length) { throw "无法解析的字符：" + s.substring(i); }
  return value;
}

function FormatNumber(n: number): string {
  return String(Math.round(n * 1e6) / 1e6);      // 收掉浮点尾差
}

/* 本地知识库：lui 的能力条目，供检索工具使用（关键词命中计分取最高） */
const KB = [
  { keys: ["能力", "特性", "功能", "能做什么", "介绍", "是什么"],
    title: "lui 的定位",
    body: "lui 是零第三方依赖的声明式 Free Pascal UI 引擎：XML 声明结构、CSS 子集样式、TS 子集脚本驱动逻辑。" },
  { keys: ["组件", "组件库", "ui-", "按钮", "表格", "弹窗", "对话框"],
    title: "组件库",
    body: "ui/ 提供 60+ 组件（按钮 / 输入 / 表单校验 / 表格 / 对话框 / 抽屉 / 标签 / 分页 / 步骤条等），用 <ui-*> 标签即用。" },
  { keys: ["响应式", "绑定", "x-model", "x-for", "x-if", "状态", "reactive"],
    title: "响应式绑定",
    body: "参照 Vue 3：reactive / computed / watch / onMount，XML 侧 x-text / x-if / x-for / x-model / :class，改状态即刷新 UI。" },
  { keys: ["脚本", "ts", "typescript", "async", "await", "异步", "promise"],
    title: "脚本引擎",
    body: "自研 TS 子集解释器，支持 async/await、Promise、定时器与真实 I/O（ui.http / ui.fs / ui.storage）。" },
  { keys: ["渲染", "出图", "png", "cli", "打包", "单程序", "lui-render"],
    title: "lui-render 渲染器",
    body: "独立渲染器可把页面导出 PNG（CLI/GUI、批量、双主题、--json），并支持把资源内嵌为单程序 exe。" },
  { keys: ["热重载", "重载", "reload"],
    title: "热重载",
    body: "记录 XML/CSS/include/script 依赖的修改时间，改动后自动重载；仅样式变化时就地重解析、保留运行时状态。" }
];

function ToolCalc(args): string {
  const expr = String(args.expr);
  return expr + " = " + FormatNumber(EvalExpr(expr));
}

function ToolTime(args): string {
  return ui.time();
}

function ToolSearch(args): string {
  const q = String(args.query);
  let best = null;
  let bestScore = 0;
  for (let i = 0; i < KB.length; i = i + 1) {
    let score = 0;
    for (let k = 0; k < KB[i].keys.length; k = k + 1) {
      if (q.indexOf(KB[i].keys[k]) >= 0) { score = score + 1; }
    }
    if (score > bestScore) { bestScore = score; best = KB[i]; }
  }
  if (best === null) { return "未在知识库中找到与「" + q + "」相关的内容"; }
  return "【" + best.title + "】" + best.body;
}

/* 工具注册表：name 供在线档的函数名，label/glyph/summary 供 UI 展示 */
const TOOLS = [
  {
    name: "calculator", label: "计算器", glyph: "=",
    desc: "计算数学表达式（支持 + - * / % 与括号）",
    params: { expr: "string" },
    summary: function (a) { return String(a.expr); },
    run: ToolCalc
  },
  {
    name: "current_time", label: "当前时间", glyph: "◷",
    desc: "获取本地当前日期与时间",
    params: {},
    summary: function (a) { return "本地时钟"; },
    run: ToolTime
  },
  {
    name: "knowledge_search", label: "知识检索", glyph: "⌕",
    desc: "在 lui 知识库中检索能力说明",
    params: { query: "string" },
    summary: function (a) { return String(a.query); },
    run: ToolSearch
  }
];

function FindTool(name: string) {
  for (let i = 0; i < TOOLS.length; i = i + 1) {
    if (TOOLS[i].name === name) { return TOOLS[i]; }
  }
  return null;
}

/* ---------- 本地规则规划器（离线档的“大脑”） ---------- */

function ContainsAny(text: string, words): boolean {
  for (let i = 0; i < words.length; i = i + 1) {
    if (text.indexOf(words[i]) >= 0) { return true; }
  }
  return false;
}

/* 从文本里抽出最长的候选算式片段（连续的数字 / 运算符 / 括号 / 空格） */
function ExtractExpr(text: string): string {
  let best = "";
  let cur = "";
  for (let i = 0; i < text.length; i = i + 1) {
    const c = text.charAt(i);
    if ("0123456789+-*/%(). ".indexOf(c) >= 0) {
      cur = cur + c;
    } else {
      if (cur.length > best.length) { best = cur; }
      cur = "";
    }
  }
  if (cur.length > best.length) { best = cur; }
  return best.trim();
}

function LooksLikeMath(text: string): boolean {
  let hasDigit = false;
  let hasOp = false;
  for (let i = 0; i < text.length; i = i + 1) {
    const c = text.charAt(i);
    if ("0123456789".indexOf(c) >= 0) { hasDigit = true; }
    if ("+-*/%".indexOf(c) >= 0) { hasOp = true; }
  }
  return hasDigit && hasOp;
}

/* 规划：按意图顺序产出工具调用（支持一条消息里多个意图） */
function PlanFor(text: string) {
  const out = [];
  const low = text.toLowerCase();

  const wantsTime = ContainsAny(low, ["几点", "时间", "日期", "现在", "clock", "time"]);
  const wantsKb = ContainsAny(low, ["lui", "组件", "能力", "特性", "功能", "响应式", "脚本",
    "渲染", "打包", "热重载", "介绍", "是什么"]);
  const expr = ExtractExpr(text);
  let wantsCalc = LooksLikeMath(expr) && expr.length >= 3;
  // 纯时间问句里可能带数字（如“3 点了”）→ 无运算符时不当作算式
  if (wantsTime && !ContainsAny(text, ["+", "*", "/", "%", "(", "*"])) { wantsCalc = false; }

  if (wantsCalc) { out.push({ tool: "calculator", args: { expr: expr } }); }
  if (wantsTime) { out.push({ tool: "current_time", args: {} }); }
  if (wantsKb) { out.push({ tool: "knowledge_search", args: { query: low } }); }
  return out;
}

/* 据工具结果拼装离线回答 */
function ComposeAnswer(text: string, results): string {
  if (results.length === 0) {
    return "我是本地离线智能体，可以调用工具帮你做事。试试：「计算 (12+8)*3」「现在几点」「lui 有哪些能力」。";
  }
  const parts = [];
  for (let i = 0; i < results.length; i = i + 1) {
    const r = results[i];
    if (r.tool === "calculator") { parts.push("计算结果：" + r.result); }
    else if (r.tool === "current_time") { parts.push("当前时间：" + r.result); }
    else if (r.tool === "knowledge_search") { parts.push(r.result); }
    else { parts.push(r.result); }
  }
  return parts.join("\n");
}

/* ---------- 消息与步骤（UI 数据） ---------- */

function AddMessage(role: string, text: string) {
  state.seq = state.seq + 1;
  const m = { id: state.seq, role: role, text: text, steps: [], pending: false, error: false };
  state.messages.push(m);
  return m;
}

function AddStep(msg, tool, args) {
  const t = FindTool(tool);
  const s = {
    id: msg.steps.length + 1,
    name: tool,
    label: t === null ? tool : t.label,
    glyph: t === null ? "•" : t.glyph,
    detail: t === null ? JSON.stringify(args) : t.summary(args),
    result: "",
    done: false,
    error: false
  };
  msg.steps.push(s);
  return s;
}

function ScrollToBottom(): void {
  const box = document.find("agent-scroll");
  if (box !== null) { box.scrollTop = 1e9; }   // 引擎按内容高夹取
}

/* 打字机：逐字追加，营造流式输出观感。用 await ui.delay 循环而非 setInterval，
   便于取消与串行——每次 Tick 推进一步（定时器由引擎 Tick 泵驱动）。 */
async function Typewriter(msg, full: string): void {
  msg.text = "";
  msg.pending = true;
  const step = Math.max(1, Math.round(full.length / 60));   // 长文按比例加速
  let shown = 0;
  while (shown < full.length) {
    await ui.delay(16);
    shown = Math.min(full.length, shown + step);
    msg.text = full.substring(0, shown);
    ScrollToBottom();
  }
  msg.pending = false;
  ScrollToBottom();
}

/* 顺序执行规划出的工具调用，逐步把结果写进该消息的步骤卡 */
async function ExecutePlan(msg, plan): void {
  const results = [];
  for (let i = 0; i < plan.length; i = i + 1) {
    const call = plan[i];
    const step = AddStep(msg, call.tool, call.args);
    const t = FindTool(call.tool);
    await ui.delay(220);                    // 模拟执行耗时，让步骤卡肉眼可见
    if (t === null) {
      step.result = "未知工具";
      step.error = true;
      step.done = true;
      results.push({ tool: call.tool, result: "未知工具" });
      continue;
    }
    try {
      const out = t.run(call.args);
      step.result = out;
      step.done = true;
      results.push({ tool: call.tool, result: out });
    } catch (e) {
      step.result = "执行失败：" + e;
      step.error = true;
      step.done = true;
      results.push({ tool: call.tool, result: "执行失败：" + e });
    }
    ScrollToBottom();
  }
  return results;
}

/* ---------- 在线档：OpenAI 兼容 agent loop ---------- */

function BuildMessages() {
  const out = [];
  for (let i = 0; i < state.messages.length; i = i + 1) {
    const m = state.messages[i];
    if (m.role === "user") { out.push({ role: "user", content: m.text }); }
    else if (m.role === "assistant" && m.text !== "") {
      out.push({ role: "assistant", content: m.text });
    }
  }
  return out;
}

function ToolSchema() {
  const arr = [];
  for (let i = 0; i < TOOLS.length; i = i + 1) {
    const t = TOOLS[i];
    const props = {};
    const keys = Object.keys(t.params);
    for (let k = 0; k < keys.length; k = k + 1) {
      props[keys[k]] = { type: t.params[keys[k]] };
    }
    arr.push({
      type: "function",
      function: {
        name: t.name,
        description: t.desc,
        parameters: { type: "object", properties: props }
      }
    });
  }
  return arr;
}

async function CallLlm(msgs): void {
  const body = JSON.stringify({
    model: state.cfg.model,
    messages: msgs,
    tools: ToolSchema(),
    tool_choice: "auto"
  });
  const resp = await ui.http.post(state.cfg.baseUrl + "/chat/completions", body, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + state.cfg.apiKey
    },
    timeout: 30000
  });
  if (resp.status < 200 || resp.status >= 300) { throw "HTTP " + resp.status; }
  const data = JSON.parse(resp.data);
  if (data.choices === undefined || data.choices === null || data.choices.length === 0) {
    throw "响应缺少 choices";
  }
  return data.choices[0].message;
}

/* 在线 agent loop：模型 → tool_calls → 本地执行 → 回填 → 再问，直到终答 */
async function RunOnline(msg): void {
  const msgs = BuildMessages();
  const MAX_TURNS = 4;
  for (let turn = 0; turn < MAX_TURNS; turn = turn + 1) {
    const reply = await CallLlm(msgs);
    const calls = reply.tool_calls;
    if (calls !== undefined && calls !== null && calls.length > 0) {
      msgs.push({
        role: "assistant",
        content: reply.content === undefined || reply.content === null ? "" : reply.content,
        tool_calls: calls
      });
      for (let i = 0; i < calls.length; i = i + 1) {
        const fn = calls[i].function;
        let args = {};
        try { args = JSON.parse(fn.arguments); } catch (e) { args = {}; }
        const step = AddStep(msg, fn.name, args);
        const t = FindTool(fn.name);
        let out = "";
        if (t === null) { out = "未知工具：" + fn.name; step.error = true; }
        else {
          try { out = t.run(args); } catch (e) { out = "执行失败：" + e; step.error = true; }
        }
        step.result = out;
        step.done = true;
        msgs.push({ role: "tool", tool_call_id: calls[i].id, content: String(out) });
        ScrollToBottom();
      }
      continue;
    }
    const content = reply.content === undefined || reply.content === null ? "" : String(reply.content);
    if (content === "") { throw "模型没有返回内容"; }
    await Typewriter(msg, content);
    return;
  }
  throw "超过最大工具轮次";
}

/* ---------- 入口：发送 ---------- */

async function Send(): void {
  const text = String(state.draft).trim();
  if (text === "" || state.busy) { return; }
  state.draft = "";                       // 清空输入（x-model 同步回输入框）
  AddMessage("user", text);
  const msg = AddMessage("assistant", "");
  msg.pending = true;
  state.busy = true;
  ScrollToBottom();

  if (state.online) {
    state.status = "在线：调用 " + state.cfg.model + "…";
    try {
      await RunOnline(msg);
      state.status = "在线生成完成";
      state.busy = false;
      return;
    } catch (e) {
      msg.error = true;
      state.status = "在线失败，已回落本地";
      const plan = PlanFor(text);
      const results = await ExecutePlan(msg, plan);
      await Typewriter(msg, "在线调用失败（" + e + "），已回落本地模式。\n\n" +
        ComposeAnswer(text, results));
      state.busy = false;
      return;
    }
  }

  state.status = "本地规划中…";
  const plan = PlanFor(text);
  const results = await ExecutePlan(msg, plan);
  state.status = "本地生成完成";
  await Typewriter(msg, ComposeAnswer(text, results));
  state.busy = false;
}

/* ---------- 交互 ---------- */

function UsePrompt(text: string): void {
  if (state.busy) { return; }
  state.draft = text;
  Send();
}

function ClearChat(): void {
  state.messages = [];
  state.seq = 0;
  state.status = "已清空会话";
  Greet();
}

function ToggleOnline(): void {
  state.online = !state.online;
  state.status = state.online ? "已切换到在线模式（需配置端点与密钥）" : "已切换到本地模式";
}

function ToggleConfig(): void {
  state.cfg.show = !state.cfg.show;
}

function Greet(): void {
  state.seq = state.seq + 1;
  state.messages.push({
    id: state.seq, role: "assistant", pending: false, error: false,
    text: "你好，我是 lui Agent，可调用计算器、本地时钟与知识检索三个工具。\n" +
      "试着问我：「计算 (12+8)*3」「现在几点」「lui 有哪些能力」。",
    steps: []
  });
}

/* 首屏问候在**模块顶层**播种（而非 onMount）：onMount 回调要等首次响应式刷新才执行，
   而 CLI 单次出图（lui-render）只走一遍"脚本求值 → 绑定首轮扫描 → 绘制"，等不到那次刷新。
   顶层调用使 messages 在首轮绑定扫描时就非空，首次绘制即有内容（同 script.ts 的 Boot()）。 */
Greet();

onMount(function () {
  console.log("agent.ts 就绪：工具 " + TOOLS.length + " 个");
});
