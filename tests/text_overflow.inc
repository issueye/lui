{ R7：letter-spacing、white-space:nowrap、text-overflow:ellipsis }

procedure TestLetterSpacing;
var
  doc: TXuiDocument;
  t: TXuiNode;
begin
  WriteLn('--- R7：letter-spacing ---');

  // 假测量器：8px/字符；行内 label 的主轴尺寸即文本宽度
  doc := PrepareDoc(
    '<window><panel id="row"><label id="t" text="abcd"/></panel></window>',
    '#row { display:flex; } #t { white-space:nowrap; font-size:14px; }',
    400, 100);
  try
    t := doc.FindElementById('t');
    Check(t.BoxRect.Right - t.BoxRect.Left = 32,
      Format('无字距时宽度为 4×8=32 [实际 %d]', [t.BoxRect.Right - t.BoxRect.Left]));
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><label id="t" text="abcd"/></panel></window>',
    '#row { display:flex; } #t { white-space:nowrap; letter-spacing:4px; }',
    400, 100);
  try
    t := doc.FindElementById('t');
    Check(t.BoxRect.Right - t.BoxRect.Left = 44,
      Format('字距 4px 时宽度为 32+4×3=44 [实际 %d]', [t.BoxRect.Right - t.BoxRect.Left]));
  finally
    doc.Free;
  end;

  // letter-spacing 是继承属性：父级声明对子 label 生效
  doc := PrepareDoc(
    '<window><panel id="row"><panel id="mid"><label id="t" text="abcd"/></panel></panel></window>',
    '#row { display:flex; } #mid { letter-spacing:4px; } #t { white-space:nowrap; }',
    400, 100);
  try
    t := doc.FindElementById('t');
    Check(t.Style.LetterSpacing = 4, 'letter-spacing 被子节点继承');
    Check(t.BoxRect.Right - t.BoxRect.Left = 44,
      Format('继承字距后宽度为 44 [实际 %d]', [t.BoxRect.Right - t.BoxRect.Left]));
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="t" text="abcd"/></window>',
    '#t { letter-spacing:normal; }',
    200, 100);
  try
    Check(doc.FindElementById('t').Style.LetterSpacing = 0, 'letter-spacing:normal 归零');
  finally
    doc.Free;
  end;
end;

procedure TestWhiteSpaceAndOverflow;
var
  doc: TXuiDocument;
  t: TXuiNode;
begin
  WriteLn('--- R7：white-space / text-overflow ---');

  // 默认 normal：窄容器里 CJK 逐字软换行成两行（5 字/行）
  doc := PrepareDoc(
    '<window><panel id="t" text="中文中文中文"/></window>',
    '#t { width:40px; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 2, Format('默认换行成 2 行 [实际 %d]', [Length(t.TextLines)]));
    Check((Length(t.TextLines) = 2) and (t.TextLines[0] = '中文中文中'),
      '第一行填满可用宽度');
  finally
    doc.Free;
  end;

  // nowrap：保持一行，内容溢出（不裁剪、不加省略号）
  doc := PrepareDoc(
    '<window><panel id="t" text="abcdefgh"/></window>',
    '#t { width:40px; white-space:nowrap; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 1, 'nowrap 只有一行');
    Check((Length(t.TextLines) = 1) and (t.TextLines[0] = 'abcdefgh'),
      'nowrap 无省略号时保留完整文本');
  finally
    doc.Free;
  end;

  // nowrap + ellipsis：截断到可用宽度并加省略号
  doc := PrepareDoc(
    '<window><panel id="t" text="abcdefghij"/></window>',
    '#t { width:40px; white-space:nowrap; text-overflow:ellipsis; overflow:hidden; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 1, 'ellipsis 仍为一行');
    Check((Length(t.TextLines) = 1) and (t.TextLines[0] = 'abcd…'),
      Format('ellipsis 截断为 4 字符 + 省略号 [实际 %s]',
        [t.TextLines[0]]));
  finally
    doc.Free;
  end;

  // 不可断长串在 normal 模式下同样按 ellipsis 截断（否则会溢出容器）
  doc := PrepareDoc(
    '<window><panel id="t" text="abcdefghij"/></window>',
    '#t { width:40px; text-overflow:ellipsis; overflow:hidden; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check((Length(t.TextLines) = 1) and (t.TextLines[0] = 'abcd…'),
      Format('不可断长串被 ellipsis 截断 [实际 %s]', [t.TextLines[0]]));
  finally
    doc.Free;
  end;

  // 装得下时不加省略号
  doc := PrepareDoc(
    '<window><panel id="t" text="abc"/></window>',
    '#t { width:80px; white-space:nowrap; text-overflow:ellipsis; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check((Length(t.TextLines) = 1) and (t.TextLines[0] = 'abc'),
      '装得下时不做省略');
  finally
    doc.Free;
  end;

  // CJK + ellipsis：按码点截断，不切半字符
  doc := PrepareDoc(
    '<window><panel id="t" text="中文中文中文"/></window>',
    '#t { width:40px; white-space:nowrap; text-overflow:ellipsis; }',
    200, 100);
  try
    t := doc.FindElementById('t');
    Check((Length(t.TextLines) = 1) and (t.TextLines[0] = '中文中文…'),
      Format('CJK 按码点截断 [实际 %s]', [t.TextLines[0]]));
  finally
    doc.Free;
  end;
end;
