{ M3：Flex 主轴分布与 grow }

procedure TestFlexJustify;
var
  doc: TXuiDocument;
  a, b: TXuiNode;
begin
  WriteLn('--- flex justify-content ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; justify-content:center; } ' +
    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',
    300, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 100, 0, 140, 10, 'center：整体居中');
    CheckRect(doc.FindElementById('b').BoxRect, 140, 0, 200, 10, 'center：第二项紧随');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; justify-content:flex-end; } ' +
    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',
    300, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 200, 0, 240, 10, 'flex-end：贴右');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; justify-content:space-between; } ' +
    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(a.BoxRect, 0, 0, 40, 10, 'space-between：首项贴左');
    CheckRect(b.BoxRect, 240, 0, 300, 10, 'space-between：末项贴右');
  finally
    doc.Free;
  end;

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; justify-content:space-around; } ' +
    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',
    300, 200);
  try
    CheckRect(doc.FindElementById('a').BoxRect, 50, 0, 90, 10, 'space-around：首项半间隙');
    CheckRect(doc.FindElementById('b').BoxRect, 190, 0, 250, 10, 'space-around：末项留白');
  finally
    doc.Free;
  end;
end;

procedure TestFlexGrow;
var
  doc: TXuiDocument;
  a, b: TXuiNode;
begin
  WriteLn('--- flex-grow ---');

  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; } ' +
    '#a { flex-grow:1; height:10px; } #b { flex-grow:3; height:10px; }',
    300, 200);
  try
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(a.BoxRect, 0, 0, 75, 10, 'grow 1/4 分得 75px');
    CheckRect(b.BoxRect, 75, 0, 300, 10, 'grow 3/4 分得 225px');
  finally
    doc.Free;
  end;
end;
