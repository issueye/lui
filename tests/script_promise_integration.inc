{ M6 P1 集成：事件切片排水与 Promise 错误分类 }

procedure TestScriptPromiseIntegration;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  btn: TXuiNode;
begin
  WriteLn('--- M6 P1 Promise 集成（切片排水 / 错误分类）---');

  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.OnError := @sink.HandleError;

      script.Run(
        'function OnBtnClick() {' + #10 +
        '  const out = document.find("out");' + #10 +
        '  out.text = "sync";' + #10 +
        '  Promise.resolve("done").then(function (v) { out.text = "async-" + v; });' + #10 +
        '  out.text = out.text + "-tail";' + #10 +
        '}', 'async.ts');
      Check(script.ErrorCount = 0, '异步脚本求值无错误');
      engine.LoadFromString(
        '<window><button id="b" text="go" onclick="OnBtnClick"/>' +
        '<label id="out" text="init"/></window>');
      DrawEngine(engine);
      btn := engine.Document.FindElementById('b');
      ClickNode(engine, btn);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'async-done',
        '事件切片结束排水：回调晚于同步尾语句且改 DOM 立即生效');

      script.Run('function Fire() { Promise.reject("orphan2"); }', 'fire.ts');
      sink.Errors := 0;
      sink.LastError := '';
      script.CallGlobal('Fire', []);
      Check(sink.Errors = 1, '未处理拒绝上报一次');
      Check(Pos('orphan2', sink.LastError) > 0, '未处理拒绝携带原因');
      Check(sink.LastErrorStage = ssUnhandledRejection, '错误阶段为 unhandledRejection');

      script.Run('function Handled() { Promise.reject("h3").catch(function (r) { }); }',
        'h3.ts');
      sink.Errors := 0;
      script.CallGlobal('Handled', []);
      Check(sink.Errors = 0, '已处理的拒绝不上报');

      script.Run('function FireLoop() {' +
        ' Promise.resolve().then(function () { let i = 0; while (true) { i++; } }); }',
        'loop.ts');
      sink.Errors := 0;
      sink.LastError := '';
      script.CallGlobal('FireLoop', []);
      Check(sink.Errors = 1, '微任务超预算上报');
      Check(sink.LastErrorStage = ssBudget, '微任务预算超限归类为 budget');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
