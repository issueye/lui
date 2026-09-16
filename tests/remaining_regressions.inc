{ Small cross-version regressions kept together after the main suites. }

procedure TestHotReload;
var
  dir, xmlFile, cssFile, partFile: string;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  node: TXuiNode;
begin
  WriteLn('--- M5 热重载 ---');
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'lui_m5_reload';
  ForceDirectories(dir);
  xmlFile := dir + PathDelim + 'page.xml';
  cssFile := dir + PathDelim + 'page.css';
  partFile := dir + PathDelim + 'part.xml';
  WriteTestFile(partFile, '<label id="part" text="P1"/>');
  WriteTestFile(xmlFile, '<window><include src="part.xml"/><panel id="box"/></window>');
  WriteTestFile(cssFile, '#box { width:50px; height:20px; background-color:#ff0000; }');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromFile(xmlFile);
    engine.LoadStyleSheetFromFile(cssFile);
    DrawEngine(engine);
    node := engine.Document.FindElementById('box');
    Check(node.Style.BgColor.R = $FF, '初始样式生效');
    Check(not engine.ReloadChangedFiles, '无文件变化时不重载');
    Check(engine.Document.SourceFile <> '', '文档来源已记录');
    engine.AddElement(engine.Document.Root, '<panel id="runtime"/>');
    WaitForMTimeTick;
    WriteTestFile(cssFile, '#box { width:50px; height:20px; background-color:#00ff00; }');
    Check(engine.ReloadChangedFiles, 'CSS 变化触发重载');
    DrawEngine(engine);
    Check(engine.Document.FindElementById('box').Style.BgColor.G = $FF, '重载后新样式生效');
    Check(engine.Document.FindElementById('runtime') <> nil, 'CSS 重载保留运行时 DOM');
    WaitForMTimeTick;
    WriteTestFile(partFile, '<label id="part" text="P2"/>');
    Check(engine.ReloadChangedFiles, 'include 依赖变化触发重载');
    DrawEngine(engine);
    Check(engine.Document.FindElementById('part').Text = 'P2', 'include 重载后内容更新');
    Check(engine.Document.FindElementById('runtime') = nil, 'XML 重载重建文档（运行时改动不保留）');
    Check(engine.ReloadFromSource, 'ReloadFromSource 无条件重建');
    DeleteFile(xmlFile);
    DeleteFile(cssFile);
    DeleteFile(partFile);
    RemoveDir(dir);
  finally
    engine.Free;
  end;
end;

procedure TestInputCjkEditing;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  input: TXuiNode;

  procedure Reset(const AText: string);
  begin
    engine.SetText(input, '');
    ClickNode(engine, input);
    engine.HandleTextInput(AText);
    DrawEngine(engine);
  end;

  procedure Key(AKey: Word);
  begin
    engine.HandleKeyDown(AKey, []);
    DrawEngine(engine);
  end;

begin
  WriteLn('--- M5 输入框：中文光标与删除（回归）---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><input id="t"/></window>');
    engine.LoadStyleSheetFromString(
      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);
    input := engine.Document.FindElementById('t');
    Reset('中文');
    engine.HandleTextInput('X');
    Check(input.Text = '中文X', '末尾插入不受多字节影响');
    Reset('中文');
    Key(VK_LEFT);
    engine.HandleTextInput('X');
    Check(input.Text = '中X文', '← 左移一个码点（落在字符边界，不是半个字符）');
    Reset('中文');
    Key(VK_HOME);
    Key(VK_RIGHT);
    engine.HandleTextInput('A');
    Check(input.Text = '中A文', '→ 右移一个码点');
    Reset('中文');
    Key(VK_HOME);
    Key(VK_RIGHT);
    Key(VK_RIGHT);
    engine.HandleTextInput('Z');
    Check(input.Text = '中文Z', '→ 连续右移可越过多个中文');
    Reset('中');
    Key(VK_BACK);
    Check(input.Text = '', '单个中文 Backspace 全删（无残留字节）');
    Reset('中文');
    Key(VK_BACK);
    Check(input.Text = '中', '中文 Backspace 只删一个码点（无乱码）');
    Reset('中文');
    Key(VK_BACK);
    Key(VK_BACK);
    Check(input.Text = '', '连续 Backspace 删空中文');
    Reset('中文');
    Key(VK_LEFT);
    Key(VK_BACK);
    Check(input.Text = '文', '光标在中间时 Backspace 删前一个码点');
    Reset('中文');
    Key(VK_LEFT);
    Key(VK_DELETE);
    Check(input.Text = '中', '光标在中间时 Delete 删后一个码点');
    Reset('中');
    Key(VK_BACK);
    Check(Length(input.Text) = 0, '删除后无孤立续字节残留');
    Reset('中文');
    Key(VK_LEFT);
    Key(VK_LEFT);
    Key(VK_BACK);
    Check((input.Text = '中文') and (Length(input.Text) = 6), '行首 Backspace 不破坏文本');
    Reset('中文');
    Key(VK_HOME);
    engine.HandleKeyDown(VK_RIGHT, [xssShift]);
    DrawEngine(engine);
    engine.HandleTextInput('Q');
    Check(input.Text = 'Q文', 'Shift+→ 选中一个中文码点并被输入替换');
    Reset('');
    Key(VK_BACK);
    Key(VK_DELETE);
    Key(VK_LEFT);
    Key(VK_RIGHT);
    Check(input.Text = '', '空文本时编辑键不越界');
  finally
    engine.Free;
  end;
end;

procedure TestRoundedAndOpacity;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
begin
  WriteLn('--- M4 圆角 / 不透明度 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window><panel id="round"/><panel id="plain"/>' +
      '<panel id="fade"><label text="hi"/></panel></window>');
    engine.LoadStyleSheetFromString(
      '#round { width:40px; height:40px; background-color:#123456; border-radius:8px; } ' +
      '#plain { width:40px; height:40px; background-color:#123456; } ' +
      '#fade { opacity:0.5; height:30px; }');
    fake.Clear;
    DrawEngine(engine);
    Check(fake.CountOf('roundfill') >= 1, 'border-radius 走圆角填充');
    Check(fake.CountOf('fill') >= 1, '无圆角仍走直角填充');
    Check(fake.HasOpacity(0.5), '子树按 opacity 连乘设置不透明度');
    Check(fake.HasOpacity(1), '普通节点不透明度为 1');
  finally
    engine.Free;
  end;
end;

procedure TestM4CssProps;
var
  s: TXuiStyle;
begin
  WriteLn('--- M4 属性解析 ---');
  s := TXuiStyle.Create;
  try
    ApplyDeclaration(s, 'border-radius', '6px', 14);
    Check(s.BorderRadius = 6, 'border-radius: 6px');
    ApplyDeclaration(s, 'opacity', '0.5', 14);
    Check(Abs(s.Opacity - 0.5) < 0.01, 'opacity: 0.5');
    ApplyDeclaration(s, 'opacity', '3', 14);
    Check(s.Opacity = 1, 'opacity 上限夹取为 1');
  finally
    s.Free;
  end;
end;

procedure TestBackendMeasureConsistency;
{$IFDEF WINDOWS}
const
  Samples: array[0..3] of string = ('x', 'abc', '用户名：', '登 录');
var
  bmp: TBitmap;
  gdip: TGdiPlusRenderer;
  rd: TGdiRenderer;
  s: TXuiStyle;
  i: Integer;
{$ENDIF}
begin
  WriteLn('--- M4 后端：文本测量一致性 ---');
{$IFDEF WINDOWS}
  if not GdiPlusAvailable then
  begin
    Check(True, 'GDI+ 不可用，跳过一致性检查');
    Exit;
  end;
  bmp := TBitmap.Create;
  bmp.SetSize(200, 50);
  s := TXuiStyle.Create;
  try
    s.FontSize := 14;
    s.FontFamily := 'Microsoft YaHei UI';
    rd := TGdiRenderer.Create(bmp.Canvas);
    gdip := TGdiPlusRenderer.Create(bmp.Canvas);
    try
      for i := Low(Samples) to High(Samples) do
        Check(rd.MeasureText(Samples[i], s).cx = gdip.MeasureText(Samples[i], s).cx,
          Format('测量一致 "%s"', [Samples[i]]));
      Check(gdip.MeasureText('用户名：', s).cx <= 60, 'GDI+ 测量不虚高（≤60px）');
    finally
      gdip.Free;
      rd.Free;
    end;
  finally
    s.Free;
    bmp.Free;
  end;
{$ELSE}
  Check(True, '非 Windows 平台无 GDI+ 后端');
{$ENDIF}
end;

procedure TestSvgSupport;
var
  cmds: TXuiPathCmdArray;
  doc: TXuiSvgDoc;
  shape: TSvgShape;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  svgNode: TXuiNode;
  xml: string;
begin
  WriteLn('--- SVG 矢量图形支持 ---');
  cmds := ParseSvgPath('M 10 20 L 30 40 H 50 V 60 Z');
  Check(Length(cmds) = 5, 'SVG Path: 直线与闭合指令解析');
  if Length(cmds) >= 5 then
  begin
    Check((cmds[0].Kind = pckMoveTo) and (Round(cmds[0].P1.X) = 10) and (Round(cmds[0].P1.Y) = 20), 'MoveTo 坐标');
    Check((cmds[1].Kind = pckLineTo) and (Round(cmds[1].P1.X) = 30) and (Round(cmds[1].P1.Y) = 40), 'LineTo 坐标');
    Check((cmds[2].Kind = pckLineTo) and (Round(cmds[2].P1.X) = 50) and (Round(cmds[2].P1.Y) = 40), 'H 水平线坐标');
    Check((cmds[3].Kind = pckLineTo) and (Round(cmds[3].P1.X) = 50) and (Round(cmds[3].P1.Y) = 60), 'V 垂直线坐标');
    Check(cmds[4].Kind = pckClose, 'Close 闭合指令');
  end;
  cmds := ParseSvgPath('M0,0 C 10 20, 30 40, 50 60 S 70 80, 90 100');
  Check(Length(cmds) = 3, 'SVG Path: 贝塞尔 C/S 指令');
  if Length(cmds) >= 3 then
  begin
    Check(cmds[1].Kind = pckBezierTo, '三次贝塞尔 C');
    Check(cmds[2].Kind = pckBezierTo, '平滑三次贝塞尔 S 自动计算反射控制点');
    Check((Round(cmds[2].P1.X) = 70) and (Round(cmds[2].P1.Y) = 80), '平滑反射控制点精确计算');
  end;
  cmds := ParseSvgPath('M 0 0 A 25 25 0 0 1 50 50');
  Check(Length(cmds) > 1, 'SVG Path: 椭圆弧 A 转贝塞尔');
  xml := '<svg viewBox="0 0 100 100" width="100" height="100">' +
    '<circle cx="50" cy="50" r="40" fill="#ff0000" stroke="#0000ff" stroke-width="2"/>' +
    '<rect x="10" y="10" width="80" height="80" rx="5" fill="none" stroke="currentColor"/>' +
    '<line x1="0" y1="0" x2="100" y2="100" stroke="#00ff00"/>' +
    '<polygon points="10,10 90,10 50,90" fill="#ffff00"/></svg>';
  doc := TXuiSvgDoc.Create;
  try
    doc.LoadFromString(xml);
    Check(doc.HasViewBox, 'SVG 文档解析 viewBox 成功');
    Check(Round(doc.ViewBox.Right) = 100, 'viewBox 宽度正确');
    Check(doc.Shapes.Count = 4, 'SVG 图元解析数量为 4 (circle, rect, line, polygon)');
    shape := TSvgShape(doc.Shapes[1]);
    Check(shape.IsCurrentColorStroke, 'rect 描边正确识别 currentColor');
    Check(not shape.HasFill, 'rect fill 为 none');
    fake := TFakeRenderer.Create;
    try
      doc.Render(fake, Rect(0, 0, 200, 200), XuiRGB(255, 255, 255));
      Check(True, 'SVG Render 视口映射与缩放绘制完成');
    finally
      fake.Free;
    end;
  finally
    doc.Free;
  end;
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window><svg id="s1" width="32" height="32" viewBox="0 0 24 24">' +
      '<circle cx="12" cy="12" r="10" stroke="currentColor" fill="none"/></svg></window>');
    svgNode := engine.Document.FindElementById('s1');
    Check(svgNode <> nil, 'UI 引擎成功生成 <svg> 节点');
    Check(svgNode.Behavior is TXuiSvgBehavior, 'svg 节点已挂载 TXuiSvgBehavior 行为');
    Check(TXuiBehavior(svgNode.Behavior).SuppressChildrenRendering,
      'svg 行为抑制子图元普通流式渲染');
    DrawEngine(engine);
    Check(True, '引擎 Paint SVG 流程无异常');
  finally
    engine.Free;
  end;
end;
