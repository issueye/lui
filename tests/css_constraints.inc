{ R7：CSS 尺寸约束（max-width / max-height）与 flex-shrink / flex-wrap }

procedure TestCssMaxWidth;
var
  doc: TXuiDocument;
  a, b: TXuiNode;
begin
  WriteLn('--- R7：max-width ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/></panel></window>',
    '#row { display:flex; } #a { width:400px; height:10px; max-width:120px; }',
    300, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 0, 0, 120, 10,
      '显式 width 被 max-width 夹取');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="col"><panel id="a"/></panel></window>',
    '#col { display:flex; flex-direction:column; } #a { height:10px; max-width:150px; }',
    400, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 0, 0, 150, 10,
      '列方向 stretch 交叉轴被 max-width 夹取');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; } ' +
    '#a { flex-grow:1; max-width:80px; height:10px; } #b { flex-grow:1; height:10px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    Check(a.BoxRect.Right - a.BoxRect.Left = 80,
      Format('grow 分配后仍受 max-width 限制 [实际 %d]',
        [a.BoxRect.Right - a.BoxRect.Left]));
    Check(b.BoxRect.Right - b.BoxRect.Left = 150,
      Format('另一项按 grow 分得 150 [实际 %d]',
        [b.BoxRect.Right - b.BoxRect.Left]));
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="a"/></window>',
    '#a { width:100px; height:10px; max-width:50%; }',
    400, 200);
  try
    Check(not doc.FindElementById('a').Style.MaxWidth.IsAuto,
      'max-width 百分比被解析（非 auto）');
    Check(doc.FindElementById('a').Style.MaxWidth.Kind = xlkPercent,
      'max-width:50% 记录为百分比');
  finally
    doc.Free;
  end;
end;

procedure TestCssMaxHeight;
var
  doc: TXuiDocument;
begin
  WriteLn('--- R7：max-height ---');

  doc := PrepareDoc(
    '<window><panel id="box"><panel id="inner"/></panel></window>',
    '#inner { height:200px; } #box { max-height:60px; }',
    200, 300);
  try
    CheckRect(doc.FindElementById('box').BoxRect, 0, 0, 200, 60,
      'max-height 夹取自动高度');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="box"/></window>',
    '#box { height:200px; max-height:80px; }',
    200, 300);
  try
    CheckRect(doc.FindElementById('box').BoxRect, 0, 0, 200, 80,
      'max-height 覆盖显式 height');
  finally
    doc.Free;
  end;
end;

procedure TestFlexShrink;
var
  doc: TXuiDocument;
  a, b: TXuiNode;
begin
  WriteLn('--- R7：flex-shrink ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; } ' +
    '#a { width:200px; height:10px; } #b { width:200px; height:10px; }',
    300, 100);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    Check(a.BoxRect.Right - a.BoxRect.Left = 150,
      Format('默认 shrink 平均收缩 [实际 %d]', [a.BoxRect.Right - a.BoxRect.Left]));
    Check(b.BoxRect.Right - b.BoxRect.Left = 150,
      Format('第二项同样收缩到 150 [实际 %d]', [b.BoxRect.Right - b.BoxRect.Left]));
    Check(a.BoxRect.Right = 150,
      Format('收缩后首项右边界为 150 [实际 %d]', [a.BoxRect.Right]));
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; } ' +
    '#a { width:200px; height:10px; flex-shrink:0; } #b { width:200px; height:10px; }',
    300, 100);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    Check(a.BoxRect.Right - a.BoxRect.Left = 200,
      Format('flex-shrink:0 不收缩 [实际 %d]', [a.BoxRect.Right - a.BoxRect.Left]));
    Check(b.BoxRect.Right - b.BoxRect.Left = 100,
      Format('收缩全部落在第二项 [实际 %d]', [b.BoxRect.Right - b.BoxRect.Left]));
  finally
    doc.Free;
  end;

  // min-width 兜底：收缩不会小于 min-width
  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; } ' +
    '#a { width:200px; height:10px; min-width:180px; } #b { width:200px; height:10px; }',
    300, 100);
  try
    a := doc.FindElementById('a');
    Check(a.BoxRect.Right - a.BoxRect.Left = 180,
      Format('收缩被 min-width 兜住 [实际 %d]', [a.BoxRect.Right - a.BoxRect.Left]));
  finally
    doc.Free;
  end;
end;

procedure TestFlexWrap;
var
  doc: TXuiDocument;
  row: TXuiNode;
begin
  WriteLn('--- R7：flex-wrap ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/><panel id="c"/></panel></window>',
    '#row { display:flex; flex-wrap:wrap; column-gap:10px; row-gap:6px; } ' +
    '#a, #b, #c { width:120px; height:20px; }',
    200, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 0, 0, 120, 20, 'wrap：首行首项');
    CheckRect(doc.FindElementById('b').BoxRect, 0, 26, 120, 46, 'wrap：第二项换行');
    CheckRect(doc.FindElementById('c').BoxRect, 0, 52, 120, 72, 'wrap：第三项再换行');
    row := doc.FindElementById('row');
    Check(row.BoxRect.Bottom - row.BoxRect.Top = 72,
      Format('wrap 容器高度为三行之和 [实际 %d]',
        [row.BoxRect.Bottom - row.BoxRect.Top]));
  finally
    doc.Free;
  end;

  // 装得下时不换行：两项并排在同一行
  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; flex-wrap:wrap; column-gap:10px; row-gap:6px; } ' +
    '#a, #b { width:80px; height:20px; }',
    200, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 0, 0, 80, 20, 'wrap：装得下保持单行（首项）');
    CheckRect(doc.FindElementById('b').BoxRect, 90, 0, 170, 20, 'wrap：装得下保持单行（次项）');
  finally
    doc.Free;
  end;

  // 默认 nowrap：溢出而不是换行
  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/><panel id="c"/></panel></window>',
    '#row { display:flex; column-gap:10px; } ' +
    '#a, #b, #c { width:120px; height:20px; flex-shrink:0; }',
    200, 200);
  try
    CheckRect(doc.FindElementById('b').BoxRect, 130, 0, 250, 20, 'nowrap：第二项仍在首行并溢出');
    CheckRect(doc.FindElementById('c').BoxRect, 260, 0, 380, 20, 'nowrap：第三项溢出');
  finally
    doc.Free;
  end;
end;

procedure TestFlexShorthandAndWrapStyle;
var
  doc: TXuiDocument;
  x: TXuiNode;
begin
  WriteLn('--- R7：flex 简写与 flex-wrap 解析 ---');

  doc := PrepareDoc(
    '<window><panel id="x"/></window>',
    '#x { flex:1 2 100px; }',
    200, 100);
  try
    x := doc.FindElementById('x');
    Check(x.Style.FlexGrow = 1, 'flex 简写解析 grow');
    Check(x.Style.FlexShrink = 2, 'flex 简写解析 shrink');
    Check((not x.Style.FlexBasis.IsAuto) and (Round(x.Style.FlexBasis.Value) = 100),
      'flex 简写解析 basis');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="x"/></window>',
    '#x { flex:1 0 auto; flex-wrap:wrap; }',
    200, 100);
  try
    x := doc.FindElementById('x');
    Check(x.Style.FlexShrink = 0, 'flex 简写 shrink 可为 0');
    Check(x.Style.FlexBasis.IsAuto, 'flex 简写 basis=auto');
    Check(x.Style.FlexWrap = xfwWrap, 'flex-wrap:wrap 记录到样式');
  finally
    doc.Free;
  end;
end;
