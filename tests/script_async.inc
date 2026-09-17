{ M6 P1：Promise、微任务、预算与 GC }

procedure TestScriptAsync;
var
  interp: TXuiJsInterp;
  prog: TXuiJsProgram;
  sink: TScriptSink;
  src: string;
  baseline, syncSteps: Int64;
  progs: TObjectList;

  procedure RunNoDrain(const ACode: string);
  begin
    prog := XuiJsParse(ACode, 'test.ts');
    progs.Add(prog);
    interp.Run(prog.Root);
  end;

  function RunAndDrain(const ACode: string): string;
  begin
    sink.Log.Clear;
    RunNoDrain(ACode);
    interp.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M6 P1 Promise 与微任务 ---');
  sink := TScriptSink.Create;
  interp := TXuiJsInterp.Create;
  progs := TObjectList.Create(True);
  try
    interp.OnLog := @sink.HandleLog;
    interp.OnUnhandledRejection := @sink.HandleUnhandled;

    sink.Log.Clear;
    RunNoDrain(
      'console.log("a");' + #10 +
      'Promise.resolve(1).then(function (v) { console.log("c" + v); });' + #10 +
      'console.log("b");');
    Check((Pos('a', sink.Log.Text) > 0) and (Pos('b', sink.Log.Text) > 0) and
      (Pos('c1', sink.Log.Text) = 0), 'then 回调不同步执行');
    interp.DrainMicrotasks;
    Check(Pos('c1', sink.Log.Text) > Pos('b', sink.Log.Text),
      '排水后回调执行且晚于同步语句');

    src := RunAndDrain(
      'Promise.resolve().then(function () { console.log("t1"); });' + #10 +
      'Promise.resolve().then(function () { console.log("t2"); });' + #10 +
      'Promise.resolve().then(function () { console.log("t3"); });');
    Check((Pos('t1', src) < Pos('t2', src)) and (Pos('t2', src) < Pos('t3', src)),
      '微任务按 FIFO 顺序执行');

    src := RunAndDrain(
      'Promise.resolve(1)' + #10 +
      '  .then(function (v) { return v + 1; })' + #10 +
      '  .then(function (v) { return v * 10; })' + #10 +
      '  .then(function (v) { console.log("chain" + v); });');
    Check(Pos('chain20', src) > 0, '链式 then 传递回调返回值');

    src := RunAndDrain(
      'Promise.resolve("p").then().then(function (v) { console.log("pass" + v); });' + #10 +
      'Promise.resolve(5).then(123).then(function (v) { console.log("pass2" + v); });' + #10 +
      'Promise.reject("ep").then(undefined, function (r) { console.log("pass3" + r); });');
    Check(Pos('passp', src) > 0, '空 then 透传成功值');
    Check(Pos('pass25', src) > 0, '非函数 onFulfilled 透传');
    Check(Pos('pass3ep', src) > 0, 'then(undefined, f) 处理拒绝');

    src := RunAndDrain(
      'Promise.resolve("x").then(function (v) { throw "boom"; })' + #10 +
      '  .catch(function (r) { console.log("caught" + r); return "rec"; })' + #10 +
      '  .then(function (v) { console.log("after" + v); });' + #10 +
      'Promise.reject("rj").then(function (v) { console.log("skipx" + v); })' + #10 +
      '  .catch(function (r) { console.log("skipped" + r); });');
    Check(Pos('caughtboom', src) > 0, 'then 回调抛错进入下游 catch');
    Check(Pos('afterrec', src) > 0, 'catch 返回值恢复链路');
    Check(Pos('skipx', src) = 0, '拒绝跳过 onFulfilled');
    Check(Pos('skippedrj', src) > 0, 'catch 捕获初始拒绝');

    src := RunAndDrain(
      'let fire;' + #10 +
      'const q = new Promise(function (res, rej) { fire = res; });' + #10 +
      'fire("first");' + #10 +
      'fire("second");' + #10 +
      'q.then(function (v) { console.log("once" + v); });');
    Check((Pos('oncefirst', src) > 0) and (Pos('second', src) = 0),
      'promise 状态不可逆');

    src := RunAndDrain(
      'console.log("pre");' + #10 +
      'new Promise(function (res) { console.log("exec"); res("ok"); })' + #10 +
      '  .then(function (v) { console.log("then" + v); });' + #10 +
      'console.log("post");' + #10 +
      'new Promise(function () { throw "ctor-throw"; })' + #10 +
      '  .catch(function (r) { console.log("ct" + r); });');
    Check((Pos('pre', src) < Pos('exec', src)) and (Pos('exec', src) < Pos('post', src)),
      'executor 同步执行');
    Check(Pos('thenok', src) > Pos('post', src), 'executor 内 resolve 仍异步回调');
    Check(Pos('ctctor-throw', src) > 0, 'executor 抛错使 promise 拒绝');

    src := RunAndDrain(
      'const outer = Promise.resolve("in")' + #10 +
      '  .then(function (v) { return Promise.resolve(v + "!"); });' + #10 +
      'outer.then(function (v) { console.log("adopt" + v); });');
    Check(Pos('adoptin!', src) > 0, '下游采纳回调返回的 promise');

    src := RunAndDrain(
      'const same = Promise.resolve(7);' + #10 +
      'console.log("same" + (Promise.resolve(same) === same) +' + #10 +
      '  (Promise.resolve(8) === same));');
    Check(Pos('sametruefalse', src) > 0, 'Promise.resolve 对 promise 原样返回');

    src := RunAndDrain(
      'Promise.all([Promise.resolve(1), 2, Promise.resolve(3)])' + #10 +
      '  .then(function (a) { console.log("all" + a.join("-")); });' + #10 +
      'Promise.all([Promise.resolve(1), Promise.reject("all-rej")])' + #10 +
      '  .catch(function (r) { console.log("allerr" + r); });' + #10 +
      'Promise.all([]).then(function (a) { console.log("allempty" + a.length); });');
    Check(Pos('all1-2-3', src) > 0, 'Promise.all 收集全部值（含普通值混入）');
    Check(Pos('allerrall-rej', src) > 0, 'Promise.all 任一拒绝即拒绝');
    Check(Pos('allempty0', src) > 0, 'Promise.all 空数组立即完成');

    src := RunAndDrain(
      'Promise.allSettled([Promise.resolve(1), Promise.reject("r2")])' + #10 +
      '  .then(function (a) {' + #10 +
      '    console.log("as" + a[0].status + ":" + a[0].value + "|" +' + #10 +
      '      a[1].status + ":" + a[1].reason); });');
    Check(Pos('asfulfilled:1|rejected:r2', src) > 0, 'Promise.allSettled 收集全部结局');

    src := RunAndDrain(
      'Promise.race(["first", Promise.resolve("late")])' + #10 +
      '  .then(function (v) { console.log("race1" + v); });' + #10 +
      'Promise.race([Promise.reject("race-rej"), Promise.resolve("x")])' + #10 +
      '  .catch(function (r) { console.log("race2" + r); });');
    Check(Pos('race1first', src) > 0, 'Promise.race 首个 settle 生效');
    Check(Pos('race2race-rej', src) > 0, 'Promise.race 拒绝领先同样生效');

    src := RunAndDrain(
      'Promise.resolve("fin").finally(function () { console.log("fin-run"); })' + #10 +
      '  .then(function (v) { console.log("fin-pass" + v); });' + #10 +
      'Promise.reject("fe").finally(function () { console.log("fin-rej-run"); })' + #10 +
      '  .catch(function (r) { console.log("fin-keep" + r); });' + #10 +
      'Promise.resolve("x").finally(function () { throw "fin-throw"; })' + #10 +
      '  .catch(function (r) { console.log("fin-threw" + r); });');
    Check(Pos('fin-run', src) > 0, 'finally 回调执行');
    Check(Pos('fin-passfin', src) > 0, 'finally 透传成功值');
    Check(Pos('fin-rej-run', src) > 0, 'finally 在拒绝路径也执行');
    Check(Pos('fin-keepfe', src) > 0, 'finally 透传拒绝原因');
    Check(Pos('fin-threwfin-throw', src) > 0, 'finally 回调抛错使下游拒绝');

    sink.Unhandled.Clear;
    sink.Log.Clear;
    RunNoDrain(
      'Promise.reject("orphan");' + #10 +
      'const p2 = Promise.reject("handled2");' + #10 +
      'p2.catch(function (r) { console.log("lh" + r); });');
    interp.DrainMicrotasks;
    Check(sink.Unhandled.Count = 1, '未处理拒绝恰上报一次');
    Check(Pos('orphan', sink.Unhandled.Text) > 0, '未处理拒绝携带原因');
    Check(Pos('handled2', sink.Unhandled.Text) = 0, '已挂接处理的拒绝不上报');
    Check(Pos('lhhandled2', sink.Log.Text) > 0, '挂接的处理函数正常执行');
    interp.DrainMicrotasks;
    Check(sink.Unhandled.Count = 1, '同一拒绝不重复上报');

    interp.MaxSteps := 50000;
    sink.Unhandled.Clear;
    sink.Log.Clear;
    RunNoDrain('Promise.resolve().then(function () { let i = 0; while (true) { i++; } });');
    interp.DrainMicrotasks;
    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0, '微任务内死循环超预算并上报');
    interp.MaxSteps := 2000000;

    sink.Log.Clear;
    RunNoDrain(
      'function Loop(n) { let s = 0; let i; for (i = 0; i < n; i++) { s += i; } return s; }' + #10 +
      'Loop(20000);');
    syncSteps := interp.Steps;
    Check(syncSteps > 1000, '同步切片消耗步数可测');
    interp.MaxSteps := syncSteps * 3 div 2;
    RunNoDrain('Promise.resolve().then(function () { console.log("mb" + Loop(20000)); });');
    interp.DrainMicrotasks;
    Check(Pos('mb', sink.Log.Text) > 0, '微任务预算独立重置（跨任务不累计）');
    sink.Unhandled.Clear;
    RunNoDrain('Promise.resolve().then(function () { console.log("mc" + Loop(200000)); });');
    interp.DrainMicrotasks;
    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0, '微任务内预算超限仍生效');
    Check(Pos('mc', sink.Log.Text) = 0, '超预算微任务未产生输出');
    interp.MaxSteps := 2000000;

    interp.ForceCollectGarbage;
    baseline := interp.ObjectCount;
    RunNoDrain(
      'for (let i = 0; i < 50; i++) { Promise.resolve(i).then(function (v) { return v; }); }');
    interp.ForceCollectGarbage;
    Check(interp.ObjectCount > baseline + 50, '挂起中的回调与下游不被回收');
    interp.DrainMicrotasks;
    interp.ForceCollectGarbage;
    Check(interp.ObjectCount < baseline + 30, '排水后脚本对象数收敛');

    sink.Unhandled.Clear;
    RunNoDrain('let saved; new Promise(function (res) { saved = res; });');
    interp.ForceCollectGarbage;
    sink.Log.Clear;
    RunNoDrain('saved(42); console.log("ctl-ok");');
    Check(Pos('ctl-ok', sink.Log.Text) > 0, 'GC 后控制函数仍可用');
    Check(sink.Unhandled.Count = 0, '控制函数 settle 成功无拒绝');
  finally
    progs.Free;
    interp.Free;
    sink.Free;
  end;
end;
