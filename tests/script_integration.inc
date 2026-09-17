{ M6：脚本 DOM 集成、事件桥接与错误路由 }

procedure TestScriptIntegration;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  btn: TXuiNode;
begin
  WriteLn('--- M6 脚本集成（DOM 桥 / 事件 / 错误）---');

  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.Run(
        'function OnBtnClick() {' + #10 +
        '  const n = document.find("btn");' + #10 +
        '  n.text = "clicked"; n.class = "hot";' + #10 +
        '}' + #10 +
        'function Boot() {' + #10 +
        '  document.find("btn").on("mouseenter", function (e) {' + #10 +
        '    document.find("tip").text = "hover:" + e.type;' + #10 +
        '  });' + #10 +
        '}', 'app.ts');
      Check(script.ErrorCount = 0, '脚本求值无错误');
      Check(script.HasGlobalFunction('OnBtnClick'), '全局函数可被查询（事件第二来源）');
      Check(not script.HasGlobalFunction('NotDefined'), '未定义函数查询为假');

      engine.LoadFromString(
        '<window><panel>' +
        '  <button id="btn" text="原始" onclick="OnBtnClick"/>' +
        '  <label id="tip" text="none"/>' +
        '</panel></window>');
      engine.LoadStyleSheetFromString(
        '#btn { width:80px; height:30px; } .hot { background-color:#ff0000; }');
      DrawEngine(engine);
      btn := engine.Document.FindElementById('btn');
      Check(btn <> nil, '节点就绪');

      ClickNode(engine, btn);
      DrawEngine(engine);
      Check(btn.Text = 'clicked', 'onclick 回退到脚本全局函数并改写文本');
      Check(btn.HasClass('hot'), '脚本可设置类名');
      Check((btn.Style <> nil) and (btn.Style.BgColor.R = $FF), '类名变更后样式生效');

      script.CallGlobal('Boot', []);
      engine.HandleMouseMove(295, 195);
      engine.HandleMouseMove((btn.BoxRect.Left + btn.BoxRect.Right) div 2,
        (btn.BoxRect.Top + btn.BoxRect.Bottom) div 2);
      DrawEngine(engine);
      Check(engine.Document.FindElementById('tip').Text = 'hover:onmouseenter',
        '动态绑定收到事件并携带事件对象');

      script.OnError := @sink.HandleError;
      script.Run('function Boom() { throw "内部错误"; }', 'bad.ts');
      script.CallGlobal('Boom', []);
      Check(sink.LastError <> '', '脚本运行时错误经 OnError 上报');
      Check(sink.LastErrorStage = ssRuntime, '错误阶段标记为运行时');

      script.Run('function Slow() { let s = 0; let i;' +
        ' for (i = 0; i < 50000; i++) { s += i; } return s; }', 'slow.ts');
      Check(Round(script.CallGlobal('Slow', []).Num) = 1249975000, '首次调用完成');
      Check(Round(script.CallGlobal('Slow', []).Num) = 1249975000,
        '重复调用同样通过（预算不累积）');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;
