{ M6 P2：定时器宏任务 }

procedure TestScriptTimers;
var
  interp: TXuiJsInterp;
  prog: TXuiJsProgram;
  sink: TScriptSink;
  src: string;
  baseline: Int64;
  i: Integer;
  progs: TObjectList;

  procedure Run(const ACode: string);
  begin
    prog := XuiJsParse(ACode, 'test.ts');
    progs.Add(prog);
    interp.Run(prog.Root);
  end;

  procedure AdvanceAndPump(ADeltaMs: Int64);
  begin
    interp.SetClockMs(interp.NowMs + ADeltaMs);
    interp.PumpTimers;
  end;

begin
  WriteLn('--- M6 P2 定时器宏任务 ---');
  sink := TScriptSink.Create;
  interp := TXuiJsInterp.Create;
  progs := TObjectList.Create(True);
  try
    interp.OnLog := @sink.HandleLog;
    interp.OnUnhandledRejection := @sink.HandleUnhandled;
    interp.OnCallbackError := @sink.HandleUnhandled;

    sink.Log.Clear;
    Run(
      'ui.setTimeout(function () { console.log("a"); }, 0);' + #10 +
      'ui.setTimeout(function () { console.log("b"); }, 0);');
    Check(interp.HasDueTimers, 'setTimeout(0) 注册即到期待执行');
    Check(interp.PumpTimers = 2, '泵返回执行的宏任务数');
    Check((Pos('a', sink.Log.Text) > 0) and (Pos('a', sink.Log.Text) < Pos('b', sink.Log.Text)),
      'setTimeout(0) 泵内执行且按注册序');
    Check(not interp.HasDueTimers, '执行后无到期定时器');

    sink.Log.Clear;
    Run(
      'ui.setTimeout(function () { console.log("late"); }, 50);' + #10 +
      'ui.setTimeout(function () { console.log("soon"); }, 10);');
    AdvanceAndPump(10);
    Check((Pos('soon', sink.Log.Text) > 0) and (Pos('late', sink.Log.Text) = 0),
      '仅到期定时器执行');
    AdvanceAndPump(40);
    Check(Pos('soon', sink.Log.Text) < Pos('late', sink.Log.Text), '到期顺序按延迟先后');

    sink.Log.Clear;
    Run(
      'const id = ui.setTimeout(function () { console.log("nope"); }, 30);' + #10 +
      'ui.clearTimeout(id);' + #10 +
      'ui.setTimeout(function () { console.log("yes"); }, 30);');
    Check(interp.TimersPending = 1, 'clearTimeout 回收表项');
    AdvanceAndPump(30);
    Check((Pos('yes', sink.Log.Text) > 0) and (Pos('nope', sink.Log.Text) = 0),
      '已取消的定时器不执行');

    sink.Log.Clear;
    Run(
      'let n = 0;' + #10 +
      'const id = ui.setInterval(function () { n += 1; console.log("tick" + n);' + #10 +
      '  if (n >= 3) { ui.clearInterval(id); } }, 10);');
    for i := 1 to 5 do
      AdvanceAndPump(10);
    Check((Pos('tick3', sink.Log.Text) > 0) and (Pos('tick4', sink.Log.Text) = 0),
      'setInterval 重复执行且 clearInterval 停止');

    sink.Log.Clear;
    Run(
      'let n2 = 0;' + #10 +
      'const id2 = ui.setInterval(function () { n2 += 1;' + #10 +
      '  if (n2 >= 3) { ui.clearInterval(id2); console.log("z" + n2); } }, 0);');
    AdvanceAndPump(5);
    Check(Pos('z3', sink.Log.Text) > 0, '零间隔 setInterval 钳制且可停止');

    sink.Log.Clear;
    Run(
      'ui.setTimeout(function () { console.log("macro"); }, 0);' + #10 +
      'Promise.resolve().then(function () { console.log("micro"); });' + #10 +
      'console.log("sync");');
    interp.DrainMicrotasks;
    Check(Pos('macro', sink.Log.Text) = 0, '定时器不因排水而提前执行');
    AdvanceAndPump(0);
    Check(Pos('micro', sink.Log.Text) < Pos('macro', sink.Log.Text), '微任务先于下一宏任务');

    sink.Log.Clear;
    Run('ui.setTimeout(function (a, b) { console.log("args" + a + b); }, 5, "x", 7);');
    AdvanceAndPump(5);
    Check(Pos('argsx7', sink.Log.Text) > 0, '定时器回调接收额外参数');

    interp.SetClockMs(0);
    sink.Log.Clear;
    Run('ui.delay(20).then(function (v) { console.log("delayed" + v + "@" + ui.now()); });');
    Check(interp.TimersPending = 1, 'ui.delay 基于定时器表');
    AdvanceAndPump(20);
    Check(Pos('delayedundefined@20', sink.Log.Text) > 0,
      'ui.delay 到点 resolve(undefined)，ui.now 为相对时钟');

    sink.Log.Clear;
    Run('console.log("T|" + ui.time() + "|");');
    src := sink.Log.Text;
    Check((Pos('T|', src) > 0) and (Length(Trim(src)) > 12), 'ui.time 返回墙钟时间字符串');

    sink.Unhandled.Clear;
    sink.Log.Clear;
    Run(
      'ui.setTimeout(function () { throw "cb-error"; }, 0);' + #10 +
      'ui.setTimeout(function () { console.log("after-err"); }, 0);');
    Check(interp.PumpTimers = 2, '异常后泵继续执行后续定时器');
    Check(Pos('cb-error', sink.Unhandled.Text) > 0, '宏任务回调异常上报');
    Check(Pos('after-err', sink.Log.Text) > 0, '异常不中断后续定时器');

    interp.MaxSteps := 50000;
    sink.Unhandled.Clear;
    sink.Log.Clear;
    Run(
      'ui.setTimeout(function () { let i = 0; while (true) { i++; } }, 0);' + #10 +
      'ui.setTimeout(function () { console.log("ok-after-budget"); }, 0);');
    interp.PumpTimers;
    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0, '宏任务死循环超预算上报');
    Check(Pos('ok-after-budget', sink.Log.Text) > 0, '超预算不中断后续定时器');
    interp.MaxSteps := 2000000;

    interp.ForceCollectGarbage;
    baseline := interp.ObjectCount;
    Run('ui.setTimeout(function () { return 1; }, 100000);');
    interp.ForceCollectGarbage;
    Check(interp.ObjectCount > baseline, '定时器表中的回调不被回收');
    interp.ClearTimer(999999);
  finally
    progs.Free;
    interp.Free;
    sink.Free;
  end;
end;
