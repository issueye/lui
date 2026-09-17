{ M4：滚动与运行时 DOM }

procedure TestScroll;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  list: TXuiNode;
begin
  WriteLn('--- M4 滚动 ---');

  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window><panel id="list">' +
      '  <panel class="item"/><panel class="item"/><panel class="item"/>' +
      '  <panel class="item"/><panel class="item"/>' +
      '</panel></window>');
    engine.LoadStyleSheetFromString(
      '#list { overflow:hidden; width:200px; height:60px; } ' +
      '.item { height:40px; }');
    DrawEngine(engine);

    list := engine.Document.FindElementById('list');
    Check(Abs(list.ContentHeight - 200) < 0.5, '记录自然内容高 200');
    Check(list[0].BoxRect.Top = 0, '初始未滚动');

    Check(engine.HandleMouseWheel(10, 10, -120), '滚轮向下被处理');
    DrawEngine(engine);
    Check(Abs(list.ScrollTop - 48) < 0.5, '滚动一格 = 48px');
    Check(list[0].BoxRect.Top = -48, '子节点整体上移');

    engine.HandleMouseWheel(10, 10, -120);
    engine.HandleMouseWheel(10, 10, -120);
    engine.HandleMouseWheel(10, 10, -120);
    DrawEngine(engine);
    Check(Abs(list.ScrollTop - 140) < 0.5, '滚动到底部夹取在 maxScroll=140');

    engine.HandleMouseWheel(10, 10, 120);
    DrawEngine(engine);
    Check(Abs(list.ScrollTop - 92) < 0.5, '向上回滚 48px');

    engine.HandleMouseWheel(10, 10, 120);
    engine.HandleMouseWheel(10, 10, 120);
    DrawEngine(engine);
    Check(list.ScrollTop = 0, '顶部夹取在 0');
  finally
    engine.Free;
  end;
end;

procedure TestRuntimeDom;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  sink: TEventSink;
  list, item: TXuiNode;
begin
  WriteLn('--- M4 运行时 DOM ---');

  sink := TEventSink.Create;
  engine := NewTestEngine(fake);
  try
    engine.EventTarget := sink;
    engine.LoadFromString('<window><panel id="list"/></window>');
    engine.LoadStyleSheetFromString(
      '.item { height:20px; background-color:#112233; }');
    DrawEngine(engine);

    list := engine.Document.FindElementById('list');
    Check(list.Count = 0, '初始无子节点');

    item := engine.AddElement(list, '<panel class="item" onclick="BtnClick"/>');
    Check((item <> nil) and (list.Count = 1), 'AddElement 追加节点');
    DrawEngine(engine);
    Check(item.Style <> nil, '新增节点获得计算样式');
    Check(item.Style.BgColor.R = $11, '新增节点匹配 CSS 类');
    Check(item.BoxRect.Bottom - item.BoxRect.Top = 20, '新增节点参与布局');
    Check(TXuiEventBinding(item.Bindings[0]).Handler.Code <> nil,
      '新增节点的绑定被解析');

    ClickNode(engine, item);
    Check(sink.Clicks = 1, '新增节点的点击绑定生效');

    engine.SetDisabled(item, True);
    DrawEngine(engine);
    Check(xpDisabled in item.Pseudos, 'SetDisabled 生效');

    engine.ClearChildren(list);
    Check(list.Count = 0, 'ClearChildren 清空子节点');

    item := engine.AddElement(list, '<panel class="item"/>');
    engine.RemoveElement(item);
    Check(list.Count = 0, 'RemoveElement 移除节点');
  finally
    engine.Free;
    sink.Free;
  end;
end;
