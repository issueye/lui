{ M3：布局契约（组件库依赖的稳定行为） }

procedure TestLayoutContract;
var
  doc: TXuiDocument;
  box, child, row, a, b: TXuiNode;
begin
  WriteLn('--- 布局契约 ---');

  // 显式 width/height 按默认 border-box 解释；padding/border 不会把外框撑大。
  doc := PrepareDoc(
    '<window><panel id="box"><panel id="child"/></panel></window>',
    '#box { width:100px; height:60px; padding:10px; border:2px solid #000; } ' +
    '#child { width:50%; height:20px; }',
    300, 200);
  try
    box := doc.FindElementById('box');
    child := doc.FindElementById('child');
    CheckRect(box.BoxRect, 0, 0, 100, 60, '默认 border-box 保持显式外框尺寸');
    Check((box.PaddingBox.Right - box.PaddingBox.Left) = 96,
      'PaddingBox 扣除两侧 border');
    Check((box.ContentBox.Right - box.ContentBox.Left) = 76,
      'ContentBox 再扣除两侧 padding');
    CheckRect(child.BoxRect, 12, 12, 50, 32,
      '百分比宽度相对父内容盒，子节点从内容原点开始');
  finally
    doc.Free;
  end;

  // Flex row 的 gap 和交叉轴居中是组件库 Row/Space 等组件的基础契约。
  doc := PrepareDoc(
    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',
    '#row { display:flex; width:200px; height:40px; column-gap:10px; align-items:center; } ' +
    '#a { width:40px; height:10px; } #b { width:60px; height:20px; }',
    300, 200);
  try
    row := doc.FindElementById('row');
    a := doc.FindElementById('a');
    b := doc.FindElementById('b');
    CheckRect(row.BoxRect, 0, 0, 200, 40, 'Flex 容器显式尺寸稳定');
    CheckRect(a.BoxRect, 0, 15, 40, 25, 'Flex 交叉轴居中');
    CheckRect(b.BoxRect, 50, 10, 110, 30, 'Flex gap 位于相邻项目之间');
  finally
    doc.Free;
  end;
end;
