{ M7 demo page loading through the real document/script path. }

procedure TestDemoPage;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node, ucRoot: TXuiNode;
  errs: Integer;
  xmlPath, cssPath: string;
begin
  WriteLn('--- M7 演示页（demo/m7）---');
  xmlPath := DemoFilePath('m7.xml');
  if xmlPath = '' then
  begin
    WriteLn('SKIP  未找到 demo/m7.xml');
    Exit;
  end;
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
      cssPath := DemoFilePath('m7-light.css');
      if cssPath <> '' then
        engine.LoadStyleSheetFromFile(cssPath);
      engine.LoadFromFile(xmlPath);
      DrawEngine(engine);

      Check(script.ErrorCount = 0, '演示页 m7：整页加载无脚本错误');
      node := engine.Document.FindElementById('uc-head');
      Check((node <> nil) and (node.Parent <> nil) and node.Parent.HasClass('ucard'),
        '演示页 m7：脚本注册的组件被实例化（具名 slot 内容进入 .ucard 实例根）');
      node := engine.Document.FindElementById('cnt');
      Check((node <> nil) and (Pos('点击 0 次（平方 0）', node.Text) > 0),
        '演示页 m7：插值 + computed 首渲染');
      node := engine.Document.FindElementById('rows');
      Check((node <> nil) and (node.Count = 2), '演示页 m7：keyed x-for 渲染初始 2 条');

      script.CallGlobal('OnInc', []);
      script.FlushReactive;
      DrawEngine(engine);
      node := engine.Document.FindElementById('cnt');
      Check((node <> nil) and (Pos('点击 1 次（平方 1）', node.Text) > 0),
        '演示页 m7：改状态后插值/computed 自动刷新');
      node := engine.Document.FindElementById('uc-head');
      ucRoot := nil;
      if node <> nil then
        ucRoot := node.Parent;
      Check((ucRoot <> nil) and (ucRoot.Count = 3) and
        (Pos('1 次点击', ucRoot[1].Text) > 0),
        '演示页 m7：函数 prop 在组件模板内随 props 重新求值');

      if DemoFilePath('script.xml') <> '' then
      begin
        errs := script.ErrorCount;
        engine.LoadFromFile(DemoFilePath('script.xml'));
        DrawEngine(engine);
        Check(script.ErrorCount = errs, '演示页切换 m7 → 脚本页：无脚本错误');
        node := engine.Document.FindElementById('counter');
        Check((node <> nil) and (node.Text = '共 1 条'), '演示页切换 m7 → 脚本页：新页脚本生效');
        script.CallGlobal('OnAdd', []);
        script.FlushReactive;
        DrawEngine(engine);
        node := engine.Document.FindElementById('counter');
        Check((node <> nil) and (node.Text = '共 2 条'), '演示页切换后：脚本功能仍可用');
      end;
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
