{ M6 P4：真实 I/O（fake 注入与文件往返） }

var
  IoLastHeaders: string;

procedure IoFakeExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
begin
  if Pos('slow', AReq.Url) > 0 then
  begin
    ARes.Ok := False;
    ARes.ErrMsg := 'I/O 操作超时';
    Exit;
  end;
  ARes.Ok := True;
  IoLastHeaders := AReq.Headers;
  ARes.Status := 200;
  ARes.Headers := 'Content-Type: text/plain';
  if Pos('json:', AReq.Url) = 1 then
    ARes.Data := Copy(AReq.Url, 6, MaxInt)
  else
    ARes.Data := AReq.Url;
end;

procedure TestScriptIO;
var
  script: TXuiScript;
  sink: TScriptSink;
  io: TXuiScriptIO;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  bridge: TXuiDomBridge;
  src, tmpFile, jsPath: string;
  ioSeq: Integer;

  function RunAndPump(const ACode: string): string;
  begin
    Inc(ioSeq);
    sink.Log.Clear;
    script.Run(ACode, 'io' + IntToStr(ioSeq) + '.ts');
    repeat
      script.PumpIO;
      script.DrainMicrotasks;
    until (script.IoInFlight = 0) and (script.Interp.MicroTaskCount = 0);
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M6 P4 真实 I/O ---');
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  tmpFile := IncludeTrailingPathDelimiter(GetTempDir) + 'lui_p4_io.txt';
  ioSeq := 0;
  try
    script.OnError := @sink.HandleError;
    script.Interp.OnLog := @sink.HandleLog;
    io := script.IO;
    io.SyncMode := True;
    io.Executor := nil;

    src := RunAndPump(
      'const j0 = JSON.parse(''{"n": 7, "list": [1, 2], "o": {"k": "K"}}'');' + #10 +
      'console.log("jp" + j0.n + j0.list[1] + j0.o.k);');
    Check(Pos('jp72K', src) > 0, 'JSON.parse 对象/数组/数字');

    jsPath := StringReplace(tmpFile, PathDelim, '/', [rfReplaceAll]);
    src := RunAndPump(
      'async function fsRound() {' + #10 +
      '  await ui.fs.writeText("' + jsPath + '", "hello-lui-123");' + #10 +
      '  return ui.fs.readText("' + jsPath + '");' + #10 +
      '}' + #10 +
      'fsRound().then(function (t) { console.log("fs" + t); });');
    Check(script.ErrorCount = 0, 'fs 往返无错误');
    Check(Pos('fshello-lui-123', src) > 0, 'fs 写读往返');

    io.Executor := @IoFakeExecute;
    src := RunAndPump(
      'ui.http.get("u1").then(function (resp) {' + #10 +
      '  console.log("t" + resp.status + resp.text());' + #10 +
      '});');
    Check(Pos('t200u1', src) > 0, 'http.get 响应对象（status/text）');

    IoLastHeaders := '';
    src := RunAndPump(
      'ui.http.post("u2", "{}", { timeout: 5000, headers: { "Content-Type": "application/json", "X-Token": "abc" } }).then(function (r) { console.log("h" + r.status); });');
    Check((Pos('Content-Type: application/json', IoLastHeaders) > 0) and
      (Pos('X-Token: abc', IoLastHeaders) > 0),
      'http opts.headers 作为请求头发送（嵌套对象，非平铺）');
    Check(Pos('timeout', IoLastHeaders) = 0,
      'http opts 的选项键不混入请求头（timeout 被排除）');

    src := RunAndPump(
      'ui.http.get("json:{\"n\": 7, \"list\": [1, 2], \"o\": {\"k\": \"K\"}}").then(function (resp) { return resp.json(); })' + #10 +
      '  .then(function (j) { console.log("j" + j.n + j.list[1] + j.o.k); });');
    Check(script.ErrorCount = 0, 'json() 无错误');
    Check(Pos('j72K', src) > 0, 'resp.json() 经 JSON.parse 解析');

    src := RunAndPump(
      'ui.http.get("w1").then(function (r) { console.log("a" + r.text()); });' + #10 +
      'ui.http.get("w2").then(function (r) { console.log("b" + r.text()); });' + #10 +
      'ui.http.get("w3").then(function (r) { console.log("c" + r.text()); });');
    Check((Pos('aw1', src) < Pos('bw2', src)) and (Pos('bw2', src) < Pos('cw3', src)),
      '完成按提交顺序 FIFO 派发');

    sink.Errors := 0;
    sink.LastError := '';
    sink.LastErrorStage := ssRuntime;
    src := RunAndPump(
      'ui.http.get("slow-api").then(function (r) { console.log("no"); })' + #10 +
      '  .catch(function (r) { console.log("caught:" + r); });');
    Check(Pos('caught:Error: I/O 操作超时', src) > 0, '超时请求 reject 可捕获');
    Check(sink.Errors = 1, 'I/O 失败上报一次');
    Check(sink.LastErrorStage = ssIO, '错误阶段为 io');

    DeleteFile('lui_missing_p4.txt');
    io.Executor := nil;
    src := RunAndPump(
      'ui.fs.readText("lui_missing_p4.txt").then(function (t) { console.log("no:" + t); })' + #10 +
      '  .catch(function (r) { console.log("ferr:" + r); });');
    Check(Pos('ferr', src) > 0, '缺文件 reject 可捕获');

    src := RunAndPump(
      'ui.storage.set("k", "v1");' + #10 +
      'ui.storage.set("k", "v2");' + #10 +
      'console.log("st" + ui.storage.get("k") + "|" + ui.storage.get("missing"));');
    Check(Pos('stv2|null', src) > 0, 'storage 同步读写与 null 缺省');

    sink.Errors := 0;
    sink.LastError := '';
    script.Run('function Sig() { ui.http.get("u", { signal: {} }); }', 'sig.ts');
    script.CallGlobal('Sig', []);
    Check(sink.Errors = 1, 'AbortSignal 报不支持');
    Check(sink.LastErrorStage = ssRuntime, 'signal 错误阶段为运行时');

    script.Run('function FireReq() { ui.http.get("inflight"); }', 'ifl.ts');
    script.CallGlobal('FireReq', []);
    Check(script.IoInFlight = 1, '在途请求计数为 1');
    script.PumpIO;
    script.DrainMicrotasks;
    Check(script.IoInFlight = 0, '完成后在途清零');

    io.Executor := @IoFakeExecute;
    engine := NewTestEngine(fake);
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      engine.LoadFromString('<window><label id="out" text="init"/></window>');
      DrawEngine(engine);
      script.Run(
        'ui.http.get("tickdata").then(function (r) {' + #10 +
        '  document.find("out").text = r.text(); });', 'tickio.ts');
      Check(engine.NeedsTick, '在途 I/O 使 NeedsTick 为真');
      engine.Tick(500);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('out').Text = 'tickdata',
        '引擎 Tick 泵完成队列并改 DOM');
      Check(not engine.NeedsTick, 'I/O 完成后 NeedsTick 为假');
    finally
      bridge.Free;
      engine.Free;
    end;
  finally
    DeleteFile(tmpFile);
    script.Free;
    sink.Free;
  end;
end;
