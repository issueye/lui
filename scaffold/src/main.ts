/* @@PROJECT_NAME@@ — 页面逻辑（lui 的 TypeScript 子集：类型仅擦除，无模块系统，全局即命名空间）

   规则只有一条：**只改状态，界面由 x-* 绑定在安全点自动刷新**。
   XML 里 onclick="MethodName"（不带 x- 前缀）才会去找宿主 published 方法；
   x-onclick="表达式" 一律在本脚本作用域求值。 */

const state = reactive({
  draft: "",
  hideDone: false,
  seq: 3,
  items: [
    { id: 1, title: "把 src/main.xml 改成自己的结构", done: false },
    { id: 2, title: "在 src/main.ts 里加逻辑（只改状态）", done: true },
    { id: 3, title: "npm run test 通过后再交付", done: false }
  ]
});

/* 派生状态用 computed：依赖的状态一变就重算，不用手写同步代码 */
const visible = computed(function () {
  if (!state.hideDone) {
    return state.items;
  }
  return state.items.filter(function (it) {
    return !it.done;
  });
});

const percent = computed(function () {
  if (state.items.length === 0) {
    return 0;
  }
  let n = 0;
  for (let i = 0; i < state.items.length; i = i + 1) {
    if (state.items[i].done) {
      n = n + 1;
    }
  }
  return Math.round(n * 100 / state.items.length);
});

const summary = computed(function () {
  return "共 " + state.items.length + " 条，已完成 " + percent.value + "%";
});

function FindItem(id) {
  for (let i = 0; i < state.items.length; i = i + 1) {
    if (state.items[i].id === id) {
      return i;
    }
  }
  return -1;
}

function OnAdd() {
  const title = state.draft.trim();
  if (title.length === 0) {
    return;   // 空输入不新增
  }
  state.seq = state.seq + 1;
  state.items.push({ id: state.seq, title: title, done: false });
  state.draft = "";
}

/* 行内事件：x-for 里的表达式天然带上迭代作用域，所以能直接拿到 it.id */
function Toggle(id) {
  const i = FindItem(id);
  if (i >= 0) {
    state.items[i].done = !state.items[i].done;
  }
}

function Remove(id) {
  const i = FindItem(id);
  if (i >= 0) {
    state.items.splice(i, 1);
  }
}

function OnToggleFilter() {
  state.hideDone = !state.hideDone;
}

function OnClearDone() {
  // 倒序删除：正向删会让后续下标错位
  for (let i = state.items.length - 1; i >= 0; i = i - 1) {
    if (state.items[i].done) {
      state.items.splice(i, 1);
    }
  }
}

function OnReset() {
  state.items.splice(0, state.items.length);
  state.seq = 0;
  state.draft = "";
}

onMount(function () {
  console.log("@@PROJECT_NAME@@ 就绪（lui " + ui.version + "）");
});
