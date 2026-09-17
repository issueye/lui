{ M6：脚本内核 }

procedure TestScriptCore;
var
  interp: TXuiJsInterp;
  prog: TXuiJsProgram;
  sink: TScriptSink;
  src: string;

  function RunScript(const ACode: string): string;
  begin
    sink.Log.Clear;
    prog := XuiJsParse(ACode, 'test.ts');
    try
      interp.Run(prog.Root);
    finally
      prog.Free;
    end;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M6 脚本内核 ---');

  sink := TScriptSink.Create;
  interp := TXuiJsInterp.Create;
  try
    interp.OnLog := @sink.HandleLog;

    src := RunScript(
      'let x: number = 1 + 2 * 3;' + #10 +
      'console.log("a" + x);' + #10 +
      'function add(p: number, q: number): number { return p + q; }' + #10 +
      'console.log("b" + add(2, 3));' + #10 +
      'const o = { k: 1, s: "hi" };' + #10 +
      'console.log("c" + o.k + o.s);' + #10 +
      'const arr = [1, 2, 3];' + #10 +
      'console.log("d" + arr.length + arr.map(v => v * 2).join("-"));' + #10 +
      'console.log("e" + `t${1 + 1}`);' + #10 +
      'const { k, s } = o;' + #10 +
      'console.log("f" + k + s);' + #10 +
      'let 计数 = 0; 计数 += 5;' + #10 +
      'console.log("g" + 计数);');
    Check(Pos('a7', src) > 0, '表达式优先级与类型擦除');
    Check(Pos('b5', src) > 0, '函数声明与调用');
    Check(Pos('c1hi', src) > 0, '对象字面量与成员访问');
    Check(Pos('d32-4-6', src) > 0, '数组方法（map/join）');
    Check(Pos('et2', src) > 0, '模板串');
    Check(Pos('f1hi', src) > 0, '对象解构');
    Check(Pos('g5', src) > 0, '中文标识符与复合赋值');

    src := RunScript(
      'class A { constructor(n) { this.n = n; } hi() { return "A" + this.n; } }' + #10 +
      'class B extends A { hi() { return "B" + this.n; } }' + #10 +
      'console.log("h" + new B("x").hi());' + #10 +
      'let sum = 0; for (const v of [1,2,3]) { sum += v; }' + #10 +
      'console.log("i" + sum);' + #10 +
      'try { throw "err"; } catch (e) { console.log("j" + e); }' + #10 +
      'console.log("k" + JSON.stringify({ p: 1, q: [true, null] }));' + #10 +
      'const s2 = "你好世界";' + #10 +
      'console.log("l" + s2.length + s2.slice(1, 3));');
    Check(Pos('hBx', src) > 0, '类继承与方法覆盖');
    Check(Pos('i6', src) > 0, 'for..of 累加');
    Check(Pos('jerr', src) > 0, 'try/catch 捕获 throw');
    Check(Pos('k{"p":1,"q":[true,null]}', src) > 0, 'JSON.stringify');
    Check(Pos('l4好世', src) > 0, '中文字符串按码点计数与切片');

    // 预算：切片内死循环应被拦下（不挂死测试进程）
    src := RunScript(
      'function Loop() { let i = 0; while (true) { i++; } }' + #10 +
      'try { Loop(); } catch (e) { console.log("m" + e); }');
    Check(Pos('m', src) > 0, '死循环被指令预算拦截');
  finally
    interp.Free;
    sink.Free;
  end;
end;
