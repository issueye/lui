{ M4：事件绑定与引擎级兜底 }

procedure TestEventBindingFallback;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  sink: TEventSink;
  okNode, badNode: TXuiNode;
begin
  WriteLn('--- M4 事件绑定（RTTI 与兜底）---');

  sink := TEventSink.Create;
  engine := NewTestEngine(fake);
  try
    engine.EventTarget := sink;
    engine.LoadFromString(
      '<window>' +
      '  <button id="ok" text="A" onclick="BtnClick"/>' +
      '  <button id="bad" text="B" onclick="NoSuchMethod"/>' +
      '</window>');
    DrawEngine(engine);

    okNode := engine.Document.FindElementById('ok');
    badNode := engine.Document.FindElementById('bad');
    Check(okNode.Bindings.Count = 1, 'onclick 属性被记录为绑定');
    Check(TXuiEventBinding(okNode.Bindings[0]).Handler.Code <> nil,
      'published 方法经 MethodAddress 解析成功');
    Check(TXuiEventBinding(badNode.Bindings[0]).Handler.Code = nil,
      '不存在的方法保持未解析');

    ClickNode(engine, okNode);
    Check(sink.Clicks = 1, '已解析的绑定被触发');
    ClickNode(engine, badNode);
    Check(sink.Clicks = 1, '未解析的方法不触发回调');
    Check(sink.LastSender = okNode, '回调的 Sender = 承载绑定的节点');
    Check(sink.FallbackClicks = 0, '有绑定时不走兜底');

    // 兜底：无可用绑定时由引擎级 OnEvent 统一接管
    engine.OnEvent := @sink.EngineEvent;
    ClickNode(engine, badNode);
    Check(sink.FallbackClicks = 1, '无绑定时走 OnEvent 兜底');
    Check(sink.LastSender = badNode, '兜底回调收到命中节点');
  finally
    engine.Free;
    sink.Free;
  end;
end;
