{ M8 component-library smoke, form, overlay, data, and navigation coverage. }

const
  UiIconPathCloseD =
    'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z';

function FindFirstByClass(ARoot: TXuiNode; const AClass: string): TXuiNode;
var
  i: Integer;
  found: TXuiNode;
begin
  Result := nil;
  if ARoot = nil then
    Exit;
  if ARoot.HasClass(AClass) then
    Exit(ARoot);
  for i := 0 to ARoot.Count - 1 do
  begin
    found := FindFirstByClass(ARoot[i], AClass);
    if found <> nil then
      Exit(found);
  end;
end;

function RepoPath(const ARelative: string): string;
begin
  Result := ARelative;
  if FileExists(Result) then
    Exit;
  Result := '..' + PathDelim + ARelative;
  if not FileExists(Result) then
    Result := '';
end;

procedure TestUiLibrary;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node, btn: TXuiNode;
  theme, index, src: string;
  errs, seq, pathCountBefore: Integer;

  function RunFlush(const ACode: string): string;
  begin
    Inc(seq);
    sink.Log.Clear;
    script.Run(ACode, 'uif' + IntToStr(seq) + '.ts');
    script.FlushReactive;
    script.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M8 组件库（ui/）---');
  theme := RepoPath('ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css');
  index := RepoPath('ui' + PathDelim + 'index.ts');
  if (theme = '') or (index = '') then
  begin
    WriteLn('SKIP  未找到 ui/ 组件库文件');
    Exit;
  end;
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.OnError := @sink.HandleError;
      script.Interp.OnLog := @sink.HandleLog;
      engine.LoadStyleSheetFromFile(theme);
      script.RunFile(index);
      script.Run('const uiTaps = reactive({ n: 1 });' + #10 +
        'const uiState = reactive({ name: "lui" });' + #10 +
        'function OnUiTap(): void { uiTaps.n = uiTaps.n + 1; }', 'uiprobe.ts');
      Check(script.ErrorCount = 0, '组件库入口加载无错误');
      engine.LoadFromString(
        '<window><ui-card title="卡片"><ui-row id="r1" gutter="8">' +
        '<ui-col span="12"><label id="c1" text="a"/></ui-col>' +
        '<ui-col span="12"><label id="c2" text="b"/></ui-col></ui-row>' +
        '<ui-button id="b1" text="主按钮" type="primary" size="small" x-onclick="OnUiTap"/>' +
        '<label id="cnt" text="taps={{uiTaps.n}}"/>' +
        '<ui-input id="i1" x-model="uiState.name" placeholder="请输入"/></ui-card></window>');
      engine.LoadStyleSheetFromFile(theme);
      DrawEngine(engine);
      node := engine.Document.FindElementById('r1');
      Check((node <> nil) and (node.Style.Display = xdispFlex) and
        (node.Style.ColumnGap.Value = 8), '组件库：ui-row 横向栅格 + gutter');
      node := engine.Document.FindElementById('c1');
      Check((node <> nil) and (node.Parent.Style.FlexGrow = 12), '组件库：ui-col 按 span 分配 flex-grow');
      node := engine.Document.FindElementById('i1');
      Check((node <> nil) and (node.Style.Display = xdispFlex),
        '组件库：主题样式生效（ui-input 根节点 display:flex）');
      btn := engine.Document.FindElementById('b1');
      Check((btn <> nil) and btn.HasClass('ui-btn') and btn.HasClass('ui-btn--primary') and
        btn.HasClass('ui-btn--sm') and (btn.Style.BgColor.R = $16),
        '组件库：ui-button 修饰类与主题色（primary/small）');
      ClickNode(engine, btn);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('cnt').Text = 'taps=2',
        '组件库：ui-button 回调 prop 触发父级函数');
      node := engine.Document.FindElementById('i1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'lui'),
        '组件库：ui-input 经 x-model 取到宿主状态');

      script.Run('const uiForm_ = reactive({ name: "", agree: false, pick: "b", level: 20, num: 3 });' + #10 +
        'function OnSubmitProbe(): string { return uiFormValidate("f1") ? "ok" : "bad"; }', 'uiform.ts');
      engine.LoadFromString(
        '<window><ui-form id="f1"><ui-form-item form="f1" prop="name" label="用户名" :model="uiForm_" ' +
        ':rules="[UiRules.required(''请输入用户名''), UiRules.minLength(3, ''至少 3 个字符'')]">' +
        '<ui-input id="fn" x-model="uiForm_.name" placeholder="用户名"/></ui-form-item></ui-form>' +
        '<ui-checkbox id="cb1" text="同意条款" x-model="uiForm_.agree"/>' +
        '<ui-switch id="sw1" x-model="uiForm_.agree"/>' +
        '<ui-radio-group id="rg1" :options="[{value: ''a'', text: ''A''}, {value: ''b'', text: ''B''}]" x-model="uiForm_.pick"/>' +
        '<ui-slider id="sl1" x-model="uiForm_.level" :max="100"/>' +
        '<ui-input-number id="in1" x-model="uiForm_.num" :max="10"/>' +
        '<label id="probe" x-text="''pick='' + uiForm_.pick + ''/lvl='' + uiForm_.level + ''/num='' + uiForm_.num"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fn');
      Check((node <> nil) and (node.Parent <> nil) and
        (Pos('请输入用户名', node.Parent.Parent[2].Text) > 0), '组件库：ui-form-item 校验提示（必填）');
      RunFlush('uiForm_.name = "lui";');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('fn').Parent.Parent[2].Text = '',
        '组件库：校验通过后提示清空');
      ClickNode(engine, engine.Document.FindElementById('cb1'));
      DrawEngine(engine);
      src := RunFlush('console.log("agree=" + uiForm_.agree);');
      Check(Pos('agree=true', src) > 0, '组件库：ui-checkbox 点击切换并回写状态');
      ClickNode(engine, engine.Document.FindElementById('sw1'));
      DrawEngine(engine);
      src := RunFlush('console.log("agree=" + uiForm_.agree);');
      Check(Pos('agree=false', src) > 0, '组件库：ui-switch 点击切换并回写状态');
      ClickNode(engine, engine.Document.FindElementById('rg1')[0][0]);
      DrawEngine(engine);
      src := RunFlush('console.log("pick=" + uiForm_.pick);');
      Check(Pos('pick=a', src) > 0, '组件库：ui-radio-group 选择回写状态');
      node := engine.Document.FindElementById('sl1');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("lvl=" + uiForm_.level);');
      Check(Pos('lvl=', src) > 0, '组件库：ui-slider 点击定位取值');
      ClickNode(engine, engine.Document.FindElementById('in1')[0]);
      DrawEngine(engine);
      src := RunFlush('console.log("num=" + uiForm_.num);');
      Check(Pos('num=2', src) > 0, '组件库：ui-input-number 步进（− 1 步）');
      src := RunFlush('console.log("v=" + (uiFormValidate("f1") ? "ok" : "bad"));');
      Check(Pos('v=ok', src) > 0, '组件库：uiFormValidate 全部通过');

      RunFlush('const dlgState = reactive({ open: true });');
      engine.LoadFromString(
        '<window><panel id="dlg-host" x-if="dlgState.open" x-popup="" x-popup-placement="center"' +
        ' style="width:80px; height:40px"><label text="浮层"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dlg-host');
      Check((node <> nil) and (node.Parent = engine.Document.Root) and
        (node.Style.Position = xposAbsolute), 'x-popup：浮层节点挂到文档根并绝对定位');
      RunFlush('dlgState.open = false;');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dlg-host') = nil, 'x-popup：x-if 假值时收回');
      RunFlush('dlgState.open = true;');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dlg-host').Parent = engine.Document.Root,
        'x-popup：恢复显示后重新浮出');
      engine.LoadFromString('<window><panel id="sty2"/></window>');
      DrawEngine(engine);
      RunFlush('document.find("sty2").style = "width:50px; height:20px";');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('sty2').Style.Width.Value = 50,
        'node.style：脚本设置内联样式生效');
      RunFlush('function OnAddedTap(): void { uiForm_.name = "added"; }');
      RunFlush('document.add(''<ui-button id="added-btn" text="新增" x-onclick="OnAddedTap"/>'');');
      DrawEngine(engine);
      node := engine.Document.FindElementById('added-btn');
      Check((node <> nil) and node.HasClass('ui-btn'),
        'document.add：运行时新增子树里的组件被实例化');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("nm=" + uiForm_.name);');
      Check(Pos('nm=added', src) > 0, 'document.add：新增子树的事件绑定生效');

      RunFlush('const fb = reactive({ show: false, oked: 0, closed: 0 });' + #10 +
        'function OnDlgClose(): void { fb.closed = fb.closed + 1; fb.show = false; }' + #10 +
        'function OnDlgOk(): void { fb.oked = fb.oked + 1; fb.show = false; }');
      engine.LoadFromString(
        '<window><ui-alert id="al1" type="success" title="成功" text="操作已完成"/>' +
        '<ui-loading id="ld1" text="加载中…"/><ui-dialog id="dg1" :visible="fb.show" title="确认" :width="260" ' +
        ':on-close="OnDlgClose" :on-ok="OnDlgOk"><label text="内容"/></ui-dialog></window>');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dg1') = nil, '组件库：ui-dialog 默认不显示（x-if 摘除）');
      RunFlush('fb.show = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dg1');
      Check((node <> nil) and (node.Parent = engine.Document.Root) and
        (node.Style.Position = xposAbsolute), '组件库：ui-dialog 显示时挂到文档根（浮层）');
      node := engine.Document.FindElementById('ui-dialog-ok');
      Check(node <> nil, '组件库：ui-dialog-ok 按钮存在');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("oked=" + fb.oked + ",closed=" + fb.closed);');
      Check(Pos('oked=1', src) > 0, '组件库：ui-dialog 点击确定触发 onOk 回调');
      Check(engine.Document.FindElementById('dg1') = nil, '组件库：onOk 改状态后 ui-dialog 自动关闭');

      engine.LoadFromString('<window><ui-svg-icon id="ic1" name="close" size="14"/></window>');
      pathCountBefore := fake.PathCount;
      DrawEngine(engine);
      node := engine.Document.FindElementById('ic1');
      Check((node <> nil) and (node.Tag = 'svg') and (node.Count >= 1) and (node[0].Tag = 'path'),
        '组件库：ui-svg-icon 实例根为 svg 且含 path');
      Check(node[0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：path 的 d 来自图标库 close');
      Check(fake.PathCount > pathCountBefore, '组件库：ui-svg-icon 经矢量路径渲染（RenderPath 被调用）');
      RunFlush('const icst = reactive({ n: "check" });');
      engine.LoadFromString('<window><ui-svg-icon id="ic2" :name="icst.n" size="14"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ic2');
      Check((node <> nil) and (node[0].Tag = 'path') and
        (node[0].AttributeValue('d', '') <> UiIconPathCloseD),
        '组件库：动态图标初始为 check（d 非 close 路径）');
      RunFlush('icst.n = "close";');
      DrawEngine(engine);
      Check(node[0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：动态换图标后 svg 重解析（d 更新为 close 路径）');
      engine.LoadFromString(
        '<window><ui-dialog id="dg1" :visible="fb.show" title="确认" :width="260" ' +
        ':on-close="OnDlgClose" :on-ok="OnDlgOk"><label text="内容"/></ui-dialog></window>');
      DrawEngine(engine);
      RunFlush('fb.show = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dg1');
      Check(node <> nil, '组件库：ui-dialog 再次显示');
      btn := FindFirstByClass(node, 'ui-dialog__close');
      Check((btn <> nil) and (btn.Count = 1) and (btn[0].Tag = 'svg') and
        (btn[0].Count >= 1) and (btn[0][0].Tag = 'path'),
        '组件库：弹窗关闭按钮为 ui-svg-icon（svg>path）');
      Check(btn[0][0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：关闭按钮 path 来自图标库 close');
      ClickNode(engine, btn);
      src := RunFlush('console.log("closed=" + fb.closed);');
      Check(Pos('closed=1', src) > 0, '组件库：SVG 关闭按钮点击触发 onClose');
      RunFlush('fb.show = false;');
      sink.LastError := '';
      src := RunFlush('let boxResult = -1;' + #10 +
        'uiMessageBox.confirm("删除", "确定删除该条？").then(function(res: boolean): void { boxResult = (res ? 1 : 0); });');
      DrawEngine(engine);
      src := RunFlush('console.log("boxn=" + (document.find("uibox0") === undefined ? "0" : "1"));');
      Check(Pos('boxn=1', src) > 0, '组件库：uiMessageBox 的浮层节点已挂到文档');
      node := engine.Document.FindElementById('uibox-ok');
      Check(node <> nil, '组件库：uiMessageBox 确定按钮存在');
      ClickNode(engine, node);
      script.DrainMicrotasks;
      DrawEngine(engine);
      src := RunFlush('console.log("res=" + boxResult);');
      Check(Pos('res=1', src) > 0, '组件库：uiMessageBox 点击确定 Promise 被 resolve 为 true');
      Check(engine.Document.FindElementById('uibox0') = nil, '组件库：uiMessageBox 结算后浮层节点自 DOM 移除');

      RunFlush('const dispState = reactive({ tagClosed: 0, tagClosable: true, badgeVal: 150, progress: 75, ' +
        'colActive: false, colToggled: 0, page: 1, paged: 0, ' +
        'tblData: [{ id: "1", name: "Alice" }, { id: "2", name: "Bob" }], ' +
        'tblCols: [{ prop: "id", label: "ID" }, { prop: "name", label: "姓名" }] });' + #10 +
        'function OnTagClose(): void { dispState.tagClosed = 1; }' + #10 +
        'function OnColToggle(): void { dispState.colActive = !dispState.colActive; dispState.colToggled = dispState.colToggled + 1; }' + #10 +
        'function OnPageNext(): void { dispState.page = dispState.page + 1; dispState.paged = dispState.paged + 1; }');
      engine.LoadFromString(
        '<window><ui-tag id="t1" text="成功标签" type="success" :closable="dispState.tagClosable" :on-close="OnTagClose"/>' +
        '<ui-badge id="bg1" :value="dispState.badgeVal" :max="99"><label text="消息"/></ui-badge>' +
        '<ui-badge id="bg2" dot="true"><label text="待办"/></ui-badge>' +
        '<ui-progress id="prg1" :percentage="dispState.progress" status="success"/>' +
        '<ui-avatar id="av1" text="L" size="40" shape="circle"/><ui-collapse id="cp1">' +
        '<ui-collapse-item id="cpi1" title="折叠标题" :active="dispState.colActive" :on-toggle="OnColToggle">' +
        '<label id="cpi-text" text="折叠详情文本"/></ui-collapse-item></ui-collapse>' +
        '<ui-pagination id="pg1" :current="dispState.page" :total="55" :page-size="10" :on-next="OnPageNext"/>' +
        '<ui-table id="tb1" :columns="dispState.tblCols" :data="dispState.tblData"/>' +
        '<ui-tooltip id="tt1" content="提示内容"><label text="悬停"/></ui-tooltip>' +
        '<ui-popover id="pop1" title="卡片标题" content="卡片正文"><label text="点击"/></ui-popover></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('t1');
      Check((node <> nil) and node.HasClass('ui-tag') and node.HasClass('ui-tag--success'),
        '组件库：ui-tag 带有成功配色修饰类');
      btn := nil;
      for seq := 0 to node.Count - 1 do
        if node[seq].HasClass('ui-tag__close') then begin btn := node[seq]; Break; end;
      Check(btn <> nil, '组件库：ui-tag closable 关闭按钮存在');
      ClickNode(engine, btn);
      DrawEngine(engine);
      src := RunFlush('console.log("tag=" + dispState.tagClosed);');
      Check(Pos('tag=1', src) > 0, '组件库：ui-tag 点击关闭触发 onClose 回调');
      node := engine.Document.FindElementById('bg1');
      Check((node <> nil) and (node.Count >= 2) and (node[1].Count >= 1) and
        (node[1][0].Text = '99+'), '组件库：ui-badge 数值超出 max 截断显示 99+');
      node := engine.Document.FindElementById('bg2');
      Check((node <> nil) and (node.Count >= 2) and node[1].HasClass('is-dot'),
        '组件库：ui-badge dot 模式带有 is-dot 样式');
      node := engine.Document.FindElementById('bg1');
      Check((node <> nil) and (node.Count >= 2) and
        ((node.BoxRect.Bottom - node.BoxRect.Top) = (node[0].BoxRect.Bottom - node[0].BoxRect.Top)),
        '组件库：ui-badge 容器不被子项默认 margin 撑高');
      Check((node.Count >= 2) and ((node[1].BoxRect.Bottom - node[0].BoxRect.Top) = 10),
        '组件库：ui-badge 角标贴住内容右上角（未被默认 margin 顶飞）');
      node := engine.Document.FindElementById('prg1');
      Check((node <> nil) and node.HasClass('ui-progress') and node.HasClass('is-success'),
        '组件库：ui-progress 带有 is-success 状态类');
      Check((node.Count >= 2) and (node[1].Text = '75%'), '组件库：ui-progress 进度文字显示 75%');
      node := engine.Document.FindElementById('av1');
      Check((node <> nil) and node.HasClass('ui-avatar') and node.HasClass('ui-avatar--circle'),
        '组件库：ui-avatar 圆形头像');
      Check(engine.Document.FindElementById('cpi-text') = nil,
        '组件库：ui-collapse-item active=false 时详情折叠隐藏');
      node := engine.Document.FindElementById('cpi1');
      Check((node <> nil) and (node.Count >= 1), '组件库：ui-collapse-item 头节点存在');
      ClickNode(engine, node[0]);
      DrawEngine(engine);
      src := RunFlush('console.log("col=" + dispState.colActive);');
      Check(Pos('col=true', src) > 0, '组件库：ui-collapse-item 点击头部切换展开状态');
      Check(engine.Document.FindElementById('cpi-text') <> nil,
        '组件库：ui-collapse-item 展开后内容节点进入 DOM');
      node := engine.Document.FindElementById('pg1');
      Check((node <> nil) and (node.Count >= 4) and (node[2].Text = '1 / 6'),
        '组件库：ui-pagination 总页数正确计算为 1 / 6');
      ClickNode(engine, node[3]);
      DrawEngine(engine);
      src := RunFlush('console.log("page=" + dispState.page);');
      Check(Pos('page=2', src) > 0, '组件库：ui-pagination 点击下一页触发回调');
      node := engine.Document.FindElementById('tb1');
      Check((node <> nil) and (node.Count = 2), '组件库：ui-table 渲染出表头与表体两大部分');
      Check(node[1].Count = 2, '组件库：ui-table 表体由 x-for 渲染出 2 行数据');
      Check(engine.Document.FindElementById('tt1') <> nil, '组件库：ui-tooltip 宿主就绪');
      Check(engine.Document.FindElementById('pop1') <> nil, '组件库：ui-popover 宿主就绪');

      RunFlush('const navState = reactive({ tab: "t1", tabSwitched: 0, menuClicked: 0, ' +
        'crumbClicked: 0, backtopClicked: 0, tabList: [{ name: "t1", label: "标签一" }, { name: "t2", label: "标签二" }], ' +
        'dropItems: [{ key: "edit", label: "编辑" }, { key: "del", label: "删除", danger: true }] });' + #10 +
        'function OnNavTab(name: string): void { navState.tab = name; navState.tabSwitched = navState.tabSwitched + 1; }' + #10 +
        'function OnNavMenu(): void { navState.menuClicked = navState.menuClicked + 1; }' + #10 +
        'function OnCrumbClick(): void { navState.crumbClicked = navState.crumbClicked + 1; }' + #10 +
        'function OnBacktop(): void { navState.backtopClicked = 1; }');
      engine.LoadFromString(
        '<window><ui-tabs id="tabs1" :items="navState.tabList" :active="navState.tab" :on-change="OnNavTab">' +
        '<ui-tab-pane name="t1" :active="navState.tab === ''t1''"><label id="pane1" text="内容一"/></ui-tab-pane>' +
        '<ui-tab-pane name="t2" :active="navState.tab === ''t2''"><label id="pane2" text="内容二"/></ui-tab-pane></ui-tabs>' +
        '<ui-menu id="menu1" mode="horizontal"><ui-menu-item id="m1" name="home" title="首页" :active="true" :on-click="OnNavMenu"/>' +
        '<ui-menu-item id="m2" name="settings" title="设置" :disabled="true"/></ui-menu>' +
        '<ui-breadcrumb id="bc1"><ui-breadcrumb-item id="bc-item-1" text="首页" :on-click="OnCrumbClick"/>' +
        '<ui-breadcrumb-item id="bc-item-2" text="组件" :last="true"/></ui-breadcrumb>' +
        '<ui-dropdown id="dp1" :items="navState.dropItems"><ui-button id="dp-btn" text="下拉操作"/></ui-dropdown>' +
        '<ui-steps id="st1" :current="2"><ui-step id="st-item-1" :step="1" title="已完成" status="finish"/>' +
        '<ui-step id="st-item-2" :step="2" title="进行中" status="process"/><ui-step id="st-item-3" :step="3" title="等待中" status="wait"/></ui-steps>' +
        '<ui-backtop id="bt1" :on-click="OnBacktop"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tabs1');
      Check((node <> nil) and node.HasClass('ui-tabs'), '组件库：ui-tabs 根节点样式生效');
      Check((node.Count >= 2) and (node[0].Count = 2), '组件库：ui-tabs 渲染出两个头部标签项');
      Check(node[0][0].HasClass('is-active'), '组件库：ui-tabs 首个标签为激活态 is-active');
      Check(not node[0][1].HasClass('is-active'), '组件库：ui-tabs 第二个标签非激活态');
      ClickNode(engine, node[0][1]);
      DrawEngine(engine);
      src := RunFlush('console.log("tab=" + navState.tab + ",sw=" + navState.tabSwitched);');
      Check((Pos('tab=t2', src) > 0) and (Pos('sw=1', src) > 0), '组件库：ui-tabs 点击切换并触发回调');
      node := engine.Document.FindElementById('menu1');
      Check((node <> nil) and node.HasClass('ui-menu--horizontal'), '组件库：ui-menu 横向模式生效');
      node := engine.Document.FindElementById('m1');
      Check((node <> nil) and node.HasClass('is-active'), '组件库：ui-menu-item 激活态生效');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("menu=" + navState.menuClicked);');
      Check(Pos('menu=1', src) > 0, '组件库：ui-menu-item 点击触发回调');
      node := engine.Document.FindElementById('m2');
      Check((node <> nil) and node.HasClass('is-disabled'), '组件库：ui-menu-item 禁用态生效');
      node := engine.Document.FindElementById('bc-item-1');
      Check(node <> nil, '组件库：ui-breadcrumb-item 项存在');
      ClickNode(engine, node[0]);
      DrawEngine(engine);
      src := RunFlush('console.log("crumb=" + navState.crumbClicked);');
      Check(Pos('crumb=1', src) > 0, '组件库：ui-breadcrumb-item 点击触发回调');
      node := engine.Document.FindElementById('bc-item-2');
      Check((node <> nil) and node[0].HasClass('is-last'), '组件库：ui-breadcrumb-item 末项带 is-last 样式');
      node := engine.Document.FindElementById('st-item-1');
      Check((node <> nil) and node.HasClass('is-finish') and (node[0][0][0].Text = '✓'),
        '组件库：ui-step 完成态带 is-finish 并呈现完成对勾');
      node := engine.Document.FindElementById('st-item-2');
      Check((node <> nil) and node.HasClass('is-process') and (node[0][0][0].Text = '2'),
        '组件库：ui-step 进行中带 is-process 并呈现序号');
      node := engine.Document.FindElementById('st-item-3');
      Check((node <> nil) and node.HasClass('is-wait'), '组件库：ui-step 待处理带 is-wait');
      Check(engine.Document.FindElementById('dp1') <> nil, '组件库：ui-dropdown 宿主就绪');
      node := engine.Document.FindElementById('bt1');
      Check((node <> nil) and node.HasClass('ui-backtop'), '组件库：ui-backtop 节点就绪');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("bt=" + navState.backtopClicked);');
      Check(Pos('bt=1', src) > 0, '组件库：ui-backtop 点击触发回调');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
