{ M6 P2 集成：引擎 Tick 驱动定时器 }

procedure TestScriptTimersIntegration;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
begin
  WriteLn('--- M6 P2 定时器集成（Tick 泵 / NeedsTick）---');

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
        'ui.setTimeout(function () { document.find("out").text = "t:" + ui.now(); }, 100);' + #10 +
        'ui.delay(200).then(function () { document.find("out").text = "delayed"; });',
        'timers.ts');
      Check(script.ErrorCount = 0, '定时器脚本求值无错误');
      Check(engine.NeedsTick, '定时器表非空 NeedsTick 为真');

      engine.Tick(1000);
      Check(engine.Document.FindElementById('out').Text = 'init', '未到期不执行');
      engine.Tick(1100);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 't:100',
        'Tick 到期触发且 ui.now 为相对时钟');
      Check(engine.NeedsTick, 'delay(200) 仍挂起时 NeedsTick 保持');

      engine.Tick(1200);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'delayed',
        'ui.delay 到点后 Promise 回调改 DOM');
      Check(not engine.NeedsTick, '定时器全部完成后 NeedsTick 为假');

      script.Run('function Boom() { ui.setTimeout(function () { throw "timer-boom"; }, 5); }',
        'boom2.ts');
      sink.Errors := 0;
      sink.LastError := '';
      script.CallGlobal('Boom', []);
      engine.Tick(1210);
      Check(sink.Errors = 1, '宏任务回调异常上报');
      Check(Pos('timer-boom', sink.LastError) > 0, '宏任务异常消息含脚本值');
      Check(sink.LastErrorStage = ssRuntime, '宏任务异常阶段为运行时');

      script.Run('function LoopTimer() {' +
        ' ui.setTimeout(function () { let i = 0; while (true) { i++; } }, 5); }',
        'loopt.ts');
      sink.Errors := 0;
      sink.LastError := '';
      script.CallGlobal('LoopTimer', []);
      engine.Tick(1220);
      Check(sink.Errors = 1, '宏任务死循环上报');
      Check(sink.LastErrorStage = ssBudget, '宏任务预算超限归类为 budget');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
