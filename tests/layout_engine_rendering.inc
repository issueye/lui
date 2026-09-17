{ M3：引擎绘制、裁剪、可见性与绘制顺序 }

procedure TestEngineRendering;
var
  engine: TXuiEngine;
  renderer: TFakeRenderer;
begin
  WriteLn('--- 引擎绘制：裁剪 / visibility / 绘制序 ---');

  renderer := TFakeRenderer.Create;
  engine := TXuiEngine.Create;
  try
    engine.Renderer := renderer; // 引擎接管渲染器所有权
    engine.LoadFromString(
      '<window>' +
      '  <panel id="clip"><label text="inside"/></panel>' +
      '  <label id="hid" text="看不见"/>' +
      '  <label id="vis" text="看得见"/>' +
      '  <panel id="z1"><label text="上层"/></panel>' +
      '  <panel id="z2"><label text="下层"/></panel>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      '#clip { overflow:hidden; width:100px; height:50px; } ' +
      '#hid { visibility:hidden; } ' +
      '#z1 { position:absolute; left:0; top:0; z-index:2; width:30px; height:20px; } ' +
      '#z2 { position:absolute; left:0; top:0; z-index:1; width:30px; height:20px; }');

    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));

    Check(renderer.CountOf('push') = 1, 'overflow:hidden 触发 PushClip');
    Check(renderer.CountOf('pop') = 1, 'overflow:hidden 触发 PopClip');
    Check(renderer.CountOf('text') = 4, '共绘制 4 段文本（hidden 的除外）');
    Check(not renderer.TextDrawn('看不见'), 'visibility:hidden 不绘制');
    Check(renderer.TextDrawn('看得见'), 'visible 正常绘制');
    Check(renderer.TextDrawIndex('下层') < renderer.TextDrawIndex('上层'),
      'z-index 小的先绘制（下层在下）');
  finally
    engine.Free;
  end;
end;
