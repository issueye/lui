/* lui M7 演示：响应式绑定 + 组件化（TypeScript 子集，类型仅擦除）
   - 逻辑只改状态，UI 由 x-* 绑定在安全点自动刷新（ADR 19/21）
   - XML 的 onclick="OnInc" 先找宿主 published 方法（如 ThemeClick），找不到回退到这里的全局函数 */

const state = reactive({
  n: 0,
  name: 'lui',
  detail: true,
  rows: [
    { id: 1, title: '条目 #1（初始）' },
    { id: 2, title: '条目 #2（初始）' }
  ]
});

const double = computed(function () { return state.n * state.n; });

const rowSeq = reactive({ next: 3, watchHits: 0 });

watch(function () { return state.rows; },
  function (nv, ov) {
    rowSeq.watchHits = rowSeq.watchHits + 1;
    const log = document.find("watch-log");
    if (log !== null) {
      log.text = "watch：列表变化第 " + rowSeq.watchHits + " 次（共 " + nv.length + " 条）";
    }
  },
  { deep: true });

function OnInc(e): void {
  state.n = state.n + 1;
}

function OnDec(e): void {
  state.n = state.n - 1;
}

function OnReset(e): void {
  state.n = 0;
}

function OnToggle(e): void {
  state.detail = !state.detail;
}

/* ---- keyed v-for：新增 / 删除首条 / 反转（x-key 复用克隆，节点不重建）---- */

function OnAdd(e): void {
  rowSeq.next = rowSeq.next + 1;
  state.rows.push({ id: rowSeq.next, title: "条目 #" + rowSeq.next + "（脚本添加）" });
}

function OnDrop(e): void {
  if (state.rows.length > 0) {
    state.rows.shift();
  }
}

function OnReverse(e): void {
  state.rows.reverse();
}

/* ---- 组件：父级函数经 props 传入子组件模板内求值 ---- */

function LabelOf(n: number): string {
  return "函数 prop：父级算出「" + n + " 次点击，平方 " + (n * n) + "」";
}

component("user-card", {
  props: {
    count: { type: "number", default: 0 },
    onLabels: { type: "function" }
  },
  template: "<panel class=\"ucard\">" +
    "<slot name=\"head\"/>" +
    "<label class=\"text\" x-text=\"props.onLabels(props.count)\"/>" +
    "<slot/>" +
    "</panel>"
});

console.log("m7.ts 已加载");
