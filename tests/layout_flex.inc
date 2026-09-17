{ M3：Flex 行列、交叉轴与间距 }

procedure TestFlexRow;
var
  doc: TXuiDocument;
  row, a, b: TXuiNode;
begin
  WriteLn('--- flex row ---');

  doc := PrepareDoc(
    '<window>' +
    '  <panel id="row"><panel id="a"/><panel id="b"/></panel>' +
    '</window>',
    '#row { display:flex; height:100px; column-gap:10px; } ' +
    '#a { width:50px; height:20px; } ' +
    '#b { width:60px; height:30px; }',
    300, 200);
  try
    row := doc.FindElementById('row');
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(row.BoxRect, 0, 0, 300, 100, 'row 高度由显式值决定');
    CheckRect(a.BoxRect, 0, 0, 50, 20, '主轴第一项在起点');
    CheckRect(b.BoxRect, 60, 0, 120, 30, '第二项相距一个 column-gap');
  finally
    doc.Free;
  end;
end;

procedure TestFlexAlign;
var
  doc: TXuiDocument;
  a, b: TXuiNode;
begin
  WriteLn('--- flex align-items ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; height:100px; align-items:center; } ' +
    '#a { width:40px; height:20px; } #b { width:40px; height:40px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(a.BoxRect, 0, 40, 40, 60, 'center：20 高项垂直居中');
    CheckRect(b.BoxRect, 40, 30, 80, 70, 'center：40 高项垂直居中');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/></panel></window>',
    '#row { display:flex; height:100px; align-items:stretch; } ' +
    '#a { width:40px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    CheckRect(a.BoxRect, 0, 0, 40, 100, 'stretch：auto 高度拉伸到容器高');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/></panel></window>',
    '#row { display:flex; height:100px; align-items:flex-end; } ' +
    '#a { width:40px; height:20px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    CheckRect(a.BoxRect, 0, 80, 40, 100, 'flex-end：贴交叉轴末端');
  finally
    doc.Free;
  end;
end;

procedure TestFlexColumn;
var
  doc: TXuiDocument;
  col, a, b: TXuiNode;
begin
  WriteLn('--- flex column ---');

  doc := PrepareDoc(
    '<window><panel id="col"><panel id="a"/><panel id="b"/></panel></window>',
    '#col { display:flex; flex-direction:column; width:200px; row-gap:10px; } ' +
    '#a { height:20px; } #b { height:30px; }',
    300, 200);
  try
    col := doc.FindElementById('col');
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(a.BoxRect, 0, 0, 200, 20, '纵向第一项');
    CheckRect(b.BoxRect, 0, 30, 200, 60, 'row-gap 生效');
    CheckRect(col.BoxRect, 0, 0, 200, 60, '容器高度 = 内容 + 间距');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="col"><panel id="a"/><panel id="b"/></panel></window>',
    '#col { display:flex; flex-direction:column; width:200px; height:100px; ' +
    'justify-content:center; } #a { height:20px; } #b { height:30px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(a.BoxRect, 0, 25, 200, 45, '纵向 center：首项下移');
    CheckRect(b.BoxRect, 0, 45, 200, 75, '纵向 center：次项紧随');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="col"><panel id="a"/></panel></window>',
    '#col { display:flex; flex-direction:column; width:200px; align-items:center; } ' +
    '#a { width:50px; height:20px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    CheckRect(a.BoxRect, 75, 0, 125, 20, '纵向 center：交叉轴水平居中');
  finally
    doc.Free;
  end;
end;
