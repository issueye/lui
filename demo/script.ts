/* lui M6 P0 演示：脚本侧逻辑（TypeScript 子集，类型仅擦除）
   - XML 的 onclick="OnAdd" 先找宿主 published 方法，找不到则回退到这里的全局函数
   - document.find / node.text / node.class / node.add 等经 DOM 桥路由到引擎 API */

const seen: number = 0;
let count: number = 1;

function OnAdd(e): void {
  const list = document.find("list");
  if (list === null) {
    return;
  }
  count = count + 1;
  list.add('<panel class="item"><label class="text" text="条目 #' + count + '（脚本添加）"/></panel>');
  UpdateCounter();
}

function OnClear(e): void {
  const list = document.find("list");
  if (list === null) {
    return;
  }
  list.clear();
  count = 0;
  UpdateCounter();
}

function UpdateCounter(): void {
  const c = document.find("counter");
  if (c !== null) {
    c.text = "共 " + count + " 条";
  }
}

function Boot(): void {
  UpdateCounter();
  console.log("script.ts 已加载，条目数=" + count);
}

Boot();

/* ---- P5 异步示例：await ui.delay 序列 + 网络请求（含错误捕获）---- */

async function RunSeq(): void {
  const st = document.find("async-status");
  if (st === null) {
    return;
  }
  st.text = "异步：步骤 1/3";
  await ui.delay(400);
  st.text = "异步：步骤 2/3";
  await ui.delay(400);
  st.text = "异步：步骤 3/3";
  await ui.delay(400);
  st.text = "异步：序列完成 ✓";
}

function OnSeq(e): void {
  RunSeq();
}

function OnFetch(e): void {
  const st = document.find("async-status");
  if (st === null) {
    return;
  }
  st.text = "异步：请求网络…";
  ui.http.get("https://httpbin.org/get").then(function (resp) {
    st.text = "异步：HTTP " + resp.status + " ✓";
  }).catch(function (r) {
    st.text = "异步：网络失败（已捕获）";
  });
}
