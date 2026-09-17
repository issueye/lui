// ---- M12：应用清单（lui.json）与自包含应用容器（xui_bundle）----

{ 写一个临时文件（文本） }
procedure WriteTextAt(const APath, AText: string);
var
  lines: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  lines := TStringList.Create;
  try
    lines.Text := AText;
    lines.SaveToFile(APath);
  finally
    lines.Free;
  end;
end;

function LinesOf(const AItems: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := Low(AItems) to High(AItems) do
  begin
    if i > Low(AItems) then
      Result := Result + LineEnding;
    Result := Result + AItems[i];
  end;
end;

procedure TestAppSpec;
var
  base, app, nested, legacyDir, plainDir: string;
  spec: TXuiAppSpec;
  pages: TStringList;
begin
  WriteLn('--- M12 应用清单（lui.json / 应用根）---');
  base := GetTempDir(False) + 'lui-appspec-test';
  app := base + PathDelim + 'myapp';
  nested := app + PathDelim + 'src' + PathDelim + 'views' + PathDelim + 'deep';
  legacyDir := base + PathDelim + 'legacyapp';
  plainDir := base + PathDelim + 'plainapp';
  if DirectoryExists(base) then
    DeleteDirectory(base, True);
  ForceDirectories(nested);
  ForceDirectories(legacyDir + PathDelim + 'src');
  ForceDirectories(plainDir + PathDelim + 'src');

  WriteTextAt(app + PathDelim + 'src' + PathDelim + 'main.xml', '<window/>');
  WriteTextAt(app + PathDelim + 'src' + PathDelim + 'other.xml', '<window/>');
  WriteTextAt(app + PathDelim + 'ui' + PathDelim + 'index.ts', '// ui');
  WriteTextAt(app + PathDelim + 'lui.json', LinesOf([
    '{',
    '  "name": "myapp",',
    '  "displayName": "我的应用",',
    '  "version": "2.3.1",',
    '  "main": "src/main.xml",',
    '  "ui": "vendor/lui-ui",',
    '  "window": {',
    '    "width": 640,',
    '    "height": 900,',
    '    "theme": "dark",',
    '    "title": "标题来自清单",',
    '    "resizable": false,',
    '    "center": false',
    '  },',
    '  "styles": ["src/base.css"],',
    '  "dev": { "watch": false },',
    '  "build": {',
    '    "out": "build-out",',
    '    "exclude": ["out", "dist", "docs"],',
    '    "assets": ["assets/logo.png"]',
    '  }',
    '}']));

  Check(XuiAppRootOf(nested) = ExpandFileName(app),
    'XuiAppRootOf：从深层子目录向上找到含 lui.json 的应用根');
  Check(XuiAppRootOf(app + PathDelim + 'src' + PathDelim + 'main.xml') = ExpandFileName(app),
    'XuiAppRootOf：给一个文件也能定位到应用根');
  Check(XuiAppRootOf(plainDir) = '', 'XuiAppRootOf：没有清单时返回空（由调用方兜底）');

  spec := TXuiAppSpec.Create;
  try
    Check(spec.Load(app), 'lui.json 解析成功');
    Check(spec.Kind = XuiManifestName, '清单类型识别为 lui.json');
    Check(spec.Name = 'myapp', 'name 解析（exe 名 / 默认窗口标题用它）');
    Check(spec.DisplayName = '我的应用', 'displayName 解析（中文不依赖转义）');
    Check(spec.Version = '2.3.1', 'version 解析');
    Check(spec.Title = '标题来自清单', 'window.title 优先于 displayName 作为标题');
    Check(spec.Main = 'src/main.xml', 'main 解析');
    Check(spec.UiDir = 'vendor/lui-ui', 'ui 目录可改成非默认名');
    Check(spec.UiIndex = ExpandFileName(app + PathDelim + 'vendor' + PathDelim + 'lui-ui' +
      PathDelim + 'index.ts'), 'UiIndex 按清单的 ui 目录拼出');
    Check(spec.WindowWidth = 640, 'window.width 数值解析');
    Check(spec.WindowHeight = 900, 'window.height 数值解析');
    Check(spec.DefaultTheme = 'dark', 'window.theme 解析');
    Check(not spec.Resizable, 'window.resizable=false 解析');
    Check(not spec.Center, 'window.center=false 解析');
    Check(not spec.Watch, 'dev.watch=false 解析');
    Check(spec.BuildOut = 'build-out', 'build.out 解析');
    Check(spec.Exclude.IndexOf('docs') >= 0, 'build.exclude 数组解析');
    Check(spec.Assets.Count = 1, 'build.assets 数组解析');
    Check(spec.Styles.Count = 1, 'styles 数组解析');
    Check(spec.Entry = ExpandFileName(app + PathDelim + 'src' + PathDelim + 'main.xml'),
      'Entry 解析为绝对路径（相对应用根）');
    Check(spec.PathOf('ui/x.ts') = ExpandFileName(app + PathDelim + 'ui' + PathDelim + 'x.ts'),
      'PathOf：相对路径锚定应用根（正斜杠也接受）');
    Check(spec.PathOf(app) = ExpandFileName(app), 'PathOf：绝对路径原样返回');

    pages := spec.Pages;
    try
      Check((pages.Count = 2) and (pages.IndexOf(spec.Entry) = 0),
        'Pages：入口页在最前，src/ 下其它页面一并列出（check 逐页自检靠它）');
    finally
      pages.Free;
    end;
  finally
    spec.Free;
  end;

  // 旧清单（M11 lui-project.json）继续可读：老工程不迁移也能跑
  WriteTextAt(legacyDir + PathDelim + 'lui-project.json', LinesOf([
    '{',
    '  "name": "legacy",',
    '  "entry": "src/main.xml",',
    '  "viewport": { "width": "320", "height": "480" },',
    '  "theme": "dark"',
    '}']));
  WriteTextAt(legacyDir + PathDelim + 'src' + PathDelim + 'main.xml', '<window/>');
  spec := TXuiAppSpec.Create;
  try
    Check(spec.Load(legacyDir), '旧清单 lui-project.json 仍可读（向后兼容）');
    Check(spec.Kind = XuiManifestLegacy, '清单类型识别为 lui-project.json');
    Check(spec.Main = 'src/main.xml', '旧清单 entry → main 映射');
    Check((spec.WindowWidth = 320) and (spec.WindowHeight = 480),
      '旧清单 viewport 的字符串数值也能解析');
    Check(spec.DefaultTheme = 'dark', '旧清单 theme 映射');
    Check(spec.Warnings.Count > 0, '用旧清单时给出迁移提示（不静默）');
  finally
    spec.Free;
  end;

  // 没有清单：按目录约定推导，仍然可用（"给个目录就能跑"）
  WriteTextAt(plainDir + PathDelim + 'src' + PathDelim + 'main.xml', '<window/>');
  spec := TXuiAppSpec.Create;
  try
    Check(spec.Load(plainDir), '没有清单也能装配（默认值兜底）');
    Check(spec.Main = 'src/main.xml', '默认入口优先取 src/main.xml');
    Check((spec.WindowWidth = 480) and (spec.WindowHeight = 560), '默认视口 480x560');
    Check(spec.BuildOut = 'dist', '默认构建输出 dist');
    Check(spec.Exclude.IndexOf('dist') >= 0, '默认排除产物目录');
  finally
    spec.Free;
  end;

  // 清单语法错误：宁可报错，也不要静默用默认值跑出"看起来对"的结果
  WriteTextAt(base + PathDelim + 'bad.json', '{ "name": }');
  spec := TXuiAppSpec.Create;
  try
    ForceDirectories(base + PathDelim + 'badapp');
    WriteTextAt(base + PathDelim + 'badapp' + PathDelim + 'lui.json', '{ "name": }');
    Check(not spec.Load(base + PathDelim + 'badapp'), 'lui.json 语法错误 → Load 返回 False');
  finally
    spec.Free;
  end;

  // 应用内资源解析：给了应用根才改变行为，不给就维持旧语义（当前工作目录）
  WriteTextAt(app + PathDelim + 'assets' + PathDelim + 'logo.svg', '<svg/>');
  XuiAppRootOverride := '';
  Check(XuiAppResourcePath('assets/logo.svg') = 'assets/logo.svg',
    '未指定应用根时：相对路径原样返回（不改变单页渲染的旧行为）');
  XuiAppRootOverride := ExpandFileName(app);
  Check(XuiAppResourcePath('assets/logo.svg') =
    ExpandFileName(app + PathDelim + 'assets' + PathDelim + 'logo.svg'),
    '指定应用根后：<svg src> 一类相对资源锚定应用根（不再依赖当前工作目录）');
  Check(XuiAppResourcePath('assets/nope.svg') = 'assets/nope.svg',
    '应用根下找不到时回落旧语义，由调用方给出诊断');
  XuiAppRootOverride := '';

  if DirectoryExists(base) then
    DeleteDirectory(base, True);
end;

procedure TestBundle;
var
  base, payloadDir, outExe, mount, mount2: string;
  files: TStringList;
  info: TXuiBundleInfo;
  names: TStringList;
  entries: TXuiBundleEntries;
  i: Integer;
  raw: TBytes;
  fs: TFileStream;
  fp1, fp2: Cardinal;
  n: Integer;
  err: string;
  buf: string;

  function ReadAll(const APath: string): TBytes;
  begin
    SetLength(Result, 0);
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(Result[0], fs.Size);
    finally
      fs.Free;
    end;
  end;

  function SameBytes(const A, B: TBytes): Boolean;
  begin
    Result := (Length(A) = Length(B)) and
      ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
  end;

  procedure WriteBytes(const APath: string; const AData: TBytes);
  begin
    ForceDirectories(ExtractFileDir(APath));
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(AData) > 0 then
        fs.WriteBuffer(AData[0], Length(AData));
    finally
      fs.Free;
    end;
  end;

  function BytesOf(const AParts: array of Integer): TBytes;
  var
    k: Integer;
  begin
    SetLength(Result, Length(AParts));
    for k := 0 to High(AParts) do
      Result[k] := Byte(AParts[k]);
  end;

begin
  WriteLn('--- M12 自包含应用容器（xui_bundle）---');
  base := GetTempDir(False) + 'lui-bundle-test';
  payloadDir := base + PathDelim + 'app';
  outExe := base + PathDelim + 'dist' + PathDelim + 'myapp.exe';
  if DirectoryExists(base) then
    DeleteDirectory(base, True);
  ForceDirectories(payloadDir);

  // 载荷内容：含 NUL / CRLF / 高位字节，专门验证"字节级原样搬运"而不是文本搬运
  WriteBytes(payloadDir + PathDelim + 'a.bin', BytesOf([0, 1, 2, 13, 10, 255, 128, 0]));
  WriteTextAt(payloadDir + PathDelim + 'src' + PathDelim + 'main.xml', '<window/>');
  WriteTextAt(payloadDir + PathDelim + 'ui' + PathDelim + 'index.ts', '// ui');
  WriteTextAt(payloadDir + PathDelim + 'lui.json', '{ "name": "myapp" }');

  files := TStringList.Create;
  try
    files.Add('a.bin');
    files.Add('src/main.xml');
    files.Add('ui/index.ts');
    files.Add('lui.json');
    files.Add('missing.txt');       // 缺失项应被跳过而不是让整次构建失败

    // 模板用测试程序自身（一个真实的 PE 文件）
    Check(XuiBundleBuild(ParamStr(0), outExe, payloadDir, files, n, err),
      '构建自包含应用成功（模板 = 测试 exe 自身）: ' + err);
    Check(n = 4, '缺失文件被跳过：4 个有效文件进载荷');
    Check(FileExists(outExe), '产物 exe 已生成');
    Check(FileExists(outExe + '.lui-tmp') = False, '不留临时文件（先写 tmp 再原子替换）');

    Check(XuiBundleProbe(outExe, info) and info.Valid, '探测尾部载荷：识别为自包含应用');
    Check(info.FileCount = 4, '载荷文件数正确');
    Check(info.PayloadSize > 0, '载荷长度非零');
    fp1 := info.Fingerprint;

    names := XuiBundleList(outExe);
    try
      Check(names.Count = 4, '载荷清单 4 项');
      Check(names.IndexOf('ui/index.ts') >= 0, '清单里保留正斜杠分隔的相对路径');
    finally
      names.Free;
    end;

    entries := XuiBundleEntries(outExe);
    Check(Length(entries) = 4, '目录项可读');
    if Length(entries) = 4 then
      Check(entries[0].Offset = 0, '首项偏移为 0（载荷按 TOC 顺序紧密排列）');

    // 挂载：内容必须与源文件逐字节一致（含二进制）
    mount := '';
    Check(XuiBundleMount(outExe, mount) and (mount <> ''), '载荷挂载到缓存目录');
    Check(DirectoryExists(mount), '挂载目录存在');
    raw := ReadAll(mount + PathDelim + 'a.bin');
    Check(SameBytes(raw, ReadAll(payloadDir + PathDelim + 'a.bin')),
      '二进制文件逐字节还原（NUL / CRLF / 高位字节）');
    raw := ReadAll(mount + PathDelim + 'src' + PathDelim + 'main.xml');
    Check(SameBytes(raw, ReadAll(payloadDir + PathDelim + 'src' + PathDelim + 'main.xml')),
      '子目录结构还原（src/main.xml）');
    Check(FileExists(mount + PathDelim + 'lui.json'), '清单文件随载荷一起带上');

    // 复现性：同一份输入两次构建 → 相同指纹（缓存与增量判断都依赖它）
    Check(XuiBundleBuild(ParamStr(0), outExe, payloadDir, files, n, err), '重复构建成功');
    Check(XuiBundleProbe(outExe, info) and (info.Fingerprint = fp1),
      '相同输入两次构建指纹一致（可复现）');
    fp2 := info.Fingerprint;

    // 挂载幂等：同一个包挂两次应命中缓存（不再重解），且根目录一致
    mount2 := '';
    Check(XuiBundleMount(outExe, mount2), '二次挂载成功');
    Check(ExpandFileName(mount2) = ExpandFileName(mount), '二次挂载命中同一缓存目录');

    // 非容器 / 损坏的 exe 必须被识别为"没有载荷"，而不是读出乱七八糟的东西
    Check(not XuiBundleProbe(ParamStr(0), info),
      '普通 exe（没有尾部载荷）→ 判定为非容器');
    Check(info.Error <> '', '非容器时给出原因（诊断可读）');

    // 截断尾部：magic 之后的长度字段不再自洽，必须拒绝
    raw := ReadAll(outExe);
    SetLength(raw, Length(raw) - 8);
    WriteBytes(base + PathDelim + 'truncated.exe', raw);
    Check(not XuiBundleProbe(base + PathDelim + 'truncated.exe', info),
      '被截断的包 → 拒绝（长度自洽性校验）');

    // 篡改尾部 magic：直接不认
    raw := ReadAll(outExe);
    for i := Length(raw) - 8 to Length(raw) - 1 do
      raw[i] := Byte(Ord('X'));
    WriteBytes(base + PathDelim + 'badmagic.exe', raw);
    Check(not XuiBundleProbe(base + PathDelim + 'badmagic.exe', info),
      '尾部标记被改坏 → 判定为非容器（不会误挂载）');

    // 不允许把运行时自身当输出：那会把模板覆盖掉，运行时就被自己的产物吃掉了
    buf := '';
    Check(not XuiBundleBuild(ParamStr(0), ParamStr(0), payloadDir, files, n, err),
      '拒绝"输出 = 模板"（避免运行时自我覆盖）');
    Check(Pos('覆盖', err) > 0, '给出可读的拒绝原因');

    // 载荷里放 .exe 没有意义：CLI 的收集器会过滤，这里验证容器本身不管这些（只搬运）
    Check(fp2 = fp1, '指纹在多次探测之间稳定');
  finally
    files.Free;
  end;

  if DirectoryExists(base) then
    DeleteDirectory(base, True);
end;


// ---- M13：文件系统补全与进程执行（ui.fs 扩展 / ui.exec）----
//
// 这两块能力是"把真实应用（a_da 的 Agent）从 Pascal 搬进 TS"的前置条件：
// 只有 readText/writeText 时，落 JSONL、建目录、目录遍历、原子替换写都做不了；
// 没有进程执行时，bash 工具根本无从实现。
procedure TestIoFsAndExec;
var
  script: TXuiScript;
  sink: TScriptSink;
  io: TXuiScriptIO;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  bridge: TXuiDomBridge;
  src, base, sub, f1, f2, jsBase, jsF1, jsF2, jsSub: string;
  ioSeq: Integer;

  function Js(const APath: string): string;
  begin
    Result := StringReplace(APath, PathDelim, '/', [rfReplaceAll]);
  end;

  function RunAndPump(const ACode: string): string;
  begin
    Inc(ioSeq);
    sink.Log.Clear;
    script.Run(ACode, 'm13_' + IntToStr(ioSeq) + '.ts');
    repeat
      script.PumpIO;
      script.DrainMicrotasks;
    until (script.IoInFlight = 0) and (script.Interp.MicroTaskCount = 0);
    Result := sink.Log.Text;
  end;

  // 断言日志里出现标记；不匹配时把实际输出打出来——异步+日志的用例只报 FAIL
  // 是查不动的（看不到真实值），这条助手是给后续维护者省时间的
  procedure CheckLog(const AName, AMarker, ASrc: string);
  begin
    if Pos(AMarker, ASrc) > 0 then
      Check(True, AName)
    else
    begin
      WriteLn('      实际输出: [' +
        StringReplace(StringReplace(ASrc, #13#10, ' / ', [rfReplaceAll]),
          #10, ' / ', [rfReplaceAll]) + ']');
      Check(False, AName);
    end;
  end;

begin
  WriteLn('--- M13 文件系统补全与进程执行 ---');

  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  bridge := TXuiDomBridge.Create(engine, script);
  bridge.Install;
  engine.AttachScript(script);
  script.OnError := @sink.HandleError;
  script.Interp.OnLog := @sink.HandleLog;
  io := script.IO;
  io.SyncMode := True;   // 确定性：不开工作线程，但走的是真实执行器
  io.Executor := nil;

  base := GetTempDir(False) + 'lui-m13-io';
  if DirectoryExists(base) then
    DeleteDirectory(base, True);
  ForceDirectories(base);
  sub := base + PathDelim + 'nested' + PathDelim + 'deep';
  f1 := base + PathDelim + 'a.txt';
  f2 := base + PathDelim + 'b.txt';
  jsBase := Js(base);
  jsF1 := Js(f1);
  jsF2 := Js(f2);
  jsSub := Js(sub);

  try
    // ---- 1. 追加写（JSONL 的落地方式）----
    src := RunAndPump(
      'async function app() {' + #10 +
      '  await ui.fs.writeText("' + jsF1 + '", "l1\n");' + #10 +
      '  await ui.fs.appendText("' + jsF1 + '", "l2\n");' + #10 +
      '  await ui.fs.appendText("' + jsF1 + '", "l3");' + #10 +
      '  return ui.fs.readText("' + jsF1 + '");' + #10 +
      '}' + #10 +
      'app().then(function (t) { console.log("A[" + t + "]"); });');
    Check(script.ErrorCount = 0, 'appendText 无错误');
    Check(Pos('A[l1' + #10 + 'l2' + #10 + 'l3]', src) > 0,
      'appendText 追加到末尾（writeText 不丢内容，可作 JSONL 落盘）');

    // ---- 2. exists / stat ----
    src := RunAndPump(
      'async function st() {' + #10 +
      '  const e1 = await ui.fs.exists("' + jsF1 + '");' + #10 +
      '  const e2 = await ui.fs.exists("' + jsBase + '/nope.txt");' + #10 +
      '  const s = await ui.fs.stat("' + jsF1 + '");' + #10 +
      '  console.log("S" + e1 + e2 + s.exists + s.isDir + ":" + s.size + ":" + (s.mtimeMs > 0));' + #10 +
      '}' + #10 +
      'st().then(function () {});');
    Check(Pos('Struefalse', src) > 0, 'exists 对存在/不存在的路径分别返回 true/false');
    CheckLog('stat 给出 size / isDir / mtimeMs（文件大小与真实字节数一致）',
      'truefalse:' + IntToStr(Length('l1' + #10 + 'l2' + #10 + 'l3')) + ':true', src);

    // ---- 3. mkdir（多级）+ listDir ----
    src := RunAndPump(
      'async function mk() {' + #10 +
      '  await ui.fs.mkdir("' + jsSub + '");' + #10 +
      '  await ui.fs.writeText("' + jsSub + '/inner.ts", "x");' + #10 +
      '  const top = await ui.fs.listDir("' + jsBase + '");' + #10 +
      '  let names = top.map(function (e) { return e.name + (e.isDir ? "/" : ""); });' + #10 +
      '  const inner = await ui.fs.listDir("' + jsSub + '");' + #10 +
      '  console.log("L" + names.join(",") + "|" + inner.length + ":" + inner[0].name);' + #10 +
      '}' + #10 +
      'mk().then(function () {});');
    Check(script.ErrorCount = 0, 'mkdir 建多级目录 + listDir 无错误');
    CheckLog('listDir 返回名称/是否目录（已排序），子目录内容可再遍历',
      'La.txt,nested/|1:inner.ts', src);

    src := RunAndPump(
      'ui.fs.listDir("' + jsBase + '/not-a-dir").then(function () {}, ' +
      'function (e) { console.log("LR" + e); });');
    Check(Pos('LR', src) > 0, 'listDir 对不存在的目录 reject（不是静默返回空数组）');

    // ---- 4. rename（覆盖已存在目标：原子替换写的基础）----
    src := RunAndPump(
      'async function rn() {' + #10 +
      '  await ui.fs.writeText("' + jsF2 + '", "old");' + #10 +
      '  await ui.fs.writeText("' + jsBase + '/tmp.part", "new");' + #10 +
      '  await ui.fs.rename("' + jsBase + '/tmp.part", "' + jsF2 + '");' + #10 +
      '  const t = await ui.fs.readText("' + jsF2 + '");' + #10 +
      '  const gone = await ui.fs.exists("' + jsBase + '/tmp.part");' + #10 +
      '  console.log("R" + t + ":" + gone);' + #10 +
      '}' + #10 +
      'rn().then(function () {});');
    CheckLog('rename 覆盖已存在的目标文件，且源文件消失（替换写可用）',
      'Rnew:false', src);

    // ---- 5. remove ----
    src := RunAndPump(
      'async function rm() {' + #10 +
      '  const r1 = await ui.fs.remove("' + jsF2 + '");' + #10 +
      '  const r2 = await ui.fs.remove("' + jsF2 + '");' + #10 +
      '  console.log("D" + r1 + ":" + r2 + ":" + (await ui.fs.exists("' + jsF2 + '")));' + #10 +
      '}' + #10 +
      'rm().then(function () {});');
    CheckLog('remove 删除文件返回 true；删不存在的返回 false（不抛错）',
      'Dtrue:false:false', src);

    // ---- 6. 相对路径锚定应用根 ----
    XuiAppRootOverride := base;
    src := RunAndPump(
      'async function rel() {' + #10 +
      '  await ui.fs.mkdir("logs");' + #10 +
      '  await ui.fs.appendText("logs/e.jsonl", "{}");' + #10 +
      '  const s = await ui.fs.stat("logs/e.jsonl");' + #10 +
      '  console.log("P" + s.exists + ":" + s.size);' + #10 +
      '}' + #10 +
      'rel().then(function () {});');
    CheckLog('相对路径按应用根解析（写操作也需要确定的落点，不能依赖当前工作目录）',
      'Ptrue:2', src);
    XuiAppRootOverride := '';
    Check(FileExists(base + PathDelim + 'logs' + PathDelim + 'e.jsonl'),
      '相对路径确实落在应用根下（磁盘上可见）');

    // ---- 7. 进程执行 ----
    {$IFDEF WINDOWS}
    src := RunAndPump(
      'ui.exec.run("echo hello-m13").then(function (r) {' + #10 +
      '  console.log("E" + r.ok + ":" + r.exitCode + ":" + r.stdout.indexOf("hello-m13") + ' +
      '":" + r.timedOut + ":" + r.truncated);' + #10 +
      '});');
    CheckLog('ui.exec.run 执行命令：退出码 0、stdout 与 stderr 分流、未超时未截断',
      'Etrue:0:0:false:false', src);

    src := RunAndPump(
      'ui.exec.run("exit /b 3").then(function (r) {' + #10 +
      '  console.log("X" + r.ok + ":" + r.exitCode);' + #10 +
      '});');
    CheckLog('非零退出码不算 Promise 失败（命令跑了就是成功，判定交给调用方）',
      'Xtrue:3', src);

    src := RunAndPump(
      'ui.exec.run("echo oops 1>&2").then(function (r) {' + #10 +
      '  console.log("W" + (r.stderr.indexOf("oops") >= 0) + ":" + r.stdout.length);' + #10 +
      '});');
    Check(Pos('Wtrue:0', src) > 0, 'stderr 与 stdout 分开捕获（不混流）');

    src := RunAndPump(
      'ui.exec.run("ping -n 6 127.0.0.1 > nul", { timeout: 250 }).then(function (r) {' + #10 +
      '  console.log("T" + r.timedOut + ":" + r.exitCode);' + #10 +
      '}, function (e) { console.log("TE[" + e + "]"); });');
    CheckLog('超时终止进程并标记 timedOut（exitCode=-1）——否则一个挂住的命令会锁死 Agent',
      'Ttrue:-1', src);

    src := RunAndPump(
      'ui.exec.run("for /l %i in (1,1,400) do @echo 0123456789", { maxBytes: 64 })' +
      '.then(function (r) {' + #10 +
      '  console.log("C" + r.truncated + ":" + (r.stdout.length <= 64));' + #10 +
      '}, function (e) { console.log("CE[" + e + "]"); });');
    CheckLog('输出上限生效并标记 truncated（大输出不会撑爆内存与 UI）',
      'Ctrue:true', src);

    src := RunAndPump(
      'ui.exec.run("echo zzz", { cwd: "' + jsBase + '" }).then(function (r) {' + #10 +
      '  console.log("K" + r.ok + ":" + r.exitCode);' + #10 +
      '});');
    Check(Pos('Ktrue:0', src) > 0, 'cwd 参数生效（在工作区内执行）');
    {$ENDIF}

    src := RunAndPump(
      'ui.exec.run("").then(function () { console.log("NE[none]"); }, ' +
      'function (e) { console.log("NE" + e); });');
    CheckLog('空命令 reject（走 Promise 拒绝而不是引擎级异常，调用方能 catch）', 'NE', src);

    // ---- 8. Array 查找与排序（移植真实应用代码的基础）----
    src := RunAndPump(
      'const xs = [{ n: 3, k: "c" }, { n: 1, k: "a" }, { n: 2, k: "b" }];' + #10 +
      'const f = xs.find(function (x) { return x.n === 2; });' + #10 +
      'const fi = xs.findIndex(function (x) { return x.n === 9; });' + #10 +
      'const so = xs.some(function (x) { return x.n > 2; });' + #10 +
      'const ev = xs.every(function (x) { return x.n > 0; });' + #10 +
      'const ev2 = xs.every(function (x) { return x.n > 1; });' + #10 +
      'const sorted = xs.slice().sort(function (a, b) { return a.n - b.n; });' + #10 +
      'const str = xs.slice().sort();' + #10 +
      'const empty = [];' + #10 +
      'console.log("F" + f.k + fi + so + ev + ev2 + "|" + ' +
      'sorted.map(function (x) { return x.k; }).join("") + "|" + ' +
      'str.map(function (x) { return x.k; }).join("") + "|" + ' +
      'empty.some(function () { return true; }) + ' +
      'empty.every(function () { return false; }) + ' +
      '(empty.find(function () { return true; }) === undefined));');
    CheckLog('Array find/findIndex/some/every/sort（含空数组语义与默认字符串排序）',
      'Fb-1truetruefalse|abc|cab|falsetruetrue', src);
    // ---- 9. 字符串码点工具（移植真实应用时必备）----
    src := RunAndPump(
      'const s = "a" + String.fromCharCode(13) + String.fromCharCode(10) + "中";' + #10 +
      'console.log("CC" + s.length + ":" + s.charCodeAt(0) + ":" + ' +
      's.charCodeAt(1) + ":" + s.charCodeAt(2) + ":" + s.charCodeAt(3) + ' +
      '":" + s.charCodeAt(9));');
    CheckLog('String.fromCharCode / charCodeAt（码点下标，越界给 0）',
      'CC4:97:13:10:20013:0', src);

    src := RunAndPump(
      'console.log("CP" + String.fromCharCode(65, 66) + ":" + ' +
      'String.fromCharCode(20013).length);');
    CheckLog('String.fromCharCode 多参拼接与多字节码点长度', 'CPAB:1', src);
  finally
    script.Free;
    sink.Free;
    engine.Free;
    if DirectoryExists(base) then
      DeleteDirectory(base, True);
  end;
end;
