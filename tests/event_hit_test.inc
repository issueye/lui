{ M4：命中测试 }

procedure TestHitTest;
var
  doc: TXuiDocument;
begin
  WriteLn('--- M4 命中测试 ---');

  doc := PrepareDoc(
    '<window>' +
    '  <panel id="box"><label id="in" text="x"/></panel>' +
    '  <panel id="hidden"/>' +
    '  <panel id="clip"><label id="deep" text="y"/></panel>' +
    '</window>',
    '#box { width:200px; height:100px; } ' +
    '#in { height:20px; margin:0; } ' +
    '#hidden { display:none; width:50px; height:50px; } ' +
    '#clip { overflow:hidden; width:100px; height:40px; } ' +
    '#deep { height:200px; margin:0; }',
    300, 200);
  try
    Check(XuiHitTest(doc.Root, 10, 10) = doc.FindElementById('in'), '最深节点优先命中');
    Check(XuiHitTest(doc.Root, 150, 50) = doc.FindElementById('box'), '容器空白处命中容器');
    Check(XuiHitTest(doc.Root, 10, 150) = doc.Root, 'display:none 不参与命中');
    Check(XuiHitTest(doc.Root, 50, 120) = doc.FindElementById('deep'),
      '裁剪区内溢出的子节点可命中');
    Check(XuiHitTest(doc.Root, 50, 160) = doc.Root,
      'overflow:hidden 之外不命中溢出的子节点');
  finally
    doc.Free;
  end;
end;
