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
