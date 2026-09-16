{ M4：RTTI、事件测试基础设施与输入辅助 }

type
  {$M+}
  TRttiProbeSink = class
  published
    procedure ProbeMethod(Sender: TObject);
  end;
  {$M-}

procedure TRttiProbeSink.ProbeMethod(Sender: TObject);
begin
  // 探针：只验证能否按名字解析
end;

procedure TestRttiProbe;
var
  sink: TRttiProbeSink;
  m: TMethod;
begin
  WriteLn('--- RTTI 探针（事件绑定前提）---');

  sink := TRttiProbeSink.Create;
  try
    m.Code := sink.MethodAddress('ProbeMethod');
    m.Data := sink;
    Check(m.Code <> nil, 'MethodAddress 解析 published 方法');
    Check(sink.MethodAddress('NotExist') = nil, '未声明的方法返回 nil');
    Check(Assigned(TNotifyEvent(m)), 'TMethod 可转为 TNotifyEvent');
  finally
    sink.Free;
  end;
end;

type
  {$M+}
  TEventSink = class
  public
    Clicks: Integer;
    MouseDowns: Integer;
    FallbackClicks: Integer;
    Inputs: Integer;
    Enters: Integer;
    LastInputText: string;
    LastSender: TObject;
    LastNodeId: string;
    procedure EngineEvent(ANode: TXuiNode; AKind: TXuiEventKind);
    published
      procedure BtnClick(Sender: TObject);
      procedure BtnMouseDown(Sender: TObject);
      procedure InputChanged(Sender: TObject);
      procedure EnterPressed(Sender: TObject);
  end;
  {$M-}

procedure TEventSink.InputChanged(Sender: TObject);
begin
  Inc(Inputs);
  if Sender is TXuiNode then
    LastInputText := TXuiNode(Sender).Text;
end;

procedure TEventSink.EnterPressed(Sender: TObject);
begin
  Inc(Enters);
end;

procedure TEventSink.BtnClick(Sender: TObject);
begin
  Inc(Clicks);
  LastSender := Sender;
  if Sender is TXuiNode then
    LastNodeId := TXuiNode(Sender).Id;
end;

procedure TEventSink.BtnMouseDown(Sender: TObject);
begin
  Inc(MouseDowns);
end;

// 兜底回调（引擎 OnEvent）：只统计 click
procedure TEventSink.EngineEvent(ANode: TXuiNode; AKind: TXuiEventKind);
begin
  if AKind = xevClick then
  begin
    Inc(FallbackClicks);
    LastSender := ANode;
  end;
end;

// 引擎 + 假渲染器（渲染器所有权归引擎）
function NewTestEngine(out AFake: TFakeRenderer): TXuiEngine;
begin
  AFake := TFakeRenderer.Create;
  Result := TXuiEngine.Create;
  Result.Renderer := AFake;
end;

const
  TestViewport: TRect = (Left: 0; Top: 0; Right: 300; Bottom: 200);

procedure DrawEngine(AEngine: TXuiEngine);
begin
  AEngine.Draw(nil, TestViewport);
end;

procedure ClickNode(AEngine: TXuiEngine; ANode: TXuiNode);
var
  cx, cy: Integer;
begin
  cx := (ANode.BoxRect.Left + ANode.BoxRect.Right) div 2;
  cy := (ANode.BoxRect.Top + ANode.BoxRect.Bottom) div 2;
  AEngine.HandleMouseMove(cx, cy);
  AEngine.HandleMouseDown(cx, cy);
  AEngine.HandleMouseUp(cx, cy);
end;
