{ M7/M8 reactive bindings, component props/slots, events, and popup tests. }

function DemoFilePath(const AName: string): string;
begin
  Result := 'demo' + PathDelim + AName;
  if FileExists(Result) then
    Exit;
  Result := '..' + PathDelim + 'demo' + PathDelim + AName;
  if not FileExists(Result) then
    Result := '';
end;

procedure TestScriptReactive;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node: TXuiNode;
  keptA, keptC: TXuiNode;
  errs: Integer;
  tplDir, incDir, src: string;
  ioSeq: Integer;

  function RunFlush(const ACode: string): string;
  begin
    Inc(ioSeq);
    sink.Log.Clear;
    script.Run(ACode, 'rx' + IntToStr(ioSeq) + '.ts');
    script.FlushReactive;
    script.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M7 响应式绑定 ---');
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  ioSeq := 0;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.OnError := @sink.HandleError;
      script.Interp.OnLog := @sink.HandleLog;

      engine.LoadFromString(
        '<window>' +
        '<label id="t1" x-text="state.greeting"/>' +
        '<label id="t2" text="共 {{state.count}} 条"/>' +
        '<button id="b1" class="base" x-class="state.hot" text="B"/>' +
        '<button id="b2" x-disabled="state.locked" text="D"/>' +
        '<label id="lb3" class="vis" x-show="state.visible" text="showme"/>' +
        '<panel id="cond"><label id="cx" x-if="state.on" text="ON"/></panel>' +
        '<input id="inp" x-model="state.name"/>' +
        '<panel id="lst" x-for="it in state.items"><label x-text="it.n"/></panel>' +
        '</window>');
      DrawEngine(engine);

      src := RunFlush(
        'const state = reactive({' + #10 +
        '  greeting: "hi", count: 3, hot: "hot", locked: true,' + #10 +
        '  visible: true, on: true, name: "init",' + #10 +
        '  items: [{ n: "a" }, { n: "b" }]' + #10 +
        '});' + #10 +
        'function SetName(v: string): boolean { state.name = v; return true; }' + #10 +
        'function GetCount(): number { return state.count; }');
      Check(script.ErrorCount = 0, '响应式脚本求值无错误');
      Check(engine.Document.FindElementById('t1').Text = 'hi', 'x-text 初始渲染');
      Check(engine.Document.FindElementById('t2').Text = '共 3 条', '插值绑定');
      node := engine.Document.FindElementById('b1');
      Check(node.HasClass('hot') and node.HasClass('base'), 'x-class 追加类名');
      Check(XuiIsDisabled(engine.Document.FindElementById('b2')), 'x-disabled 初始禁用');
      node := engine.Document.FindElementById('lst');
      Check(node.Count = 2, 'x-for 初始渲染条目数');
      Check(engine.Document <> nil, '文档可用');

      RunFlush('state.greeting = "yo"; state.count = 8;');
      Check(engine.Document.FindElementById('t1').Text = 'yo', 'x-text 随状态更新');
      Check(engine.Document.FindElementById('t2').Text = '共 8 条', '插值随状态更新');
      RunFlush('state.hot = "cold"; state.locked = false;');
      node := engine.Document.FindElementById('b1');
      Check(node.HasClass('base') and node.HasClass('cold') and
        (not node.HasClass('hot')), 'x-class 更新为最新类');
      Check(not XuiIsDisabled(engine.Document.FindElementById('b2')), 'x-disabled 解除');

      RunFlush('state.visible = false;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('lb3');
      Check((node.Style <> nil) and (node.Style.Display = xdispNone), 'x-show=false 隐藏');
      RunFlush('state.visible = true;');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('lb3').Style.Display <> xdispNone,
        'x-show=true 恢复显示');

      RunFlush('state.on = false;');
      Check(engine.Document.FindElementById('cond').Count = 0, 'x-if=false 摘除子树');
      RunFlush('state.on = true;');
      node := engine.Document.FindElementById('cond');
      Check((node.Count = 1) and (node[0].Text = 'ON'), 'x-if=true 原位恢复');

      RunFlush('state.items = [{ n: "x" }, { n: "y" }, { n: "z" }];');
      node := engine.Document.FindElementById('lst');
      Check(node.Count = 3, 'x-for 数组增长重建');
      DrawEngine(engine);
      node := engine.Document.FindElementById('lst');
      Check((node.Count = 3) and (node[2].Text = 'z'), 'x-for 克隆内容按序渲染');

      RunFlush('state.name = "init";');
      node := engine.Document.FindElementById('inp');
      ClickNode(engine, node);
      engine.HandleTextInput('li');
      DrawEngine(engine);
      src := RunFlush('console.log("name=" + state.name);');
      Check(Pos('name=initli', src) > 0, 'x-model 输入回写状态');

      RunFlush('function OnInc() { state.count = state.count + 1; }');
      engine.LoadFromString(
        '<window><label id="t2" text="共 {{state.count}} 条"/>' +
        '<button id="inc" text="+1" onclick="OnInc"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('inc'));
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t2').Text = '共 9 条',
        '事件处理器写状态 → UI 自动更新');

      sink.Log.Clear;
      src := RunFlush(
        'const st = reactive({ a: 2 });' + #10 +
        'const double = computed(function () { return st.a * 2; });' + #10 +
        'console.log("c" + double.value);' + #10 +
        'st.a = 5;' + #10 +
        'console.log("c" + double.value);' + #10 +
        'watch(function () { return st.a; }, function (nv, ov) { console.log("w" + ov + "->" + nv); });' + #10 +
        'onMount(function () { console.log("mounted"); });');
      Check(Pos('c4', src) > 0, 'computed 求值');
      Check(Pos('c10', src) > 0, 'computed 随状态失效重算');
      Check(Pos('mounted', src) > 0, 'onMount 在首次刷新后调用');
      RunFlush('st.a = 9;');
      Check(Pos('w5->9', sink.Log.Text) > 0, 'watch 捕获新旧值');

      RunFlush('const st2 = reactive({ inner: { v: "d1" } });');
      script.Run('function SetInner2(v: string): boolean { st2.inner.v = v; return true; }', 'si2.ts');
      engine.LoadFromString('<window><label id="t3" x-text="st2.inner.v"/></window>');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t3').Text = 'd1', '嵌套对象初始渲染');
      script.CallGlobal('SetInner2', [script.Str('d2')]);
      script.FlushReactive;
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t3').Text = 'd2',
        '嵌套响应式：深层属性写入触发绑定更新');

      engine.LoadFromString(
        '<window><panel id="lst" x-for="it in state.items"><label x-text="it.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('state.items.push({ n: "w" });');
      Check(engine.Document.FindElementById('lst').Count = 4, '数组 push 触发 x-for 重建');

      RunFlush(
        'const keyed = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }, { id: 3, n: "C" }] });');
      engine.LoadFromString(
        '<window><panel id="kl" x-for="r in keyed.rows"><label x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kl');
      Check((node.Count = 3) and (node[0].Text = 'A') and (node[2].Text = 'C'),
        'keyed x-for 初始渲染');
      script.Run('function Reorder(): boolean { keyed.rows = [{ id: 3, n: "C2" }, { id: 1, n: "A" }]; return true; }', 're.ts');
      script.CallGlobal('Reorder', []);
      script.FlushReactive;
      DrawEngine(engine);
      node := engine.Document.FindElementById('kl');
      Check((node.Count = 2) and (node[0].Text = 'C2') and (node[1].Text = 'A'),
        'keyed x-for：重排与删除按 key 正确');

      RunFlush('const cs = reactive({ on: true });');
      engine.LoadFromString(
        '<window><label id="cl" class="base" x-class="{ hot: cs.on, cold: !cs.on }" text="cls"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('cl');
      Check(node.HasClass('hot') and (not node.HasClass('cold')), ':class 对象语法（真值键生效）');
      RunFlush('cs.on = false;');
      node := engine.Document.FindElementById('cl');
      Check(node.HasClass('cold') and (not node.HasClass('hot')), ':class 对象语法随状态切换');

      src := RunFlush(
        'const wi = reactive({ v: 3 });' + #10 +
        'watch(function () { return wi.v; }, function (nv, ov) { console.log("wi" + nv + "/" + ov); }, { immediate: true });');
      Check(Pos('wi3/undefined', src) > 0, 'watch immediate 注册即回调');
      RunFlush(
        'const dw = reactive({ o: { v: 1 } });' + #10 +
        'watch(function () { return dw.o; }, function (nv, ov) { console.log("deep-fire"); }, { deep: true });');
      Check(sink.Log.Text = '', 'deep watch 基线不触发');
      RunFlush('dw.o.v = 2;');
      Check(Pos('deep-fire', sink.Log.Text) > 0, 'watch deep 捕获嵌套变化');

      RunFlush(
        'function Dbl(n: number): number { return n * 2; }' + #10 +
        'component("badge", { props: ["count", "f"], template: "<panel class=\"badge\"><label x-text=\"props.f(props.count)\"/></panel>" });');
      engine.LoadFromString('<window><badge count="7" :f="Dbl"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '14'), '组件实例化：静态 prop 与函数 prop');
      RunFlush('const bc = reactive({ n: 9 });');
      engine.LoadFromString('<window><badge :count="bc.n" :f="Dbl"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '18'), '动态 prop 初始渲染');
      RunFlush('bc.n = 11;');
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '22'), '动态 prop 随父状态更新');

      RunFlush(
        'const slotState = reactive({ msg: "SLOT-OK" });' + #10 +
        'component("my-box", { props: [], template: "<panel class=\"box\"><slot/></panel>" });');
      engine.LoadFromString(
        '<window><my-box><label id="sl" x-text="slotState.msg"/></my-box></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sl');
      Check((node <> nil) and (node.Text = 'SLOT-OK') and (node.Parent.Tag = 'panel'),
        'slot 内容移入组件槽位并按父作用域求值');

      RunFlush(
        'const kx = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }, { id: 3, n: "C" }] });');
      engine.LoadFromString(
        '<window><panel id="kx1" x-for="r in kx.rows"><label x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kx1');
      keptA := node[0];
      keptC := node[2];
      errs := script.ErrorCount;
      RunFlush('kx.rows = [{ id: 3, n: "C2" }, { id: 1, n: "A2" }];');
      node := engine.Document.FindElementById('kx1');
      Check(node.Count = 2, 'keyed x-for：重排且删除后条目数正确');
      Check((node[0] = keptC) and (node[1] = keptA), 'keyed x-for：同 key 复用克隆（节点对象保持）');
      Check((node[0].Text = 'C2') and (node[1].Text = 'A2'), 'keyed x-for：复用条目文本随新数据更新');
      RunFlush('kx.rows.push({ id: 9, n: "D" });');
      node := engine.Document.FindElementById('kx1');
      Check((node.Count = 3) and (node[2].Text = 'D'), 'keyed x-for：新 key 追加克隆');
      Check(script.ErrorCount = errs, 'keyed x-for：复用/移除全程无脚本错误');

      RunFlush(
        'const tr = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }] });');
      engine.LoadFromString(
        '<window><panel id="tr1" x-for="r in tr.rows"><label class="ftr" x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      RunFlush('tr.rows = [{ id: 2, n: "B" }];');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tr1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'B'),
        'keyed x-for 移除条目后仍可绘制（过渡表不留悬垂节点引用）');
      Check(script.ErrorCount = errs, 'keyed x-for 移除后无脚本错误');

      RunFlush('const nx = reactive({ rows: [{ n: "x1" }, { n: "x2" }] });');
      engine.LoadFromString(
        '<window><panel id="nx1" x-for="r in nx.rows"><label x-text="r.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('nx.rows = [{ n: "y1" }, { n: "y2" }];');
      node := engine.Document.FindElementById('nx1');
      Check((node.Count = 2) and (node[0].Text = 'y1') and (node[1].Text = 'y2'),
        '非键控 x-for：同长度元素替换就地更新');

      RunFlush(
        'component("duo", { props: [], template: "<label class=\"d1\" text=\"first\"/><label class=\"d2\" text=\"second\"/>" });');
      engine.LoadFromString('<window><duo id="duo1" class="host"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root;
      Check((node.Count = 2) and (node[0].Text = 'first') and (node[1].Text = 'second'),
        '组件模板多根：两棵根按序插入宿主位置');
      Check((node[0].Id = 'duo1') and node[0].HasClass('host') and (node[1].Id = ''),
        '多根组件：宿主 id/class 落到首个实例根');

      RunFlush(
        'component("page-box", { props: [], template: "<panel class=\"page\"><slot name=\"head\"/><label text=\"mid\"/><slot/></panel>" });');
      engine.LoadFromString(
        '<window><page-box><label id="hd" slot="head" text="H"/><label id="ft" text="F"/>' +
        '<label id="dr" slot="none" text="X"/></page-box></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('hd');
      Check((node <> nil) and (node.Parent.Tag = 'panel') and
        (node.Parent.IndexOfChild(node) = 0), '具名 slot：head 内容进入对应槽位');
      node := engine.Document.FindElementById('ft');
      Check((node <> nil) and (node.Parent.IndexOfChild(node) = 2),
        '默认 slot：未标 slot 的内容进入无具名槽位');
      Check(engine.Document.FindElementById('dr') = nil, '未匹配槽位的内容被丢弃');

      RunFlush(
        'component("typed", { props: { n: "number", s: "string" }, template: "<label x-text=\"props.s + props.n\"/>" });');
      engine.LoadFromString('<window><typed id="ty1" n="7" s="v"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ty1');
      Check((node <> nil) and (node.Text = 'v7'), 'props 类型校验：静态属性按声明强转 number');
      RunFlush('const tv = reactive({ bad: "str" });');
      errs := script.ErrorCount;
      engine.LoadFromString('<window><typed id="ty2" s="x" :n="tv.bad"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'props 类型校验：动态 prop 类型不匹配上报错误');
      node := engine.Document.FindElementById('ty2');
      Check((node <> nil) and (node.Text = 'xundefined'),
        'props 类型校验：不匹配的写入被拒绝（保留旧值）');
      errs := script.ErrorCount;
      RunFlush(
        'component("reqd", { props: { v: { type: "string", required: true } }, template: "<label x-text=\"props.v\"/>" });');
      engine.LoadFromString('<window><reqd/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'props 必填校验：缺失时上报错误');
      Check(Pos('缺少必填 prop', sink.LastError) > 0, 'props 必填校验：错误信息含 prop 名');

      RunFlush(
        'const cl = reactive({ rows: [{ id: 1, n: "C1" }, { id: 2, n: "C2" }] });' + #10 +
        'component("crow", { props: ["n"], template: "<panel class=\"crow\"><label x-text=\"props.n\"/></panel>" });');
      engine.LoadFromString(
        '<window><panel id="kcl" x-for="r in cl.rows"><crow :n="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kcl');
      Check((node.Count = 2) and (node[0][0].Text = 'C1') and (node[1][0].Text = 'C2'),
        '组件作为 keyed 列表项：首次刷新即渲染');
      RunFlush('cl.rows = [{ id: 2, n: "C2b" }, { id: 1, n: "C1b" }];');
      node := engine.Document.FindElementById('kcl');
      Check((node.Count = 2) and (node[0][0].Text = 'C2b') and (node[1][0].Text = 'C1b'),
        '组件作为 keyed 列表项：重排后组件 props 随新条目更新');

      RunFlush(
        'const bl = reactive({ rows: [{ id: 1, tags: ["a", "b"] }, { id: 2, tags: ["c"] }] });' + #10 +
        'component("tag-box", { props: ["tags"], template: "<panel class=\"tb\"><panel x-for=\"t in props.tags\"><label x-text=\"t\"/></panel></panel>" });');
      engine.LoadFromString(
        '<window><panel id="tbl" x-for="r in bl.rows"><tag-box :tags="r.tags" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tbl');
      Check((node.Count = 2) and (node[0][0].Count = 2) and (node[1][0].Count = 1),
        '组件内 x-for：按 props 数组渲染');
      RunFlush('bl.rows = [{ id: 2, tags: ["c", "d"] }, { id: 1, tags: ["a"] }];');
      node := engine.Document.FindElementById('tbl');
      Check((node[0][0].Count = 2) and (node[0][0][0].Text = 'c') and
        (node[0][0][1].Text = 'd') and (node[1][0].Count = 1) and
        (node[1][0][0].Text = 'a'),
        '组件内 x-for 与父级 keyed 复用叠加：内层列表随新 props 更新');
      errs := script.ErrorCount;
      engine.LoadFromString('<window><panel id="badfor" x-for="x in bl.rows"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'x-for 缺少模板子节点：上报错误');
      Check(engine.Document.FindElementById('badfor').Count = 0, 'x-for 缺少模板子节点：容器保持空');

      RunFlush(
        'const vv = reactive({ on: true });' + #10 +
        'component("fx-box", { props: [], template: "<label class=\"fx\" text=\"FX\"/>" });');
      engine.LoadFromString('<window><panel id="fxp"><fx-box id="fxc" x-if="vv.on"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fxc');
      Check((node <> nil) and (node.Text = 'FX'), '组件宿主 x-if：真值渲染实例');
      RunFlush('vv.on = false;');
      Check(engine.Document.FindElementById('fxc') = nil, '组件宿主 x-if：假值摘除实例');
      RunFlush('vv.on = true;');
      node := engine.Document.FindElementById('fxc');
      Check((node <> nil) and (node.Parent.Tag = 'panel') and (node.Text = 'FX'),
        '组件宿主 x-if：真值原位恢复实例');
      errs := script.ErrorCount;
      engine.LoadFromString('<window><duo id="duox" x-if="vv.on"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, '多根组件 + x-if：上报不支持');

      RunFlush(
        'component("dv-box", { props: { n: { type: "number", default: 5 }, s: { type: "string", default: "d" } }, template: "<label x-text=\"props.s + props.n\"/>" });');
      engine.LoadFromString('<window><dv-box id="dv1"/><dv-box id="dv2" s="x" n="9"/></window>');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dv1').Text = 'd5', 'props default：原始值缺省生效');
      Check(engine.Document.FindElementById('dv2').Text = 'x9', 'props default：显式传入覆盖缺省');
      errs := script.ErrorCount;
      RunFlush(
        'component("fx-list", { props: { tags: { type: "array", default: function () { return ["t1"]; } } }, template: "<panel class=\"fl\"><panel x-for=\"t in props.tags\"><label x-text=\"t\"/></panel></panel>" });');
      engine.LoadFromString('<window><fx-list id="fl1"/><fx-list id="fl2"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fl1');
      Check((node <> nil) and (node[0].Count = 1) and (node[0][0].Text = 't1'),
        'props default：工厂函数缺省（数组）');
      Check(script.ErrorCount = errs, 'props default：缺省值通过类型校验，无错误上报');

      RunFlush(
        'const mg = reactive({ rows: [{ id: 1, n: "M1" }, { id: 2, n: "M2" }] });' + #10 +
        'component("pair", { props: ["n"], template: "<label class=\"p1\" x-text=\"props.n\"/><label class=\"p2\" text=\"tail\"/>" });');
      engine.LoadFromString(
        '<window><panel id="mg1" x-for="r in mg.rows"><pair :n="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('mg1');
      Check((node.Count = 4) and (node[0].Text = 'M1') and (node[1].Text = 'tail') and
        (node[2].Text = 'M2') and (node[3].Text = 'tail'),
        '多根组件作为 keyed 列表项：两棵根成组渲染');
      RunFlush('mg.rows = [{ id: 2, n: "M2b" }, { id: 1, n: "M1b" }];');
      node := engine.Document.FindElementById('mg1');
      Check((node.Count = 4) and (node[0].Text = 'M2b') and (node[1].Text = 'tail') and
        (node[2].Text = 'M1b') and (node[3].Text = 'tail'),
        '多根组件作为 keyed 列表项：重排后两棵根保持成组有序');

      RunFlush(
        'function LabelOf(n: number): string { return "L" + n; }' + #10 +
        'component("uc2", { props: { count: { type: "number", default: 0 }, onLabels: { type: "function" } }, template: "<panel><label x-text=\"props.onLabels(props.count)\"/></panel>" });');
      engine.LoadFromString('<window><uc2 id="uc2" :count="7" :on-labels="LabelOf"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('uc2');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'L7'),
        '函数 prop：kebab 属性名转 camel 后可在模板内调用');

      RunFlush('const rv = reactive({ rows: [{ n: "r1" }, { n: "r2" }] });');
      engine.LoadFromString(
        '<window><panel id="rv1" x-for="r in rv.rows"><label x-text="r.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('rv.rows.reverse();');
      node := engine.Document.FindElementById('rv1');
      Check((node.Count = 2) and (node[0].Text = 'r2') and (node[1].Text = 'r1'),
        '数组 reverse 触发 x-for 刷新');
      RunFlush('rv.rows.splice(1, 0, { n: "r3" });');
      node := engine.Document.FindElementById('rv1');
      Check((node.Count = 3) and (node[1].Text = 'r3'), '数组 splice 触发 x-for 刷新');

      errs := script.ErrorCount;
      script.Run('watch(function () { return state.nope.deep; }, function (nv, ov) { console.log("not-reached"); });', 'badw.ts');
      script.Run('watch(function () { return st.a; }, function (nv, ov) { console.log("good" + nv); });', 'goodw.ts');
      script.FlushReactive;
      Check(script.ErrorCount > errs, 'watch 求值异常上报为脚本错误');
      Check(Pos('not-reached', sink.Log.Text) = 0, 'watch 求值异常不执行回调');
      src := RunFlush('st.a = st.a + 1;');
      Check(Pos('good', src) > 0, 'watch 异常不阻断其它监听器与刷新链路');

      RunFlush(
        'const ev = reactive({ n: 0, calls: 0 });' + #10 +
        'function OnTap() { ev.calls = ev.calls + 1; }');
      engine.LoadFromString(
        '<window><button id="ev1" x-onclick="ev.n = ev.n + 1" text="b1"/>' +
        '<button id="ev2" x-on:click="OnTap" text="b2"/>' +
        '<label id="ev3" text="n={{ev.n}}/c={{ev.calls}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('ev1'));
      ClickNode(engine, engine.Document.FindElementById('ev2'));
      DrawEngine(engine);
      node := engine.Document.FindElementById('ev3');
      Check((node <> nil) and (node.Text = 'n=1/c=1'),
        'x-onclick：表达式（赋值）与函数名两种写法都触发（含 x-on:click 别名）');

      RunFlush(
        'const cev = reactive({ taps: 0 });' + #10 +
        'function OnHostTap() { cev.taps = cev.taps + 1; }' + #10 +
        'component("ui-tap", { props: { onClick: { type: "function" } }, ' +
        'template: "<panel class=\"tapbox\" x-onclick=\"props.onClick\"><slot/></panel>" });');
      engine.LoadFromString(
        '<window><ui-tap id="tap1" x-onclick="OnHostTap"><label id="tap-lbl" text="点我"/></ui-tap>' +
        '<label id="tap-cnt" text="taps={{cev.taps}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('tap-lbl'));
      DrawEngine(engine);
      node := engine.Document.FindElementById('tap-cnt');
      Check((node <> nil) and (node.Text = 'taps=1'),
        '组件 x-onclick：模板内 props.onClick 触发父级函数（子→父事件链路）');

      errs := script.ErrorCount;
      engine.LoadFromString(
        '<window><button id="ev4" x-onclick="ev.nope.deep" text="boom"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('ev4'));
      Check(script.ErrorCount > errs, 'x-onclick：表达式出错上报为脚本错误（不崩应用）');

      RunFlush(
        'const iv = reactive({ n: 0 });' + #10 +
        'function OnIv() { iv.n = iv.n + 1; }');
      engine.LoadFromString(
        '<window><input id="iv1" x-oninput="OnIv"/><label id="iv2" text="n={{iv.n}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('iv1'));
      engine.HandleTextInput('x');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('iv2').Text = 'n=1', 'x-oninput：input 事件触发表达式');

      RunFlush('const it2 = reactive({ t: "-" });');
      engine.LoadFromString(
        '<window><input id="iv3" x-oninput="it2.t = event.text"/><label id="iv4" text="t={{it2.t}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('iv3'));
      engine.HandleTextInput('hi');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('iv4').Text = 't=hi',
        'x-oninput：表达式可用 event.text 读取载荷');

      RunFlush(
        'const mv = reactive({ name: "init" });' + #10 +
        'component("ui-text", { props: { modelValue: { type: "string", default: "" } }, ' +
        'template: "<panel class=\"uitext\"><input :text=\"props.modelValue\" x-oninput=\"props.onModelValue\"/></panel>" });');
      engine.LoadFromString('<window><ui-text id="ut1" x-model="mv.name"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ut1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'init'),
        'x-model 组件：宿主状态写入 props.modelValue（初值）');
      ClickNode(engine, node[0]);
      engine.HandleTextInput('abc');
      DrawEngine(engine);
      src := RunFlush('console.log("mv=" + mv.name);');
      Check(Pos('mv=initabc', src) > 0,
        'x-model 组件：组件内输入经 props.onModelValue 回写宿主状态');
      RunFlush('mv.name = "reset";');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ut1');
      Check((node <> nil) and (node[0].Text = 'reset'),
        'x-model 组件：宿主状态变化回灌组件内部');

      tplDir := GetTempDir + 'lui_m8_tpl';
      ForceDirectories(tplDir);
      WriteTestFile(tplDir + PathDelim + 'card.xml',
        '<panel class="tplcard"><label x-text="props.t"/></panel>');
      WriteTestFile(tplDir + PathDelim + 'ui.ts',
        'component("tpl-card", { props: { t: "string" }, templateFile: "card.xml" });');
      script.RunFile(tplDir + PathDelim + 'ui.ts');
      engine.LoadFromString('<window><tpl-card id="tc1" t="hi"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tc1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'hi'),
        'templateFile：外部模板文件按脚本目录解析并实例化');
      errs := script.ErrorCount;
      WriteTestFile(tplDir + PathDelim + 'bad.ts',
        'component("tpl-bad", { props: [], templateFile: "no-such-file.xml" });');
      script.RunFile(tplDir + PathDelim + 'bad.ts');
      Check(script.ErrorCount > errs, 'templateFile：模板文件缺失上报为脚本错误');

      RunFlush('const pp = reactive({ open: false });');
      engine.LoadFromString(
        '<window><panel id="hostbox" style="overflow:hidden; width:120px; height:40px">' +
        '<button id="anchor1" text="锚点"/></panel>' +
        '<panel id="pop1" style="width:60px; height:30px"><label text="浮层"/></panel></window>');
      DrawEngine(engine);
      src := RunFlush(
        'console.log("rect=" + document.find("anchor1").rect.top + "/" + document.find("anchor1").rect.height);' +
        'ui.popup(document.find("pop1"), { anchor: "anchor1", placement: "bottom-start" });');
      DrawEngine(engine);
      node := engine.Document.FindElementById('pop1');
      Check((node <> nil) and (node.Parent = engine.Document.Root),
        'ui.popup：浮层挂到文档根（脱离父级 overflow 裁剪）');
      Check((node <> nil) and (node.Style.Position = xposAbsolute),
        'ui.popup：内联 style 实现绝对定位');
      Check((node <> nil) and
        (node.Style.Inset.Top.Value >= engine.Document.FindElementById('anchor1').BoxRect.Bottom - 1),
        'ui.popup：定位到锚点下方（bottom-start）');
      Check((node <> nil) and (node.Style.Width.Value = 60),
        'ui.popup：保留作者内联样式（width 未被定位覆盖）');
      Check(Pos('rect=', src) > 0, 'node.rect：脚本可读元素矩形');

      RunFlush('const sty = reactive({ w: 40 });');
      engine.LoadFromString(
        '<window><panel id="sty1" :style="''width:'' + sty.w + ''px; height:20px''"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sty1');
      Check((node <> nil) and (node.Style.Width.Value = 40), ':style：运行时样式生效');
      RunFlush('sty.w = 80;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sty1');
      Check((node <> nil) and (node.Style.Width.Value = 80),
        ':style：状态变化后样式随之更新（组件按 props 算样式的基础）');
      RunFlush('const ph = reactive({ hint: "请输入用户名" });');
      engine.LoadFromString('<window><input id="ph1" :placeholder="ph.hint"/></window>');
      fake.Clear;
      DrawEngine(engine);
      Check(fake.TextDrawn('请输入用户名'), ':placeholder：运行时占位符生效');

      incDir := GetTempDir + 'lui_m8_inc';
      ForceDirectories(incDir);
      WriteTestFile(incDir + PathDelim + 'part.ts', 'function IncFn(): number { return 7; }');
      WriteTestFile(incDir + PathDelim + 'main.ts',
        'ui.include("part.ts");' + #10 + 'ui.include("part.ts");' + #10 +
        'console.log("inc=" + IncFn());');
      sink.Log.Clear;
      script.RunFile(incDir + PathDelim + 'main.ts');
      Check(Pos('inc=7', sink.Log.Text) > 0,
        'ui.include：按当前脚本目录加载并执行另一个脚本');
      errs := script.ErrorCount;
      WriteTestFile(incDir + PathDelim + 'badinc.ts', 'ui.include("nope.ts");');
      script.RunFile(incDir + PathDelim + 'badinc.ts');
      Check(script.ErrorCount > errs, 'ui.include：文件缺失上报为脚本错误');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
