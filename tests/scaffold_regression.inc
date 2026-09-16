{ M11 project scaffold generation and generated-project integration. }

procedure TestScaffold;
var
  base, proj, pagePath, scriptPath, cssLightPath, cssDarkPath: string;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node: TXuiNode;
  lines: TStringList;
  jsonText, cmdText: string;

  function HasNonAscii(const S: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    for k := 1 to Length(S) do
      if Ord(S[k]) > 127 then
        Exit(True);
  end;

  function ReadFileRaw(const APath: string): string;
  var
    fs: TFileStream;
  begin
    Result := '';
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(Result[1], fs.Size);
    finally
      fs.Free;
    end;
  end;

  function ReadText(const APath: string): string;
  begin
    Result := ReadFileRaw(APath);
  end;

  function Gen(ATarget: string; AForce: Boolean): Boolean;
  var
    o: TXuiScaffoldOptions;
    r: TXuiScaffoldResult;
  begin
    o := Default(TXuiScaffoldOptions);
    o.TargetDir := ATarget;
    o.Width := 480;
    o.Height := 560;
    o.Theme := 'light';
    o.LuiVersion := '0.10.0';
    o.RendererPath := 'C:\fake\lui-render.exe';
    o.Force := AForce;
    Result := XuiScaffoldCreate(o, r);
    if not Result then
      WriteLn('      失败原因: ' + r.Error);
    r.Files.Free;
    r.Skipped.Free;
  end;

begin
  WriteLn('--- M11 项目脚手架（--init）---');
  if XuiScaffoldDir = '' then
  begin
    WriteLn('SKIP  未找到 scaffold/（模板目录）');
    Exit;
  end;
  base := GetTempDir(False) + 'lui-scaffold-test';
  proj := base + PathDelim + 'myapp';
  if DirectoryExists(base) then
    DeleteDirectory(base, True);
  try
    if not Gen(proj, False) then
    begin
      Check(False, '脚手架生成成功（模板与 ui/ 运行时均定位到）');
      Exit;
    end;
    Check(True, '脚手架生成成功（模板与 ui/ 运行时均定位到）');
    pagePath := proj + PathDelim + 'src' + PathDelim + 'main.xml';
    scriptPath := proj + PathDelim + 'src' + PathDelim + 'main.ts';
    cssLightPath := proj + PathDelim + 'src' + PathDelim + 'main-light.css';
    cssDarkPath := proj + PathDelim + 'src' + PathDelim + 'main-dark.css';

    Check(FileExists(pagePath), '生成入口页面 src/main.xml');
    Check(FileExists(scriptPath), '生成页面逻辑 src/main.ts');
    Check(FileExists(cssLightPath), '生成浅色样式 src/main-light.css');
    Check(FileExists(cssDarkPath), '生成深色样式 src/main-dark.css');
    Check(FileExists(proj + PathDelim + 'lui-project.json'), '生成工程清单 lui-project.json');
    Check(FileExists(proj + PathDelim + 'run-dev.cmd'), '生成 run-dev.cmd（开发）');
    Check(FileExists(proj + PathDelim + 'run-test.cmd'), '生成 run-test.cmd（测试）');
    Check(FileExists(proj + PathDelim + 'run-pack.cmd'), '生成 run-pack.cmd（打包交付）');
    Check(FileExists(proj + PathDelim + 'README.md'), '生成 README.md');
    Check(FileExists(proj + PathDelim + '.gitignore'),
      'gitignore 模板还原为 .gitignore（模板名不能以点开头，否则会被 git 当忽略规则）');
    Check(FileExists(proj + PathDelim + 'ui' + PathDelim + 'index.ts'),
      '自带组件库运行时 ui/index.ts（生成即不依赖 lui 仓库）');
    Check(FileExists(proj + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css'),
      '自带组件库主题 ui/theme/lui-light.css');

    jsonText := ReadText(proj + PathDelim + 'lui-project.json');
    Check(Pos('"name": "myapp"', jsonText) > 0, '清单里回填工程名（默认取目录名）');
    Check(Pos('"width": "480"', jsonText) > 0, '清单里回填视口宽（--init -w）');
    Check(Pos('"height": "560"', jsonText) > 0, '清单里回填视口高（--init -H）');
    Check(Pos('C:/fake/lui-render.exe', jsonText) > 0,
      '清单里渲染器路径用正斜杠（JSON/跨工具友好）');
    Check(Pos('@@', jsonText) = 0, '清单里占位符已全部替换');
    cmdText := ReadText(proj + PathDelim + 'run-dev.cmd');
    Check(Pos('C:\fake\lui-render.exe', cmdText) > 0,
      '.cmd 里渲染器路径用原生分隔符（cmd.exe 语义正确）');
    Check(Pos('@@', cmdText) = 0, '.cmd 里占位符已全部替换');
    Check(Pos(#13#10, cmdText) > 0, '.cmd 用 CRLF 换行（cmd 对 LF-only 的标签解析不可靠）');
    Check(Pos(#$EF#$BB#$BF, cmdText) = 0, '生成文件不写 BOM');
    Check(not HasNonAscii(cmdText), '.cmd 保持纯 ASCII（cmd.exe 按 OEM 码页解码，非 ASCII 会乱码）');
    Check(not HasNonAscii(ReadText(proj + PathDelim + 'run-test.cmd')),
      '.cmd 保持纯 ASCII（run-test.cmd）');
    Check(not HasNonAscii(ReadText(proj + PathDelim + 'run-pack.cmd')),
      '.cmd 保持纯 ASCII（run-pack.cmd）');

    lines := TStringList.Create;
    try
      lines.LoadFromFile(pagePath);
      Check(Pos('width="480"', lines.Text) > 0, '页面 window 回填视口宽');
      Check(Pos('@@', lines.Text) = 0, '页面里占位符已全部替换');
    finally
      lines.Free;
    end;
    lines := TStringList.Create;
    try
      lines.Text := '// 用户手改过，不该被覆盖' + LineEnding;
      lines.SaveToFile(scriptPath);
    finally
      lines.Free;
    end;
    Check(Gen(proj, False), '对已存在工程再生成一次（默认策略）不报错');
    Check(Pos('用户手改过', ReadText(scriptPath)) > 0,
      '默认跳过已存在文件：用户改动被保留');
    Check(Gen(proj, True), '--force 重新生成不报错');
    Check(Pos('用户手改过', ReadText(scriptPath)) = 0,
      '--force 覆盖已存在文件（模板内容回来）');
    Check(not Gen(base, False),
      '已存在且非 lui 工程的目录：默认拒写（不往任意目录铺文件）');
    Check(Gen(base, True), '同上目录加 --force 后允许写入');

    engine := NewTestEngine(fake);
    script := TXuiScript.Create;
    sink := TScriptSink.Create;
    try
      bridge := TXuiDomBridge.Create(engine, script);
      try
        bridge.Install;
        engine.AttachScript(script);
        script.OnError := @sink.HandleError;
        script.Interp.OnLog := @sink.HandleLog;
        engine.LoadStyleSheetFromFile(proj + PathDelim + 'ui' + PathDelim + 'theme' +
          PathDelim + 'lui-light.css');
        engine.LoadStyleSheetFromFile(cssLightPath);
        engine.LoadFromFile(pagePath);
        DrawEngine(engine);
        Check(script.ErrorCount = 0, '生成的起步页装配与脚本执行无错误');
        node := engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 3),
          'x-for 渲染出 3 条初始条目（脚本里的 reactive 状态生效）');
        Check(engine.Document.FindElementById('btn-add') <> nil,
          '组件库组件 ui-button 实例化成功（自带 ui/ 运行时可用）');
        Check(engine.Document.FindElementById('draft') <> nil,
          '组件库组件 ui-input 实例化成功');
        Check(engine.Document.FindElementById('filter') <> nil, '原生 button 存在');

        script.CallGlobal('OnAdd', []);
        script.FlushReactive;
        DrawEngine(engine);
        node := engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 3),
          '空输入不新增（OnAdd 里 trim 后为空即返回）');
        script.CallGlobal('Toggle', [script.Num(1)]);
        script.FlushReactive;
        DrawEngine(engine);
        node := engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 3),
          '切换完成态不增删条目（Toggle 只改 done 标志）');
        script.CallGlobal('OnToggleFilter', []);
        script.FlushReactive;
        DrawEngine(engine);
        node := engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 1),
          '只看未完成：computed 过滤生效（初始 1 条完成，再切 1 条 → 剩 1 条）');
        Check(script.ErrorCount = 0, '交互后无脚本错误');

        engine.LoadStyleSheetFromString('');
        engine.LoadFromFile(pagePath);
        DrawEngine(engine);
        node := engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 3), '重置页面后列表回到 3 条');
        if (node <> nil) and (node.Count > 0) then
        begin
          Check(node[0].HasClass('item'), '条目根节点带 item 类');
          Check(node[0].Count = 3, '条目行含标记/标题/删除按钮三个子节点');
          Check(node[1].HasClass('done'),
            '第二条初始为完成态（脚本初始数据 done:true → :class 生效）');
          Check(not node[0].HasClass('done'), '第一条非完成态');
        end;
        Check(script.ErrorCount = 0, '重新装配后无脚本错误');
        engine.LoadStyleSheetFromString('');
        engine.LoadFromFile(pagePath);
        DrawEngine(engine);
        Check(script.ErrorCount = 0, '清空样式表后重新装配仍无脚本错误');
      finally
        bridge.Free;
      end;
    finally
      sink.Free;
      script.Free;
      engine.Free;
    end;
  finally
    if DirectoryExists(proj) then
      DeleteDirectory(proj, True);
    if DirectoryExists(base) then
      DeleteDirectory(base, True);
  end;
end;
