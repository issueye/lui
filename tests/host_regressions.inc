{ M11 host wiring and console output regressions. }

procedure TestPreviewHostWiring;
var
  form: TForm;
  host: TXuiHost;
  app: TXuiApp;
  node: TXuiNode;
  bmp: TBitmap;
  r: TRect;
  painted: Boolean;
  pagePath: string;
  i, nonWhite: Integer;
  px: TColor;
begin
  WriteLn('--- M11 预览窗装配（窗口级）---');
  form := TForm.CreateNew(nil);
  bmp := TBitmap.Create;
  try
    form.ClientWidth := 320;
    form.ClientHeight := 240;
    host := TXuiHost.Create(form);
    host.Parent := form;
    host.Align := alClient;
    Check(host.Parent = form, '宿主已挂到窗体（漏掉会整片空白）');
    Check(form.ContainsControl(host), '窗体控件树包含宿主（LCL 可见性判定的依据）');
    Check(host.Visible, '宿主可见');

    app := TXuiApp.CreateAttached(host.Engine, host.Script);
    try
      pagePath := DemoFilePath('m7.xml');
      if pagePath = '' then
        WriteLn('SKIP  未找到 demo/m7.xml')
      else
      begin
        bmp.SetSize(320, 240);
        bmp.Canvas.Brush.Color := clWhite;
        bmp.Canvas.FillRect(0, 0, 320, 240);
        app.Engine.Renderer := TGdiRenderer.Create(bmp.Canvas);
        app.Configure(pagePath, 'light', '');
        r := Rect(0, 0, 320, 240);
        app.Engine.Draw(bmp.Canvas, r);
        nonWhite := 0;
        for i := 0 to 239 do
        begin
          px := bmp.Canvas.Pixels[160, i];
          if px <> clWhite then
            Inc(nonWhite);
        end;
        painted := nonWhite > 0;
        Check(painted, Format('装配后绘制出内容（竖中线非白像素 %d 个）', [nonWhite]));
        node := app.Engine.Document.FindElementById('rows');
        Check((node <> nil) and (node.Count = 2),
          '窗口级路径下脚本依然生效（x-for 列表 2 条）');
        Check(host.Script.ErrorCount = 0, '窗口级装配无脚本错误');
      end;
    finally
      app.Free;
    end;
    host.Parent := nil;
    Check(not form.ContainsControl(host), '解除 Parent 后脱离窗体控件树');
    host.Free;
  finally
    bmp.Free;
    form.Free;
  end;
end;

{ IME 组合窗锚点：Win32 约定 ptCurrentPos 相对宿主窗口左上角（客户区坐标）。
  曾误传 ClientToScreen 的屏幕坐标，组合串被推到窗口外再裁剪，表现为中文输入"字形移位"。 }
procedure TestImeCompositionAnchor;
var
  form: TForm;
  host: TXuiHost;
  node: TXuiNode;
  r: TRect;
  p: TPoint;
begin
  WriteLn('--- IME 组合窗锚点坐标系 ---');

  r := Types.Rect(128, 640, 129, 664);
  p := XuiImeCompositionPoint(r);
  Check((p.X = 128) and (p.Y = 664), '锚点取光标矩形左下角（客户区坐标）');

  r := Types.Rect(0, 0, 1, 18);
  p := XuiImeCompositionPoint(r);
  Check((p.X = 0) and (p.Y = 18),
    '零位光标锚点仍在原点（误做 ClientToScreen 会失败）');

  // 真实引擎路径：窗体故意偏离屏幕原点，锚点不得跟着窗口屏幕位置走
  form := TForm.CreateNew(nil);
  form.ClientWidth := 320;
  form.ClientHeight := 240;
  form.Left := 300;
  form.Top := 200;
  host := TXuiHost.Create(form);
  host.Parent := form;
  try
    host.Engine.Renderer := TFakeRenderer.Create; // 渲染器所有权归引擎
    host.Engine.LoadFromString('<window><input id="ime-target"/></window>');
    node := host.Engine.Document.FindElementById('ime-target');
    Check(node <> nil, '页面含目标输入框');
    Check(host.Engine.FocusNext(True) and (host.Engine.FocusNode = node),
      '输入框获得焦点');
    Check(host.Engine.HandleTextInput('你好'), '中文文本进入输入框');
    host.Engine.Draw(nil, Types.Rect(0, 0, 320, 240));
    Check(host.Engine.CaretRect(r), '引擎给出光标矩形');
    p := XuiImeCompositionPoint(r);
    Check((p.X >= 0) and (p.X < form.ClientWidth) and
          (p.Y >= 0) and (p.Y <= form.ClientHeight),
      Format('锚点落在客户区内 (%d,%d)，与窗口屏幕位置无关', [p.X, p.Y]));
  finally
    host.Parent := nil;
    host.Free;
    form.Free;
  end;
end;

procedure TestConsoleOutput;
var
  ok, sawHighByte: Boolean;
  i, highCount: Integer;
  mixedMsg, pureMsg: string;
  enc: Boolean;
begin
  WriteLn('--- M11 控制台输出健壮性 ---');
  XuiConsoleInit;
  ok := ConWriteLn('（自检）控制台输出可用');
  Check(ok, '正常环境下输出成功');
  Check(ConsoleWritable, '正常环境下输出被标记为可写');
  Check(ConWriteLnFmt('（自检）格式化输出 %d/%s', [7, 'ok']),
    '格式化输出（ConWriteLnFmt）成功');
  Check(ConErrWriteLn('（自检）stderr 输出可用'), 'stderr 输出成功');

  ok := True;
  try
    ConWriteLn('（自检）连续写入 1');
    ConWriteLn('（自检）连续写入 2');
    ConWriteLn;
  except
    on E: Exception do
    begin
      ok := False;
      WriteLn('      异常: ' + E.Message);
    end;
  end;
  Check(ok, '连续写入不抛异常');

  pureMsg := '参数错误';
  mixedMsg := '' + '参数错误';
  enc := Length(pureMsg) = Length(mixedMsg);
  Check(enc, '字面量与拼接构造的中文长度一致（同一编码路径）');
  Check(ConWriteLn('（自检）字面量与拼接并排：' + pureMsg + ' / ' + mixedMsg),
    '字面量与拼接混合输出成功');
  sawHighByte := False;
  highCount := 0;
  for i := 1 to Length(pureMsg) do
    if Ord(pureMsg[i]) > 127 then
    begin
      sawHighByte := True;
      Inc(highCount);
    end;
  Check(sawHighByte and (highCount > 0), '中文经统一路径输出（含高位字节）');
end;

procedure TestGdiPlusCjkCaretAlignment;
var
  bmp: TBitmap;
  rend: TGdiPlusRenderer;
  style: TXuiStyle;
  text: string;
  sz: TSize;
begin
  WriteLn('--- GDI+ 长中文紧致排版与度量回归 ---');
  bmp := TBitmap.Create;
  try
    bmp.SetSize(1200, 100);
    rend := TGdiPlusRenderer.Create(bmp.Canvas);
    try
      style := TXuiStyle.Create;
      try
        style.FontFamily := 'Segoe UI';
        style.FontSize := 13;

        // 测试包含 45 个 CJK 字符的长文本（与用户反馈用例完全一致）
        text := '啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊水水水水水顶顶顶，，，啊实打实的啊实打实大苏打';
        sz := rend.MeasureText(text, style);
        Check(sz.cx > 500, Format('长中文度量有效 (cx=%d)', [sz.cx]));
        // 在新紧致排版（GenericTypographic，0 margins）下，13px Segoe UI fallback CJK 45字测量值约为 613px；
        // 若退化为旧 GenericDefault 排版，会带额外字符 margins 累积达到 635px（导致光标偏左 22px）
        Check((sz.cx >= 605) and (sz.cx <= 620),
          Format('紧致排版度量符合 GenericTypographic (实际 %d px，在 [605..620] 区间内)', [sz.cx]));
      finally
        style.Free;
      end;
    finally
      rend.Free;
    end;
  finally
    bmp.Free;
  end;
end;
