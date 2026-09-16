{ M3：文本换行、尺寸约束与定位 }

procedure TestTextWrap;
var
  doc: TXuiDocument;
  t: TXuiNode;
begin
  WriteLn('--- 文本换行 ---');

  doc := PrepareDoc(
    '<window><label id="t" text="中文中文中文"/></window>',
    '#t { width:32px; margin:0; font-size:10px; line-height:2; }',
    300, 200);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 2, 'CJK 逐字断行为 2 行');
    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = '中文中文'), '第一行 4 个汉字');
    Check((Length(t.TextLines) > 1) and (t.TextLines[1] = '中文'), '第二行 2 个汉字');
    CheckRect(t.BoxRect, 0, 0, 32, 40, '行高 20 × 2 行');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><label id="t" text="hello world"/></window>',
    '#t { width:44px; margin:0; font-size:10px; line-height:2; }',
    300, 200);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 2, '拉丁按空格断行为 2 行');
    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = 'hello'), '第一行 hello');
    Check((Length(t.TextLines) > 1) and (t.TextLines[1] = 'world'), '第二行 world');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><label id="t" text="abcdefghij"/></window>',
    '#t { width:24px; margin:0; font-size:10px; line-height:2; }',
    300, 200);
  try
    t := doc.FindElementById('t');
    Check(Length(t.TextLines) = 1, '超长不可断词不硬切');
    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = 'abcdefghij'), '整词保留');
  finally
    doc.Free;
  end;
end;

procedure TestAutoMarginAndMinSize;
var
  doc: TXuiDocument;
  card, p: TXuiNode;
begin
  WriteLn('--- auto 外边距 / 最小尺寸 ---');

  doc := PrepareDoc(
    '<window><panel id="card"/></window>',
    '#card { width:320px; height:20px; margin:12px auto; }',
    360, 240);
  try
    card := doc.FindElementById('card');
    CheckRect(card.BoxRect, 20, 12, 340, 32, 'margin auto 水平居中');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="p"/></window>',
    '#p { min-width:100px; min-height:60px; }',
    300, 200);
  try
    p := doc.FindElementById('p');
    CheckRect(p.BoxRect, 0, 0, 300, 60, 'min-height 撑起 auto 高度');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="p"/></window>',
    '#p { width:50px; height:10px; min-width:120px; min-height:40px; }',
    300, 200);
  try
    p := doc.FindElementById('p');
    CheckRect(p.BoxRect, 0, 0, 120, 40, 'min-* 覆盖显式尺寸');
  finally
    doc.Free;
  end;
end;

procedure TestPositioning;
var
  doc: TXuiDocument;
  badge, badge2, p, c: TXuiNode;
begin
  WriteLn('--- 绝对 / 相对定位 ---');

  doc := PrepareDoc(
    '<window>' +
    '  <panel id="box">' +
    '    <panel id="badge"/><panel id="badge2"/>' +
    '  </panel>' +
    '</window>',
    '#box { position:relative; width:200px; height:100px; padding:10px; } ' +
    '#badge { position:absolute; left:5px; top:8px; width:20px; height:10px; } ' +
    '#badge2 { position:absolute; right:10px; bottom:5px; width:20px; height:10px; }',
    300, 200);
  try
    badge := doc.FindElementById('badge');
    badge2 := doc.FindElementById('badge2');
    CheckRect(badge.BoxRect, 5, 8, 25, 18, 'left/top 相对包含块 padding box');
    CheckRect(badge2.BoxRect, 170, 85, 190, 95, 'right/bottom 定位');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="p"><panel id="abs"/></panel></window>',
    '#p { height:50px; } ' +
    '#abs { position:absolute; left:7px; top:9px; width:10px; height:10px; }',
    300, 200);
  try
    doc.FindElementById('abs');
    CheckRect(doc.FindElementById('abs').BoxRect, 7, 9, 17, 19,
      '无定位祖先时回退根节点');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="p"><panel id="c"/></panel></window>',
    '#p { position:relative; left:10px; top:5px; height:30px; } ' +
    '#c { height:10px; }',
    300, 200);
  try
    p := doc.FindElementById('p');
    c := doc.FindElementById('c');
    CheckRect(p.BoxRect, 10, 5, 310, 35, 'relative 平移自身');
    CheckRect(c.BoxRect, 10, 5, 310, 15, 'relative 平移整个子树');
  finally
    doc.Free;
  end;
end;
