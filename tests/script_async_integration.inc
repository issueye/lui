{ M6 P3 集成：await、定时器与 DOM 更新 }

procedure TestScriptAsyncIntegration;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
begin
  WriteLn('--- M6 P3 async 集成（await ui.delay 改 DOM）---');

  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.OnError := @sink.HandleError;
      engine.LoadFromString('<window><label id="out" text="init"/></window>');
      DrawEngine(engine);

      script.Run(
        'async function boot() {' + #10 +
        '  const out = document.find("out");' + #10 +
        '  out.text = "step1";' + #10 +
        '  await ui.delay(100);' + #10 +
        '  out.text = "step2";' + #10 +
        '  await ui.delay(100);' + #10 +
        '  out.text = "done";' + #10 +
        '}' + #10 +
        'boot();', 'asyncboot.ts');
      Check(script.ErrorCount = 0, 'async 引导脚本求值无错误');

      engine.Tick(1000);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'step1',
        'async 同步段立即生效');
      engine.Tick(1100);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'step2',
        'await ui.delay 恢复后继续执行');
      engine.Tick(1200);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'done',
        '多次 await 序列完成');
      Check(not engine.NeedsTick, 'async 完成后无待处理任务');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
