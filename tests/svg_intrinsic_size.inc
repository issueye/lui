{ R7：SVG 图标的固有尺寸必须在样式级联后保留（否则布局按 0×0、绘制按自身尺寸） }

procedure TestSvgIntrinsicSize;
var
  engine: TXuiEngine;
  renderer: TFakeRenderer;
  ic, lbl, row: TXuiNode;
begin
  WriteLn('--- R7：SVG 固有尺寸 ---');

  renderer := TFakeRenderer.Create;
  engine := TXuiEngine.Create;
  try
    engine.Renderer := renderer;
    engine.LoadFromString(
      '<window><panel id="row">' +
      '<svg id="ic" viewBox="0 0 24 24" width="16" height="16">' +
      '<path d="M0 0h24v24H0z" fill="currentColor"/></svg>' +
      '<label id="t" text="abcd"/>' +
      '</panel></window>');
    engine.LoadStyleSheetFromString('#row { display:flex; column-gap:6px; }');
    engine.Draw(nil, Rect(0, 0, 200, 100));

    ic := engine.Document.FindElementById('ic');
    lbl := engine.Document.FindElementById('t');
    row := engine.Document.FindElementById('row');

    Check((not ic.Style.Width.IsAuto) and (Round(ic.Style.Width.Value) = 16),
      'width 属性在样式计算后仍然生效');
    Check(ic.BoxRect.Right - ic.BoxRect.Left = 16,
      Format('SVG 占据 16px 宽度 [实际 %d]', [ic.BoxRect.Right - ic.BoxRect.Left]));
    Check(ic.BoxRect.Bottom - ic.BoxRect.Top = 16, 'SVG 占据 16px 高度');
    Check(lbl.BoxRect.Left = 22,
      Format('后续文本偏移 = 图标宽 + gap [实际 %d]', [lbl.BoxRect.Left]));
    Check(row.BoxRect.Right - row.BoxRect.Left = 200, '容器仍填满可用宽度');

    // CSS 显式尺寸优先于属性（属性只是缺省值）
    engine.LoadStyleSheetFromString(
      '#row { display:flex; column-gap:6px; } #ic { width:24px; height:24px; }');
    engine.Draw(nil, Rect(0, 0, 200, 100));
    ic := engine.Document.FindElementById('ic');
    lbl := engine.Document.FindElementById('t');
    Check(ic.BoxRect.Right - ic.BoxRect.Left = 24,
      Format('CSS 显式尺寸覆盖属性 [实际 %d]', [ic.BoxRect.Right - ic.BoxRect.Left]));
    Check(lbl.BoxRect.Left = 30, '覆盖后文本偏移按 CSS 尺寸计算');
  finally
    engine.Free;
  end;
end;
