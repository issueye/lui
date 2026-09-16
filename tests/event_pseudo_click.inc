{ M4：伪类状态机、点击与禁用 }

procedure TestPseudoAndClick;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  sink: TEventSink;
  btn: TXuiNode;
  cx, cy: Integer;
begin
  WriteLn('--- M4 伪类状态机 / 点击 / 禁用 ---');

  sink := TEventSink.Create;
  engine := NewTestEngine(fake);
  try
    engine.EventTarget := sink;
    engine.LoadFromString(
      '<window><panel id="card">' +
      '<button id="btn" text="ok" onclick="BtnClick" onmousedown="BtnMouseDown"/>' +
      '</panel></window>');
    engine.LoadStyleSheetFromString(
      '#btn { width:80px; height:30px; background-color:#0000ff; } ' +
      '#btn:hover { background-color:#ff0000; } ' +
      '#btn:active { background-color:#00ff00; } ' +
      '#btn:disabled { background-color:#888888; }');

    DrawEngine(engine);
    btn := engine.Document.FindElementById('btn');
    Check(btn <> nil, '按钮节点存在');
    Check(btn.Style.BgColor.B = $FF, '初始背景为蓝');

    cx := (btn.BoxRect.Left + btn.BoxRect.Right) div 2;
    cy := (btn.BoxRect.Top + btn.BoxRect.Bottom) div 2;
    engine.HandleMouseMove(cx, cy);
    DrawEngine(engine);
    Check(xpHover in btn.Pseudos, 'mousemove 设置 :hover');
    Check(btn.Style.BgColor.R = $FF, 'hover 样式生效（变红）');

    engine.HandleMouseDown(cx, cy);
    DrawEngine(engine);
    Check(xpActive in btn.Pseudos, 'mousedown 设置 :active');
    Check(xpFocus in btn.Pseudos, 'mousedown 设置 :focus（button 可聚焦）');
    Check(btn.Style.BgColor.G = $FF, 'active 样式生效（变绿）');
    Check(sink.MouseDowns = 1, 'onmousedown 绑定被调用');

    engine.HandleMouseUp(cx, cy);
    DrawEngine(engine);
    Check(sink.Clicks = 1, 'onclick 绑定被调用');
    Check(sink.LastNodeId = 'btn', 'Sender 为承载绑定的节点');
    Check(not (xpActive in btn.Pseudos), 'mouseup 清除 :active');
    Check(btn.Style.BgColor.R = $FF, '回到 hover 样式（红）');

    engine.SetDisabled(btn, True);
    DrawEngine(engine);
    Check(xpDisabled in btn.Pseudos, 'SetDisabled 设置 :disabled');
    Check(btn.Style.BgColor.R = $88, 'disabled 样式生效');
    engine.HandleMouseDown(cx, cy);
    engine.HandleMouseUp(cx, cy);
    Check(sink.Clicks = 1, 'disabled 节点不派发 click');

    engine.HandleMouseLeave;
    DrawEngine(engine);
    Check(not (xpHover in btn.Pseudos), '鼠标离开清除 :hover');
  finally
    engine.Free;
    sink.Free;
  end;
end;
