{ M10 conversational agent demo and deterministic fake OpenAI endpoint. }

procedure AgentFakeHttp(AReq: TXuiIoRequest; ARes: TXuiIoResult); forward;

procedure TestAgentPage;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node, msgNode: TXuiNode;
  errs, pumpClock: Integer;
  xmlPath, cssPath: string;

  procedure Pump(Times: Integer);
  var
    t: Integer;
  begin
    for t := 1 to Times do
    begin
      Inc(pumpClock, 20);
      engine.Tick(1000 + QWord(pumpClock));
      DrawEngine(engine);
    end;
  end;

  function TextOf(ANode: TXuiNode): string;
  var
    k: Integer;
  begin
    Result := '';
    if ANode = nil then Exit;
    Result := ANode.Text;
    for k := 0 to ANode.Count - 1 do
      Result := Result + ' ' + TextOf(ANode[k]);
  end;

  procedure CollectMsgs(ANode: TXuiNode; AList: TList);
  var
    k: Integer;
  begin
    if ANode = nil then Exit;
    if ANode.HasClass('msg') then
      AList.Add(ANode)
    else
      for k := 0 to ANode.Count - 1 do
        CollectMsgs(ANode[k], AList);
  end;

  function LastMessage: TXuiNode;
  var
    list: TList;
  begin
    Result := nil;
    list := TList.Create;
    try
      CollectMsgs(engine.Document.FindElementById('agent-scroll'), list);
      if list.Count > 0 then
        Result := TXuiNode(list[list.Count - 1]);
    finally
      list.Free;
    end;
  end;

begin
  WriteLn('--- M10 演示页（demo/agent）---');
  xmlPath := DemoFilePath('agent.xml');
  if xmlPath = '' then
  begin
    WriteLn('SKIP  未找到 demo/agent.xml');
    Exit;
  end;
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  bridge := TXuiDomBridge.Create(engine, script);
  try
    bridge.Install;
    engine.AttachScript(script);
    script.OnError := @sink.HandleError;
    script.Interp.OnLog := @sink.HandleLog;
    cssPath := DemoFilePath('agent-light.css');
    if cssPath <> '' then
      engine.LoadStyleSheetFromFile(cssPath);
    engine.LoadFromFile(xmlPath);
    pumpClock := 0;
    DrawEngine(engine);
    Check(script.ErrorCount = 0, '演示页 agent：整页加载无脚本错误');
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('lui Agent', TextOf(msgNode)) > 0),
      '演示页 agent：首屏问候已渲染');

    errs := script.ErrorCount;
    script.CallGlobal('UsePrompt', [script.Str('计算 12*(3+4)')]);
    script.FlushReactive;
    Pump(400);
    Check(script.ErrorCount = errs, '演示页 agent：离线工具回路无脚本错误');
    node := engine.Document.FindElementById('agent-status');
    Check((node <> nil) and (Pos('完成', node.Text) > 0),
      '演示页 agent：离线流程结束（状态=完成）');
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('84', TextOf(msgNode)) > 0),
      '演示页 agent：计算器工具结果进入回答（12*(3+4)=84）');
    Check((msgNode <> nil) and (msgNode.Count > 0) and
      (Pos('计算器', TextOf(msgNode)) > 0) and (Pos('12*(3+4)', TextOf(msgNode)) > 0),
      '演示页 agent：工具步骤卡展示工具名与参数');

    script.CallGlobal('UsePrompt', [script.Str('算一下 99*99 再告诉我时间')]);
    script.FlushReactive;
    Pump(400);
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('9801', TextOf(msgNode)) > 0),
      '演示页 agent：大数乘法不走 32 位截断（99*99=9801）');
    Check((msgNode <> nil) and (Pos('当前时间', TextOf(msgNode)) > 0),
      '演示页 agent：多意图规划命中时间工具');

    script.CallGlobal('UsePrompt', [script.Str('随便说点什么')]);
    script.FlushReactive;
    Pump(400);
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('可以调用工具', TextOf(msgNode)) > 0),
      '演示页 agent：无工具命中时给出兜底提示');

    script.IO.SyncMode := True;
    script.IO.Executor := @AgentFakeHttp;
    script.CallGlobal('ToggleOnline', []);
    script.FlushReactive;
    errs := script.ErrorCount;
    script.CallGlobal('UsePrompt', [script.Str('计算 5+5')]);
    script.FlushReactive;
    Pump(400);
    Check(script.ErrorCount = errs, '演示页 agent：在线档 agent loop 无脚本错误');
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('10', TextOf(msgNode)) > 0),
      '演示页 agent：在线 tool_calls 经本地执行后回填并给出终答');
  finally
    bridge.Free;
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;

procedure AgentFakeHttp(AReq: TXuiIoRequest; ARes: TXuiIoResult);
begin
  ARes.Ok := True;
  ARes.Status := 200;
  ARes.Headers := 'Content-Type: application/json';
  if Pos('tool_call_id', AReq.Body) > 0 then
    ARes.Data := '{"choices":[{"message":{"role":"assistant","content":"在线回答：结果是 10。"}}]}'
  else
    ARes.Data := '{"choices":[{"message":{"role":"assistant","content":"",' +
      '"tool_calls":[{"id":"call_1","type":"function","function":{' +
      '"name":"calculator","arguments":"{\"expr\":\"5+5\"}"}}]}}]}';
end;
