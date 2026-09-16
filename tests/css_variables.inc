{ M8：CSS 变量 }

procedure TestCssVariables;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  node: TXuiNode;
begin
  WriteLn('--- CSS 变量（M8）---');

  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window>' +
      '<panel id="p1"><label id="l1" text="a"/>' +
      '<panel id="p2"><label id="l2" text="b"/></panel></panel>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      'window { --ui-brand: #1677ff; --ui-gap: 6px; } ' +
      '#p1 { background-color: var(--ui-brand); } ' +
      '#p2 { background-color: var(--missing, #ff0000); margin-top: var(--ui-gap); } ' +
      '#l1 { border: 1px solid var(--ui-brand); }');
    engine.Draw(nil, Rect(0, 0, 300, 200));

    node := engine.Document.FindElementById('p1');
    Check((node.Style.BgColor.R = $16) and (node.Style.BgColor.G = $77) and
      (node.Style.BgColor.B = $FF), 'var()：取祖先定义的变量（继承可见）');
    node := engine.Document.FindElementById('l1');
    Check(node.Style.BorderColor.R = $16, 'var()：简写值内也能替换（border 颜色）');
    node := engine.Document.FindElementById('p2');
    Check(node.Style.BgColor.R = $FF, 'var()：未定义变量使用回退值');
    Check(node.Style.Margin.Top.Value = 6, 'var()：长度值替换（margin-top）');

    engine.LoadStyleSheetFromString('window { --ui-brand: #00ff00; }');
    engine.Draw(nil, Rect(0, 0, 300, 200));
    node := engine.Document.FindElementById('p1');
    Check(node.Style.BgColor.G = $FF, '主题覆盖：后加载样式表重定义变量后使用处随之变化');
  finally
    engine.Free;
  end;
end;
