{ M6 P3：async/await }

procedure TestScriptAsyncAwait;
var
  interp: TXuiJsInterp;
  prog: TXuiJsProgram;
  sink: TScriptSink;
  src: string;
  progs: TObjectList;

  function RunAndDrain(const ACode: string): string;
  begin
    sink.Log.Clear;
    prog := XuiJsParse(ACode, 'test.ts');
    progs.Add(prog);
    interp.Run(prog.Root);
    interp.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

  procedure CheckParseError(const ACode, APart, AName: string);
  begin
    try
      prog := XuiJsParse(ACode, 'test.ts');
      progs.Add(prog);
      Check(False, AName);
    except
      on E: Exception do
        Check((E is EXuiJsSyntaxError) and (Pos(APart, E.Message) > 0), AName);
    end;
  end;

begin
  WriteLn('--- M6 P3 async/await ---');
  sink := TScriptSink.Create;
  interp := TXuiJsInterp.Create;
  progs := TObjectList.Create(True);
  try
    interp.OnLog := @sink.HandleLog;
    interp.OnUnhandledRejection := @sink.HandleUnhandled;

    src := RunAndDrain(
      'async function f() {' + #10 +
      '  console.log("a");' + #10 +
      '  const v = await Promise.resolve("b");' + #10 +
      '  console.log(v); return v + "c";' + #10 +
      '}' + #10 +
      'console.log("s"); f().then(function (v) { console.log("t" + v); });' + #10 +
      'console.log("e");');
    Check((Pos('s', src) < Pos('a', src)) and (Pos('a', src) < Pos('e', src)) and
      (Pos('e', src) < Pos('b', src)), 'async 同步执行到首个 await，之后走微任务');
    Check(Pos('tbc', src) > 0, 'async 返回值经 promise 送达');

    src := RunAndDrain(
      'async function add() { const x = 1 + await Promise.resolve(2); return x * 10; }' + #10 +
      'add().then(function (v) { console.log("expr" + v); });');
    Check(Pos('expr30', src) > 0, 'await 参与表达式运算');

    src := RunAndDrain(
      'async function opt() {' + #10 +
      '  const o = await Promise.resolve({ v: "opt" });' + #10 +
      '  const n = await Promise.resolve(null);' + #10 +
      '  return (n)?.v ?? "d|" + ((o)?.v ?? "x");' + #10 +
      '}' + #10 +
      'opt().then(function (v) { console.log("R" + v); });');
    Check(Pos('Rd|opt', src) > 0, 'await 后接可选链与 ??');

    src := RunAndDrain(
      'async function loops() {' + #10 +
      '  let s = ""; let n = 0;' + #10 +
      '  while (await Promise.resolve(n < 3)) { s += n; n += 1; }' + #10 +
      '  for (const x of await Promise.resolve(["A", "B"])) { s += x; }' + #10 +
      '  for (let i2 = 0; i2 < 2; i2 = await Promise.resolve(i2 + 1)) { s += "s"; }' + #10 +
      '  return s; }' + #10 +
      'loops().then(function (v) { console.log("L" + v); });');
    Check(Pos('L012ABss', src) > 0, 'while 条件 / for..of 源 / 步进中的 await');

    src := RunAndDrain(
      'async function guarded() {' + #10 +
      '  let out = ""; try {' + #10 +
      '    out += await Promise.resolve("ok");' + #10 +
      '    out += await Promise.reject("bad"); out += "skip";' + #10 +
      '  } catch (e) { out += "|caught" + e; }' + #10 +
      '  finally { out += "|fin" + await Promise.resolve("!"); }' + #10 +
      '  return out; }' + #10 +
      'guarded().then(function (v) { console.log("G" + v); });');
    Check(Pos('Gok|caughtbad|fin!', src) > 0, 'try/catch/finally 内的 await 与拒绝捕获');

    src := RunAndDrain(
      'async function fin2() {' + #10 +
      '  try { return await Promise.resolve("v"); }' + #10 +
      '  finally { console.log("fin-run" + await Promise.resolve(1)); }' + #10 +
      '}' + #10 +
      'fin2().then(function (v) { console.log("F" + v); });');
    Check((Pos('fin-run1', src) > 0) and (Pos('Fv', src) > 0),
      'finally 内 await 后仍透传返回值');

    src := RunAndDrain(
      'async function inner() { return await Promise.resolve(5); }' + #10 +
      'async function outer() { return await inner(); }' + #10 +
      'async function fib(n: number): number {' + #10 +
      '  if (n < 2) { return n; }' + #10 +
      '  return (await fib(n - 1)) + (await fib(n - 2)); }' + #10 +
      'outer().then(function (v) { console.log("nest" + v); });' + #10 +
      'fib(5).then(function (v) { console.log("fib" + v); });');
    Check(Pos('nest5', src) > 0, 'return await 解包一层');
    Check(Pos('fib5', src) > 0, '异步递归（同表达式双 await）');

    src := RunAndDrain(
      'class C { async m() { return await Promise.resolve("m"); } }' + #10 +
      'const arrow = async (x: number): number => x + await Promise.resolve(1);' + #10 +
      'const c = new C();' + #10 +
      'async function lits() {' + #10 +
      '  const o = { k: await Promise.resolve("K") };' + #10 +
      '  const arr2 = [0, await Promise.resolve(9)];' + #10 +
      '  return c.m() && false ? "" : o.k + arr2[1]; }' + #10 +
      'arrow(1).then(function (v) { console.log("ar" + v); });' + #10 +
      'lits().then(function (v) { console.log("lit" + v); });');
    Check(Pos('ar2', src) > 0, 'async 箭头函数');
    Check(Pos('litK9', src) > 0, 'async 方法与字面量中的 await');

    sink.Unhandled.Clear;
    src := RunAndDrain(
      'async function boom() { throw "boom-val"; }' + #10 +
      'boom().then(function (v) { console.log("no" + v); });' + #10 +
      'async function handled() { throw "h"; }' + #10 +
      'handled().catch(function (r) { console.log("hc" + r); });');
    Check(Pos('hch', src) > 0, 'async 抛错经 catch 处理');
    Check((Pos('boom-val', sink.Unhandled.Text) > 0) and
      (Pos('h', sink.Unhandled.Text) = 0), '未处理的 async 拒绝上报一次');

    CheckParseError('function bad() { return await Promise.resolve(1); }',
      'await 只能用于 async 函数内', '非 async 函数内 await 报错');
    CheckParseError('const t = await Promise.resolve(1);',
      'await 只能用于 async 函数内', '顶层 await 报错');
    CheckParseError('for await (const x of [1]) {}',
      'for await', 'for await..of 报错');
    src := RunAndDrain('const okArrow = async (x: number): number => x; console.log("okp");');
    Check(Pos('okp', src) > 0, 'async 前缀合法语法不受影响');

    interp.MaxSteps := 60000;
    sink.Unhandled.Clear;
    RunAndDrain(
      'async function loop() { while (true) { } return 1; }' + #10 +
      'loop().catch(function (r) { console.log("lc" + r); });');
    Check(Pos('lc', sink.Log.Text) > 0, 'async 死循环被预算拦截且可捕获');
    interp.MaxSteps := 2000000;

    sink.Log.Clear;
    RunAndDrain(
      'let rs;' + #10 +
      'const never = new Promise(function (res) { rs = res; });' + #10 +
      'const keep = { tag: "K" };' + #10 +
      'async function waiter() { const local = await never; return "W" + local.tag + keep.tag; }' + #10 +
      'waiter().then(function (v) { console.log(v); });');
    interp.ForceCollectGarbage;
    RunAndDrain('rs(keep);');
    Check(Pos('WKK', sink.Log.Text) > 0, '挂起中的 async 帧栈不被回收且可恢复');
  finally
    progs.Free;
    interp.Free;
    sink.Free;
  end;
end;
