/* M8-1 组件库演示页：逻辑只改状态，UI 由组件与声明式绑定更新 */

const state = reactive({
  clicks: 0,
  last: "—",
  name: "lui",
  pwd: "",
  locked: false
});

function OnTap(): void {
  state.clicks = state.clicks + 1;
  state.last = "组件事件";
}

function OnLock(): void {
  state.locked = !state.locked;
  state.last = "禁用=" + state.locked;
}

onMount(function () {
  console.log("ui 演示页就绪（" + ui.version + "）");
});
