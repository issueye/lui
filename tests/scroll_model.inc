{ R2/R3：滚动容器、滚动条与横向滚动（引擎级 + 纯逻辑） }

procedure TestScrollOverflowParsing;
var
  s: TXuiStyle;
begin
  WriteLn('--- R2 滚动：overflow 解析与滚动容器策略 ---');
  s := TXuiStyle.Create;
  try
    ApplyDeclaration(s, 'overflow', 'auto', 14);
    Check(s.Overflow = xovAuto, 'overflow: auto 解析');
    Check(XuiIsScrollContainer(s), 'auto 是滚动容器');
    Check(XuiDrawsScrollbars(s), 'auto 绘制滚动条');

    ApplyDeclaration(s, 'overflow', 'scroll', 14);
    Check(s.Overflow = xovScroll, 'overflow: scroll 解析');
    Check(XuiDrawsScrollbars(s), 'scroll 绘制滚动条');

    ApplyDeclaration(s, 'overflow', 'hidden', 14);
    Check(s.Overflow = xovHidden, 'overflow: hidden 解析');
    Check(XuiIsScrollContainer(s) and (not XuiDrawsScrollbars(s)),
      'hidden 可滚动但保持不绘制滚动条（v1 语义）');

    ApplyDeclaration(s, 'overflow', 'visible', 14);
    Check((s.Overflow = xovVisible) and (not XuiIsScrollContainer(s)),
      'overflow: visible 不是滚动容器');
  finally
    s.Free;
  end;
end;

procedure TestScrollMetrics;
var
  doc: TXuiDocument;
  box: TXuiNode;
begin
  WriteLn('--- R2/R3 滚动：范围记录与偏移夹取 ---');

  // 横向溢出：记录自然内容宽，ScrollLeft 夹取到最大滚动量
  doc := PrepareDoc(
    '<window><panel id="box"><label id="wide" text="x"/></panel></window>',
    '#box { overflow:auto; width:100px; height:50px; } ' +
    '#wide { width:300px; height:20px; margin:0; }',
    300, 200);
  try
    box := doc.FindElementById('box');
    Check(Abs(box.ContentWidth - 300) < 0.5,
      Format('ContentWidth 记录自然内容宽 300 [实际 %.1f]', [box.ContentWidth]));
    Check(Abs(XuiMaxScrollLeft(box) - 200) < 0.5, '横向最大滚动量 = 内容宽 - 内容盒宽');

    box.ScrollLeft := 500;
    LayoutDocument(doc, 300, 200, @Measurer.Measure);
    Check(Abs(box.ScrollLeft - 200) < 0.5, 'ScrollLeft 夹取到最大值');

    box.ScrollLeft := -10;
    LayoutDocument(doc, 300, 200, @Measurer.Measure);
    Check(box.ScrollLeft = 0, 'ScrollLeft 负值夹取为 0');

    // 内容缩小后偏移必须收敛（避免残留空白视口）
    box.ScrollLeft := 200;
    LayoutDocument(doc, 300, 200, @Measurer.Measure);
    doc.FindElementById('wide').Style.Width.Kind := xlkPx;
    doc.FindElementById('wide').Style.Width.Value := 40;
    LayoutDocument(doc, 300, 200, @Measurer.Measure);
    Check(box.ScrollLeft = 0, '内容缩小后 ScrollLeft 收敛为 0');
  finally
    doc.Free;
  end;

  // 内容不溢出：双向滚动量均为 0
  doc := PrepareDoc(
    '<window><panel id="box"><label id="fit" text="x"/></panel></window>',
    '#box { overflow:auto; width:100px; height:50px; } #fit { margin:0; }',
    300, 200);
  try
    box := doc.FindElementById('box');
    Check((XuiMaxScrollLeft(box) = 0) and (XuiMaxScrollTop(box) = 0),
      '内容不溢出时双向滚动量均为 0');
  finally
    doc.Free;
  end;
end;

procedure TestScrollBarsAndWheel;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  box, child: TXuiNode;
  bars: TXuiScrollBarLayout;
  fills: Integer;
begin
  WriteLn('--- R2/R3 滚动：滚动条绘制、滚轮与命中 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><panel id="box"><label id="c" text="row"/></panel></window>');
    engine.LoadStyleSheetFromString(
      '#box { overflow:auto; width:100px; height:50px; } ' +
      '#c { width:300px; height:200px; margin:0; }');
    DrawEngine(engine);
    box := engine.Document.FindElementById('box');
    child := engine.Document.FindElementById('c');

    bars := XuiScrollBarLayout(box);
    Check(bars.ShowV and bars.ShowH, 'auto + 双向溢出：纵横滚动条都显示');
    Check(bars.VTrack.Right = box.PaddingBox.Right, '纵向滚动条贴 padding box 右边');
    Check(bars.HTrack.Bottom = box.PaddingBox.Bottom, '横向滚动条贴 padding box 下边');
    Check((bars.VThumb.Right - bars.VThumb.Left) = XuiScrollbarThickness,
      '滑块厚度 = 滚动条厚度');
    Check(bars.VThumb.Top = bars.VTrack.Top, '未滚动时滑块贴轨道顶端');

    fake.Clear;
    DrawEngine(engine);
    fills := fake.CountOf('fill');
    Check(fills >= 4, Format('滚动条以填充绘制轨道与滑块（fill=%d）', [fills]));

    engine.HandleMouseWheel(10, 10, -120);
    DrawEngine(engine);
    Check(box.ScrollTop > 0, '滚轮纵向滚动生效');
    Check(box.ScrollLeft = 0, '纵向优先：横向不动');
    bars := XuiScrollBarLayout(box);
    Check(bars.VThumb.Top > bars.VTrack.Top, '滚动后滑块随偏移下移');

    engine.HandleMouseWheel(10, 10, -120, [xssShift]);
    DrawEngine(engine);
    Check(box.ScrollLeft > 0, 'Shift+滚轮横向滚动');

    // 命中：滚动条条带内不命中子节点；内容区仍命中子节点
    Check(engine.HitTest(bars.VThumb.Left + 2, box.PaddingBox.Top + 2) <> child,
      '纵向滚动条条带内不命中内容子节点');
    Check(engine.HitTest(box.PaddingBox.Left - 0, box.PaddingBox.Top + 2) = child,
      '内容区仍命中内容子节点');
  finally
    engine.Free;
  end;

  // 常显（scroll）：内容不溢出也显示滚动条；hidden：不显示保持 v1
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window>' +
      '<panel id="s1"><label text="a"/></panel>' +
      '<panel id="h1"><label text="b"/></panel></window>');
    engine.LoadStyleSheetFromString(
      '#s1 { overflow:scroll; width:80px; height:40px; } ' +
      '#h1 { overflow:hidden; width:80px; height:40px; }');
    DrawEngine(engine);
    Check(XuiScrollBarLayout(engine.Document.FindElementById('s1')).ShowV,
      'overflow:scroll 内容不溢出也显示滚动条');
    Check(not XuiScrollBarLayout(engine.Document.FindElementById('h1')).ShowV,
      'overflow:hidden 不显示滚动条（v1 语义不变）');
  finally
    engine.Free;
  end;

  // 仅横向溢出：滚轮降级为横向滚动
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><panel id="box"><label id="c" text="x"/></panel></window>');
    engine.LoadStyleSheetFromString(
      '#box { overflow:auto; width:100px; height:80px; } ' +
      '#c { width:300px; height:20px; margin:0; }');
    DrawEngine(engine);
    box := engine.Document.FindElementById('box');
    Check(not XuiScrollBarLayout(box).ShowH or (XuiMaxScrollTop(box) = 0),
      '横向溢出时纵向无余量');
    engine.HandleMouseWheel(10, 10, -120);
    DrawEngine(engine);
    Check((box.ScrollTop = 0) and (box.ScrollLeft > 0),
      '纵向无余量时滚轮降级为横向滚动');
  finally
    engine.Free;
  end;
end;

procedure TestScrollLeftScriptBridge;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  box: TXuiNode;
begin
  WriteLn('--- R3 滚动：脚本 scrollLeft 桥 ---');
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  bridge := TXuiDomBridge.Create(engine, script);
  try
    bridge.Install;
    engine.AttachScript(script);
    script.Interp.OnLog := @sink.HandleLog;
    script.OnError := @sink.HandleError;
    engine.LoadFromString('<window><panel id="box"><label id="c" text="x"/></panel></window>');
    engine.LoadStyleSheetFromString(
      '#box { overflow:auto; width:100px; height:50px; } ' +
      '#c { width:300px; height:20px; margin:0; }');
    DrawEngine(engine);
    box := engine.Document.FindElementById('box');

    script.Run('document.find("box").scrollLeft = 40;', 'sl.ts');
    script.FlushReactive;
    DrawEngine(engine);
    Check(Abs(box.ScrollLeft - 40) < 0.5, '脚本写 scrollLeft 生效');
    Check(script.ErrorCount = 0, '脚本 scrollLeft 写入无错误');

    sink.Log.Clear;
    script.Run('console.log("sl=" + document.find("box").scrollLeft);', 'sl2.ts');
    script.FlushReactive;
    Check(Pos('sl=40', sink.Log.Text) > 0, '脚本读 scrollLeft 与写入一致');
  finally
    bridge.Free;
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
