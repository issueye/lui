{ R7：box-shadow 解析与绘制层次 }

procedure TestBoxShadow;
var
  engine: TXuiEngine;
  renderer: TFakeRenderer;
  n: TXuiNode;
begin
  WriteLn('--- R7：box-shadow ---');

  renderer := TFakeRenderer.Create;
  engine := TXuiEngine.Create;
  try
    engine.Renderer := renderer;      // 引擎接管渲染器所有权
    engine.LoadFromString('<window><panel id="card"/></window>');

    // 基线：无阴影时只画一次自身背景
    engine.LoadStyleSheetFromString(
      '#card { width:100px; height:60px; border-radius:8px; background-color:#ffffff; }');
    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));
    Check(renderer.CountOf('roundfill') = 1,
      Format('无 box-shadow 时只有一次圆角背景 [实际 %d]', [renderer.CountOf('roundfill')]));

    // 有阴影：6 层阴影 + 1 次背景
    engine.ClearStyleSheets;
    engine.LoadStyleSheetFromString(
      '#card { width:100px; height:60px; border-radius:8px; background-color:#ffffff; ' +
      'box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4); }');
    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));
    Check(renderer.CountOf('roundfill') = 7,
      Format('有 box-shadow 时为 6 层阴影 + 1 次背景 [实际 %d]',
        [renderer.CountOf('roundfill')]));

    n := engine.Document.FindElementById('card');
    Check(Round(n.Style.BoxShadowX) = 0, 'x 偏移解析为 0');
    Check(Round(n.Style.BoxShadowY) = 4, 'y 偏移解析为 4');
    Check(Round(n.Style.BoxShadowBlur) = 12, '模糊半径解析为 12');
    Check(n.Style.BoxShadowColor.A >= 90, 'rgba alpha 解析（0.4×255≈102）');
    Check((n.Style.BoxShadowColor.R = 0) and (n.Style.BoxShadowColor.B = 0),
      '阴影颜色为黑色');

    // 直角盒子的阴影走 FillRect
    engine.ClearStyleSheets;
    engine.LoadStyleSheetFromString(
      '#card { width:100px; height:60px; background-color:#ffffff; ' +
      'box-shadow: 2px 2px 6px #888888; }');
    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));
    Check(renderer.CountOf('fill') = 8,
      Format('直角盒子：window 背景 1 + 阴影 6 层 + 自身背景 1 [实际 %d]',
        [renderer.CountOf('fill')]));
    n := engine.Document.FindElementById('card');
    Check((Round(n.Style.BoxShadowX) = 2) and (Round(n.Style.BoxShadowBlur) = 6),
      '十六进制颜色与偏移解析');

    // none 清除阴影
    engine.ClearStyleSheets;
    engine.LoadStyleSheetFromString(
      '#card { width:100px; height:60px; border-radius:8px; background-color:#ffffff; ' +
      'box-shadow: none; }');
    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));
    Check(renderer.CountOf('roundfill') = 1, 'box-shadow:none 不产生阴影层');
    Check(engine.Document.FindElementById('card').Style.BoxShadowColor.A = 0,
      'none 把阴影颜色重置为透明');

    // 内联样式同样生效（组件库与宿主都用内联 style）
    engine.ClearStyleSheets;
    engine.LoadFromString(
      '<window><panel id="card" style="width:80px; height:40px; border-radius:6px; ' +
      'background-color:#ffffff; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.3);"/></window>');
    renderer.Clear;
    engine.Draw(nil, Rect(0, 0, 300, 200));
    Check(renderer.CountOf('roundfill') = 7, '内联 box-shadow 同样绘制阴影层');
  finally
    engine.Free;
  end;
end;
