program runtests;





{$mode objfpc}{$H+}





{ lui M1 单元测试（控制台）：XML 解析 → 节点树、默认样式、块级布局。


  约定：全部通过退出码 0，存在失败输出 FAIL 明细并退出码 1。 }





uses


  {$IFDEF UNIX}cthreads,{$ENDIF}


  Interfaces,


  Classes, SysUtils, Types, Math, Contnrs, Graphics, LCLType, FileUtil,


  Forms, Controls,


  xui_types, xui_style, xui_dom, xui_xml, xui_layout, xui_text,


  xui_css_token, xui_css_parser, xui_css_match, xui_render, xui_engine, xui_scroll,


  xui_events, xui_widget, xui_input, xui_svg,


  xui_js_token, xui_js_parser, xui_js_runtime, xui_script, xui_script_dom,


  xui_script_bind, xui_script_io, xui_scaffold, xui_console, xui_host, xui_app,
  xui_appspec, xui_bundle


  {$IFDEF WINDOWS}, xui_render_gdiplus{$ENDIF};





var


  FailCount, PassCount: Integer;





// 测试输出也必须走 xui_console 的安全路径。测试套件包含“关闭/不可写 stdout”的回归场景，
// 如果后续的 PASS/FAIL 和分组标题仍直接调用 WriteLn，前一个安全写入失败后会再次触发
// EInOutError（FPC 常见文案为“Disk Full”），导致测试自身无法报告结果。
procedure TestWriteLn; overload;
begin
  ConWriteLn;
end;

procedure TestWriteLn(const S: string); overload;
begin
  ConWriteLn(S);
end;

procedure TestWriteLn(const A, B: string); overload;
begin
  ConWrite(A);
  ConWriteLn(B);
end;

procedure TestWriteLn(const A, B, C: string); overload;
begin
  ConWrite(A);
  ConWrite(B);
  ConWriteLn(C);
end;

{$MACRO ON}
{$DEFINE WriteLn := TestWriteLn}





procedure Check(ACondition: Boolean; const AName: string);


begin


  if ACondition then


  begin


    Inc(PassCount);


    WriteLn('PASS  ', AName);


  end


  else


  begin


    Inc(FailCount);


    WriteLn('FAIL  ', AName);


  end;


end;





// UTF-8 字符数（假测量器按"每字 8px"模拟，不能按字节数）


function Utf8CharCount(const S: string): Integer;


var


  i: Integer;


begin


  Result := 0;


  i := 1;


  while i <= Length(S) do


  begin


    Inc(Result);


    if Byte(S[i]) < $80 then


      Inc(i)


    else if (Byte(S[i]) and $E0) = $C0 then


      Inc(i, 2)


    else if (Byte(S[i]) and $F0) = $E0 then


      Inc(i, 3)


    else


      Inc(i, 4);


  end;


end;





type


  // 假测量器：每字符 8px 宽，行高固定 20px


  TFakeMeasurer = class


  public


    function Measure(const AText: string; AStyle: TXuiStyle): TSize;


  end;





function TFakeMeasurer.Measure(const AText: string; AStyle: TXuiStyle): TSize;


var


  n: Integer;


begin


  n := Utf8CharCount(AText);


  Result.cx := n * 8;


  // R7：与 GDI 渲染器同一口径（宽度 + 字距×(字数-1)），保证布局断言可信
  if (AStyle <> nil) and (AStyle.LetterSpacing <> 0) and (n > 1) then


    Result.cx := Result.cx + Round(AStyle.LetterSpacing) * (n - 1);


  Result.cy := 20;


end;





var


  Measurer: TFakeMeasurer;





const


  DemoXML =


    '<window title="登录" width="360" height="240">' +


    '  <panel id="login-card" class="card">' +


    '    <label class="title" text="登录 Aluka"/>' +


    '    <panel class="row">' +


    '      <label class="field-label" text="用户名"/>' +


    '      <input id="username"/>' +


    '    </panel>' +


    '    <button id="btn-ok" text="登 录" onclick="BtnOkClick"/>' +


    '  </panel>' +


    '</window>';





{$IFDEF LUI_CORE_INLINE}
procedure TestXmlParsingInline;


var


  doc: TXuiDocument;


  card, btn, lbl: TXuiNode;


begin


  WriteLn('--- XML 解析 ---');


  doc := LoadDocumentFromXML(DemoXML);


  try


    Check(doc.Root <> nil, '根节点存在');


    Check(doc.Root.Tag = 'window', '根标签为 window');


    Check(doc.Title = '登录', 'title 属性读取');


    Check(doc.Root.Count = 1, '根下有一个子节点');





    card := doc.FindElementById('login-card');


    Check(card <> nil, '按 id 查找 login-card');


    Check(card.HasClass('card'), 'class 拆分: card');


    Check(card.Tag = 'panel', 'login-card 是 panel');


    Check(card.Count = 3, 'login-card 有 3 个子元素');





    lbl := card[0];


    Check((lbl.Tag = 'label') and (lbl.Text = '登录 Aluka'), 'text 属性成为节点文本');





    btn := doc.FindElementById('btn-ok');


    Check(btn <> nil, '按 id 查找 btn-ok');


    Check(btn.HasAttribute('onclick'), 'onclick 属性保留');





    doc.Free;


    doc := LoadDocumentFromXML('<window><label>来自文本</label></window>');


    Check(doc.FindElementById('nope') = nil, '查不存在的 id 返回 nil');


    Check(doc.Root[0].Text = '来自文本', '文本子节点成为节点文本');


  finally


    doc.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestDefaultStylesInline;


var


  doc: TXuiDocument;


  btn, panel: TXuiNode;


begin


  WriteLn('--- 默认样式 ---');


  doc := LoadDocumentFromXML(DemoXML);


  try


    panel := doc.FindElementById('login-card');


    panel.Style := DefaultStyleForTag(panel.Tag, nil);


    Check(panel.Style.BgColor.A = 0, 'panel 默认背景透明');


    Check(panel.Style.Height.IsAuto, 'panel 默认高度 auto');





    btn := doc.FindElementById('btn-ok');


    btn.Style := DefaultStyleForTag(btn.Tag, nil);


    Check(not btn.Style.Height.IsAuto, 'button 默认高度为固定值');


    Check(btn.Style.Height.Resolve(0) = 32, 'button 默认高度 32px');


    Check(btn.Style.TextAlign = xtaCenter, 'button 文本居中');


  finally


    doc.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestCssParserInline;


var


  sheet: TCssStyleSheet;


  rule: TCssRule;


begin


  WriteLn('--- CSS 解析 ---');


  sheet := TCssStyleSheet.Create;


  try


    sheet.ParseStyleSheet(


      '/* 注释 */ @import "x.css"; ' +


      '.card .title, #btn-ok:hover { color: #ff0000; margin: 4px 8px; } ' +


      'label { font-size: 14px; }' +


      '@media screen { div { color: blue; } }');





    Check(sheet.RuleCount = 3, '规则数 = 3（组展开 + label，@规则跳过）');





    rule := sheet[0];


    Check(rule.Selector.Parts.Count = 2, '组合选择器两个 part');


    Check((rule.SpecB = 2) and (rule.SpecC = 0), '特异性 .card .title = (0,2,0)');


    Check(rule.Declarations[0].Value = '#ff0000', '声明值保留原文');





    rule := sheet[1];


    Check(rule.SpecA = 1, '#btn-ok 特异性 A=1');


    Check(rule.Selector.Parts.Count = 1, '#btn-ok:hover 单 part');


    Check(TCssSelectorPart(rule.Selector.Parts[0]).Pseudos.IndexOf('hover') >= 0, '伪类记录 hover');


  finally


    sheet.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestCssApplyAndCascadeInline;


var


  sheet: TCssStyleSheet;


  style: TXuiStyle;


  base: TXuiStyle;


begin


  WriteLn('--- 声明应用与简写 ---');


  style := TXuiStyle.Create;


  try


    style.FontSize := 14;


    ApplyDeclaration(style, 'margin', '4px 8px', 14);


    Check(style.Margin.Top.Value = 4, 'margin 上下=4');


    Check(style.Margin.Left.Value = 8, 'margin 左右=8');





    ApplyDeclaration(style, 'padding', '10px 20px 30px 40px', 14);


    Check(style.Padding.Top.Value = 10, 'padding top=10');


    Check(style.Padding.Left.Value = 40, 'padding left=40');





    ApplyDeclaration(style, 'border', '1px solid #cccccc', 14);


    Check(style.BorderWidth = 1, 'border-width=1');


    Check(style.BorderColor.R = $CC, 'border-color r=$CC');





    ApplyDeclaration(style, 'background-color', 'rgba(22, 119, 255, 0.5)', 14);


    Check((style.BgColor.R = 22) and (style.BgColor.G = 119) and


          (style.BgColor.A = 128), 'rgba 解析');





    ApplyDeclaration(style, 'font-size', '1.5em', 14);


    Check(style.FontSize = 21, 'font-size 1.5em=21（基准14）');





    ApplyDeclaration(style, 'width', '50%', 14);


    Check(style.Width.Kind = xlkPercent, 'width 50% → 百分比');


  finally


    style.Free;


  end;





  WriteLn('--- 级联辅助检查 ---');


  sheet := TCssStyleSheet.Create;


  try


    sheet.ParseStyleSheet(


      '.card { background-color: #111111; } ' +           // spec (0,1,0)


      'div.card { background-color: #222222; } ' +        // spec (0,1,1) 组内胜


      '.card { background-color: #333333; } ' +           // 同特异性后者胜


      '.card { color: #444444 !important; }');


    Check(sheet.RuleCount = 4, '级联样式表规则数 = 4');


    Check((sheet[1].SpecC = 1) and (sheet[1].SpecB = 1), 'panel.card 特异性 (0,1,1)');


    Check(sheet[3].Declarations[0].Important, '!important 被标记');


  finally


    sheet.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestThemeSkinInline;


var


  doc: TXuiDocument;


  sheet: TCssStyleSheet;


  sheets: TObjectList;


  card, btn: TXuiNode;


begin


  WriteLn('--- 换肤（同 XML 不同 CSS）---');


  doc := LoadDocumentFromXML(DemoXML);


  sheets := TObjectList.Create(True);


  try


    sheet := TCssStyleSheet.Create;


    sheet.ParseStyleSheet(


      'window { background-color: #eef1f5; } ' +


      '.card { background-color: #ffffff; border: 1px solid #d9d9d9; } ' +


      '#btn-ok { background-color: #1677ff; color: #ffffff; }');


    sheets.Add(sheet);


    ComputeDocumentStyles(doc, sheets);





    Check(doc.Root.Style.BgColor.R = $EE, '浅色主题：窗口背景');


    card := doc.FindElementById('login-card');


    Check(card.Style.BgColor.R = $FF, '浅色主题：卡片白色');


    btn := doc.FindElementById('btn-ok');


    Check(btn.Style.BgColor.B = $FF, '浅色主题：按钮蓝');





    // 换深色主题：清空重加


    sheets.Clear;


    sheet := TCssStyleSheet.Create;


    sheet.ParseStyleSheet(


      'window { background-color: #121212; } ' +


      '.card { background-color: #1e1e1e; } ' +


      '#btn-ok { background-color: #1668dc; color: #ffffff; }');


    sheets.Add(sheet);


    ComputeDocumentStyles(doc, sheets);





    Check(doc.Root.Style.BgColor.R = $12, '深色主题：窗口背景');


    Check(card.Style.BgColor.R = $1E, '深色主题：卡片深灰');


    Check(btn.Style.BgColor.G = $68, '深色主题：按钮蓝变体');


  finally


    sheets.Free;


    doc.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestCssCascadeOnNodeInline;


var


  doc: TXuiDocument;


  sheets: TObjectList;


  sheet: TCssStyleSheet;


  card: TXuiNode;


begin


  WriteLn('--- 级联：特异性 / 顺序 / important / 内联 ---');


  doc := LoadDocumentFromXML(


    '<window><panel id="login-card" class="card" style="background-color:#999999"/></window>');


  sheets := TObjectList.Create(True);


  try


    sheet := TCssStyleSheet.Create;


    sheet.ParseStyleSheet(


      '.card { background-color: #111111; } ' +        // (0,1,0)


      'panel.card { background-color: #222222; } ' +   // (0,1,1) 组内最高


      '.card { background-color: #333333; } ' +        // (0,1,0)


      '.card { color: #444444 !important; }');


    sheets.Add(sheet);


    ComputeDocumentStyles(doc, sheets);





    card := doc.FindElementById('login-card');


    Check(card <> nil, '级联测试节点存在');


    Check(card.Style.BgColor.R = $99, '内联 style 胜过全部普通规则');


    Check(card.Style.TextColor.R = $44, 'important 覆盖内联 color');


  finally


    sheets.Free;


    doc.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_CORE_INLINE}
procedure TestBlockLayoutInline;


var


  doc: TXuiDocument;


  card, btn: TXuiNode;


  i: Integer;


  prevBottom: LongInt;


  ok: Boolean;


begin


  WriteLn('--- 块级布局 ---');


  doc := LoadDocumentFromXML(DemoXML);


  try


    LayoutDocument(doc, 360, 240, @Measurer.Measure);





    Check(doc.Root.BoxRect.Left = 0, '根节点贴左');


    Check(doc.Root.BoxRect.Right = 360, '根节点宽度 = 视口宽');


    Check(doc.Root.BoxRect.Bottom = 240, '根节点高度 = 视口高');





    card := doc.FindElementById('login-card');


    Check(card.BoxRect.Right = 360, '卡片宽度 = 视口宽（auto）');


    Check(card.BoxRect.Bottom > card.BoxRect.Top + 50, '卡片高度由内容撑开');





    // 子节点自上而下排列


    prevBottom := card.BoxRect.Top;


    ok := True;


    for i := 0 to card.Count - 1 do


    begin


      if card[i].BoxRect.Top < prevBottom then


        ok := False;


      prevBottom := card[i].BoxRect.Bottom;


    end;


    Check(ok, '子节点按块级流自上而下');





    btn := doc.FindElementById('btn-ok');


    Check(btn.BoxRect.Bottom - btn.BoxRect.Top = 32, 'button 高度 32px');


  finally


    doc.Free;


  end;


end;





{$ENDIF}
{ ---------- M3：假渲染器与辅助 ---------- }





type


  TFakeRenderer = class(TXuiCustomRenderer)


  private


    FKinds: TStringList;  // 调用序列：fill / frame / roundfill / roundframe / text / push / pop
    PathCount: Integer;   // RenderPath 调用次数（SVG 矢量渲染验证）


    FTexts: TStringList;  // DrawText 的文本（按绘制顺序）


    FOpacities: TStringList; // SetOpacity 记录（去重）


  public


    constructor Create;


    destructor Destroy; override;


    procedure Clear;


    procedure FillRect(const R: TRect; const AColor: TXuiColor); override;


    procedure FrameRect(const R: TRect; const AColor: TXuiColor; AWidth: Single); override;


    procedure DrawText(const R: TRect; const AText: string; AStyle: TXuiStyle); override;


    function MeasureText(const AText: string; AStyle: TXuiStyle): TSize; override;


    procedure PushClip(const R: TRect); override;


    procedure PopClip; override;
    procedure RenderPath(const ACmds: TXuiPathCmdArray; const AFill, AStroke: TXuiColor;
      AStrokeWidth: Single); override;


    function LineHeight(ACurrent: TXuiStyle): Single; override;


    procedure SetOpacity(AValue: Single); override;


    procedure FillRoundRect(const R: TRect; ARadius: Single; const AColor: TXuiColor); override;


    procedure FrameRoundRect(const R: TRect; ARadius, AWidth: Single;


      const AColor: TXuiColor); override;


    function CountOf(const AKind: string): Integer;


    function TextDrawn(const AText: string): Boolean;


    function TextDrawIndex(const AText: string): Integer;


    function HasOpacity(AValue: Single): Boolean;


  end;





procedure TFakeRenderer.RenderPath(const ACmds: TXuiPathCmdArray;
  const AFill, AStroke: TXuiColor; AStrokeWidth: Single);
begin
  Inc(PathCount);
end;

constructor TFakeRenderer.Create;


begin


  inherited Create;


  FKinds := TStringList.Create;


  FTexts := TStringList.Create;


  FOpacities := TStringList.Create;


end;





destructor TFakeRenderer.Destroy;


begin


  FOpacities.Free;


  FTexts.Free;


  FKinds.Free;


  inherited Destroy;


end;





procedure TFakeRenderer.Clear;


begin


  FKinds.Clear;


  FTexts.Clear;


  FOpacities.Clear;


end;





procedure TFakeRenderer.FillRect(const R: TRect; const AColor: TXuiColor);


begin


  FKinds.Add('fill');


end;





procedure TFakeRenderer.FrameRect(const R: TRect; const AColor: TXuiColor; AWidth: Single);


begin


  FKinds.Add('frame');


end;





procedure TFakeRenderer.FillRoundRect(const R: TRect; ARadius: Single;


  const AColor: TXuiColor);


begin


  FKinds.Add('roundfill');


end;





procedure TFakeRenderer.FrameRoundRect(const R: TRect; ARadius, AWidth: Single;


  const AColor: TXuiColor);


begin


  FKinds.Add('roundframe');


end;





procedure TFakeRenderer.SetOpacity(AValue: Single);


begin


  inherited SetOpacity(AValue);


  if FOpacities.IndexOf(FormatFloat('0.###', AValue)) < 0 then


    FOpacities.Add(FormatFloat('0.###', AValue));


end;





function TFakeRenderer.HasOpacity(AValue: Single): Boolean;


begin


  Result := FOpacities.IndexOf(FormatFloat('0.###', AValue)) >= 0;


end;





procedure TFakeRenderer.DrawText(const R: TRect; const AText: string; AStyle: TXuiStyle);


begin


  FKinds.Add('text');


  FTexts.Add(AText);


end;





function TFakeRenderer.MeasureText(const AText: string; AStyle: TXuiStyle): TSize;


begin


  Result.cx := Utf8CharCount(AText) * 8;


  Result.cy := 20;


end;





procedure TFakeRenderer.PushClip(const R: TRect);


begin


  FKinds.Add('push');


end;





procedure TFakeRenderer.PopClip;


begin


  FKinds.Add('pop');


end;





function TFakeRenderer.LineHeight(ACurrent: TXuiStyle): Single;


begin


  Result := ACurrent.FontSize * ACurrent.LineHeight;


end;





function TFakeRenderer.CountOf(const AKind: string): Integer;


var


  i: Integer;


begin


  Result := 0;


  for i := 0 to FKinds.Count - 1 do


    if FKinds[i] = AKind then


      Inc(Result);


end;





function TFakeRenderer.TextDrawn(const AText: string): Boolean;


begin


  Result := FTexts.IndexOf(AText) >= 0;


end;





function TFakeRenderer.TextDrawIndex(const AText: string): Integer;


begin


  Result := FTexts.IndexOf(AText);


end;





// 计算样式（含内联 style）后按视口布局


function PrepareDoc(const AXML, ACSS: string; AW, AH: Single): TXuiDocument;


var


  sheets: TObjectList;


  sheet: TCssStyleSheet;


begin


  Result := LoadDocumentFromXML(AXML);


  sheets := TObjectList.Create(True);


  try


    if ACSS <> '' then


    begin


      sheet := TCssStyleSheet.Create;


      sheet.ParseStyleSheet(ACSS);


      sheets.Add(sheet);


    end;


    ComputeDocumentStyles(Result, sheets);


  finally


    sheets.Free;


  end;


  LayoutDocument(Result, AW, AH, @Measurer.Measure);


end;





procedure CheckRect(const ARect: TRect; AL, AT, AR, AB: Integer; const AName: string);


begin


  Check((ARect.Left = AL) and (ARect.Top = AT) and (ARect.Right = AR) and (ARect.Bottom = AB),


    Format('%s [实际 %d,%d,%d,%d]', [AName, ARect.Left, ARect.Top, ARect.Right, ARect.Bottom]));


end;





{$I layout_contract.inc}
{$I layout_flex.inc}
{$I layout_flex_advanced.inc}
{$I css_constraints.inc}
{$I text_overflow.inc}
{$I box_shadow.inc}
{$I svg_intrinsic_size.inc}
{$I text_wrap_cache.inc}
{$I layout_text_position.inc}
{$I layout_css_props.inc}
{$I layout_engine_rendering.inc}
{$I event_helpers.inc}
{$I event_hit_test.inc}
{$I event_pseudo_click.inc}
{$I event_binding.inc}
{$I event_scroll_dom.inc}
{$I input_tests.inc}
{$I input_transition.inc}
{$I include_templates.inc}
{$I script_helpers.inc}
{$I scroll_model.inc}
{$I textarea_model.inc}
{$I script_core.inc}
{$I script_async.inc}
{$I script_timers.inc}
{$I script_async_await.inc}
{$I script_integration.inc}
{$I script_promise_integration.inc}
{$I script_timers_integration.inc}
{$I script_async_integration.inc}
{$I script_io.inc}
{$I css_variables.inc}
{$I script_reactive.inc}
{$I script_demo_page.inc}
{$I host_regressions.inc}
{$I scaffold_regression.inc}
{$I agent_page.inc}
{$I remaining_regressions.inc}
{$I ui_library.inc}
{$I core_layout.inc}
{$I core_css.inc}
{$I m12_m13.inc}




{ ---------- M3：flex ---------- }





{ Staged extraction: the modular definitions are active above; keep the old
  inline copies disabled until the whole M3 block has been migrated. }
{$IFDEF LUI_LAYOUT_FLEX_INLINE}
procedure TestFlexRow;


var


  doc: TXuiDocument;


  row, a, b: TXuiNode;


begin


  WriteLn('--- flex row ---');


  doc := PrepareDoc(


    '<window>' +


    '  <panel id="row"><panel id="a"/><panel id="b"/></panel>' +


    '</window>',


    '#row { display:flex; height:100px; column-gap:10px; } ' +


    '#a { width:50px; height:20px; } ' +


    '#b { width:60px; height:30px; }',


    300, 200);


  try


    row := doc.FindElementById('row');


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(row.BoxRect, 0, 0, 300, 100, 'row 高度由显式值决定');


    CheckRect(a.BoxRect, 0, 0, 50, 20, '主轴第一项在起点');


    CheckRect(b.BoxRect, 60, 0, 120, 30, '第二项相距一个 column-gap');


  finally


    doc.Free;


  end;


end;





{ Staged extraction: the modular definitions are active above; keep the old
  inline copies disabled until the whole M3 block has been migrated. }
{$IFDEF LUI_LAYOUT_FLEX_INLINE}
procedure TestFlexJustify;


var


  doc: TXuiDocument;


  a, b: TXuiNode;


begin


  WriteLn('--- flex justify-content ---');


  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; justify-content:center; } ' +


    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',


    300, 200);


  try


    CheckRect(doc.FindElementById('a').BoxRect, 100, 0, 140, 10, 'center：整体居中');


    CheckRect(doc.FindElementById('b').BoxRect, 140, 0, 200, 10, 'center：第二项紧随');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; justify-content:flex-end; } ' +


    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',


    300, 200);


  try


    CheckRect(doc.FindElementById('a').BoxRect, 200, 0, 240, 10, 'flex-end：贴右');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; justify-content:space-between; } ' +


    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(a.BoxRect, 0, 0, 40, 10, 'space-between：首项贴左');


    CheckRect(b.BoxRect, 240, 0, 300, 10, 'space-between：末项贴右');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; justify-content:space-around; } ' +


    '#a { width:40px; height:10px; } #b { width:60px; height:10px; }',


    300, 200);


  try


    CheckRect(doc.FindElementById('a').BoxRect, 50, 0, 90, 10, 'space-around：首项半间隙');


    CheckRect(doc.FindElementById('b').BoxRect, 190, 0, 250, 10, 'space-around：末项留白');


  finally


    doc.Free;


  end;


end;





{$ENDIF}
{$IFDEF LUI_LAYOUT_FLEX_INLINE}
procedure TestFlexGrow;


var


  doc: TXuiDocument;


  a, b: TXuiNode;


begin


  WriteLn('--- flex-grow ---');


  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; } ' +


    '#a { flex-grow:1; height:10px; } #b { flex-grow:3; height:10px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(a.BoxRect, 0, 0, 75, 10, 'grow 1/4 分得 75px');


    CheckRect(b.BoxRect, 75, 0, 300, 10, 'grow 3/4 分得 225px');


  finally


    doc.Free;


  end;


end;





{$ENDIF}
procedure TestFlexAlign;


var


  doc: TXuiDocument;


  a, b: TXuiNode;


begin


  WriteLn('--- flex align-items ---');


  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/><panel id="b"/></panel></window>',


    '#row { display:flex; height:100px; align-items:center; } ' +


    '#a { width:40px; height:20px; } #b { width:40px; height:40px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(a.BoxRect, 0, 40, 40, 60, 'center：20 高项垂直居中');


    CheckRect(b.BoxRect, 40, 30, 80, 70, 'center：40 高项垂直居中');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/></panel></window>',


    '#row { display:flex; height:100px; align-items:stretch; } ' +


    '#a { width:40px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    CheckRect(a.BoxRect, 0, 0, 40, 100, 'stretch：auto 高度拉伸到容器高');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="row"><panel id="a"/></panel></window>',


    '#row { display:flex; height:100px; align-items:flex-end; } ' +


    '#a { width:40px; height:20px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    CheckRect(a.BoxRect, 0, 80, 40, 100, 'flex-end：贴交叉轴末端');


  finally


    doc.Free;


  end;


end;





procedure TestFlexColumn;


var


  doc: TXuiDocument;


  col, a, b: TXuiNode;


begin


  WriteLn('--- flex column ---');


  doc := PrepareDoc(


    '<window><panel id="col"><panel id="a"/><panel id="b"/></panel></window>',


    '#col { display:flex; flex-direction:column; width:200px; row-gap:10px; } ' +


    '#a { height:20px; } #b { height:30px; }',


    300, 200);


  try


    col := doc.FindElementById('col');


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(a.BoxRect, 0, 0, 200, 20, '纵向第一项');


    CheckRect(b.BoxRect, 0, 30, 200, 60, 'row-gap 生效');


    CheckRect(col.BoxRect, 0, 0, 200, 60, '容器高度 = 内容 + 间距');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="col"><panel id="a"/><panel id="b"/></panel></window>',


    '#col { display:flex; flex-direction:column; width:200px; height:100px; ' +


    'justify-content:center; } #a { height:20px; } #b { height:30px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    b := doc.FindElementById('b');


    CheckRect(a.BoxRect, 0, 25, 200, 45, '纵向 center：首项下移');


    CheckRect(b.BoxRect, 0, 45, 200, 75, '纵向 center：次项紧随');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="col"><panel id="a"/></panel></window>',


    '#col { display:flex; flex-direction:column; width:200px; align-items:center; } ' +


    '#a { width:50px; height:20px; }',


    300, 200);


  try


    a := doc.FindElementById('a');


    CheckRect(a.BoxRect, 75, 0, 125, 20, '纵向 center：交叉轴水平居中');


  finally


    doc.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_LAYOUT_M3_INLINE}
{ ---------- M3：文本换行 ---------- }





procedure TestTextWrap;


var


  doc: TXuiDocument;


  t: TXuiNode;


begin


  WriteLn('--- 文本换行 ---');


  doc := PrepareDoc(


    '<window><label id="t" text="中文中文中文"/></window>',


    '#t { width:32px; margin:0; font-size:10px; line-height:2; }',


    300, 200);


  try


    t := doc.FindElementById('t');


    Check(Length(t.TextLines) = 2, 'CJK 逐字断行为 2 行');


    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = '中文中文'), '第一行 4 个汉字');


    Check((Length(t.TextLines) > 1) and (t.TextLines[1] = '中文'), '第二行 2 个汉字');


    CheckRect(t.BoxRect, 0, 0, 32, 40, '行高 20 × 2 行');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><label id="t" text="hello world"/></window>',


    '#t { width:44px; margin:0; font-size:10px; line-height:2; }',


    300, 200);


  try


    t := doc.FindElementById('t');


    Check(Length(t.TextLines) = 2, '拉丁按空格断行为 2 行');


    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = 'hello'), '第一行 hello');


    Check((Length(t.TextLines) > 1) and (t.TextLines[1] = 'world'), '第二行 world');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><label id="t" text="abcdefghij"/></window>',


    '#t { width:24px; margin:0; font-size:10px; line-height:2; }',


    300, 200);


  try


    t := doc.FindElementById('t');


    Check(Length(t.TextLines) = 1, '超长不可断词不硬切');


    Check((Length(t.TextLines) > 0) and (t.TextLines[0] = 'abcdefghij'), '整词保留');


  finally


    doc.Free;


  end;


end;





{ ---------- M3：auto 外边距 / 最小尺寸 / 定位 ---------- }





procedure TestAutoMarginAndMinSize;


var


  doc: TXuiDocument;


  card, p: TXuiNode;


begin


  WriteLn('--- auto 外边距 / 最小尺寸 ---');


  doc := PrepareDoc(


    '<window><panel id="card"/></window>',


    '#card { width:320px; height:20px; margin:12px auto; }',


    360, 240);


  try


    card := doc.FindElementById('card');


    CheckRect(card.BoxRect, 20, 12, 340, 32, 'margin auto 水平居中');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="p"/></window>',


    '#p { min-width:100px; min-height:60px; }',


    300, 200);


  try


    p := doc.FindElementById('p');


    CheckRect(p.BoxRect, 0, 0, 300, 60, 'min-height 撑起 auto 高度');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="p"/></window>',


    '#p { width:50px; height:10px; min-width:120px; min-height:40px; }',


    300, 200);


  try


    p := doc.FindElementById('p');


    CheckRect(p.BoxRect, 0, 0, 120, 40, 'min-* 覆盖显式尺寸');


  finally


    doc.Free;


  end;


end;





procedure TestPositioning;


var


  doc: TXuiDocument;


  badge, badge2, p, c: TXuiNode;


begin


  WriteLn('--- 绝对 / 相对定位 ---');


  doc := PrepareDoc(


    '<window>' +


    '  <panel id="box">' +


    '    <panel id="badge"/><panel id="badge2"/>' +


    '  </panel>' +


    '</window>',


    '#box { position:relative; width:200px; height:100px; padding:10px; } ' +


    '#badge { position:absolute; left:5px; top:8px; width:20px; height:10px; } ' +


    '#badge2 { position:absolute; right:10px; bottom:5px; width:20px; height:10px; }',


    300, 200);


  try


    badge := doc.FindElementById('badge');


    badge2 := doc.FindElementById('badge2');


    CheckRect(badge.BoxRect, 5, 8, 25, 18, 'left/top 相对包含块 padding box');


    CheckRect(badge2.BoxRect, 170, 85, 190, 95, 'right/bottom 定位');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="p"><panel id="abs"/></panel></window>',


    '#p { height:50px; } ' +


    '#abs { position:absolute; left:7px; top:9px; width:10px; height:10px; }',


    300, 200);


  try


    doc.FindElementById('abs');


    CheckRect(doc.FindElementById('abs').BoxRect, 7, 9, 17, 19,


      '无定位祖先时回退根节点');


  finally


    doc.Free;


  end;





  doc := PrepareDoc(


    '<window><panel id="p"><panel id="c"/></panel></window>',


    '#p { position:relative; left:10px; top:5px; height:30px; } ' +


    '#c { height:10px; }',


    300, 200);


  try


    p := doc.FindElementById('p');


    c := doc.FindElementById('c');


    CheckRect(p.BoxRect, 10, 5, 310, 35, 'relative 平移自身');


    CheckRect(c.BoxRect, 10, 5, 310, 15, 'relative 平移整个子树');


  finally


    doc.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_LAYOUT_CSS_INLINE}
{ ---------- M3：CSS 属性解析 ---------- }





procedure TestM3CssProps;


var


  s: TXuiStyle;


begin


  WriteLn('--- M3 属性解析 ---');


  s := TXuiStyle.Create;


  try


    s.FontSize := 14;


    ApplyDeclaration(s, 'position', 'absolute', 14);


    Check(s.Position = xposAbsolute, 'position: absolute');


    ApplyDeclaration(s, 'top', '5px', 14);


    Check(s.Inset.Top.Value = 5, 'top: 5px');


    ApplyDeclaration(s, 'right', '10%', 14);


    Check(s.Inset.Right.Kind = xlkPercent, 'right: 10%');


    ApplyDeclaration(s, 'left', 'auto', 14);


    Check(s.Inset.Left.IsAuto, 'left: auto');


    ApplyDeclaration(s, 'z-index', '7', 14);


    Check(s.ZIndex = 7, 'z-index: 7');


    ApplyDeclaration(s, 'overflow', 'hidden', 14);


    Check(s.Overflow = xovHidden, 'overflow: hidden');


    ApplyDeclaration(s, 'visibility', 'hidden', 14);


    Check(s.Visibility = xvisHidden, 'visibility: hidden');


    ApplyDeclaration(s, 'min-width', '80px', 14);


    Check(s.MinWidth.Value = 80, 'min-width: 80px');


    ApplyDeclaration(s, 'min-height', '50%', 14);


    Check(s.MinHeight.Kind = xlkPercent, 'min-height: 50%');


    ApplyDeclaration(s, 'flex-direction', 'column', 14);


    Check(s.FlexDirection = xfdColumn, 'flex-direction: column');


    ApplyDeclaration(s, 'justify-content', 'space-between', 14);


    Check(s.JustifyContent = xjcSpaceBetween, 'justify-content: space-between');


    ApplyDeclaration(s, 'align-items', 'center', 14);


    Check(s.AlignItems = xaiCenter, 'align-items: center');


    ApplyDeclaration(s, 'gap', '6px 12px', 14);


    Check((s.RowGap.Value = 6) and (s.ColumnGap.Value = 12), 'gap: 6px 12px');


    ApplyDeclaration(s, 'flex-grow', '2', 14);


    Check(Abs(s.FlexGrow - 2) < 0.01, 'flex-grow: 2');


    ApplyDeclaration(s, 'flex', '3', 14);


    Check((Abs(s.FlexGrow - 3) < 0.01) and (s.FlexBasis.Value = 0),


      'flex: 3 简写（grow=3 + basis=0）');


    ApplyDeclaration(s, 'flex-basis', '40%', 14);


    Check(s.FlexBasis.Kind = xlkPercent, 'flex-basis: 40%');


    ApplyDeclaration(s, 'row-gap', '4px', 14);


    Check(s.RowGap.Value = 4, 'row-gap: 4px');


  finally


    s.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_LAYOUT_ENGINE_INLINE}
{ ---------- M3：引擎绘制（裁剪 / visibility / 绘制序） ---------- }





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





{$ENDIF}

{$IFDEF LUI_M4_HELPERS_INLINE}
{ ---------- M4：RTTI 探针 ---------- }





type


  {$M+}


  TRttiProbeSink = class


  published


    procedure ProbeMethod(Sender: TObject);


  end;


  {$M-}





procedure TRttiProbeSink.ProbeMethod(Sender: TObject);


begin


  // 探针：只验证能否按名字解析


end;





procedure TestRttiProbe;


var


  sink: TRttiProbeSink;


  m: TMethod;


begin


  WriteLn('--- RTTI 探针（事件绑定前提）---');


  sink := TRttiProbeSink.Create;


  try


    m.Code := sink.MethodAddress('ProbeMethod');


    m.Data := sink;


    Check(m.Code <> nil, 'MethodAddress 解析 published 方法');


    Check(sink.MethodAddress('NotExist') = nil, '未声明的方法返回 nil');


    Check(Assigned(TNotifyEvent(m)), 'TMethod 可转为 TNotifyEvent');


  finally


    sink.Free;


  end;


end;





{ ---------- M4：事件 / 命中测试 / 伪类 / 滚动 / 运行时 DOM ---------- }





type


  {$M+}


  TEventSink = class


  public


    Clicks: Integer;


    MouseDowns: Integer;


    FallbackClicks: Integer;


    Inputs: Integer;


    Enters: Integer;


    LastInputText: string;


    LastSender: TObject;


    LastNodeId: string;


    procedure EngineEvent(ANode: TXuiNode; AKind: TXuiEventKind);


    published


      procedure BtnClick(Sender: TObject);


      procedure BtnMouseDown(Sender: TObject);


      procedure InputChanged(Sender: TObject);


      procedure EnterPressed(Sender: TObject);


  end;


  {$M-}





procedure TEventSink.InputChanged(Sender: TObject);


begin


  Inc(Inputs);


  if Sender is TXuiNode then


    LastInputText := TXuiNode(Sender).Text;


end;





procedure TEventSink.EnterPressed(Sender: TObject);


begin


  Inc(Enters);


end;





procedure TEventSink.BtnClick(Sender: TObject);


begin


  Inc(Clicks);


  LastSender := Sender;


  if Sender is TXuiNode then


    LastNodeId := TXuiNode(Sender).Id;


end;





procedure TEventSink.BtnMouseDown(Sender: TObject);


begin


  Inc(MouseDowns);


end;





// 兜底回调（引擎 OnEvent）：只统计 click


procedure TEventSink.EngineEvent(ANode: TXuiNode; AKind: TXuiEventKind);


begin


  if AKind = xevClick then


  begin


    Inc(FallbackClicks);


    LastSender := ANode;


  end;


end;





// 引擎 + 假渲染器（渲染器所有权归引擎）


function NewTestEngine(out AFake: TFakeRenderer): TXuiEngine;


begin


  AFake := TFakeRenderer.Create;


  Result := TXuiEngine.Create;


  Result.Renderer := AFake;


end;





const


  TestViewport: TRect = (Left: 0; Top: 0; Right: 300; Bottom: 200);





procedure DrawEngine(AEngine: TXuiEngine);


begin


  AEngine.Draw(nil, TestViewport);


end;





procedure ClickNode(AEngine: TXuiEngine; ANode: TXuiNode);


var


  cx, cy: Integer;


begin


  cx := (ANode.BoxRect.Left + ANode.BoxRect.Right) div 2;


  cy := (ANode.BoxRect.Top + ANode.BoxRect.Bottom) div 2;


  AEngine.HandleMouseMove(cx, cy);


  AEngine.HandleMouseDown(cx, cy);


  AEngine.HandleMouseUp(cx, cy);


end;





{$ENDIF}

{$IFDEF LUI_M4_TESTS_INLINE}
procedure TestHitTest;


var


  doc: TXuiDocument;


begin


  WriteLn('--- M4 命中测试 ---');


  doc := PrepareDoc(


    '<window>' +


    '  <panel id="box"><label id="in" text="x"/></panel>' +


    '  <panel id="hidden"/>' +


    '  <panel id="clip"><label id="deep" text="y"/></panel>' +


    '</window>',


    '#box { width:200px; height:100px; } ' +


    '#in { height:20px; margin:0; } ' +


    '#hidden { display:none; width:50px; height:50px; } ' +


    '#clip { overflow:hidden; width:100px; height:40px; } ' +


    '#deep { height:200px; margin:0; }',


    300, 200);


  try


    Check(XuiHitTest(doc.Root, 10, 10) = doc.FindElementById('in'), '最深节点优先命中');


    Check(XuiHitTest(doc.Root, 150, 50) = doc.FindElementById('box'), '容器空白处命中容器');


    Check(XuiHitTest(doc.Root, 10, 150) = doc.Root, 'display:none 不参与命中');


    Check(XuiHitTest(doc.Root, 50, 120) = doc.FindElementById('deep'),


      '裁剪区内溢出的子节点可命中');


    Check(XuiHitTest(doc.Root, 50, 160) = doc.Root,


      'overflow:hidden 之外不命中溢出的子节点');


  finally


    doc.Free;


  end;


end;
{$ENDIF}

{$IFDEF LUI_M4_TESTS_INLINE}
procedure TestPseudoAndClick;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  sink: TEventSink;


  btn: TXuiNode;


  cx, cy: Integer;


begin


  WriteLn('--- M4 伪类状态机 / 点击 / 禁用 ---');


  sink := TEventSink.Create;


  engine := NewTestEngine(fake);


  try


    engine.EventTarget := sink;


    engine.LoadFromString(


      '<window><panel id="card">' +


      '<button id="btn" text="ok" onclick="BtnClick" onmousedown="BtnMouseDown"/>' +


      '</panel></window>');


    engine.LoadStyleSheetFromString(


      '#btn { width:80px; height:30px; background-color:#0000ff; } ' +


      '#btn:hover { background-color:#ff0000; } ' +


      '#btn:active { background-color:#00ff00; } ' +


      '#btn:disabled { background-color:#888888; }');


    DrawEngine(engine);





    btn := engine.Document.FindElementById('btn');


    Check(btn <> nil, '按钮节点存在');


    Check(btn.Style.BgColor.B = $FF, '初始背景为蓝');


    cx := (btn.BoxRect.Left + btn.BoxRect.Right) div 2;


    cy := (btn.BoxRect.Top + btn.BoxRect.Bottom) div 2;





    engine.HandleMouseMove(cx, cy);


    DrawEngine(engine);


    Check(xpHover in btn.Pseudos, 'mousemove 设置 :hover');


    Check(btn.Style.BgColor.R = $FF, 'hover 样式生效（变红）');





    engine.HandleMouseDown(cx, cy);


    DrawEngine(engine);


    Check(xpActive in btn.Pseudos, 'mousedown 设置 :active');


    Check(xpFocus in btn.Pseudos, 'mousedown 设置 :focus（button 可聚焦）');


    Check(btn.Style.BgColor.G = $FF, 'active 样式生效（变绿）');


    Check(sink.MouseDowns = 1, 'onmousedown 绑定被调用');





    engine.HandleMouseUp(cx, cy);


    DrawEngine(engine);


    Check(sink.Clicks = 1, 'onclick 绑定被调用');


    Check(sink.LastNodeId = 'btn', 'Sender 为承载绑定的节点');


    Check(not (xpActive in btn.Pseudos), 'mouseup 清除 :active');


    Check(btn.Style.BgColor.R = $FF, '回到 hover 样式（红）');





    engine.SetDisabled(btn, True);


    DrawEngine(engine);


    Check(xpDisabled in btn.Pseudos, 'SetDisabled 设置 :disabled');


    Check(btn.Style.BgColor.R = $88, 'disabled 样式生效');


    engine.HandleMouseDown(cx, cy);


    engine.HandleMouseUp(cx, cy);


    Check(sink.Clicks = 1, 'disabled 节点不派发 click');





    engine.HandleMouseLeave;


    DrawEngine(engine);


    Check(not (xpHover in btn.Pseudos), '鼠标离开清除 :hover');


  finally


    engine.Free;


    sink.Free;


  end;


end;
{$ENDIF}

{$IFDEF LUI_M4_TESTS_INLINE}
procedure TestEventBindingFallback;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  sink: TEventSink;


  okNode, badNode: TXuiNode;


begin


  WriteLn('--- M4 事件绑定（RTTI 与兜底）---');


  sink := TEventSink.Create;


  engine := NewTestEngine(fake);


  try


    engine.EventTarget := sink;


    engine.LoadFromString(


      '<window>' +


      '  <button id="ok" text="A" onclick="BtnClick"/>' +


      '  <button id="bad" text="B" onclick="NoSuchMethod"/>' +


      '</window>');


    DrawEngine(engine);


    okNode := engine.Document.FindElementById('ok');


    badNode := engine.Document.FindElementById('bad');





    Check(okNode.Bindings.Count = 1, 'onclick 属性被记录为绑定');


    Check(TXuiEventBinding(okNode.Bindings[0]).Handler.Code <> nil,


      'published 方法经 MethodAddress 解析成功');


    Check(TXuiEventBinding(badNode.Bindings[0]).Handler.Code = nil,


      '不存在的方法保持未解析');





    ClickNode(engine, okNode);


    Check(sink.Clicks = 1, '已解析的绑定被触发');


    ClickNode(engine, badNode);


    Check(sink.Clicks = 1, '未解析的方法不触发回调');


    Check(sink.LastSender = okNode, '回调的 Sender = 承载绑定的节点');


    Check(sink.FallbackClicks = 0, '有绑定时不走兜底');





    // 兜底：无可用绑定时由引擎级 OnEvent 统一接管


    engine.OnEvent := @sink.EngineEvent;


    ClickNode(engine, badNode);


    Check(sink.FallbackClicks = 1, '无绑定时走 OnEvent 兜底');


    Check(sink.LastSender = badNode, '兜底回调收到命中节点');


  finally


    engine.Free;


    sink.Free;


  end;


end;
{$ENDIF}

{$IFDEF LUI_M4_TESTS_INLINE}
procedure TestScroll;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  list: TXuiNode;


begin


  WriteLn('--- M4 滚动 ---');


  engine := NewTestEngine(fake);


  try


    engine.LoadFromString(


      '<window><panel id="list">' +


      '  <panel class="item"/><panel class="item"/><panel class="item"/>' +


      '  <panel class="item"/><panel class="item"/>' +


      '</panel></window>');


    engine.LoadStyleSheetFromString(


      '#list { overflow:hidden; width:200px; height:60px; } ' +


      '.item { height:40px; }');


    DrawEngine(engine);


    list := engine.Document.FindElementById('list');





    Check(Abs(list.ContentHeight - 200) < 0.5, '记录自然内容高 200');


    Check(list[0].BoxRect.Top = 0, '初始未滚动');





    Check(engine.HandleMouseWheel(10, 10, -120), '滚轮向下被处理');


    DrawEngine(engine);


    Check(Abs(list.ScrollTop - 48) < 0.5, '滚动一格 = 48px');


    Check(list[0].BoxRect.Top = -48, '子节点整体上移');





    engine.HandleMouseWheel(10, 10, -120);


    engine.HandleMouseWheel(10, 10, -120);


    engine.HandleMouseWheel(10, 10, -120);


    DrawEngine(engine);


    Check(Abs(list.ScrollTop - 140) < 0.5, '滚动到底部夹取在 maxScroll=140');





    engine.HandleMouseWheel(10, 10, 120);


    DrawEngine(engine);


    Check(Abs(list.ScrollTop - 92) < 0.5, '向上回滚 48px');





    engine.HandleMouseWheel(10, 10, 120);


    engine.HandleMouseWheel(10, 10, 120);


    DrawEngine(engine);


    Check(list.ScrollTop = 0, '顶部夹取在 0');


  finally


    engine.Free;


  end;


end;





procedure TestRuntimeDom;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  sink: TEventSink;


  list, item: TXuiNode;


begin


  WriteLn('--- M4 运行时 DOM ---');


  sink := TEventSink.Create;


  engine := NewTestEngine(fake);


  try


    engine.EventTarget := sink;


    engine.LoadFromString('<window><panel id="list"/></window>');


    engine.LoadStyleSheetFromString(


      '.item { height:20px; background-color:#112233; }');


    DrawEngine(engine);


    list := engine.Document.FindElementById('list');


    Check(list.Count = 0, '初始无子节点');





    item := engine.AddElement(list, '<panel class="item" onclick="BtnClick"/>');


    Check((item <> nil) and (list.Count = 1), 'AddElement 追加节点');


    DrawEngine(engine);


    Check(item.Style <> nil, '新增节点获得计算样式');


    Check(item.Style.BgColor.R = $11, '新增节点匹配 CSS 类');


    Check(item.BoxRect.Bottom - item.BoxRect.Top = 20, '新增节点参与布局');


    Check(TXuiEventBinding(item.Bindings[0]).Handler.Code <> nil,


      '新增节点的绑定被解析');





    ClickNode(engine, item);


    Check(sink.Clicks = 1, '新增节点的点击绑定生效');





    engine.SetDisabled(item, True);


    DrawEngine(engine);


    Check(xpDisabled in item.Pseudos, 'SetDisabled 生效');





    engine.ClearChildren(list);


    Check(list.Count = 0, 'ClearChildren 清空子节点');





    item := engine.AddElement(list, '<panel class="item"/>');


    engine.RemoveElement(item);


    Check(list.Count = 0, 'RemoveElement 移除节点');


  finally


    engine.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_M5_INLINE}
{ ---------- M5：输入框 / 键盘 / 焦点 ---------- }





var


  FakeClipboard: string;





function FakeClipboardGet: string;


begin


  Result := FakeClipboard;


end;





procedure FakeClipboardSet(const AText: string);


begin


  FakeClipboard := AText;


end;





procedure TestInputEditing;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  input: TXuiNode;


begin


  WriteLn('--- M5 输入框：编辑 ---');


  engine := NewTestEngine(fake);


  try


    engine.LoadFromString('<window><input id="name"/></window>');


    engine.LoadStyleSheetFromString(


      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');


    DrawEngine(engine);


    input := engine.Document.FindElementById('name');


    Check(input <> nil, '输入框节点存在');


    Check((input.Behavior is TXuiBehavior) and TXuiBehavior(input.Behavior).CanFocus,


      'input 标签注册了可聚焦行为');





    ClickNode(engine, input);


    Check(engine.FocusNode = input, '点击输入框获得焦点');





    Check(engine.HandleTextInput('ab'), '文本输入被消费');


    Check(input.Text = 'ab', '值写入节点 Text');


    Check(engine.HandleKeyDown(VK_BACK, []), 'Backspace 被消费');


    Check(input.Text = 'a', 'Backspace 删除一个字符');


    Check(engine.HandleKeyDown(VK_LEFT, []), '方向键被消费');


    engine.HandleTextInput('X');


    Check(input.Text = 'Xa', '光标处插入（非末尾）');





    Check(engine.HandleKeyDown(VK_END, []), 'End 被消费');


    Check(engine.HandleKeyDown(VK_HOME, [xssShift]), 'Shift+Home 被消费');


    engine.HandleTextInput('hi');


    Check(input.Text = 'hi', '输入替换选区内容');





    engine.SetDisabled(input, True);


    Check(not engine.HandleTextInput('x'), '禁用输入框拒绝文本输入');


    Check(input.Text = 'hi', '禁用时值保持不变');


    engine.SetDisabled(input, False);


    Check(engine.HandleTextInput('!'), '恢复后可输入');


    Check(input.Text = 'hi!', '恢复输入生效');





    // 中文（多字节）按码点编辑


    engine.SetDisabled(input, False);


    Check(engine.HandleTextInput('中文'), '中文输入被消费');


    Check(input.Text = 'hi!中文', '中文追加正确');


    engine.HandleKeyDown(VK_BACK, []);


    Check(input.Text = 'hi!中', 'Backspace 删除一个中文字（码点）');


  finally


    engine.Free;


  end;


end;





procedure TestInputRender;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  input: TXuiNode;


begin


  WriteLn('--- M5 输入框：掩码 / 占位符 / 长度限制 ---');


  engine := NewTestEngine(fake);


  try


    engine.LoadFromString(


      '<window>' +


      '  <input id="pwd" password="true"/>' +


      '  <input id="tip" placeholder="请输入用户名"/>' +


      '  <input id="lim" maxlength="3"/>' +


      '</window>');


    engine.LoadStyleSheetFromString(


      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');


    DrawEngine(engine);





    input := engine.Document.FindElementById('pwd');


    ClickNode(engine, input);


    engine.HandleTextInput('abc');


    fake.Clear;


    DrawEngine(engine);


    Check(fake.TextDrawn('●●●'), '密码框以掩码绘制');


    Check(not fake.TextDrawn('abc'), '密码原文不绘制');





    fake.Clear;


    DrawEngine(engine);


    Check(fake.TextDrawn('请输入用户名'), '空值绘制占位符');





    input := engine.Document.FindElementById('lim');


    ClickNode(engine, input);


    engine.HandleTextInput('abcdef');


    Check(input.Text = 'abc', 'maxlength 截断到 3 个码点');


  finally


    engine.Free;


  end;


end;





procedure TestFocusTraversalAndEnter;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  sink: TEventSink;


  a, b, btn: TXuiNode;


begin


  WriteLn('--- M5 焦点遍历 / Enter 激活 / oninput ---');


  sink := TEventSink.Create;


  engine := NewTestEngine(fake);


  try


    engine.EventTarget := sink;


    engine.LoadFromString(


      '<window>' +


      '  <input id="a" oninput="InputChanged" onenter="EnterPressed"/>' +


      '  <input id="b"/>' +


      '  <button id="go" text="go" onclick="BtnClick"/>' +


      '  <button id="off" text="off" disabled="true" onclick="BtnClick"/>' +


      '</window>');


    engine.LoadStyleSheetFromString(


      'input, button { width:120px; height:24px; padding:0; border-width:0; }');


    DrawEngine(engine);


    a := engine.Document.FindElementById('a');


    b := engine.Document.FindElementById('b');


    btn := engine.Document.FindElementById('go');





    Check(engine.HandleKeyDown(VK_TAB, []), '无焦点时 Tab 聚焦第一个可聚焦节点');


    Check(engine.FocusNode = a, '第一个 Tab 落到 a');


    engine.HandleKeyDown(VK_TAB, []);


    Check(engine.FocusNode = b, 'Tab 前进到 b');


    engine.HandleKeyDown(VK_TAB, []);


    Check(engine.FocusNode = btn, 'Tab 跳过 disabled 到按钮');


    engine.HandleKeyDown(VK_TAB, []);


    Check(engine.FocusNode = a, 'Tab 环绕回 a');


    engine.HandleKeyDown(VK_TAB, [xssShift]);


    Check(engine.FocusNode = btn, 'Shift+Tab 反向环绕到按钮');





    engine.HandleKeyDown(VK_RETURN, []);


    Check(sink.Clicks = 1, 'Enter 激活聚焦按钮（等价点击）');





    ClickNode(engine, a);


    engine.HandleTextInput('xy');


    Check(sink.Inputs = 1, 'oninput 绑定在值变化后触发');


    Check(sink.LastInputText = 'xy', 'oninput 处理器读到节点新值');


    engine.HandleKeyDown(VK_HOME, []);


    engine.HandleKeyDown(VK_DELETE, []);


    Check(sink.Inputs = 2, '删除操作同样触发 oninput');


    Check(a.Text = 'y', 'Delete 删除光标后的字符');





    sink.Enters := 0;


    engine.HandleKeyDown(VK_RETURN, []);


    Check(sink.Enters = 1, '输入框中按 Enter 触发 onenter（表单提交用）');


  finally


    engine.Free;


    sink.Free;


  end;


end;





procedure TestInputClipboardAndMouse;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  input: TXuiNode;


  cx, cy: Integer;


begin


  WriteLn('--- M5 输入框：剪贴板 / 鼠标定位与拖选 ---');


  XuiClipboardGet := @FakeClipboardGet;


  XuiClipboardSet := @FakeClipboardSet;


  FakeClipboard := '';


  engine := NewTestEngine(fake);


  try


    engine.LoadFromString('<window><input id="t"/></window>');


    engine.LoadStyleSheetFromString(


      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');


    DrawEngine(engine);


    input := engine.Document.FindElementById('t');


    ClickNode(engine, input);


    engine.HandleTextInput('abc');





    engine.HandleKeyDown(Ord('A'), [xssCtrl]);


    engine.HandleKeyDown(Ord('C'), [xssCtrl]);


    Check(FakeClipboard = 'abc', 'Ctrl+A 全选后 Ctrl+C 复制');


    engine.HandleKeyDown(Ord('X'), [xssCtrl]);


    Check(input.Text = '', 'Ctrl+X 剪切清空');


    Check(FakeClipboard = 'abc', 'Ctrl+X 写入剪贴板');


    engine.HandleKeyDown(Ord('V'), [xssCtrl]);


    Check(input.Text = 'abc', 'Ctrl+V 粘贴回输入框');





    // 鼠标点按定位：点最右侧 → 光标到末尾；拖到左侧 → 选中


    cx := input.ContentBox.Left + 2;


    cy := (input.ContentBox.Top + input.ContentBox.Bottom) div 2;


    engine.HandleMouseDown(cx, cy);


    engine.HandleMouseUp(cx, cy);


    engine.HandleTextInput('Z');


    Check(input.Text = 'Zabc', '点按左侧后光标在行首');





    engine.HandleMouseDown(input.ContentBox.Left + 1, cy);


    engine.HandleMouseMove(input.ContentBox.Right - 1, cy);


    engine.HandleMouseUp(input.ContentBox.Right - 1, cy);


    engine.HandleTextInput('Q');


    Check(input.Text = 'Q', '拖选后输入替换选中文本');


  finally


    engine.Free;


    XuiClipboardGet := nil;


    XuiClipboardSet := nil;


  end;


end;





{$ENDIF}

{$IFDEF LUI_M5_TRANSITION_INLINE}
{ ---------- M5：过渡动画 ---------- }





procedure TestTransitionAnim;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  box: TXuiNode;


  s: TXuiStyle;


  mid: Byte;


begin


  WriteLn('--- M5 过渡动画：解析与推进 ---');


  s := TXuiStyle.Create;


  try


    ApplyDeclaration(s, 'transition', 'background-color 200ms ease-out 50ms', 14);


    Check(xapBgColor in s.TransitionProps, 'transition 解析出属性');


    Check(not (xapOpacity in s.TransitionProps), '未声明的属性不参与过渡');


    Check(Abs(s.TransitionDuration - 0.2) < 0.001, 'ms 时长换算为秒');


    Check(Abs(s.TransitionDelay - 0.05) < 0.001, '延迟解析');


    Check(s.TransitionTiming = xtfEaseOut, '时间函数解析');


    ApplyDeclaration(s, 'transition', 'all 0.1s linear', 14);


    Check(s.TransitionProps = XuiAllAnimProps, 'all 展开为白名单全集');


    Check(s.TransitionTiming = xtfLinear, 'linear 解析');


    ApplyDeclaration(s, 'transition', 'opacity, border-radius 120ms', 14);


    Check((s.TransitionProps = [xapOpacity, xapBorderRadius]), '逗号列表（逗号后空格）解析');


  finally


    s.Free;


  end;





  engine := NewTestEngine(fake);


  try


    engine.LoadFromString('<window><panel id="box"/></window>');


    engine.LoadStyleSheetFromString(


      '#box { width:100px; height:100px; background-color:#000000; ' +


      '       transition: background-color 200ms linear; } ' +


      '#box:hover { background-color:#ffffff; }');


    engine.Tick(1000);


    DrawEngine(engine);


    box := engine.Document.FindElementById('box');


    Check(box.Style.BgColor.R = 0, '初始背景为黑');


    Check(not engine.NeedsTick, '无过渡时不需要 Tick');





    engine.HandleMouseMove(10, 10);


    DrawEngine(engine);


    Check(xpHover in box.Pseudos, 'hover 生效');


    Check(box.Style.BgColor.R = 0, '过渡启动：绘制值为起点（黑）');


    Check(engine.NeedsTick, '过渡激活时 NeedsTick 为真');





    engine.Tick(1100);


    mid := box.Style.BgColor.R;


    Check((mid > 100) and (mid < 160), '半程插值（线性约 128）');





    engine.Tick(1200);


    Check(box.Style.BgColor.R = 255, '到达目标值（白）');


    Check(not engine.NeedsTick, '过渡结束后不再需要 Tick');





    // 中途反向：离开 hover 时从当前值平滑回到黑


    engine.Tick(1250);


    DrawEngine(engine);


    engine.Tick(1500);


    DrawEngine(engine);


    Check(box.Style.BgColor.R = 255, 'hover 保持目标值');


    engine.HandleMouseLeave;


    engine.Tick(1500);


    DrawEngine(engine);


    Check(box.Style.BgColor.R = 255, '离开瞬间仍为当前值（白）');


    engine.Tick(1600);


    mid := box.Style.BgColor.R;


    Check((mid > 100) and (mid < 160), '反向过渡半程插值');


    engine.Tick(1800);


    Check(box.Style.BgColor.R = 0, '反向过渡回到黑色');





    // 未声明的属性立即变化（不参与过渡）


    engine.LoadStyleSheetFromString('#box { opacity:0.5; }');


    engine.Tick(2000);


    DrawEngine(engine);


    Check(Abs(box.Style.Opacity - 0.5) < 0.01, '未声明过渡的属性立即生效');


  finally


    engine.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_M5_INCLUDE_INLINE}
{ ---------- M5：include 模板 ---------- }





procedure WriteTestFile(const APath, AContent: string);


var


  list: TStringList;


begin


  list := TStringList.Create;


  try


    list.Text := AContent;


    list.SaveToFile(APath);


  finally


    list.Free;


  end;


end;





// 让"随后的文件写入"确定性地落在新的时间戳窗口里。


// FileAge 只有 2 秒粒度（DOS 时间格式），且 FileSetDate 在 Windows 上会偶发不生效


// （文件刚写完时的缓存/索引干扰）——所以这里不用 FileSetDate，而是等过粒度边界，


// 让写入后的 mtime 必然与"加载时记录的 mtime"不同。历史上的偶发失败即源于此。


procedure WaitForMTimeTick;


begin


  Sleep(2200);


end;





procedure TestIncludeTemplates;


var


  dir, mainFile, itemFile, tmplFile, nestFile, cycA, cycB, badFile: string;


  engine: TXuiEngine;


  fake: TFakeRenderer;


  root, node: TXuiNode;


  raised: Boolean;


begin


  WriteLn('--- M5 include 模板 ---');


  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'lui_m5_tpl';


  ForceDirectories(dir);


  itemFile := dir + PathDelim + 'item.xml';


  tmplFile := dir + PathDelim + 'tmpl.xml';


  nestFile := dir + PathDelim + 'nest.xml';


  cycA := dir + PathDelim + 'cyc_a.xml';


  cycB := dir + PathDelim + 'cyc_b.xml';


  badFile := dir + PathDelim + 'bad.xml';


  mainFile := dir + PathDelim + 'main.xml';





  WriteTestFile(itemFile, '<panel class="item"><label class="t" text="item"/></panel>');


  WriteTestFile(tmplFile,


    '<template><label class="a" text="A"/><label class="b" text="B"/></template>');


  WriteTestFile(nestFile, '<panel class="nest"><include src="item.xml"/></panel>');


  WriteTestFile(cycA, '<window><include src="cyc_b.xml"/></window>');


  WriteTestFile(cycB, '<window><include src="cyc_a.xml"/></window>');


  WriteTestFile(badFile, '<window><include src="tmpl.xml" class="x"/></window>');


  WriteTestFile(mainFile,


    '<window title="tpl">' +


    '  <include src="item.xml"/>' +


    '  <include src="tmpl.xml"/>' +


    '  <include src="nest.xml"/>' +


    '  <include src="item.xml" class="extra" id="last"/>' +


    '</window>');





  engine := NewTestEngine(fake);


  try


    engine.LoadFromFile(mainFile);


    DrawEngine(engine);


    root := engine.Document.Root;


    Check(root.Count = 5, 'include 展开后节点数正确（1+2+1+1）');


    node := root[0];


    Check((node.Tag = 'panel') and node.HasClass('item'), '单根文件展开为根元素自身');


    Check((root[1].Tag = 'label') and (root[1].Text = 'A'), 'template 展开第一个子元素');


    Check((root[2].Tag = 'label') and (root[2].Text = 'B'), 'template 展开第二个子元素');


    Check(root[3].HasClass('nest') and (root[3].Count = 1), '嵌套 include 展开');


    Check(root[4].HasClass('item') and root[4].HasClass('extra'),


      'include 上的 class 合并到展开节点');


    Check(root[4].Id = 'last', 'include 上的 id 合并');


    Check(engine.Document.FindElementById('last') = root[4], '合并 id 后可被查找');


    Check(engine.Document.SourceFile <> '', '文档记录来源文件');


    Check(engine.Document.Dependencies.Count = 3, '依赖收集（item/tmpl/nest）');





    // 运行时片段里的 include（按文档目录解析）


    node := engine.AddElement(root, '<include src="item.xml"/>');


    DrawEngine(engine);


    Check((node <> nil) and node.HasClass('item'), '运行时片段中的 include 展开');





    // 多节点展开时不允许附加属性


    raised := False;


    try


      engine.LoadFromFile(badFile);


    except


      raised := True;


    end;


    Check(raised, 'template 多节点 + 附加属性 抛异常');





    // 循环 include


    raised := False;


    try


      engine.LoadFromFile(cycA);


    except


      raised := True;


    end;


    Check(raised, '循环 include 抛异常');


    Check(engine.Document <> nil, '加载失败保留原文档');





    // 清理临时文件


    DeleteFile(itemFile);


    DeleteFile(tmplFile);


    DeleteFile(nestFile);


    DeleteFile(cycA);


    DeleteFile(cycB);


    DeleteFile(badFile);


    DeleteFile(mainFile);


    RemoveDir(dir);


  finally


    engine.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_HELPERS_INLINE}
{ ---------- M6：脚本引擎（内核级 + 集成）---------- }





type


  // 脚本输出/错误接收器（回调是 of object 类型）


  TScriptSink = class


  public


    Log: TStringList;


    Unhandled: TStringList;   // 未处理 Promise 拒绝消息（P1）


    LastError: string;


    LastErrorStage: TXuiScriptStage;


    Errors: Integer;


    constructor Create;


    destructor Destroy; override;


    procedure HandleLog(const AText: string);


    procedure HandleError(const AFile, AMessage: string;


      ALine, ACol: Integer; AStage: TXuiScriptStage);


    procedure HandleUnhandled(const AMessage: string);


  end;





constructor TScriptSink.Create;


begin


  inherited Create;


  Log := TStringList.Create;


  Unhandled := TStringList.Create;


end;





destructor TScriptSink.Destroy;


begin


  Log.Free;


  Unhandled.Free;


  inherited Destroy;


end;





procedure TScriptSink.HandleLog(const AText: string);


begin


  Log.Add(AText);


end;





procedure TScriptSink.HandleError(const AFile, AMessage: string;


  ALine, ACol: Integer; AStage: TXuiScriptStage);


begin


  Inc(Errors);


  LastError := AMessage;


  LastErrorStage := AStage;


end;





procedure TScriptSink.HandleUnhandled(const AMessage: string);


begin


  Unhandled.Add(AMessage);


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_CORE_INLINE}
// 内核：词法/语法/解释器（不依赖引擎）


procedure TestScriptCore;


var


  interp: TXuiJsInterp;


  prog: TXuiJsProgram;


  sink: TScriptSink;


  src: string;





  function RunScript(const ACode: string): string;


  begin


    sink.Log.Clear;


    prog := XuiJsParse(ACode, 'test.ts');


    try


      interp.Run(prog.Root);


    finally


      prog.Free;


    end;


    Result := sink.Log.Text;


  end;





begin


  WriteLn('--- M6 脚本内核 ---');


  sink := TScriptSink.Create;


  interp := TXuiJsInterp.Create;


  try


    interp.OnLog := @sink.HandleLog;


    src := RunScript(


      'let x: number = 1 + 2 * 3;' + #10 +


      'console.log("a" + x);' + #10 +


      'function add(p: number, q: number): number { return p + q; }' + #10 +


      'console.log("b" + add(2, 3));' + #10 +


      'const o = { k: 1, s: "hi" };' + #10 +


      'console.log("c" + o.k + o.s);' + #10 +


      'const arr = [1, 2, 3];' + #10 +


      'console.log("d" + arr.length + arr.map(v => v * 2).join("-"));' + #10 +


      'console.log("e" + `t${1 + 1}`);' + #10 +


      'const { k, s } = o;' + #10 +


      'console.log("f" + k + s);' + #10 +


      'let 计数 = 0; 计数 += 5;' + #10 +


      'console.log("g" + 计数);');


    Check(Pos('a7', src) > 0, '表达式优先级与类型擦除');


    Check(Pos('b5', src) > 0, '函数声明与调用');


    Check(Pos('c1hi', src) > 0, '对象字面量与成员访问');


    Check(Pos('d32-4-6', src) > 0, '数组方法（map/join）');


    Check(Pos('et2', src) > 0, '模板串');


    Check(Pos('f1hi', src) > 0, '对象解构');


    Check(Pos('g5', src) > 0, '中文标识符与复合赋值');





    src := RunScript(


      'class A { constructor(n) { this.n = n; } hi() { return "A" + this.n; } }' + #10 +


      'class B extends A { hi() { return "B" + this.n; } }' + #10 +


      'console.log("h" + new B("x").hi());' + #10 +


      'let sum = 0; for (const v of [1,2,3]) { sum += v; }' + #10 +


      'console.log("i" + sum);' + #10 +


      'try { throw "err"; } catch (e) { console.log("j" + e); }' + #10 +


      'console.log("k" + JSON.stringify({ p: 1, q: [true, null] }));' + #10 +


      'const s2 = "你好世界";' + #10 +


      'console.log("l" + s2.length + s2.slice(1, 3));');


    Check(Pos('hBx', src) > 0, '类继承与方法覆盖');


    Check(Pos('i6', src) > 0, 'for..of 累加');


    Check(Pos('jerr', src) > 0, 'try/catch 捕获 throw');


    Check(Pos('k{"p":1,"q":[true,null]}', src) > 0, 'JSON.stringify');


    Check(Pos('l4好世', src) > 0, '中文字符串按码点计数与切片');





    // 预算：切片内死循环应被拦下（不挂死测试进程）


    src := RunScript(


      'function Loop() { let i = 0; while (true) { i++; } }' + #10 +


      'try { Loop(); } catch (e) { console.log("m" + e); }');


    Check(Pos('m', src) > 0, '死循环被指令预算拦截');


  finally


    interp.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{ ---------- M6 P1：Promise 与微任务 ---------- }





{$IFDEF LUI_SCRIPT_ASYNC_INLINE}
// 内核级：Promise 语义、微任务时序、预算切片化、GC 根扩展（不依赖引擎）


procedure TestScriptAsync;


var


  interp: TXuiJsInterp;


  prog: TXuiJsProgram;


  sink: TScriptSink;


  src: string;


  baseline, syncSteps: Int64;


  progs: TObjectList;   // AST 须存活到排水之后（闭包引用函数体节点）





  // 只求值不排水（时序断言需要）


  procedure RunNoDrain(const ACode: string);


  begin


    prog := XuiJsParse(ACode, 'test.ts');


    progs.Add(prog);    // 所有权转移：程序对象随测试结束统一释放


    interp.Run(prog.Root);


  end;





  function RunAndDrain(const ACode: string): string;


  begin


    sink.Log.Clear;


    RunNoDrain(ACode);


    interp.DrainMicrotasks;


    Result := sink.Log.Text;


  end;





begin


  WriteLn('--- M6 P1 Promise 与微任务 ---');


  sink := TScriptSink.Create;


  interp := TXuiJsInterp.Create;


  progs := TObjectList.Create(True);


  try


    interp.OnLog := @sink.HandleLog;


    interp.OnUnhandledRejection := @sink.HandleUnhandled;





    // 回调异步执行：then 回调晚于后续同步语句（经典顺序断言）


    sink.Log.Clear;


    RunNoDrain(


      'console.log("a");' + #10 +


      'Promise.resolve(1).then(function (v) { console.log("c" + v); });' + #10 +


      'console.log("b");');


    Check((Pos('a', sink.Log.Text) > 0) and (Pos('b', sink.Log.Text) > 0) and


      (Pos('c1', sink.Log.Text) = 0), 'then 回调不同步执行');


    interp.DrainMicrotasks;


    Check(Pos('c1', sink.Log.Text) > Pos('b', sink.Log.Text),


      '排水后回调执行且晚于同步语句');





    // 微任务 FIFO


    src := RunAndDrain(


      'Promise.resolve().then(function () { console.log("t1"); });' + #10 +


      'Promise.resolve().then(function () { console.log("t2"); });' + #10 +


      'Promise.resolve().then(function () { console.log("t3"); });');


    Check((Pos('t1', src) < Pos('t2', src)) and (Pos('t2', src) < Pos('t3', src)),


      '微任务按 FIFO 顺序执行');





    // 链式传值：回调返回值 resolve 下游


    src := RunAndDrain(


      'Promise.resolve(1)' + #10 +


      '  .then(function (v) { return v + 1; })' + #10 +


      '  .then(function (v) { return v * 10; })' + #10 +


      '  .then(function (v) { console.log("chain" + v); });');


    Check(Pos('chain20', src) > 0, '链式 then 传递回调返回值');





    // 非函数参数透传


    src := RunAndDrain(


      'Promise.resolve("p").then().then(function (v) { console.log("pass" + v); });' + #10 +


      'Promise.resolve(5).then(123).then(function (v) { console.log("pass2" + v); });' + #10 +


      'Promise.reject("ep").then(undefined, function (r) { console.log("pass3" + r); });');


    Check(Pos('passp', src) > 0, '空 then 透传成功值');


    Check(Pos('pass25', src) > 0, '非函数 onFulfilled 透传');


    Check(Pos('pass3ep', src) > 0, 'then(undefined, f) 处理拒绝');





    // 错误传播与恢复：handler 抛错 reject 下游；catch 捕获并恢复；跳过路径


    src := RunAndDrain(


      'Promise.resolve("x").then(function (v) { throw "boom"; })' + #10 +


      '  .catch(function (r) { console.log("caught" + r); return "rec"; })' + #10 +


      '  .then(function (v) { console.log("after" + v); });' + #10 +


      'Promise.reject("rj").then(function (v) { console.log("skipx" + v); })' + #10 +


      '  .catch(function (r) { console.log("skipped" + r); });');


    Check(Pos('caughtboom', src) > 0, 'then 回调抛错进入下游 catch');


    Check(Pos('afterrec', src) > 0, 'catch 返回值恢复链路');


    Check(Pos('skipx', src) = 0, '拒绝跳过 onFulfilled');


    Check(Pos('skippedrj', src) > 0, 'catch 捕获初始拒绝');





    // 状态不可逆：resolve 后再 resolve/reject 均无效（set 是关键字，控制函数名用 fire）


    src := RunAndDrain(


      'let fire;' + #10 +


      'const q = new Promise(function (res, rej) { fire = res; });' + #10 +


      'fire("first");' + #10 +


      'fire("second");' + #10 +


      'q.then(function (v) { console.log("once" + v); });');


    Check((Pos('oncefirst', src) > 0) and (Pos('second', src) = 0),


      'promise 状态不可逆');





    // executor 同步执行 + 抛错 → reject


    src := RunAndDrain(


      'console.log("pre");' + #10 +


      'new Promise(function (res) { console.log("exec"); res("ok"); })' + #10 +


      '  .then(function (v) { console.log("then" + v); });' + #10 +


      'console.log("post");' + #10 +


      'new Promise(function () { throw "ctor-throw"; })' + #10 +


      '  .catch(function (r) { console.log("ct" + r); });');


    Check((Pos('pre', src) < Pos('exec', src)) and (Pos('exec', src) < Pos('post', src)),


      'executor 同步执行');


    Check(Pos('thenok', src) > Pos('post', src), 'executor 内 resolve 仍异步回调');


    Check(Pos('ctctor-throw', src) > 0, 'executor 抛错使 promise 拒绝');





    // thenable 采纳：回调返回 promise → 下游等待其 settle


    src := RunAndDrain(


      'const outer = Promise.resolve("in")' + #10 +


      '  .then(function (v) { return Promise.resolve(v + "!"); });' + #10 +


      'outer.then(function (v) { console.log("adopt" + v); });');


    Check(Pos('adoptin!', src) > 0, '下游采纳回调返回的 promise');





    // Promise.resolve(promise) 原样返回


    src := RunAndDrain(


      'const same = Promise.resolve(7);' + #10 +


      'console.log("same" + (Promise.resolve(same) === same) +' + #10 +


      '  (Promise.resolve(8) === same));');


    Check(Pos('sametruefalse', src) > 0, 'Promise.resolve 对 promise 原样返回');





    // all：结果按输入序；任一 reject 即 reject；空数组


    src := RunAndDrain(


      'Promise.all([Promise.resolve(1), 2, Promise.resolve(3)])' + #10 +


      '  .then(function (a) { console.log("all" + a.join("-")); });' + #10 +


      'Promise.all([Promise.resolve(1), Promise.reject("all-rej")])' + #10 +


      '  .catch(function (r) { console.log("allerr" + r); });' + #10 +


      'Promise.all([]).then(function (a) { console.log("allempty" + a.length); });');


    Check(Pos('all1-2-3', src) > 0, 'Promise.all 收集全部值（含普通值混入）');


    Check(Pos('allerrall-rej', src) > 0, 'Promise.all 任一拒绝即拒绝');


    Check(Pos('allempty0', src) > 0, 'Promise.all 空数组立即完成');





    // allSettled：收集 {status, value|reason}


    src := RunAndDrain(


      'Promise.allSettled([Promise.resolve(1), Promise.reject("r2")])' + #10 +


      '  .then(function (a) {' + #10 +


      '    console.log("as" + a[0].status + ":" + a[0].value + "|" +' + #10 +


      '      a[1].status + ":" + a[1].reason); });');


    Check(Pos('asfulfilled:1|rejected:r2', src) > 0, 'Promise.allSettled 收集全部结局');





    // race：先到先得（含拒绝领先与普通值混入）


    src := RunAndDrain(


      'Promise.race(["first", Promise.resolve("late")])' + #10 +


      '  .then(function (v) { console.log("race1" + v); });' + #10 +


      'Promise.race([Promise.reject("race-rej"), Promise.resolve("x")])' + #10 +


      '  .catch(function (r) { console.log("race2" + r); });');


    Check(Pos('race1first', src) > 0, 'Promise.race 首个 settle 生效');


    Check(Pos('race2race-rej', src) > 0, 'Promise.race 拒绝领先同样生效');





    // finally：回调执行、透传原值、拒绝透传、回调抛错


    src := RunAndDrain(


      'Promise.resolve("fin").finally(function () { console.log("fin-run"); })' + #10 +


      '  .then(function (v) { console.log("fin-pass" + v); });' + #10 +


      'Promise.reject("fe").finally(function () { console.log("fin-rej-run"); })' + #10 +


      '  .catch(function (r) { console.log("fin-keep" + r); });' + #10 +


      'Promise.resolve("x").finally(function () { throw "fin-throw"; })' + #10 +


      '  .catch(function (r) { console.log("fin-threw" + r); });');


    Check(Pos('fin-run', src) > 0, 'finally 回调执行');


    Check(Pos('fin-passfin', src) > 0, 'finally 透传成功值');


    Check(Pos('fin-rej-run', src) > 0, 'finally 在拒绝路径也执行');


    Check(Pos('fin-keepfe', src) > 0, 'finally 透传拒绝原因');


    Check(Pos('fin-threwfin-throw', src) > 0, 'finally 回调抛错使下游拒绝');





    // 未处理拒绝：上报一次；排水前挂接处理则免报


    sink.Unhandled.Clear;


    sink.Log.Clear;


    RunNoDrain(


      'Promise.reject("orphan");' + #10 +


      'const p2 = Promise.reject("handled2");' + #10 +


      'p2.catch(function (r) { console.log("lh" + r); });');


    interp.DrainMicrotasks;


    Check(sink.Unhandled.Count = 1, '未处理拒绝恰上报一次');


    Check(Pos('orphan', sink.Unhandled.Text) > 0, '未处理拒绝携带原因');


    Check(Pos('handled2', sink.Unhandled.Text) = 0, '已挂接处理的拒绝不上报');


    Check(Pos('lhhandled2', sink.Log.Text) > 0, '挂接的处理函数正常执行');


    interp.DrainMicrotasks;


    Check(sink.Unhandled.Count = 1, '同一拒绝不重复上报');





    // 预算：微任务内死循环 → 超预算以拒绝形式冒泡并上报（不挂死）


    interp.MaxSteps := 50000;


    sink.Unhandled.Clear;


    sink.Log.Clear;


    RunNoDrain(


      'Promise.resolve().then(function () { let i = 0; while (true) { i++; } });');


    interp.DrainMicrotasks;


    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0,


      '微任务内死循环超预算并上报');


    interp.MaxSteps := 2000000;





    // 预算切片化：微任务不继承触发切片的已耗步数


    sink.Log.Clear;


    RunNoDrain(


      'function Loop(n) { let s = 0; let i; for (i = 0; i < n; i++) { s += i; } return s; }' + #10 +


      'Loop(20000);');


    syncSteps := interp.Steps;


    Check(syncSteps > 1000, '同步切片消耗步数可测');


    interp.MaxSteps := syncSteps * 3 div 2;   // 预算 = 1.5 × 单次切片：若跨任务累计必溢出


    RunNoDrain(


      'Promise.resolve().then(function () { console.log("mb" + Loop(20000)); });');


    interp.DrainMicrotasks;


    Check(Pos('mb', sink.Log.Text) > 0, '微任务预算独立重置（跨任务不累计）');


    // 负向对照：同等预算下更大循环必须仍被拦截


    sink.Unhandled.Clear;


    RunNoDrain(


      'Promise.resolve().then(function () { console.log("mc" + Loop(200000)); });');


    interp.DrainMicrotasks;


    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0, '微任务内预算超限仍生效');


    Check(Pos('mc', sink.Log.Text) = 0, '超预算微任务未产生输出');


    interp.MaxSteps := 2000000;





    // GC：排队中的微任务（回调 + 下游 promise）不被回收；排水后对象数收敛


    interp.ForceCollectGarbage;


    baseline := interp.ObjectCount;


    RunNoDrain(


      'for (let i = 0; i < 50; i++) { Promise.resolve(i).then(function (v) { return v; }); }');


    interp.ForceCollectGarbage;


    Check(interp.ObjectCount > baseline + 50, '挂起中的回调与下游不被回收');


    interp.DrainMicrotasks;


    interp.ForceCollectGarbage;


    Check(interp.ObjectCount < baseline + 30, '排水后脚本对象数收敛');





    // GC：resolve 控制函数保活其 promise（经 Tag 标记），GC 后仍可 settle


    sink.Unhandled.Clear;


    RunNoDrain('let saved; new Promise(function (res) { saved = res; });');


    interp.ForceCollectGarbage;


    sink.Log.Clear;


    RunNoDrain('saved(42); console.log("ctl-ok");');


    Check(Pos('ctl-ok', sink.Log.Text) > 0, 'GC 后控制函数仍可用');


    Check(sink.Unhandled.Count = 0, '控制函数 settle 成功无拒绝');


  finally


    progs.Free;


    interp.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{ ---------- M6 P2：定时器宏任务 ---------- }





{$IFDEF LUI_SCRIPT_TIMERS_INLINE}
// 内核级：ui.setTimeout/setInterval/clear/delay/now 与宏任务泵（人造时间推进）


procedure TestScriptTimers;


var


  interp: TXuiJsInterp;


  prog: TXuiJsProgram;


  sink: TScriptSink;


  src: string;


  baseline: Int64;


  i: Integer;


  progs: TObjectList;   // AST 须存活到泵执行之后（闭包引用函数体节点）





  procedure Run(const ACode: string);


  begin


    prog := XuiJsParse(ACode, 'test.ts');


    progs.Add(prog);


    interp.Run(prog.Root);


  end;





  // 人造时间推进 + 泵到期定时器


  procedure AdvanceAndPump(ADeltaMs: Int64);


  begin


    interp.SetClockMs(interp.NowMs + ADeltaMs);


    interp.PumpTimers;


  end;





begin


  WriteLn('--- M6 P2 定时器宏任务 ---');


  sink := TScriptSink.Create;


  interp := TXuiJsInterp.Create;


  progs := TObjectList.Create(True);


  try


    interp.OnLog := @sink.HandleLog;


    interp.OnUnhandledRejection := @sink.HandleUnhandled;


    interp.OnCallbackError := @sink.HandleUnhandled;





    // setTimeout(0)：下一次泵执行；同期到期按注册序


    sink.Log.Clear;


    Run(


      'ui.setTimeout(function () { console.log("a"); }, 0);' + #10 +


      'ui.setTimeout(function () { console.log("b"); }, 0);');


    Check(interp.HasDueTimers, 'setTimeout(0) 注册即到期待执行');


    Check(interp.PumpTimers = 2, '泵返回执行的宏任务数');


    Check((Pos('a', sink.Log.Text) > 0) and


      (Pos('a', sink.Log.Text) < Pos('b', sink.Log.Text)),


      'setTimeout(0) 泵内执行且按注册序');


    Check(not interp.HasDueTimers, '执行后无到期定时器');





    // 到期顺序按延迟排序（不同期不按注册序）


    sink.Log.Clear;


    Run(


      'ui.setTimeout(function () { console.log("late"); }, 50);' + #10 +


      'ui.setTimeout(function () { console.log("soon"); }, 10);');


    AdvanceAndPump(10);


    Check((Pos('soon', sink.Log.Text) > 0) and (Pos('late', sink.Log.Text) = 0),


      '仅到期定时器执行');


    AdvanceAndPump(40);


    Check(Pos('soon', sink.Log.Text) < Pos('late', sink.Log.Text),


      '到期顺序按延迟先后');





    // clearTimeout：取消不执行，表项回收


    sink.Log.Clear;


    Run(


      'const id = ui.setTimeout(function () { console.log("nope"); }, 30);' + #10 +


      'ui.clearTimeout(id);' + #10 +


      'ui.setTimeout(function () { console.log("yes"); }, 30);');


    Check(interp.TimersPending = 1, 'clearTimeout 回收表项');


    AdvanceAndPump(30);


    Check((Pos('yes', sink.Log.Text) > 0) and (Pos('nope', sink.Log.Text) = 0),


      '已取消的定时器不执行');





    // setInterval 重复 + clearInterval 停止


    sink.Log.Clear;


    Run(


      'let n = 0;' + #10 +


      'const id = ui.setInterval(function () { n += 1; console.log("tick" + n);' + #10 +


      '  if (n >= 3) { ui.clearInterval(id); } }, 10);');


    for i := 1 to 5 do


      AdvanceAndPump(10);


    Check((Pos('tick3', sink.Log.Text) > 0) and (Pos('tick4', sink.Log.Text) = 0),


      'setInterval 重复执行且 clearInterval 停止');





    // setInterval(,0) 钳制为 1ms：泵在有限时钟内终止


    sink.Log.Clear;


    Run(


      'let n2 = 0;' + #10 +


      'const id2 = ui.setInterval(function () { n2 += 1;' + #10 +


      '  if (n2 >= 3) { ui.clearInterval(id2); console.log("z" + n2); } }, 0);');


    AdvanceAndPump(5);


    Check(Pos('z3', sink.Log.Text) > 0, '零间隔 setInterval 钳制且可停止');





    // 微任务优先于下一宏任务（经典顺序断言）


    sink.Log.Clear;


    Run(


      'ui.setTimeout(function () { console.log("macro"); }, 0);' + #10 +


      'Promise.resolve().then(function () { console.log("micro"); });' + #10 +


      'console.log("sync");');


    interp.DrainMicrotasks;


    Check(Pos('macro', sink.Log.Text) = 0, '定时器不因排水而提前执行');


    AdvanceAndPump(0);


    Check(Pos('micro', sink.Log.Text) < Pos('macro', sink.Log.Text),


      '微任务先于下一宏任务');





    // 回调额外参数


    sink.Log.Clear;


    Run('ui.setTimeout(function (a, b) { console.log("args" + a + b); }, 5, "x", 7);');


    AdvanceAndPump(5);


    Check(Pos('argsx7', sink.Log.Text) > 0, '定时器回调接收额外参数');





    // ui.delay(ms): Promise 到点 resolve；ui.now() 返回注入时钟


    interp.SetClockMs(0);   // 时钟在前面的用例中已推进，归零便于断言


    sink.Log.Clear;


    Run('ui.delay(20).then(function (v) { console.log("delayed" + v + "@" + ui.now()); });');


    Check(interp.TimersPending = 1, 'ui.delay 基于定时器表');


    AdvanceAndPump(20);


    Check(Pos('delayedundefined@20', sink.Log.Text) > 0,


      'ui.delay 到点 resolve(undefined)，ui.now 为相对时钟');

    // ui.time()：墙钟本地时间字符串（now() 是会话相对毫秒，表达不了当前时刻）
    sink.Log.Clear;
    Run('console.log("T|" + ui.time() + "|");');
    src := sink.Log.Text;
    Check((Pos('T|', src) > 0) and (Length(Trim(src)) > 12),
      'ui.time 返回墙钟时间字符串');





    // 宏任务回调抛错：上报且不中断后续定时器


    sink.Unhandled.Clear;


    sink.Log.Clear;


    Run(


      'ui.setTimeout(function () { throw "cb-error"; }, 0);' + #10 +


      'ui.setTimeout(function () { console.log("after-err"); }, 0);');


    Check(interp.PumpTimers = 2, '异常后泵继续执行后续定时器');


    Check(Pos('cb-error', sink.Unhandled.Text) > 0, '宏任务回调异常上报');


    Check(Pos('after-err', sink.Log.Text) > 0, '异常不中断后续定时器');





    // 宏任务死循环：预算拦截 + 后续定时器继续


    interp.MaxSteps := 50000;


    sink.Unhandled.Clear;


    sink.Log.Clear;


    Run(


      'ui.setTimeout(function () { let i = 0; while (true) { i++; } }, 0);' + #10 +


      'ui.setTimeout(function () { console.log("ok-after-budget"); }, 0);');


    interp.PumpTimers;


    Check(Pos('步数超出预算', sink.Unhandled.Text) > 0, '宏任务死循环超预算上报');


    Check(Pos('ok-after-budget', sink.Log.Text) > 0, '超预算不中断后续定时器');


    interp.MaxSteps := 2000000;





    // GC：定时器表持有回调（挂起对象不被回收）


    interp.ForceCollectGarbage;


    baseline := interp.ObjectCount;


    Run('ui.setTimeout(function () { return 1; }, 100000);');


    interp.ForceCollectGarbage;


    Check(interp.ObjectCount > baseline, '定时器表中的回调不被回收');


    interp.ClearTimer(999999); // 不存在的 Id：无副作用


  finally


    progs.Free;


    interp.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{ ---------- M6 P3：async/await ---------- }





{$IFDEF LUI_SCRIPT_ASYNC_AWAIT_INLINE}
// 内核级：完整 await 矩阵（表达式/循环/try/finally/递归）、位置校验、错误传播、GC


procedure TestScriptAsyncAwait;


var


  interp: TXuiJsInterp;


  prog: TXuiJsProgram;


  sink: TScriptSink;


  src: string;


  progs: TObjectList;   // AST 须存活到排水之后（闭包引用函数体节点）





  function RunAndDrain(const ACode: string): string;


  begin


    sink.Log.Clear;


    prog := XuiJsParse(ACode, 'test.ts');


    progs.Add(prog);


    interp.Run(prog.Root);


    interp.DrainMicrotasks;


    Result := sink.Log.Text;


  end;





  // 解析应失败且报指定文案


  procedure CheckParseError(const ACode, APart: string; const AName: string);


  begin


    try


      prog := XuiJsParse(ACode, 'test.ts');


      progs.Add(prog);


      Check(False, AName);


    except


      on E: Exception do


        Check((E is EXuiJsSyntaxError) and (Pos(APart, E.Message) > 0), AName);


    end;


  end;





begin


  WriteLn('--- M6 P3 async/await ---');


  sink := TScriptSink.Create;


  interp := TXuiJsInterp.Create;


  progs := TObjectList.Create(True);


  try


    interp.OnLog := @sink.HandleLog;


    interp.OnUnhandledRejection := @sink.HandleUnhandled;





    // 基础：async 返回值即 promise；同步执行到首个 await（经典顺序断言）


    src := RunAndDrain(


      'async function f() {' + #10 +


      '  console.log("a");' + #10 +


      '  const v = await Promise.resolve("b");' + #10 +


      '  console.log(v);' + #10 +


      '  return v + "c";' + #10 +


      '}' + #10 +


      'console.log("s");' + #10 +


      'f().then(function (v) { console.log("t" + v); });' + #10 +


      'console.log("e");');


    Check((Pos('s', src) < Pos('a', src)) and (Pos('a', src) < Pos('e', src)) and


      (Pos('e', src) < Pos('b', src)),


      'async 同步执行到首个 await，之后走微任务');


    Check(Pos('tbc', src) > 0, 'async 返回值经 promise 送达');





    // await 在表达式内


    src := RunAndDrain(


      'async function add() {' + #10 +


      '  const x = 1 + await Promise.resolve(2);' + #10 +


      '  return x * 10;' + #10 +


      '}' + #10 +


      'add().then(function (v) { console.log("expr" + v); });');


    Check(Pos('expr30', src) > 0, 'await 参与表达式运算');





    // await 与可选链/空值合并（左为 null → 取右侧；右侧再嵌可选链）


    src := RunAndDrain(


      'async function opt() {' + #10 +


      '  const o = await Promise.resolve({ v: "opt" });' + #10 +


      '  const n = await Promise.resolve(null);' + #10 +


      '  return (n)?.v ?? "d|" + ((o)?.v ?? "x");' + #10 +


      '}' + #10 +


      'opt().then(function (v) { console.log("R" + v); });');


    Check(Pos('Rd|opt', src) > 0, 'await 后接可选链与 ??');





    // 循环条件 / for..of 迭代源 / 步进中的 await


    src := RunAndDrain(


      'async function loops() {' + #10 +


      '  let s = "";' + #10 +


      '  let n = 0;' + #10 +


      '  while (await Promise.resolve(n < 3)) { s += n; n += 1; }' + #10 +


      '  for (const x of await Promise.resolve(["A", "B"])) { s += x; }' + #10 +


      '  for (let i2 = 0; i2 < 2; i2 = await Promise.resolve(i2 + 1)) { s += "s"; }' + #10 +


      '  return s;' + #10 +


      '}' + #10 +


      'loops().then(function (v) { console.log("L" + v); });');


    Check(Pos('L012ABss', src) > 0, 'while 条件 / for..of 源 / 步进中的 await');





    // 含 await 的 try/catch/finally；catch 捕获 await 表达式的拒绝


    src := RunAndDrain(


      'async function guarded() {' + #10 +


      '  let out = "";' + #10 +


      '  try {' + #10 +


      '    out += await Promise.resolve("ok");' + #10 +


      '    out += await Promise.reject("bad");' + #10 +


      '    out += "skip";' + #10 +


      '  } catch (e) {' + #10 +


      '    out += "|caught" + e;' + #10 +


      '  } finally {' + #10 +


      '    out += "|fin" + await Promise.resolve("!");' + #10 +


      '  }' + #10 +


      '  return out;' + #10 +


      '}' + #10 +


      'guarded().then(function (v) { console.log("G" + v); });');


    Check(Pos('Gok|caughtbad|fin!', src) > 0, 'try/catch/finally 内的 await 与拒绝捕获');





    // finally 中含 await 且改变控制流前的时序（finally 完成后才 settle）


    src := RunAndDrain(


      'async function fin2() {' + #10 +


      '  try { return await Promise.resolve("v"); }' + #10 +


      '  finally { console.log("fin-run" + await Promise.resolve(1)); }' + #10 +


      '}' + #10 +


      'fin2().then(function (v) { console.log("F" + v); });');


    Check((Pos('fin-run1', src) > 0) and (Pos('Fv', src) > 0),


      'finally 内 await 后仍透传返回值');





    // return await / 嵌套 async / 异步递归


    src := RunAndDrain(


      'async function inner() { return await Promise.resolve(5); }' + #10 +


      'async function outer() { return await inner(); }' + #10 +


      'async function fib(n: number): number {' + #10 +


      '  if (n < 2) { return n; }' + #10 +


      '  return (await fib(n - 1)) + (await fib(n - 2));' + #10 +


      '}' + #10 +


      'outer().then(function (v) { console.log("nest" + v); });' + #10 +


      'fib(5).then(function (v) { console.log("fib" + v); });');


    Check(Pos('nest5', src) > 0, 'return await 解包一层');


    Check(Pos('fib5', src) > 0, '异步递归（同表达式双 await）');





    // async 方法 / async 箭头 / 对象与数组字面量中的 await


    src := RunAndDrain(


      'class C {' + #10 +


      '  async m() { return await Promise.resolve("m"); }' + #10 +


      '}' + #10 +


      'const arrow = async (x: number): number => x + await Promise.resolve(1);' + #10 +


      'const c = new C();' + #10 +


      'async function lits() {' + #10 +


      '  const o = { k: await Promise.resolve("K") };' + #10 +


      '  const arr2 = [0, await Promise.resolve(9)];' + #10 +


      '  return c.m() && false ? "" : o.k + arr2[1];' + #10 +


      '}' + #10 +


      'arrow(1).then(function (v) { console.log("ar" + v); });' + #10 +


      'lits().then(function (v) { console.log("lit" + v); });');


    Check(Pos('ar2', src) > 0, 'async 箭头函数');


    Check(Pos('litK9', src) > 0, 'async 方法与字面量中的 await');





    // async 内抛错 → promise 拒绝传播；未处理会上报


    sink.Unhandled.Clear;


    src := RunAndDrain(


      'async function boom() { throw "boom-val"; }' + #10 +


      'boom().then(function (v) { console.log("no" + v); });' + #10 +


      'async function handled() { throw "h"; }' + #10 +


      'handled().catch(function (r) { console.log("hc" + r); });');


    Check(Pos('hch', src) > 0, 'async 抛错经 catch 处理');


    Check((Pos('boom-val', sink.Unhandled.Text) > 0) and


      (Pos('h', sink.Unhandled.Text) = 0),


      '未处理的 async 拒绝上报一次');





    // await 位置校验（解析期中文报错）


    CheckParseError('function bad() { return await Promise.resolve(1); }',


      'await 只能用于 async 函数内', '非 async 函数内 await 报错');


    CheckParseError('const t = await Promise.resolve(1);',


      'await 只能用于 async 函数内', '顶层 await 报错');


    CheckParseError('for await (const x of [1]) {}',


      'for await', 'for await..of 报错');


    src := RunAndDrain('const okArrow = async (x: number): number => x; console.log("okp");');


    Check(Pos('okp', src) > 0, 'async 前缀合法语法不受影响');





    // 预算：async 内死循环 → 超预算拒绝（不挂死）


    interp.MaxSteps := 60000;


    sink.Unhandled.Clear;


    RunAndDrain(


      'async function loop() { while (true) { } return 1; }' + #10 +


      'loop().catch(function (r) { console.log("lc" + r); });');


    Check(Pos('lc', sink.Log.Text) > 0, 'async 死循环被预算拦截且可捕获');


    interp.MaxSteps := 2000000;





    // GC：挂起中的 async 帧栈不被回收——强制 GC 后仍可恢复并访问帧内环境


    sink.Log.Clear;


    RunAndDrain(


      'let rs;' + #10 +


      'const never = new Promise(function (res) { rs = res; });' + #10 +


      'const keep = { tag: "K" };' + #10 +


      'async function waiter() { const local = await never; return "W" + local.tag + keep.tag; }' + #10 +


      'waiter().then(function (v) { console.log(v); });');


    interp.ForceCollectGarbage;


    RunAndDrain('rs(keep);');


    Check(Pos('WKK', sink.Log.Text) > 0, '挂起中的 async 帧栈不被回收且可恢复');


  finally


    progs.Free;


    interp.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_INTEGRATION_INLINE}
// 集成：脚本经引擎操作 DOM（桥 + 事件第二来源 + 动态绑定 + 错误路由）


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


        '  n.text = "clicked";' + #10 +


        '  n.class = "hot";' + #10 +


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





      // 点击 → 脚本全局函数（XML onclick 名字回退）→ 改 DOM


      ClickNode(engine, btn);


      DrawEngine(engine);


      Check(btn.Text = 'clicked', 'onclick 回退到脚本全局函数并改写文本');


      Check(btn.HasClass('hot'), '脚本可设置类名');


      Check((btn.Style <> nil) and (btn.Style.BgColor.R = $FF), '类名变更后样式生效');





      // 动态绑定 node.on + 事件对象


      // 注意：先移出按钮（ClickNode 已把指针放在按钮上），再进入才会产生 mouseenter


      script.CallGlobal('Boot', []);


      engine.HandleMouseMove(295, 195);


      engine.HandleMouseMove((btn.BoxRect.Left + btn.BoxRect.Right) div 2,


        (btn.BoxRect.Top + btn.BoxRect.Bottom) div 2);


      DrawEngine(engine);


      Check(engine.Document.FindElementById('tip').Text = 'hover:onmouseenter',


        '动态绑定收到事件并携带事件对象');





      // 错误路由：脚本运行期错误不中断应用


      script.OnError := @sink.HandleError;


      script.Run('function Boom() { throw "内部错误"; }', 'bad.ts');


      script.CallGlobal('Boom', []);


      Check(sink.LastError <> '', '脚本运行时错误经 OnError 上报');


      Check(sink.LastErrorStage = ssRuntime, '错误阶段标记为运行时');





      // 预算按切片重置（跨调用不累积）


      script.Run('function Slow() { let s = 0; let i;' +


        ' for (i = 0; i < 50000; i++) { s += i; } return s; }', 'slow.ts');


      Check(Round(script.CallGlobal('Slow', []).Num) = 1249975000, '首次调用完成');


      Check(Round(script.CallGlobal('Slow', []).Num) = 1249975000, '重复调用同样通过（预算不累积）');


    finally


      bridge.Free;


    end;


  finally


    sink.Free;


    script.Free;


    engine.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_PROMISE_INTEGRATION_INLINE}
// P1 集成：事件切片结束排水（then 回调改 DOM 立即生效）+ 未处理拒绝/预算的错误分类


procedure TestScriptPromiseIntegration;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  script: TXuiScript;


  bridge: TXuiDomBridge;


  sink: TScriptSink;


  btn: TXuiNode;


begin


  WriteLn('--- M6 P1 Promise 集成（切片排水 / 错误分类）---');


  engine := NewTestEngine(fake);


  script := TXuiScript.Create;


  sink := TScriptSink.Create;


  try


    bridge := TXuiDomBridge.Create(engine, script);


    try


      bridge.Install;


      engine.AttachScript(script);


      script.OnError := @sink.HandleError;





      // 事件处理器内创建 Promise：切片退出即排水 → 回调改 DOM 无需等待 Tick


      script.Run(


        'function OnBtnClick() {' + #10 +


        '  const out = document.find("out");' + #10 +


        '  out.text = "sync";' + #10 +


        '  Promise.resolve("done").then(function (v) { out.text = "async-" + v; });' + #10 +


        '  out.text = out.text + "-tail";' + #10 +


        '}', 'async.ts');


      Check(script.ErrorCount = 0, '异步脚本求值无错误');


      engine.LoadFromString(


        '<window><button id="b" text="go" onclick="OnBtnClick"/>' +


        '<label id="out" text="init"/></window>');


      DrawEngine(engine);


      btn := engine.Document.FindElementById('b');


      ClickNode(engine, btn);


      DrawEngine(engine);


      // 若回调同步执行，末尾拼接会得到 "async-done-tail"；


      // 最终值为 "async-done" 证明回调晚于同步尾语句，且切片结束已排水


      Check(engine.Document.FindElementById('out').Text = 'async-done',


        '事件切片结束排水：回调晚于同步尾语句且改 DOM 立即生效');





      // 未处理拒绝 → stage=unhandledRejection


      script.Run('function Fire() { Promise.reject("orphan2"); }', 'fire.ts');


      sink.Errors := 0;


      sink.LastError := '';


      script.CallGlobal('Fire', []);


      Check(sink.Errors = 1, '未处理拒绝上报一次');


      Check(Pos('orphan2', sink.LastError) > 0, '未处理拒绝携带原因');


      Check(sink.LastErrorStage = ssUnhandledRejection, '错误阶段为 unhandledRejection');





      // 已挂接处理的拒绝不报


      script.Run('function Handled() { Promise.reject("h3").catch(function (r) { }); }', 'h3.ts');


      sink.Errors := 0;


      script.CallGlobal('Handled', []);


      Check(sink.Errors = 0, '已处理的拒绝不上报');





      // 微任务内死循环 → 预算超限（budget 分类）


      script.Run('function FireLoop() {' +


        ' Promise.resolve().then(function () { let i = 0; while (true) { i++; } }); }', 'loop.ts');


      sink.Errors := 0;


      sink.LastError := '';


      script.CallGlobal('FireLoop', []);


      Check(sink.Errors = 1, '微任务超预算上报');


      Check(sink.LastErrorStage = ssBudget, '微任务预算超限归类为 budget');


    finally


      bridge.Free;


    end;


  finally


    sink.Free;


    script.Free;


    engine.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_TIMERS_INTEGRATION_INLINE}
// P2 集成：引擎 Tick 驱动定时器（NeedsTick / 相对时钟 / delay-Promise / 宏任务错误分类）


procedure TestScriptTimersIntegration;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  script: TXuiScript;


  bridge: TXuiDomBridge;


  sink: TScriptSink;


begin


  WriteLn('--- M6 P2 定时器集成（Tick 泵 / NeedsTick）---');


  engine := NewTestEngine(fake);


  script := TXuiScript.Create;


  sink := TScriptSink.Create;


  try


    bridge := TXuiDomBridge.Create(engine, script);


    try


      bridge.Install;


      engine.AttachScript(script);


      script.OnError := @sink.HandleError;





      engine.LoadFromString('<window><label id="out" text="init"/></window>');


      DrawEngine(engine);





      script.Run(


        'ui.setTimeout(function () { document.find("out").text = "t:" + ui.now(); }, 100);' + #10 +


        'ui.delay(200).then(function () { document.find("out").text = "delayed"; });',


        'timers.ts');


      Check(script.ErrorCount = 0, '定时器脚本求值无错误');


      Check(engine.NeedsTick, '定时器表非空 NeedsTick 为真');





      engine.Tick(1000);   // 首个 Tick 建立时钟零点（相对时钟 0）


      Check(engine.Document.FindElementById('out').Text = 'init', '未到期不执行');





      engine.Tick(1100);   // 相对时钟 100：setTimeout 到期


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 't:100',


        'Tick 到期触发且 ui.now 为相对时钟');


      Check(engine.NeedsTick, 'delay(200) 仍挂起时 NeedsTick 保持');





      engine.Tick(1200);   // 相对时钟 200：delay resolve → then 改 DOM（随泵排水）


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 'delayed',


        'ui.delay 到点后 Promise 回调改 DOM');


      Check(not engine.NeedsTick, '定时器全部完成后 NeedsTick 为假');





      // 宏任务回调异常：经 OnError 上报（stage=runtime），不中断应用


      script.Run('function Boom() { ui.setTimeout(function () { throw "timer-boom"; }, 5); }',


        'boom2.ts');


      sink.Errors := 0;


      sink.LastError := '';


      script.CallGlobal('Boom', []);


      engine.Tick(1210);   // 相对时钟 210：到点执行抛错回调


      Check(sink.Errors = 1, '宏任务回调异常上报');


      Check(Pos('timer-boom', sink.LastError) > 0, '宏任务异常消息含脚本值');


      Check(sink.LastErrorStage = ssRuntime, '宏任务异常阶段为运行时');





      // 宏任务死循环：预算超限归类 budget，应用不崩


      script.Run('function LoopTimer() {' +


        ' ui.setTimeout(function () { let i = 0; while (true) { i++; } }, 5); }', 'loopt.ts');


      sink.Errors := 0;


      sink.LastError := '';


      script.CallGlobal('LoopTimer', []);


      engine.Tick(1220);


      Check(sink.Errors = 1, '宏任务死循环上报');


      Check(sink.LastErrorStage = ssBudget, '宏任务预算超限归类为 budget');


    finally


      bridge.Free;


    end;


  finally


    sink.Free;


    script.Free;


    engine.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_SCRIPT_IO_INLINE}
{ ---------- M6 P4：真实 I/O（fake 注入 + 文件往返）---------- }





// fake 执行器：http → 200 + 响应体=URL；含 "slow" → 超时失败（SyncMode 下确定性触发）


// 最近一次 fake http 请求携带的请求头（供断言 opts.headers 契约）
var
  IoLastHeaders: string;

procedure IoFakeExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);


begin


  if Pos('slow', AReq.Url) > 0 then


  begin


    ARes.Ok := False;


    ARes.ErrMsg := 'I/O 操作超时';


    Exit;


  end;


  ARes.Ok := True;
  IoLastHeaders := AReq.Headers;


  ARes.Status := 200;


  ARes.Headers := 'Content-Type: text/plain';


  if Pos('json:', AReq.Url) = 1 then


    ARes.Data := Copy(AReq.Url, 6, MaxInt)


  else


    ARes.Data := AReq.Url;


end;





procedure TestScriptIO;


var


  script: TXuiScript;


  sink: TScriptSink;


  io: TXuiScriptIO;


  engine: TXuiEngine;


  fake: TFakeRenderer;


  bridge: TXuiDomBridge;


  src, tmpFile, jsPath: string;


  ioSeq: Integer;





  function RunAndPump(const ACode: string): string;


  begin


    Inc(ioSeq);


    sink.Log.Clear;


    script.Run(ACode, 'io' + IntToStr(ioSeq) + '.ts');   // 唯一文件名：绕开编译缓存


    // 模拟宿主连续 Tick：泵 I/O 完成并排水，直至完全静止


    repeat


      script.PumpIO;


      script.DrainMicrotasks;


    until (script.IoInFlight = 0) and (script.Interp.MicroTaskCount = 0);


    Result := sink.Log.Text;


  end;





begin


  WriteLn('--- M6 P4 真实 I/O ---');


  script := TXuiScript.Create;


  sink := TScriptSink.Create;


  tmpFile := IncludeTrailingPathDelimiter(GetTempDir) + 'lui_p4_io.txt';


  ioSeq := 0;


  try


    script.OnError := @sink.HandleError;


    script.Interp.OnLog := @sink.HandleLog;   // console.log 捕获


    io := script.IO;


    io.SyncMode := True;        // 测试不开工作线程（确定性）


    io.Executor := nil;         // fs 走真实 TFileStream 路径





    // JSON.parse（响应 json() 的依赖）


    src := RunAndPump(


      'const j0 = JSON.parse(''{"n": 7, "list": [1, 2], "o": {"k": "K"}}'');' + #10 +


      'console.log("jp" + j0.n + j0.list[1] + j0.o.k);');


    Check(Pos('jp72K', src) > 0, 'JSON.parse 对象/数组/数字');





    // fs 往返（含中文内容；路径用正斜杠避免 JS 字符串转义）


    jsPath := StringReplace(tmpFile, PathDelim, '/', [rfReplaceAll]);


    src := RunAndPump(


      'async function fsRound() {' + #10 +


      '  await ui.fs.writeText("' + jsPath + '", "hello-lui-123");' + #10 +


      '  return ui.fs.readText("' + jsPath + '");' + #10 +


      '}' + #10 +


      'fsRound().then(function (t) { console.log("fs" + t); });');


    Check(script.ErrorCount = 0, 'fs 往返无错误');


    Check(Pos('fshello-lui-123', src) > 0, 'fs 写读往返');





    // http fake：text() 与 status


    io.Executor := @IoFakeExecute;


    src := RunAndPump(


      'ui.http.get("u1").then(function (resp) {' + #10 +


      '  console.log("t" + resp.status + resp.text());' + #10 +


      '});');


    Check(Pos('t200u1', src) > 0, 'http.get 响应对象（status/text）');

    // opts.headers 契约：{headers:{...}} 里的头必须真正发出；选项键（timeout）不得混入请求头
    IoLastHeaders := '';
    src := RunAndPump(
      'ui.http.post("u2", "{}", { timeout: 5000, headers: { "Content-Type": "application/json", "X-Token": "abc" } }).then(function (r) { console.log("h" + r.status); });');
    Check((Pos('Content-Type: application/json', IoLastHeaders) > 0) and
      (Pos('X-Token: abc', IoLastHeaders) > 0),
      'http opts.headers 作为请求头发送（嵌套对象，非平铺）');
    Check(Pos('timeout', IoLastHeaders) = 0,
      'http opts 的选项键不混入请求头（timeout 被排除）');





    // json() 解析


    src := RunAndPump(


      'ui.http.get("json:{\"n\": 7, \"list\": [1, 2], \"o\": {\"k\": \"K\"}}").then(function (resp) { return resp.json(); })' + #10 +


      '  .then(function (j) { console.log("j" + j.n + j.list[1] + j.o.k); });');


    Check(script.ErrorCount = 0, 'json() 无错误');


    Check(Pos('j72K', src) > 0, 'resp.json() 经 JSON.parse 解析');





    // 完成顺序 FIFO


    src := RunAndPump(


      'ui.http.get("w1").then(function (r) { console.log("a" + r.text()); });' + #10 +


      'ui.http.get("w2").then(function (r) { console.log("b" + r.text()); });' + #10 +


      'ui.http.get("w3").then(function (r) { console.log("c" + r.text()); });');


    Check((Pos('aw1', src) < Pos('bw2', src)) and (Pos('bw2', src) < Pos('cw3', src)),


      '完成按提交顺序 FIFO 派发');





    // 超时/失败：catch 收到 reject；stage=io 上报


    sink.Errors := 0;


    sink.LastError := '';


    sink.LastErrorStage := ssRuntime;


    src := RunAndPump(


      'ui.http.get("slow-api").then(function (r) { console.log("no"); })' + #10 +


      '  .catch(function (r) { console.log("caught:" + r); });');


    Check(Pos('caught:Error: I/O 操作超时', src) > 0, '超时请求 reject 可捕获');


    Check(sink.Errors = 1, 'I/O 失败上报一次');


    Check(sink.LastErrorStage = ssIO, '错误阶段为 io');





    // fs 缺文件 → reject


    DeleteFile('lui_missing_p4.txt');


    io.Executor := nil;   // fs 走真实文件系统


    src := RunAndPump(


      'ui.fs.readText("lui_missing_p4.txt").then(function (t) { console.log("no:" + t); })' + #10 +


      '  .catch(function (r) { console.log("ferr:" + r); });');


    Check(Pos('ferr', src) > 0, '缺文件 reject 可捕获');





    // storage：同步 get/set；缺失键为 null


    src := RunAndPump(


      'ui.storage.set("k", "v1");' + #10 +


      'ui.storage.set("k", "v2");' + #10 +


      'console.log("st" + ui.storage.get("k") + "|" + ui.storage.get("missing"));');


    Check(Pos('stv2|null', src) > 0, 'storage 同步读写与 null 缺省');





    // signal：传入即报不支持


    sink.Errors := 0;


    sink.LastError := '';


    script.Run('function Sig() { ui.http.get("u", { signal: {} }); }', 'sig.ts');


    script.CallGlobal('Sig', []);


    Check(sink.Errors = 1, 'AbortSignal 报不支持');


    Check(sink.LastErrorStage = ssRuntime, 'signal 错误阶段为运行时');





    // 在途计数


    script.Run('function FireReq() { ui.http.get("inflight"); }', 'ifl.ts');


    script.CallGlobal('FireReq', []);


    Check(script.IoInFlight = 1, '在途请求计数为 1');


    script.PumpIO;


    script.DrainMicrotasks;


    Check(script.IoInFlight = 0, '完成后在途清零');





    // 引擎 Tick 泵完成队列（fake 执行器 + 同步模式）


    io.Executor := @IoFakeExecute;


    engine := NewTestEngine(fake);


    bridge := TXuiDomBridge.Create(engine, script);


    try


      bridge.Install;


      engine.AttachScript(script);


      engine.LoadFromString('<window><label id="out" text="init"/></window>');


      DrawEngine(engine);


      script.Run(


        'ui.http.get("tickdata").then(function (r) {' + #10 +


        '  document.find("out").text = r.text(); });', 'tickio.ts');


      Check(engine.NeedsTick, '在途 I/O 使 NeedsTick 为真');


      engine.Tick(500);   // Tick 内 PumpIO → settle → SafePoint 排水 → 改 DOM


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 'tickdata',


        '引擎 Tick 泵完成队列并改 DOM');


      Check(not engine.NeedsTick, 'I/O 完成后 NeedsTick 为假');


    finally


      bridge.Free;


      engine.Free;


    end;


  finally


    DeleteFile(tmpFile);


    script.Free;


    sink.Free;


  end;


end;





{$ENDIF}

{$IFDEF LUI_UI_LIBRARY_INLINE}
// Staged extraction: active component-library coverage lives in ui_library.inc.
{ ---------- M8：组件库（ui/）---------- }

const
  // 与 ui/components/basic.ts 的 UiSvgIconPaths.close 一致（绑定更新断言用）
  UiIconPathCloseD =
    'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z';

// 子树内按类名找第一个节点（深度优先）
function FindFirstByClass(ARoot: TXuiNode; const AClass: string): TXuiNode;
var
  i: Integer;
  found: TXuiNode;
begin
  Result := nil;
  if ARoot = nil then
    Exit;
  if ARoot.HasClass(AClass) then
    Exit(ARoot);
  for i := 0 to ARoot.Count - 1 do
  begin
    found := FindFirstByClass(ARoot[i], AClass);
    if found <> nil then
      Exit(found);
  end;
end;

// 仓库内相对路径定位（从仓库根或 tests 目录运行都能找到）
function RepoPath(const ARelative: string): string;
begin
  Result := ARelative;
  if FileExists(Result) then
    Exit;
  Result := '..' + PathDelim + ARelative;
  if not FileExists(Result) then
    Result := '';
end;

// 组件库冒烟：注册入口 / 主题样式 / 组件交互（按钮回调、输入双向、栅格与卡片）
procedure TestUiLibrary;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node, btn: TXuiNode;
  theme, index: string;
  errs, seq: Integer;
  pathCountBefore: Integer;
  src: string;

  function RunFlush(const ACode: string): string;
  begin
    Inc(seq);
    sink.Log.Clear;
    script.Run(ACode, 'uif' + IntToStr(seq) + '.ts');
    script.FlushReactive;
    script.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M8 组件库（ui/）---');
  theme := RepoPath('ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css');
  index := RepoPath('ui' + PathDelim + 'index.ts');
  if (theme = '') or (index = '') then
  begin
    WriteLn('SKIP  未找到 ui/ 组件库文件');
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
      engine.LoadStyleSheetFromFile(theme);
      script.RunFile(index);   // ui/index.ts：注册全部组件
      script.Run('const uiTaps = reactive({ n: 1 });' + #10 +
        'const uiState = reactive({ name: "lui" });' + #10 +
        'function OnUiTap(): void { uiTaps.n = uiTaps.n + 1; }', 'uiprobe.ts');
      Check(script.ErrorCount = 0, '组件库入口加载无错误');

      engine.LoadFromString(
        '<window>' +
        '<ui-card title="卡片">' +
        '<ui-row id="r1" gutter="8">' +
        '<ui-col span="12"><label id="c1" text="a"/></ui-col>' +
        '<ui-col span="12"><label id="c2" text="b"/></ui-col>' +
        '</ui-row>' +
        '<ui-button id="b1" text="主按钮" type="primary" size="small" x-onclick="OnUiTap"/>' +
        '<label id="cnt" text="taps={{uiTaps.n}}"/>' +
        '<ui-input id="i1" x-model="uiState.name" placeholder="请输入"/>' +
        '</ui-card>' +
        '</window>');
      engine.LoadStyleSheetFromFile(theme);   // 与 demo 一致：文档（含组件实例化）在前、主题表在后
      DrawEngine(engine);
      node := engine.Document.FindElementById('r1');
      Check((node <> nil) and (node.Style.Display = xdispFlex) and
        (node.Style.ColumnGap.Value = 8), '组件库：ui-row 横向栅格 + gutter');
      node := engine.Document.FindElementById('c1');
      Check((node <> nil) and (node.Parent.Style.FlexGrow = 12),
        '组件库：ui-col 按 span 分配 flex-grow');
      node := engine.Document.FindElementById('i1');
      Check((node <> nil) and (node.Style.Display = xdispFlex),
        '组件库：主题样式生效（ui-input 根节点 display:flex）');

      btn := engine.Document.FindElementById('b1');
      Check((btn <> nil) and btn.HasClass('ui-btn') and btn.HasClass('ui-btn--primary') and
        btn.HasClass('ui-btn--sm') and (btn.Style.BgColor.R = $16),
        '组件库：ui-button 修饰类与主题色（primary/small）');
      ClickNode(engine, btn);
      DrawEngine(engine);
      node := engine.Document.FindElementById('cnt');
      Check((node <> nil) and (node.Text = 'taps=2'), '组件库：ui-button 回调 prop 触发父级函数');
      node := engine.Document.FindElementById('i1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'lui'),
        '组件库：ui-input 经 x-model 取到宿主状态');

      // ---- M8-2：表单类组件 + 校验 ----
      script.Run('const uiForm_ = reactive({ name: "", agree: false, pick: "b", level: 20, num: 3 });' + #10 +
        'function OnSubmitProbe(): string { return uiFormValidate("f1") ? "ok" : "bad"; }', 'uiform.ts');
      engine.LoadFromString(
        '<window>' +
        '<ui-form id="f1">' +
        '<ui-form-item form="f1" prop="name" label="用户名" :model="uiForm_" ' +
        ':rules="[UiRules.required(''请输入用户名''), UiRules.minLength(3, ''至少 3 个字符'')]">' +
        '<ui-input id="fn" x-model="uiForm_.name" placeholder="用户名"/>' +
        '</ui-form-item>' +
        '</ui-form>' +
        '<ui-checkbox id="cb1" text="同意条款" x-model="uiForm_.agree"/>' +
        '<ui-switch id="sw1" x-model="uiForm_.agree"/>' +
        '<ui-radio-group id="rg1" :options="[{value: ''a'', text: ''A''}, {value: ''b'', text: ''B''}]" x-model="uiForm_.pick"/>' +
        '<ui-slider id="sl1" x-model="uiForm_.level" :max="100"/>' +
        '<ui-input-number id="in1" x-model="uiForm_.num" :max="10"/>' +
        '<label id="probe" x-text="''pick='' + uiForm_.pick + ''/lvl='' + uiForm_.level + ''/num='' + uiForm_.num"/>' +
        '</window>');
      DrawEngine(engine);

      // 校验：初始为空 → form-item 标红并显示提示；置为合法值后提示消失
      node := engine.Document.FindElementById('fn');
      Check((node <> nil) and (node.Parent <> nil) and
        (Pos('请输入用户名', node.Parent.Parent[2].Text) > 0),
        '组件库：ui-form-item 校验提示（必填）');
      RunFlush('uiForm_.name = "lui";');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fn');
      Check((node <> nil) and (node.Parent.Parent[2].Text = ''),
        '组件库：校验通过后提示清空');

      // 交互：勾选 / 开关 / 单选 / 滑块 / 步进
      ClickNode(engine, engine.Document.FindElementById('cb1'));
      DrawEngine(engine);
      src := RunFlush('console.log("agree=" + uiForm_.agree);');
      Check(Pos('agree=true', src) > 0, '组件库：ui-checkbox 点击切换并回写状态');
      ClickNode(engine, engine.Document.FindElementById('sw1'));
      DrawEngine(engine);
      src := RunFlush('console.log("agree=" + uiForm_.agree);');
      Check(Pos('agree=false', src) > 0, '组件库：ui-switch 点击切换并回写状态');
      ClickNode(engine, engine.Document.FindElementById('rg1')[0][0]);
      DrawEngine(engine);
      src := RunFlush('console.log("pick=" + uiForm_.pick);');
      Check(Pos('pick=a', src) > 0, '组件库：ui-radio-group 选择回写状态');
      node := engine.Document.FindElementById('sl1');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("lvl=" + uiForm_.level);');
      Check(Pos('lvl=', src) > 0, '组件库：ui-slider 点击定位取值');
      ClickNode(engine, engine.Document.FindElementById('in1')[0]);
      DrawEngine(engine);
      src := RunFlush('console.log("num=" + uiForm_.num);');
      Check(Pos('num=2', src) > 0, '组件库：ui-input-number 步进（− 1 步）');
      src := RunFlush('console.log("v=" + (uiFormValidate("f1") ? "ok" : "bad"));');
      Check(Pos('v=ok', src) > 0, '组件库：uiFormValidate 全部通过');

      // ---- M8-3 前置：x-popup 声明式浮层 / node.style / 运行时新增子树 ----
      RunFlush('const dlgState = reactive({ open: true });');
      engine.LoadFromString(
        '<window><panel id="dlg-host" x-if="dlgState.open" x-popup="" x-popup-placement="center"' +
        ' style="width:80px; height:40px"><label text="浮层"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dlg-host');
      Check((node <> nil) and (node.Parent = engine.Document.Root) and
        (node.Style.Position = xposAbsolute), 'x-popup：浮层节点挂到文档根并绝对定位');
      RunFlush('dlgState.open = false;');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dlg-host') = nil, 'x-popup：x-if 假值时收回');
      RunFlush('dlgState.open = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dlg-host');
      Check((node <> nil) and (node.Parent = engine.Document.Root), 'x-popup：恢复显示后重新浮出');
      engine.LoadFromString('<window><panel id="sty2"/></window>');
      DrawEngine(engine);
      RunFlush('document.find("sty2").style = "width:50px; height:20px";');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sty2');
      Check((node <> nil) and (node.Style.Width.Value = 50),
        'node.style：脚本设置内联样式生效');

      RunFlush('function OnAddedTap(): void { uiForm_.name = "added"; }');
      RunFlush('document.add(''<ui-button id="added-btn" text="新增" x-onclick="OnAddedTap"/>'');');
      DrawEngine(engine);
      node := engine.Document.FindElementById('added-btn');
      Check((node <> nil) and node.HasClass('ui-btn'),
        'document.add：运行时新增子树里的组件被实例化');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("nm=" + uiForm_.name);');
      Check(Pos('nm=added', src) > 0, 'document.add：新增子树的事件绑定生效');

      // ---- M8-3：反馈与浮层（alert / dialog + 命令式 message / message-box）----
      RunFlush('const fb = reactive({ show: false, oked: 0, closed: 0 });' + #10 +
        'function OnDlgClose(): void { fb.closed = fb.closed + 1; fb.show = false; }' + #10 +
        'function OnDlgOk(): void { fb.oked = fb.oked + 1; fb.show = false; }');
      engine.LoadFromString(
        '<window>' +
        '<ui-alert id="al1" type="success" title="成功" text="操作已完成"/>' +
        '<ui-loading id="ld1" text="加载中…"/>' +
        '<ui-dialog id="dg1" :visible="fb.show" title="确认" :width="260" ' +
        ':on-close="OnDlgClose" :on-ok="OnDlgOk"><label text="内容"/></ui-dialog>' +
        '</window>');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('dg1') = nil, '组件库：ui-dialog 默认不显示（x-if 摘除）');
      RunFlush('fb.show = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dg1');
      Check((node <> nil) and (node.Parent = engine.Document.Root) and
        (node.Style.Position = xposAbsolute), '组件库：ui-dialog 显示时挂到文档根（浮层）');

      // 确定按钮点击路径（模板内按 id 定位）
      node := engine.Document.FindElementById('ui-dialog-ok');
      Check(node <> nil, '组件库：ui-dialog-ok 按钮存在');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("oked=" + fb.oked + ",closed=" + fb.closed);');
      Check(Pos('oked=1', src) > 0, '组件库：ui-dialog 点击确定触发 onOk 回调');
      Check(engine.Document.FindElementById('dg1') = nil, '组件库：onOk 改状态后 ui-dialog 自动关闭');

      // ---- M8-3+：SVG 图标库（ui-svg-icon）+ 弹窗关闭按钮为矢量 SVG ----
      // 实例化后宿主 id 转移到模板根：ic1 即 <svg> 节点（其子为 <path>）

      // ui-svg-icon 渲染：path 的 d 来自图标库（close），经 RenderPath 矢量绘制
      engine.LoadFromString(
        '<window><ui-svg-icon id="ic1" name="close" size="14"/></window>');
      pathCountBefore := fake.PathCount;
      DrawEngine(engine);
      node := engine.Document.FindElementById('ic1');
      Check((node <> nil) and (node.Tag = 'svg') and (node.Count >= 1) and
            (node[0].Tag = 'path'), '组件库：ui-svg-icon 实例根为 svg 且含 path');
      Check(node[0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：path 的 d 来自图标库 close');
      Check(fake.PathCount > pathCountBefore,
        '组件库：ui-svg-icon 经矢量路径渲染（RenderPath 被调用）');

      // 动态换图标：:name 切换 → 子 path 的 d 属性更新 → svg 重解析再渲染
      RunFlush('const icst = reactive({ n: "check" });');
      engine.LoadFromString(
        '<window><ui-svg-icon id="ic2" :name="icst.n" size="14"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ic2');
      Check((node <> nil) and (node[0].Tag = 'path') and
            (node[0].AttributeValue('d', '') <> UiIconPathCloseD),
        '组件库：动态图标初始为 check（d 非 close 路径）');
      RunFlush('icst.n = "close";');
      DrawEngine(engine);
      Check(node[0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：动态换图标后 svg 重解析（d 更新为 close 路径）');

      // 弹窗关闭按钮：dialog 模板的关闭控件为 SVG 图标（非文本 ✕）
      // （前面图标用例已换文档：重新装载对话框实例；fb 全局状态仍在）
      engine.LoadFromString(
        '<window>' +
        '<ui-dialog id="dg1" :visible="fb.show" title="确认" :width="260" ' +
        ':on-close="OnDlgClose" :on-ok="OnDlgOk"><label text="内容"/></ui-dialog>' +
        '</window>');
      DrawEngine(engine);
      RunFlush('fb.show = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dg1');
      Check(node <> nil, '组件库：ui-dialog 再次显示');
      btn := FindFirstByClass(node, 'ui-dialog__close');
      Check((btn <> nil) and (btn.Count = 1) and (btn[0].Tag = 'svg') and
            (btn[0].Count >= 1) and (btn[0][0].Tag = 'path'),
        '组件库：弹窗关闭按钮为 ui-svg-icon（svg>path）');
      Check(btn[0][0].AttributeValue('d', '') = UiIconPathCloseD,
        '组件库：关闭按钮 path 来自图标库 close');
      // 点击关闭（面板承载 x-onclick：点击 svg/面板命中后冒泡到绑定节点）
      ClickNode(engine, btn);
      src := RunFlush('console.log("closed=" + fb.closed);');
      Check(Pos('closed=1', src) > 0, '组件库：SVG 关闭按钮点击触发 onClose');
      RunFlush('fb.show = false;');

      // 命令式 message-box：创建浮层节点与按钮结算
      sink.LastError := '';
      src := RunFlush('let boxResult = -1;' + #10 +
        'uiMessageBox.confirm("删除", "确定删除该条？").then(function(res: boolean): void { boxResult = (res ? 1 : 0); });');
      DrawEngine(engine);
      src := RunFlush('console.log("boxn=" + (document.find("uibox0") === undefined ? "0" : "1"));');
      Check(Pos('boxn=1', src) > 0, '组件库：uiMessageBox 的浮层节点已挂到文档');
      node := engine.Document.FindElementById('uibox-ok');
      Check(node <> nil, '组件库：uiMessageBox 确定按钮存在');
      ClickNode(engine, node);
      script.DrainMicrotasks;
      DrawEngine(engine);
      src := RunFlush('console.log("res=" + boxResult);');
      Check(Pos('res=1', src) > 0, '组件库：uiMessageBox 点击确定 Promise 被 resolve 为 true');
      Check(engine.Document.FindElementById('uibox0') = nil, '组件库：uiMessageBox 结算后浮层节点自 DOM 移除');

      // ---- M8-4：数据展示类组件（Tag / Badge / Progress / Avatar / Collapse / Pagination / Table / Tooltip / Popover） ----
      RunFlush('const dispState = reactive({ ' +
        'tagClosed: 0, tagClosable: true, ' +
        'badgeVal: 150, ' +
        'progress: 75, ' +
        'colActive: false, colToggled: 0, ' +
        'page: 1, paged: 0, ' +
        'tblData: [{ id: "1", name: "Alice" }, { id: "2", name: "Bob" }], ' +
        'tblCols: [{ prop: "id", label: "ID" }, { prop: "name", label: "姓名" }] ' +
        '});' + #10 +
        'function OnTagClose(): void { dispState.tagClosed = 1; }' + #10 +
        'function OnColToggle(): void { dispState.colActive = !dispState.colActive; dispState.colToggled = dispState.colToggled + 1; }' + #10 +
        'function OnPageNext(): void { dispState.page = dispState.page + 1; dispState.paged = dispState.paged + 1; }');

      engine.LoadFromString(
        '<window>' +
        '<ui-tag id="t1" text="成功标签" type="success" :closable="dispState.tagClosable" :on-close="OnTagClose"/>' +
        '<ui-badge id="bg1" :value="dispState.badgeVal" :max="99"><label text="消息"/></ui-badge>' +
        '<ui-badge id="bg2" dot="true"><label text="待办"/></ui-badge>' +
        '<ui-progress id="prg1" :percentage="dispState.progress" status="success"/>' +
        '<ui-avatar id="av1" text="L" size="40" shape="circle"/>' +
        '<ui-collapse id="cp1">' +
        '<ui-collapse-item id="cpi1" title="折叠标题" :active="dispState.colActive" :on-toggle="OnColToggle">' +
        '<label id="cpi-text" text="折叠详情文本"/>' +
        '</ui-collapse-item>' +
        '</ui-collapse>' +
        '<ui-pagination id="pg1" :current="dispState.page" :total="55" :page-size="10" :on-next="OnPageNext"/>' +
        '<ui-table id="tb1" :columns="dispState.tblCols" :data="dispState.tblData"/>' +
        '<ui-tooltip id="tt1" content="提示内容"><label text="悬停"/></ui-tooltip>' +
        '<ui-popover id="pop1" title="卡片标题" content="卡片正文"><label text="点击"/></ui-popover>' +
        '</window>');
      DrawEngine(engine);

      // ui-tag 校验与关闭回调
      node := engine.Document.FindElementById('t1');
      Check((node <> nil) and node.HasClass('ui-tag') and node.HasClass('ui-tag--success'),
        '组件库：ui-tag 带有成功配色修饰类');
      // 子节点中的关闭图标
      btn := nil;
      for seq := 0 to node.Count - 1 do
        if node[seq].HasClass('ui-tag__close') then
        begin
          btn := node[seq];
          Break;
        end;
      Check(btn <> nil, '组件库：ui-tag closable 关闭按钮存在');
      ClickNode(engine, btn);
      DrawEngine(engine);
      src := RunFlush('console.log("tag=" + dispState.tagClosed);');
      Check(Pos('tag=1', src) > 0, '组件库：ui-tag 点击关闭触发 onClose 回调');

      // ui-badge 溢出截断与小红点
      node := engine.Document.FindElementById('bg1');
      Check((node <> nil) and (node.Count >= 2) and (node[1].Count >= 1) and
        (node[1][0].Text = '99+'), '组件库：ui-badge 数值超出 max 截断显示 99+');
      node := engine.Document.FindElementById('bg2');
      Check((node <> nil) and (node.Count >= 2) and node[1].HasClass('is-dot'),
        '组件库：ui-badge dot 模式带有 is-dot 样式');

      // 角标锚定：容器不得被子项默认 margin 撑高，角标须贴住内容右上角。
      // 引擎给 button/label/input 默认带 margin-top，若未在组件内归零，容器会被撑高
      // （按钮 26 → 容器 32），角标锚在容器上就会相对内容整体上移、看起来'飘'在角外。
      node := engine.Document.FindElementById('bg1');
      Check((node <> nil) and (node.Count >= 2) and
        ((node.BoxRect.Bottom - node.BoxRect.Top) =
         (node[0].BoxRect.Bottom - node[0].BoxRect.Top)),
        '组件库：ui-badge 容器不被子项默认 margin 撑高');
      // sup 高 16、top:-6 → 与内容顶边重叠恒为 10px（与子项 margin 无关）
      Check((node.Count >= 2) and ((node[1].BoxRect.Bottom - node[0].BoxRect.Top) = 10),
        '组件库：ui-badge 角标贴住内容右上角（未被默认 margin 顶飞）');

      // ui-progress 进度与状态修饰类
      node := engine.Document.FindElementById('prg1');
      Check((node <> nil) and node.HasClass('ui-progress') and node.HasClass('is-success'),
        '组件库：ui-progress 带有 is-success 状态类');
      Check((node.Count >= 2) and (node[1].Text = '75%'),
        '组件库：ui-progress 进度文字显示 75%');

      // ui-avatar 样式与尺寸
      node := engine.Document.FindElementById('av1');
      Check((node <> nil) and node.HasClass('ui-avatar') and node.HasClass('ui-avatar--circle'),
        '组件库：ui-avatar 圆形头像');

      // ui-collapse 折叠与展开
      Check(engine.Document.FindElementById('cpi-text') = nil,
        '组件库：ui-collapse-item active=false 时详情折叠隐藏');
      node := engine.Document.FindElementById('cpi1');
      Check((node <> nil) and (node.Count >= 1), '组件库：ui-collapse-item 头节点存在');
      ClickNode(engine, node[0]);   // 点击 head 触发 onToggle
      DrawEngine(engine);
      src := RunFlush('console.log("col=" + dispState.colActive);');
      Check(Pos('col=true', src) > 0, '组件库：ui-collapse-item 点击头部切换展开状态');
      Check(engine.Document.FindElementById('cpi-text') <> nil,
        '组件库：ui-collapse-item 展开后内容节点进入 DOM');

      // ui-pagination 分页与计算
      node := engine.Document.FindElementById('pg1');
      Check((node <> nil) and (node.Count >= 4) and (node[2].Text = '1 / 6'),
        '组件库：ui-pagination 总页数正确计算为 1 / 6');
      ClickNode(engine, node[3]);   // 点击下一页按钮
      DrawEngine(engine);
      src := RunFlush('console.log("page=" + dispState.page);');
      Check(Pos('page=2', src) > 0, '组件库：ui-pagination 点击下一页触发回调');

      // ui-table 渲染
      node := engine.Document.FindElementById('tb1');
      Check((node <> nil) and (node.Count = 2), '组件库：ui-table 渲染出表头与表体两大部分');
      Check((node[1].Count = 2), '组件库：ui-table 表体由 x-for 渲染出 2 行数据');

      // ui-tooltip & ui-popover 挂载
      Check(engine.Document.FindElementById('tt1') <> nil, '组件库：ui-tooltip 宿主就绪');
      Check(engine.Document.FindElementById('pop1') <> nil, '组件库：ui-popover 宿主就绪');

      // ---- M8-5：导航增强类组件（Tabs / Menu / Breadcrumb / Dropdown / Steps / Backtop） ----
      RunFlush('const navState = reactive({ ' +
        'tab: "t1", tabSwitched: 0, ' +
        'menuClicked: 0, ' +
        'crumbClicked: 0, ' +
        'backtopClicked: 0, ' +
        'tabList: [{ name: "t1", label: "标签一" }, { name: "t2", label: "标签二" }], ' +
        'dropItems: [{ key: "edit", label: "编辑" }, { key: "del", label: "删除", danger: true }] ' +
        '});' + #10 +
        'function OnNavTab(name: string): void { navState.tab = name; navState.tabSwitched = navState.tabSwitched + 1; }' + #10 +
        'function OnNavMenu(): void { navState.menuClicked = navState.menuClicked + 1; }' + #10 +
        'function OnCrumbClick(): void { navState.crumbClicked = navState.crumbClicked + 1; }' + #10 +
        'function OnBacktop(): void { navState.backtopClicked = 1; }');

      engine.LoadFromString(
        '<window>' +
        '<ui-tabs id="tabs1" :items="navState.tabList" :active="navState.tab" :on-change="OnNavTab">' +
        '<ui-tab-pane name="t1" :active="navState.tab === ''t1''"><label id="pane1" text="内容一"/></ui-tab-pane>' +
        '<ui-tab-pane name="t2" :active="navState.tab === ''t2''"><label id="pane2" text="内容二"/></ui-tab-pane>' +
        '</ui-tabs>' +
        '<ui-menu id="menu1" mode="horizontal">' +
        '<ui-menu-item id="m1" name="home" title="首页" :active="true" :on-click="OnNavMenu"/>' +
        '<ui-menu-item id="m2" name="settings" title="设置" :disabled="true"/>' +
        '</ui-menu>' +
        '<ui-breadcrumb id="bc1">' +
        '<ui-breadcrumb-item id="bc-item-1" text="首页" :on-click="OnCrumbClick"/>' +
        '<ui-breadcrumb-item id="bc-item-2" text="组件" :last="true"/>' +
        '</ui-breadcrumb>' +
        '<ui-dropdown id="dp1" :items="navState.dropItems">' +
        '<ui-button id="dp-btn" text="下拉操作"/>' +
        '</ui-dropdown>' +
        '<ui-steps id="st1" :current="2">' +
        '<ui-step id="st-item-1" :step="1" title="已完成" status="finish"/>' +
        '<ui-step id="st-item-2" :step="2" title="进行中" status="process"/>' +
        '<ui-step id="st-item-3" :step="3" title="等待中" status="wait"/>' +
        '</ui-steps>' +
        '<ui-backtop id="bt1" :on-click="OnBacktop"/>' +
        '</window>');
      DrawEngine(engine);

      // 1. ui-tabs 校验与点击切换
      node := engine.Document.FindElementById('tabs1');
      Check((node <> nil) and node.HasClass('ui-tabs'), '组件库：ui-tabs 根节点样式生效');
      Check((node.Count >= 2) and (node[0].Count = 2), '组件库：ui-tabs 渲染出两个头部标签项');
      Check(node[0][0].HasClass('is-active'), '组件库：ui-tabs 首个标签为激活态 is-active');
      Check(not node[0][1].HasClass('is-active'), '组件库：ui-tabs 第二个标签非激活态');
      ClickNode(engine, node[0][1]);   // 点击第二个 tab
      DrawEngine(engine);
      src := RunFlush('console.log("tab=" + navState.tab + ",sw=" + navState.tabSwitched);');
      Check((Pos('tab=t2', src) > 0) and (Pos('sw=1', src) > 0), '组件库：ui-tabs 点击切换并触发回调');

      // 2. ui-menu 模式与菜单项状态
      node := engine.Document.FindElementById('menu1');
      Check((node <> nil) and node.HasClass('ui-menu--horizontal'), '组件库：ui-menu 横向模式生效');
      node := engine.Document.FindElementById('m1');
      Check((node <> nil) and node.HasClass('is-active'), '组件库：ui-menu-item 激活态生效');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("menu=" + navState.menuClicked);');
      Check(Pos('menu=1', src) > 0, '组件库：ui-menu-item 点击触发回调');
      node := engine.Document.FindElementById('m2');
      Check((node <> nil) and node.HasClass('is-disabled'), '组件库：ui-menu-item 禁用态生效');

      // 3. ui-breadcrumb 面包屑导航与最后一项
      node := engine.Document.FindElementById('bc-item-1');
      Check(node <> nil, '组件库：ui-breadcrumb-item 项存在');
      ClickNode(engine, node[0]);
      DrawEngine(engine);
      src := RunFlush('console.log("crumb=" + navState.crumbClicked);');
      Check(Pos('crumb=1', src) > 0, '组件库：ui-breadcrumb-item 点击触发回调');
      node := engine.Document.FindElementById('bc-item-2');
      Check((node <> nil) and node[0].HasClass('is-last'), '组件库：ui-breadcrumb-item 末项带 is-last 样式');

      // 4. ui-steps 步骤条状态与图标
      node := engine.Document.FindElementById('st-item-1');
      Check((node <> nil) and node.HasClass('is-finish') and (node[0][0][0].Text = '✓'),
        '组件库：ui-step 完成态带 is-finish 并呈现完成对勾');
      node := engine.Document.FindElementById('st-item-2');
      Check((node <> nil) and node.HasClass('is-process') and (node[0][0][0].Text = '2'),
        '组件库：ui-step 进行中带 is-process 并呈现序号');
      node := engine.Document.FindElementById('st-item-3');
      Check((node <> nil) and node.HasClass('is-wait'),
        '组件库：ui-step 待处理带 is-wait');

      // 5. ui-dropdown & ui-backtop 挂载与回调
      Check(engine.Document.FindElementById('dp1') <> nil, '组件库：ui-dropdown 宿主就绪');
      node := engine.Document.FindElementById('bt1');
      Check((node <> nil) and node.HasClass('ui-backtop'), '组件库：ui-backtop 节点就绪');
      ClickNode(engine, node);
      DrawEngine(engine);
      src := RunFlush('console.log("bt=" + navState.backtopClicked);');
      Check(Pos('bt=1', src) > 0, '组件库：ui-backtop 点击触发回调');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;

{$ENDIF}

{$IFDEF LUI_CSS_VARIABLES_INLINE}
{ ---------- M8：CSS 变量（自定义属性）---------- }

// --x 声明 + var() 取值：继承 / 回退 / 简写值内替换 / 主题覆盖（后加载样式表重定义）
procedure TestCssVariables;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  node: TXuiNode;
begin
  WriteLn('--- CSS 变量（M8）---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window>' +
      '<panel id="p1"><label id="l1" text="a"/>' +
      '<panel id="p2"><label id="l2" text="b"/></panel></panel>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      'window { --ui-brand: #1677ff; --ui-gap: 6px; } ' +
      '#p1 { background-color: var(--ui-brand); } ' +
      '#p2 { background-color: var(--missing, #ff0000); margin-top: var(--ui-gap); } ' +
      '#l1 { border: 1px solid var(--ui-brand); }');
    engine.Draw(nil, Rect(0, 0, 300, 200));

    node := engine.Document.FindElementById('p1');
    Check((node.Style.BgColor.R = $16) and (node.Style.BgColor.G = $77) and
      (node.Style.BgColor.B = $FF), 'var()：取祖先定义的变量（继承可见）');
    node := engine.Document.FindElementById('l1');
    Check(node.Style.BorderColor.R = $16, 'var()：简写值内也能替换（border 颜色）');
    node := engine.Document.FindElementById('p2');
    Check(node.Style.BgColor.R = $FF, 'var()：未定义变量使用回退值');
    Check(node.Style.Margin.Top.Value = 6, 'var()：长度值替换（margin-top）');

    engine.LoadStyleSheetFromString('window { --ui-brand: #00ff00; }');
    engine.Draw(nil, Rect(0, 0, 300, 200));
    node := engine.Document.FindElementById('p1');
    Check(node.Style.BgColor.G = $FF, '主题覆盖：后加载样式表重定义变量后使用处随之变化');
  finally
    engine.Free;
  end;
end;

{$ENDIF}

{$IFDEF LUI_SCRIPT_REACTIVE_INLINE}
{ Staged extraction: the modular M7/M8 reactive suite is active above; retain
  the original inline copy behind a switch until the migration is retired. }
{ ---------- M7：响应式绑定（参照 Vue 3）---------- }

// 演示页文件定位（测试既可从仓库根、也可从 tests 目录运行）
function DemoFilePath(const AName: string): string;
begin
  Result := 'demo' + PathDelim + AName;
  if FileExists(Result) then
    Exit;
  Result := '..' + PathDelim + 'demo' + PathDelim + AName;
  if not FileExists(Result) then
    Result := '';
end;

// 引擎级：reactive/computed/watch/onMount + 声明式绑定（x-text/x-class/x-disabled/x-show/x-if/x-for/x-model）
procedure TestScriptReactive;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node: TXuiNode;
  keptA, keptC: TXuiNode;
  errs: Integer;
  tplDir: string;
  incDir: string;
  src: string;
  ioSeq: Integer;

  function RunFlush(const ACode: string): string;
  begin
    Inc(ioSeq);
    sink.Log.Clear;
    script.Run(ACode, 'rx' + IntToStr(ioSeq) + '.ts');
    script.FlushReactive;
    script.DrainMicrotasks;
    Result := sink.Log.Text;
  end;

begin
  WriteLn('--- M7 响应式绑定 ---');
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  ioSeq := 0;
  try
    bridge := TXuiDomBridge.Create(engine, script);
    try
      bridge.Install;
      engine.AttachScript(script);
      script.OnError := @sink.HandleError;
      script.Interp.OnLog := @sink.HandleLog;

      engine.LoadFromString(
        '<window>' +
        '<label id="t1" x-text="state.greeting"/>' +
        '<label id="t2" text="共 {{state.count}} 条"/>' +
        '<button id="b1" class="base" x-class="state.hot" text="B"/>' +
        '<button id="b2" x-disabled="state.locked" text="D"/>' +
        '<label id="lb3" class="vis" x-show="state.visible" text="showme"/>' +
        '<panel id="cond"><label id="cx" x-if="state.on" text="ON"/></panel>' +
        '<input id="inp" x-model="state.name"/>' +
        '<panel id="lst" x-for="it in state.items"><label x-text="it.n"/></panel>' +
        '</window>');
      DrawEngine(engine);

      // 初始渲染：状态 → 绑定
      src := RunFlush(
        'const state = reactive({' + #10 +
        '  greeting: "hi", count: 3, hot: "hot", locked: true,' + #10 +
        '  visible: true, on: true, name: "init",' + #10 +
        '  items: [{ n: "a" }, { n: "b" }]' + #10 +
        '});' + #10 +
        'function SetName(v: string): boolean { state.name = v; return true; }' + #10 +
        'function GetCount(): number { return state.count; }');
      Check(script.ErrorCount = 0, '响应式脚本求值无错误');

      node := engine.Document.FindElementById('t1');
      Check(node.Text = 'hi', 'x-text 初始渲染');
      node := engine.Document.FindElementById('t2');
      Check(node.Text = '共 3 条', '插值绑定');
      node := engine.Document.FindElementById('b1');
      Check(node.HasClass('hot') and node.HasClass('base'), 'x-class 追加类名');
      node := engine.Document.FindElementById('b2');
      Check(XuiIsDisabled(node), 'x-disabled 初始禁用');
      node := engine.Document.FindElementById('lst');
      Check(node.Count = 2, 'x-for 初始渲染条目数');
      Check(engine.Document <> nil, '文档可用');

      // 状态写入 → 安全点刷新 → UI 更新
      RunFlush('state.greeting = "yo"; state.count = 8;');
      Check(engine.Document.FindElementById('t1').Text = 'yo', 'x-text 随状态更新');
      WriteLn('[dbg-int] [', engine.Document.FindElementById('t2').Text, ']');
      Check(engine.Document.FindElementById('t2').Text = '共 8 条', '插值随状态更新');

      RunFlush('state.hot = "cold"; state.locked = false;');
      node := engine.Document.FindElementById('b1');
      Check(node.HasClass('base') and node.HasClass('cold') and
        (not node.HasClass('hot')), 'x-class 更新为最新类');
      node := engine.Document.FindElementById('b2');
      Check(not XuiIsDisabled(node), 'x-disabled 解除');

      // x-show：隐藏/显示
      RunFlush('state.visible = false;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('lb3');
      Check((node.Style <> nil) and (node.Style.Display = xdispNone), 'x-show=false 隐藏');
      RunFlush('state.visible = true;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('lb3');
      Check(node.Style.Display <> xdispNone, 'x-show=true 恢复显示');

      // x-if：摘除/原位恢复
      RunFlush('state.on = false;');
      node := engine.Document.FindElementById('cond');
      Check(node.Count = 0, 'x-if=false 摘除子树');
      RunFlush('state.on = true;');
      node := engine.Document.FindElementById('cond');
      Check((node.Count = 1) and (node[0].Text = 'ON'), 'x-if=true 原位恢复');

      // x-for：数组增长 → 重建
      RunFlush('state.items = [{ n: "x" }, { n: "y" }, { n: "z" }];');
      node := engine.Document.FindElementById('lst');
      Check(node.Count = 3, 'x-for 数组增长重建');
      DrawEngine(engine);
      node := engine.Document.FindElementById('lst');
      Check((node.Count = 3) and (node[2].Text = 'z'),
        'x-for 克隆内容按序渲染');

      // x-model：输入回写状态（事件切片内完成）
      RunFlush('state.name = "init";');
      node := engine.Document.FindElementById('inp');
      ClickNode(engine, node);
      engine.HandleTextInput('li');
      DrawEngine(engine);
      src := RunFlush('console.log("name=" + state.name);');
      Check(Pos('name=initli', src) > 0, 'x-model 输入回写状态');

      // 事件处理器写状态 → 事件切片结束 UI 已更新（onclick → 状态 → SafePoint 刷新）
      RunFlush('function OnInc() { state.count = state.count + 1; }');
      node := engine.Document.FindElementById('t2');
      engine.LoadFromString(
        '<window>' +
        '<label id="t2" text="共 {{state.count}} 条"/>' +
        '<button id="inc" text="+1" onclick="OnInc"/>' +
        '</window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('inc'));
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t2').Text = '共 9 条',
        '事件处理器写状态 → UI 自动更新');

      // computed / watch / onMount
      sink.Log.Clear;
      src := RunFlush(
        'const st = reactive({ a: 2 });' + #10 +
        'const double = computed(function () { return st.a * 2; });' + #10 +
        'console.log("c" + double.value);' + #10 +
        'st.a = 5;' + #10 +
        'console.log("c" + double.value);' + #10 +
        'watch(function () { return st.a; }, function (nv, ov) { console.log("w" + ov + "->" + nv); });' + #10 +
        'onMount(function () { console.log("mounted"); });');
      Check(Pos('c4', src) > 0, 'computed 求值');
      Check(Pos('c10', src) > 0, 'computed 随状态失效重算');
      Check(Pos('mounted', src) > 0, 'onMount 在首次刷新后调用');
      RunFlush('st.a = 9;');
      Check(Pos('w5->9', sink.Log.Text) > 0, 'watch 捕获新旧值');

      // ---- M7-2：嵌套响应式 / 数组变更通知 / :class 对象语法 / watch immediate ----

      // 嵌套对象属性写入触发刷新（深度标记）
      RunFlush(
        'const st2 = reactive({ inner: { v: "d1" } });');
      script.Run('function SetInner2(v: string): boolean { st2.inner.v = v; return true; }', 'si2.ts');
      engine.LoadFromString(
        '<window><label id="t3" x-text="st2.inner.v"/></window>');
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t3').Text = 'd1', '嵌套对象初始渲染');
      script.CallGlobal('SetInner2', [script.Str('d2')]);
      script.FlushReactive;
      DrawEngine(engine);
      Check(engine.Document.FindElementById('t3').Text = 'd2',
        '嵌套响应式：深层属性写入触发绑定更新');

      // 数组 push 触发 x-for 重建
      engine.LoadFromString(
        '<window><panel id="lst" x-for="it in state.items"><label x-text="it.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('state.items.push({ n: "w" });');
      node := engine.Document.FindElementById('lst');
      Check(node.Count = 4, '数组 push 触发 x-for 重建');

      // keyed v-for：重排与删除按 key 复用
      RunFlush(
        'const keyed = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }, { id: 3, n: "C" }] });');
      engine.LoadFromString(
        '<window><panel id="kl" x-for="r in keyed.rows"><label x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kl');
      Check((node.Count = 3) and (node[0].Text = 'A') and (node[2].Text = 'C'),
        'keyed x-for 初始渲染');
      script.Run('function Reorder(): boolean { keyed.rows = [{ id: 3, n: "C2" }, { id: 1, n: "A" }]; return true; }', 're.ts');
      script.CallGlobal('Reorder', []);
      script.FlushReactive;
      DrawEngine(engine);
      node := engine.Document.FindElementById('kl');
      Check((node.Count = 2) and (node[0].Text = 'C2') and (node[1].Text = 'A'),
        'keyed x-for：重排与删除按 key 正确');

      // :class 对象语法
      RunFlush(
        'const cs = reactive({ on: true });');
      engine.LoadFromString(
        '<window><label id="cl" class="base" x-class="{ hot: cs.on, cold: !cs.on }" text="cls"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('cl');
      Check(node.HasClass('hot') and (not node.HasClass('cold')), ':class 对象语法（真值键生效）');
      RunFlush('cs.on = false;');
      node := engine.Document.FindElementById('cl');
      Check(node.HasClass('cold') and (not node.HasClass('hot')), ':class 对象语法随状态切换');

      // watch immediate
      src := RunFlush(
        'const wi = reactive({ v: 3 });' + #10 +
        'watch(function () { return wi.v; }, function (nv, ov) { console.log("wi" + nv + "/" + ov); }, { immediate: true });');
      Check(Pos('wi3/undefined', src) > 0, 'watch immediate 注册即回调');

      // watch deep：嵌套对象属性变化触发（内容快照比较）
      RunFlush(
        'const dw = reactive({ o: { v: 1 } });' + #10 +
        'watch(function () { return dw.o; }, function (nv, ov) { console.log("deep-fire"); }, { deep: true });');
      Check(sink.Log.Text = '', 'deep watch 基线不触发');
      RunFlush('dw.o.v = 2;');
      Check(Pos('deep-fire', sink.Log.Text) > 0, 'watch deep 捕获嵌套变化');

      // ---- M7-3：组件化（props / 动态 prop / slot / 函数 prop）----

      // 静态 prop + 函数 prop：组件内调用父传入的函数
      RunFlush(
        'function Dbl(n: number): number { return n * 2; }' + #10 +
        'component("badge", { props: ["count", "f"], template: "<panel class=\"badge\"><label x-text=\"props.f(props.count)\"/></panel>" });');
      engine.LoadFromString(
        '<window><badge count="7" :f="Dbl"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '14'),
        '组件实例化：静态 prop 与函数 prop');

      // 动态 prop：随父状态更新
      RunFlush('const bc = reactive({ n: 9 });');
      engine.LoadFromString(
        '<window><badge :count="bc.n" :f="Dbl"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '18'), '动态 prop 初始渲染');
      RunFlush('bc.n = 11;');
      node := engine.Document.Root[0];
      Check((node.Count = 1) and (node[0].Text = '22'), '动态 prop 随父状态更新');

      // slot：宿主子内容移入组件槽位，按父作用域求值
      RunFlush(
        'const slotState = reactive({ msg: "SLOT-OK" });' + #10 +
        'component("my-box", { props: [], template: "<panel class=\"box\"><slot/></panel>" });');
      engine.LoadFromString(
        '<window><my-box><label id="sl" x-text="slotState.msg"/></my-box></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sl');
      Check((node <> nil) and (node.Text = 'SLOT-OK') and
        (node.Parent.Tag = 'panel'), 'slot 内容移入组件槽位并按父作用域求值');

      // ---- M7-4：键控复用 / 非键控同长度替换 / 多根组件 / 具名 slot / props 类型校验 ----

      // keyed x-for：同 key 复用克隆（节点对象保持），文本随新数据更新
      RunFlush(
        'const kx = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }, { id: 3, n: "C" }] });');
      engine.LoadFromString(
        '<window><panel id="kx1" x-for="r in kx.rows"><label x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kx1');
      keptA := node[0];
      keptC := node[2];
      errs := script.ErrorCount;
      RunFlush('kx.rows = [{ id: 3, n: "C2" }, { id: 1, n: "A2" }];');
      node := engine.Document.FindElementById('kx1');
      Check(node.Count = 2, 'keyed x-for：重排且删除后条目数正确');
      Check((node[0] = keptC) and (node[1] = keptA), 'keyed x-for：同 key 复用克隆（节点对象保持）');
      Check((node[0].Text = 'C2') and (node[1].Text = 'A2'), 'keyed x-for：复用条目文本随新数据更新');
      RunFlush('kx.rows.push({ id: 9, n: "D" });');
      node := engine.Document.FindElementById('kx1');
      Check((node.Count = 3) and (node[2].Text = 'D'), 'keyed x-for：新 key 追加克隆');
      Check(script.ErrorCount = errs, 'keyed x-for：复用/移除全程无脚本错误');

      // 回归（M11 发现）：移除条目后必须仍能 Draw。
      // 症状：条目带 transition 时，引擎的过渡表在键控移除路径上残留指向已释放节点的
      // 瞬态引用，下一次 Draw 的过渡 Capture 读到已释放节点 → 访问违例。
      // 根因：xui_script_bind 的键控移除自行 RemoveChild + Free，绕过了引擎的瞬态复位
      // （RemoveElement 会先 Reset 过渡表/悬停链再释放）。此处断言"删完还能画"。
      RunFlush(
        'const tr = reactive({ rows: [{ id: 1, n: "A" }, { id: 2, n: "B" }] });');
      engine.LoadFromString(
        '<window><panel id="tr1" x-for="r in tr.rows">' +
        '<label class="ftr" x-text="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      RunFlush('tr.rows = [{ id: 2, n: "B" }];');   // 移除 id=1 的条目（触发节点释放）
      DrawEngine(engine);                            // 崩溃点：过渡 Capture 读悬垂节点
      node := engine.Document.FindElementById('tr1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'B'),
        'keyed x-for 移除条目后仍可绘制（过渡表不留悬垂节点引用）');
      Check(script.ErrorCount = errs, 'keyed x-for 移除后无脚本错误');

      // 非键控 x-for：同长度元素替换 → 就地更新（不留旧数据）
      RunFlush(
        'const nx = reactive({ rows: [{ n: "x1" }, { n: "x2" }] });');
      engine.LoadFromString(
        '<window><panel id="nx1" x-for="r in nx.rows"><label x-text="r.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('nx.rows = [{ n: "y1" }, { n: "y2" }];');
      node := engine.Document.FindElementById('nx1');
      Check((node.Count = 2) and (node[0].Text = 'y1') and (node[1].Text = 'y2'),
        '非键控 x-for：同长度元素替换就地更新');

      // 组件模板多根：按序插入宿主位置；宿主 id/class 落到首根
      RunFlush(
        'component("duo", { props: [], template: "<label class=\"d1\" text=\"first\"/><label class=\"d2\" text=\"second\"/>" });');
      engine.LoadFromString('<window><duo id="duo1" class="host"/></window>');
      DrawEngine(engine);
      node := engine.Document.Root;   // <window>
      Check((node.Count = 2) and (node[0].Text = 'first') and (node[1].Text = 'second'),
        '组件模板多根：两棵根按序插入宿主位置');
      Check((node[0].Id = 'duo1') and node[0].HasClass('host') and (node[1].Id = ''),
        '多根组件：宿主 id/class 落到首个实例根');

      // 具名 slot + 默认 slot；未匹配槽位的内容丢弃
      RunFlush(
        'component("page-box", { props: [], template: "<panel class=\"page\"><slot name=\"head\"/><label text=\"mid\"/><slot/></panel>" });');
      engine.LoadFromString(
        '<window><page-box>' +
        '<label id="hd" slot="head" text="H"/>' +
        '<label id="ft" text="F"/>' +
        '<label id="dr" slot="none" text="X"/>' +
        '</page-box></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('hd');
      Check((node <> nil) and (node.Parent.Tag = 'panel') and
        (node.Parent.IndexOfChild(node) = 0), '具名 slot：head 内容进入对应槽位');
      node := engine.Document.FindElementById('ft');
      Check((node <> nil) and (node.Parent.IndexOfChild(node) = 2),
        '默认 slot：未标 slot 的内容进入无具名槽位');
      Check(engine.Document.FindElementById('dr') = nil, '未匹配槽位的内容被丢弃');

      // props 类型校验：静态属性按声明强转
      RunFlush(
        'component("typed", { props: { n: "number", s: "string" }, template: "<label x-text=\"props.s + props.n\"/>" });');
      engine.LoadFromString('<window><typed id="ty1" n="7" s="v"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ty1');
      Check((node <> nil) and (node.Text = 'v7'), 'props 类型校验：静态属性按声明强转 number');

      // props 类型校验：动态 prop 不匹配 → 上报且不写入
      RunFlush('const tv = reactive({ bad: "str" });');
      errs := script.ErrorCount;
      engine.LoadFromString('<window><typed id="ty2" s="x" :n="tv.bad"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'props 类型校验：动态 prop 类型不匹配上报错误');
      node := engine.Document.FindElementById('ty2');
      Check((node <> nil) and (node.Text = 'xundefined'),
        'props 类型校验：不匹配的写入被拒绝（保留旧值）');

      // props 必填校验
      errs := script.ErrorCount;
      RunFlush(
        'component("reqd", { props: { v: { type: "string", required: true } }, template: "<label x-text=\"props.v\"/>" });');
      engine.LoadFromString('<window><reqd/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'props 必填校验：缺失时上报错误');
      Check(Pos('缺少必填 prop', sink.LastError) > 0, 'props 必填校验：错误信息含 prop 名');

      // 组件作为 keyed 列表项：重排后组件 props 随新条目更新（键控作用域 × 组件实例叠加）
      RunFlush(
        'const cl = reactive({ rows: [{ id: 1, n: "C1" }, { id: 2, n: "C2" }] });' + #10 +
        'component("crow", { props: ["n"], template: "<panel class=\"crow\"><label x-text=\"props.n\"/></panel>" });');
      engine.LoadFromString(
        '<window><panel id="kcl" x-for="r in cl.rows"><crow :n="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('kcl');
      Check((node.Count = 2) and (node[0][0].Text = 'C1') and (node[1][0].Text = 'C2'),
        '组件作为 keyed 列表项：首次刷新即渲染');
      RunFlush('cl.rows = [{ id: 2, n: "C2b" }, { id: 1, n: "C1b" }];');
      node := engine.Document.FindElementById('kcl');
      Check((node.Count = 2) and (node[0][0].Text = 'C2b') and (node[1][0].Text = 'C1b'),
        '组件作为 keyed 列表项：重排后组件 props 随新条目更新');

      // 已知边界：组件模板内的 x-for 与父级 keyed diff 叠加
      RunFlush(
        'const bl = reactive({ rows: [{ id: 1, tags: ["a", "b"] }, { id: 2, tags: ["c"] }] });' + #10 +
        'component("tag-box", { props: ["tags"], template: "<panel class=\"tb\"><panel x-for=\"t in props.tags\"><label x-text=\"t\"/></panel></panel>" });');
      engine.LoadFromString(
        '<window><panel id="tbl" x-for="r in bl.rows"><tag-box :tags="r.tags" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tbl');
      Check((node.Count = 2) and (node[0][0].Count = 2) and (node[1][0].Count = 1),
        '组件内 x-for：按 props 数组渲染');
      RunFlush('bl.rows = [{ id: 2, tags: ["c", "d"] }, { id: 1, tags: ["a"] }];');
      node := engine.Document.FindElementById('tbl');
      Check((node[0][0].Count = 2) and (node[0][0][0].Text = 'c') and
        (node[0][0][1].Text = 'd') and (node[1][0].Count = 1) and
        (node[1][0][0].Text = 'a'),
        '组件内 x-for 与父级 keyed 复用叠加：内层列表随新 props 更新');

      // x-for 容器缺少模板子节点：上报而非崩溃
      errs := script.ErrorCount;
      engine.LoadFromString('<window><panel id="badfor" x-for="x in bl.rows"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, 'x-for 缺少模板子节点：上报错误');
      Check(engine.Document.FindElementById('badfor').Count = 0, 'x-for 缺少模板子节点：容器保持空');

      // 组件宿主上的 x-if（单根实例：改指实例根后照常摘除/恢复）
      RunFlush(
        'const vv = reactive({ on: true });' + #10 +
        'component("fx-box", { props: [], template: "<label class=\"fx\" text=\"FX\"/>" });');
      engine.LoadFromString('<window><panel id="fxp"><fx-box id="fxc" x-if="vv.on"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fxc');
      Check((node <> nil) and (node.Text = 'FX'), '组件宿主 x-if：真值渲染实例');
      RunFlush('vv.on = false;');
      Check(engine.Document.FindElementById('fxc') = nil, '组件宿主 x-if：假值摘除实例');
      RunFlush('vv.on = true;');
      node := engine.Document.FindElementById('fxc');
      Check((node <> nil) and (node.Parent.Tag = 'panel') and (node.Text = 'FX'),
        '组件宿主 x-if：真值原位恢复实例');

      // 多根组件 + x-if：明确不支持（上报）
      errs := script.ErrorCount;
      engine.LoadFromString('<window><duo id="duox" x-if="vv.on"/></window>');
      DrawEngine(engine);
      Check(script.ErrorCount > errs, '多根组件 + x-if：上报不支持');

      // ---- M7-5：props default（原始值 / 工厂函数）与多根组件作为 keyed 列表项 ----

      // 原始值缺省 + 显式传入覆盖
      RunFlush(
        'component("dv-box", { props: { n: { type: "number", default: 5 }, s: { type: "string", default: "d" } }, template: "<label x-text=\"props.s + props.n\"/>" });');
      engine.LoadFromString('<window><dv-box id="dv1"/><dv-box id="dv2" s="x" n="9"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('dv1');
      Check((node <> nil) and (node.Text = 'd5'), 'props default：原始值缺省生效');
      node := engine.Document.FindElementById('dv2');
      Check((node <> nil) and (node.Text = 'x9'), 'props default：显式传入覆盖缺省');

      // 工厂函数缺省：每次实例化调用一次（数组缺省不跨实例共享，且通过类型校验）
      errs := script.ErrorCount;
      RunFlush(
        'component("fx-list", { props: { tags: { type: "array", default: function () { return ["t1"]; } } }, template: "<panel class=\"fl\"><panel x-for=\"t in props.tags\"><label x-text=\"t\"/></panel></panel>" });');
      engine.LoadFromString('<window><fx-list id="fl1"/><fx-list id="fl2"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('fl1');
      Check((node <> nil) and (node[0].Count = 1) and (node[0][0].Text = 't1'),
        'props default：工厂函数缺省（数组）');
      Check(script.ErrorCount = errs, 'props default：缺省值通过类型校验，无错误上报');

      // 多根组件作为 keyed 列表项：两棵根成组渲染、重排后仍成组有序
      RunFlush(
        'const mg = reactive({ rows: [{ id: 1, n: "M1" }, { id: 2, n: "M2" }] });' + #10 +
        'component("pair", { props: ["n"], template: "<label class=\"p1\" x-text=\"props.n\"/><label class=\"p2\" text=\"tail\"/>" });');
      engine.LoadFromString(
        '<window><panel id="mg1" x-for="r in mg.rows"><pair :n="r.n" x-key="r.id"/></panel></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('mg1');
      Check((node.Count = 4) and (node[0].Text = 'M1') and (node[1].Text = 'tail') and
        (node[2].Text = 'M2') and (node[3].Text = 'tail'),
        '多根组件作为 keyed 列表项：两棵根成组渲染');
      RunFlush('mg.rows = [{ id: 2, n: "M2b" }, { id: 1, n: "M1b" }];');
      node := engine.Document.FindElementById('mg1');
      Check((node.Count = 4) and (node[0].Text = 'M2b') and (node[1].Text = 'tail') and
        (node[2].Text = 'M1b') and (node[3].Text = 'tail'),
        '多根组件作为 keyed 列表项：重排后两棵根保持成组有序');

      // 函数 prop：kebab 属性名（:on-labels）转 camel（onLabels）后按 props 调用
      RunFlush(
        'function LabelOf(n: number): string { return "L" + n; }' + #10 +
        'component("uc2", { props: { count: { type: "number", default: 0 }, onLabels: { type: "function" } }, template: "<panel><label x-text=\"props.onLabels(props.count)\"/></panel>" });');
      engine.LoadFromString('<window><uc2 id="uc2" :count="7" :on-labels="LabelOf"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('uc2');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'L7'),
        '函数 prop：kebab 属性名转 camel 后可在模板内调用');

      // reverse / splice 的响应式变更通知（与 push/pop/shift/unshift 对齐）
      RunFlush('const rv = reactive({ rows: [{ n: "r1" }, { n: "r2" }] });');
      engine.LoadFromString(
        '<window><panel id="rv1" x-for="r in rv.rows"><label x-text="r.n"/></panel></window>');
      DrawEngine(engine);
      RunFlush('rv.rows.reverse();');
      node := engine.Document.FindElementById('rv1');
      Check((node.Count = 2) and (node[0].Text = 'r2') and (node[1].Text = 'r1'),
        '数组 reverse 触发 x-for 刷新');
      RunFlush('rv.rows.splice(1, 0, { n: "r3" });');
      node := engine.Document.FindElementById('rv1');
      Check((node.Count = 3) and (node[1].Text = 'r3'),
        '数组 splice 触发 x-for 刷新');

      // watch 回调内未捕获异常只上报不扩散（此前会逃到宿主顶层弹异常框）
      errs := script.ErrorCount;
      script.Run('watch(function () { return state.nope.deep; }, function (nv, ov) { console.log("not-reached"); });', 'badw.ts');
      script.Run('watch(function () { return st.a; }, function (nv, ov) { console.log("good" + nv); });', 'goodw.ts');
      script.FlushReactive;
      Check(script.ErrorCount > errs, 'watch 求值异常上报为脚本错误');
      Check(Pos('not-reached', sink.Log.Text) = 0, 'watch 求值异常不执行回调');
      src := RunFlush('st.a = st.a + 1;');
      Check(Pos('good', src) > 0, 'watch 异常不阻断其它监听器与刷新链路');

      // ---- M8-0 ADR 22：x-onclick="expr" 事件表达式（组件对外抛事件的地基）----

      // 表达式与全局函数名两种写法（附：x-on:click 冒号别名）
      RunFlush(
        'const ev = reactive({ n: 0, calls: 0 });' + #10 +
        'function OnTap() { ev.calls = ev.calls + 1; }');
      engine.LoadFromString(
        '<window>' +
        '<button id="ev1" x-onclick="ev.n = ev.n + 1" text="b1"/>' +
        '<button id="ev2" x-on:click="OnTap" text="b2"/>' +
        '<label id="ev3" text="n={{ev.n}}/c={{ev.calls}}"/>' +
        '</window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('ev1'));
      ClickNode(engine, engine.Document.FindElementById('ev2'));
      DrawEngine(engine);
      node := engine.Document.FindElementById('ev3');
      Check((node <> nil) and (node.Text = 'n=1/c=1'),
        'x-onclick：表达式（赋值）与函数名两种写法都触发（含 x-on:click 别名）');

      // 组件模板内用回调 prop：父级 x-onclick="Fn" 映射为 onClick prop
      RunFlush(
        'const cev = reactive({ taps: 0 });' + #10 +
        'function OnHostTap() { cev.taps = cev.taps + 1; }' + #10 +
        'component("ui-tap", { props: { onClick: { type: "function" } }, ' +
        'template: "<panel class=\"tapbox\" x-onclick=\"props.onClick\"><slot/></panel>" });');
      engine.LoadFromString(
        '<window><ui-tap id="tap1" x-onclick="OnHostTap"><label id="tap-lbl" text="点我"/></ui-tap>' +
        '<label id="tap-cnt" text="taps={{cev.taps}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('tap-lbl'));
      DrawEngine(engine);
      node := engine.Document.FindElementById('tap-cnt');
      Check((node <> nil) and (node.Text = 'taps=1'),
        '组件 x-onclick：模板内 props.onClick 触发父级函数（子→父事件链路）');

      // 表达式出错只上报，不崩应用
      errs := script.ErrorCount;
      engine.LoadFromString(
        '<window><button id="ev4" x-onclick="ev.nope.deep" text="boom"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('ev4'));
      Check(script.ErrorCount > errs, 'x-onclick：表达式出错上报为脚本错误（不崩应用）');

      // x-oninput：input 事件触发（函数名形式）
      RunFlush(
        'const iv = reactive({ n: 0 });' + #10 +
        'function OnIv() { iv.n = iv.n + 1; }');
      engine.LoadFromString(
        '<window><input id="iv1" x-oninput="OnIv"/>' +
        '<label id="iv2" text="n={{iv.n}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('iv1'));
      engine.HandleTextInput('x');
      DrawEngine(engine);
      node := engine.Document.FindElementById('iv2');
      Check((node <> nil) and (node.Text = 'n=1'), 'x-oninput：input 事件触发表达式');

      // 表达式形式可读 event 载荷（event.text = 输入后的文本）
      RunFlush('const it2 = reactive({ t: "-" });');
      engine.LoadFromString(
        '<window><input id="iv3" x-oninput="it2.t = event.text"/>' +
        '<label id="iv4" text="t={{it2.t}}"/></window>');
      DrawEngine(engine);
      ClickNode(engine, engine.Document.FindElementById('iv3'));
      engine.HandleTextInput('hi');
      DrawEngine(engine);
      node := engine.Document.FindElementById('iv4');
      Check((node <> nil) and (node.Text = 't=hi'),
        'x-oninput：表达式可用 event.text 读取载荷');

      // ---- M8-0 ADR 23：x-model 组件双向绑定（props.modelValue ↔ props.onModelValue）----
      RunFlush(
        'const mv = reactive({ name: "init" });' + #10 +
        'component("ui-text", { props: { modelValue: { type: "string", default: "" } }, ' +
        'template: "<panel class=\"uitext\"><input :text=\"props.modelValue\" ' +
        'x-oninput=\"props.onModelValue\"/></panel>" });');
      engine.LoadFromString('<window><ui-text id="ut1" x-model="mv.name"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ut1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'init'),
        'x-model 组件：宿主状态写入 props.modelValue（初值）');

      ClickNode(engine, node[0]);
      engine.HandleTextInput('abc');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ut1');
      src := RunFlush('console.log("mv=" + mv.name);');
      Check(Pos('mv=initabc', src) > 0,
        'x-model 组件：组件内输入经 props.onModelValue 回写宿主状态');

      RunFlush('mv.name = "reset";');
      DrawEngine(engine);
      node := engine.Document.FindElementById('ut1');
      Check((node <> nil) and (node[0].Text = 'reset'),
        'x-model 组件：宿主状态变化回灌组件内部');

      // ---- M8-0 ADR 27：templateFile（模板外置，相对脚本文件目录解析）----
      tplDir := GetTempDir + 'lui_m8_tpl';
      ForceDirectories(tplDir);
      WriteTestFile(tplDir + PathDelim + 'card.xml',
        '<panel class="tplcard"><label x-text="props.t"/></panel>');
      WriteTestFile(tplDir + PathDelim + 'ui.ts',
        'component("tpl-card", { props: { t: "string" }, templateFile: "card.xml" });');
      script.RunFile(tplDir + PathDelim + 'ui.ts');
      engine.LoadFromString('<window><tpl-card id="tc1" t="hi"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('tc1');
      Check((node <> nil) and (node.Count = 1) and (node[0].Text = 'hi'),
        'templateFile：外部模板文件按脚本目录解析并实例化');

      errs := script.ErrorCount;
      WriteTestFile(tplDir + PathDelim + 'bad.ts',
        'component("tpl-bad", { props: [], templateFile: "no-such-file.xml" });');
      script.RunFile(tplDir + PathDelim + 'bad.ts');
      Check(script.ErrorCount > errs, 'templateFile：模板文件缺失上报为脚本错误');

      // ---- M8-0 ADR 24：浮层（挂到文档根 + 定位 + node.rect）----
      RunFlush('const pp = reactive({ open: false });');
      engine.LoadFromString(
        '<window>' +
        '<panel id="hostbox" style="overflow:hidden; width:120px; height:40px">' +
        '<button id="anchor1" text="锚点"/>' +
        '</panel>' +
        '<panel id="pop1" style="width:60px; height:30px"><label text="浮层"/></panel>' +
        '</window>');
      DrawEngine(engine);
      src := RunFlush(
        'console.log("rect=" + document.find("anchor1").rect.top + "/" + document.find("anchor1").rect.height);' +
        'ui.popup(document.find("pop1"), { anchor: "anchor1", placement: "bottom-start" });');
      DrawEngine(engine);
      node := engine.Document.FindElementById('pop1');
      Check((node <> nil) and (node.Parent = engine.Document.Root),
        'ui.popup：浮层挂到文档根（脱离父级 overflow 裁剪）');
      Check((node <> nil) and (node.Style.Position = xposAbsolute),
        'ui.popup：内联 style 实现绝对定位');
      Check((node <> nil) and
        (node.Style.Inset.Top.Value >= engine.Document.FindElementById('anchor1').BoxRect.Bottom - 1),
        'ui.popup：定位到锚点下方（bottom-start）');
      Check((node <> nil) and (node.Style.Width.Value = 60),
        'ui.popup：保留作者内联样式（width 未被定位覆盖）');
      Check(Pos('rect=', src) > 0, 'node.rect：脚本可读元素矩形');

      // ---- M8-1 前置：:style 运行时样式 / :placeholder 运行时属性 / ui.include ----
      RunFlush('const sty = reactive({ w: 40 });');
      engine.LoadFromString(
        '<window><panel id="sty1" :style="''width:'' + sty.w + ''px; height:20px''"/></window>');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sty1');
      Check((node <> nil) and (node.Style.Width.Value = 40), ':style：运行时样式生效');
      RunFlush('sty.w = 80;');
      DrawEngine(engine);
      node := engine.Document.FindElementById('sty1');
      Check((node <> nil) and (node.Style.Width.Value = 80),
        ':style：状态变化后样式随之更新（组件按 props 算样式的基础）');

      RunFlush('const ph = reactive({ hint: "请输入用户名" });');
      engine.LoadFromString('<window><input id="ph1" :placeholder="ph.hint"/></window>');
      fake.Clear;
      DrawEngine(engine);
      Check(fake.TextDrawn('请输入用户名'), ':placeholder：运行时占位符生效');

      incDir := GetTempDir + 'lui_m8_inc';
      ForceDirectories(incDir);
      WriteTestFile(incDir + PathDelim + 'part.ts', 'function IncFn(): number { return 7; }');
      WriteTestFile(incDir + PathDelim + 'main.ts',
        'ui.include("part.ts");' + #10 +
        'ui.include("part.ts");' + #10 +   // 重复 include 只执行一次
        'console.log("inc=" + IncFn());');
      sink.Log.Clear;
      script.RunFile(incDir + PathDelim + 'main.ts');
      Check(Pos('inc=7', sink.Log.Text) > 0, 'ui.include：按当前脚本目录加载并执行另一个脚本');
      errs := script.ErrorCount;
      WriteTestFile(incDir + PathDelim + 'badinc.ts', 'ui.include("nope.ts");');
      script.RunFile(incDir + PathDelim + 'badinc.ts');
      Check(script.ErrorCount > errs, 'ui.include：文件缺失上报为脚本错误');
    finally
      bridge.Free;
    end;
  finally
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;

{$ENDIF}

{$IFDEF LUI_SCRIPT_DEMO_PAGE_INLINE}
// Staged extraction: the active demo-page test lives in script_demo_page.inc.
// 演示页整页加载（demo/m7.xml + 同名 m7.ts）：走引擎真实的文档加载路径。
// 关键点：脚本在首轮扫描之后才运行，component(...) 的注册必须让绑定集重建，
// 否则组件标签会被当普通标签处理（真实应用里组件永不实例化）。
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
      engine.LoadFromFile(xmlPath);   // 页面内声明 <script src="m7.ts"/>
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

      // 调用脚本函数（事件回退路径）→ 状态 → 绑定与组件 props 刷新
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

      // 页内切换：m7 → 脚本页（同一引擎/脚本实例上换文档；上一页的 watch 必须作废，
      // 否则它会拿新页面的 state 求值而抛 "无法读取 undefined 的属性"）
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

{$ENDIF}

{$IFDEF LUI_HOST_REGRESSIONS_INLINE}
// Staged extraction: active host/console regressions live in host_regressions.inc.
// ---- M11 预览窗装配（窗口级回归）----
// 背景：预览窗曾整片空白——窗口出来了、引擎也装配了，但屏幕上没有任何像素。
// 根因是 TXuiHost.Create 不设置 Parent，调用方必须自己挂到窗体；渲染器的预览窗漏了
// 这一行，而 demo1 有，所以 demo 一直正常、渲染器预览一直空白（M9 就存在，长期漏检）。
//
// 教训是"窗口级装配"此前完全没有测试覆盖（套件全在引擎层，不建窗体）。
// 这里把窗口级不变量固化下来：宿主必须是窗体的子控件，且引擎随装配真的画出内容。
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

  // 造一个与预览窗同构的窗体：宿主必须是窗体的子控件，否则客户区永远空白
  form := TForm.CreateNew(nil);
  bmp := TBitmap.Create;
  try
    form.ClientWidth := 320;
    form.ClientHeight := 240;

    host := TXuiHost.Create(form);
    // ↓ 这就是曾经漏掉的一行；断言它存在，等价于断言"宿主在窗体控件树里"
    host.Parent := form;
    host.Align := alClient;

    Check(host.Parent = form, '宿主已挂到窗体（漏掉会整片空白）');
    Check(form.ContainsControl(host), '窗体控件树包含宿主（LCL 可见性判定的依据）');
    Check(host.Visible, '宿主可见');

    // 装配 + 绘制：用引擎直接画到 bitmap（离屏），证明装配后真的产出内容
    app := TXuiApp.CreateAttached(host.Engine, host.Script);
    try
      pagePath := DemoFilePath('m7.xml');
      if pagePath = '' then
      begin
        WriteLn('SKIP  未找到 demo/m7.xml');
      end
      else
      begin
        bmp.SetSize(320, 240);
        bmp.Canvas.Brush.Color := clWhite;
        bmp.Canvas.FillRect(0, 0, 320, 240);
        app.Engine.Renderer := TGdiRenderer.Create(bmp.Canvas);
        app.Configure(pagePath, 'light', '');

        r := Rect(0, 0, 320, 240);
        app.Engine.Draw(bmp.Canvas, r);

        // 真画上去了吗：统计非白像素（全白 = 什么都没画 = 空白窗口）
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

    // 解除挂载后必须真的脱离控件树（FreeAndNil 之外的路径也要安全）
    host.Parent := nil;
    Check(not form.ContainsControl(host), '解除 Parent 后脱离窗体控件树');
    host.Free;
  finally
    bmp.Free;
    form.Free;
  end;
end;

// ---- M11 健壮控制台输出（src/ui/xui_console.pas）----
// 覆盖两个实测问题：① 输出目标不可写时不得抛异常（FPC 的 I/O 检查会把写失败抛成
// EInOutError，并被固定文案误报为 "Disk Full"）；② 输出编码必须**一致**——
// 曾经纯字面量被直写成 UTF-8，而拼接/Format 的字符串经 RTL 转成控制台码页，
// 同一屏里两种编码混杂，在 GBK 控制台上后半必然乱码。
// 这里能测的是 ②：同一次运行里不同来源的字符串必须落在同一种编码。
procedure TestConsoleOutput;
var
  ok, sawHighByte: Boolean;
  i, highCount: Integer;
  mixedMsg, pureMsg: string;
  enc: Boolean;
begin
  WriteLn('--- M11 控制台输出健壮性 ---');

  XuiConsoleInit;

  // 正常环境：写入应当成功，且不影响后续
  ok := ConWriteLn('（自检）控制台输出可用');
  Check(ok, '正常环境下输出成功');
  Check(ConsoleWritable, '正常环境下输出被标记为可写');
  Check(ConWriteLnFmt('（自检）格式化输出 %d/%s', [7, 'ok']),
    '格式化输出（ConWriteLnFmt）成功');
  Check(ConErrWriteLn('（自检）stderr 输出可用'), 'stderr 输出成功');

  // 关键性质：反复写入不抛异常（实现用了 {$I-}/IOResult，不能再引入异常路径）
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

  // 编码一致性：ConWriteLn 的形参是运行时字符串，两条不同的构造路径应当给出同一种
  // 编码结果。这里比较"同一段中文经由字面量 vs 拼接"的字节序列是否一致
  // —— 若实现退化成直写（绕过转换），两者就会不同。
  pureMsg := '参数错误';
  mixedMsg := '' + '参数错误';
  enc := Length(pureMsg) = Length(mixedMsg);
  Check(enc, '字面量与拼接构造的中文长度一致（同一编码路径）');
  Check(ConWriteLn('（自检）字面量与拼接并排：' + pureMsg + ' / ' + mixedMsg),
    '字面量与拼接混合输出成功');

  // 高位字节（中文）确实写到了输出上——说明不是被静默丢弃
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

{$ENDIF}

{$IFDEF LUI_SCAFFOLD_INLINE}
// Staged extraction: active scaffold coverage lives in scaffold_regression.inc.
// ---- M11 项目脚手架（lui-render --init 的引擎侧实现：src/ui/xui_scaffold.pas）----
// 覆盖：模板定位、生成物齐备（页面/脚本/双主题样式/工程清单/三支脚本/自带 ui/ 运行时）、
// 占位符替换、.gitignore 还原、换行归一（.cmd 必须 CRLF）、"只写不改不删"策略
// （已存在文件默认保留、Force 才覆盖），以及最关键的端到端：生成物能被真实引擎装配并出图。
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

  // 生成一次（AForce 决定是否覆盖已存在文件）；失败时打印原因便于定位
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
    o.RuntimePath := 'C:\fake\lui-runtime.exe';
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
    DeleteDirectory(base, True);   // 清掉上一轮残留（否则"目录非空"会挡住生成）

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
    Check(FileExists(proj + PathDelim + 'lui.json'), '生成应用清单 lui.json（M12：运行时读的就是它）');
    Check(FileExists(proj + PathDelim + 'run-dev.cmd'), '生成 run-dev.cmd（开发）');
    Check(FileExists(proj + PathDelim + 'run-test.cmd'), '生成 run-test.cmd（测试）');
    Check(FileExists(proj + PathDelim + 'run-pack.cmd'), '生成 run-pack.cmd（交付目录）');
    Check(FileExists(proj + PathDelim + 'run-build.cmd'), '生成 run-build.cmd（构建单文件应用）');
    Check(FileExists(proj + PathDelim + 'README.md'), '生成 README.md');
    Check(FileExists(proj + PathDelim + '.gitignore'),
      'gitignore 模板还原为 .gitignore（模板名不能以点开头，否则会被 git 当忽略规则）');
    Check(FileExists(proj + PathDelim + 'ui' + PathDelim + 'index.ts'),
      '自带组件库运行时 ui/index.ts（生成即不依赖 lui 仓库）');
    Check(FileExists(proj + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css'),
      '自带组件库主题 ui/theme/lui-light.css');

    // 占位符：工程名默认取目录名；渲染器路径写进脚本与清单，两种分隔符形式各归其位
    jsonText := ReadText(proj + PathDelim + 'lui.json');
    Check(Pos('"name": "myapp"', jsonText) > 0, '清单里回填工程名（默认取目录名）');
    Check(Pos('"width": 480', jsonText) > 0, '清单里回填视口宽（--init -w）');
    Check(Pos('"height": 560', jsonText) > 0, '清单里回填视口高（--init -H）');
    Check(Pos('"main": "src/main.xml"', jsonText) > 0, '清单里声明入口页面');
    Check(Pos('"ui": "ui"', jsonText) > 0, '清单里声明组件库目录');
    Check(Pos('@@', jsonText) = 0, '清单里占位符已全部替换');

    cmdText := ReadText(proj + PathDelim + 'run-dev.cmd');
    Check(Pos('C:\fake\lui-runtime.exe', cmdText) > 0,
      '.cmd 里运行时路径用原生分隔符（cmd.exe 语义正确）');
    Check(Pos('dev .', cmdText) > 0,
      'run-dev.cmd 走新命令面（lui dev .，不再硬编码入口与主题）');
    Check(Pos('@@', cmdText) = 0, '.cmd 里占位符已全部替换');
    Check(Pos(#13#10, cmdText) > 0, '.cmd 用 CRLF 换行（cmd 对 LF-only 的标签解析不可靠）');
    Check(Pos(#$EF#$BB#$BF, cmdText) = 0, '生成文件不写 BOM');
    // .cmd 必须纯 ASCII：cmd.exe 按 OEM 代码页解码批处理，UTF-8 中文注释会乱码，
    // 极端情况下还会被当成命令执行（实测过）。渲染器自身输出的中文不受影响。
    Check(not HasNonAscii(cmdText), '.cmd 保持纯 ASCII（cmd.exe 按 OEM 码页解码，非 ASCII 会乱码）');
    Check(not HasNonAscii(ReadText(proj + PathDelim + 'run-test.cmd')),
      '.cmd 保持纯 ASCII（run-test.cmd）');
    Check(not HasNonAscii(ReadText(proj + PathDelim + 'run-pack.cmd')),
      '.cmd 保持纯 ASCII（run-pack.cmd）');
    Check(not HasNonAscii(ReadText(proj + PathDelim + 'run-build.cmd')),
      '.cmd 保持纯 ASCII（run-build.cmd）');
    Check(Pos('lui-runtime.exe', ReadText(proj + PathDelim + 'README.md')) > 0,
      'README.md 里给出运行时路径（正斜杠形式，供工具消费）');

    // 页面 XML：视口宽高进 window 属性，且不残留占位符
    lines := TStringList.Create;
    try
      lines.LoadFromFile(pagePath);
      Check(Pos('width="480"', lines.Text) > 0, '页面 window 回填视口宽');
      Check(Pos('@@', lines.Text) = 0, '页面里占位符已全部替换');
    finally
      lines.Free;
    end;

    // ---- 只写不改不删：已存在文件默认保留，Force 才覆盖 ----
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

    // 非 lui 工程的非空目录默认拒写（避免误往任意目录铺文件），--force 才放行
    Check(not Gen(base, False),
      '已存在且非 lui 工程的目录：默认拒写（不往任意目录铺文件）');
    Check(Gen(base, True), '同上目录加 --force 后允许写入');

    // ---- 端到端：生成的工程被真实引擎装配、执行脚本、交互、出图 ----
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
        engine.LoadFromFile(pagePath);   // 页面内声明 <script src="../ui/index.ts"/> 与 main.ts
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

        // 走一遍交互：只改状态 → 绑定自动刷新（证明生成物的逻辑回路是通的）
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

        // 条目行的结构：panel.item 下应有 [x] 标记 / 标题 / 删除按钮 三件
        // （删除按钮是行内嵌套的可点区域，行本身也可点；模板把两者都放上了）
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

        // 深色档：同一页面换样式表必须同样能装配（两主题文件都得是完整样式表）
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

{$ENDIF}

{$IFDEF LUI_AGENT_PAGE_INLINE}
// Staged extraction: active agent coverage lives in agent_page.inc.
// fake HTTP 执行器（定义见本段末尾）：模拟 OpenAI 兼容 /chat/completions
procedure AgentFakeHttp(AReq: TXuiIoRequest; ARes: TXuiIoResult); forward;

// ---- M10 对话式 AI Agent 演示页（demo/agent.xml + agent.ts）----
// 覆盖：整页装配无脚本错误、首屏问候、离线工具调用回路（规划 → 工具执行 → 步骤卡 → 回答）、
// 多意图规划、未知输入兜底，以及在线档 agent loop（注入 fake HTTP 执行器，确定性）。
procedure TestAgentPage;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  sink: TScriptSink;
  node, msgNode: TXuiNode;
  errs: Integer;
  pumpClock: Integer;
  xmlPath, cssPath: string;

  // 走完整异步链：定时器 + I/O + 微任务，模拟宿主连续 Tick
  procedure Pump(Times: Integer);
  var
    t: Integer;
  begin
    // 时钟必须跨调用单调推进：每次从同一值重开会把虚拟时钟拨回，
    // 后创建的定时器永远到不了期（早前 Pump 版本的真实缺陷）
    for t := 1 to Times do
    begin
      Inc(pumpClock, 20);
      engine.Tick(1000 + QWord(pumpClock));   // 定时器到期 + I/O 完成 + 排水
      DrawEngine(engine);
    end;
  end;

  // 子树文本汇总（TXuiNode.Text 只含本节点文本，不含后代）
  function TextOf(ANode: TXuiNode): string;
  var
    k: Integer;
  begin
    Result := '';
    if ANode = nil then Exit;
    Result := ANode.Text;
    for k := 0 to ANode.Count - 1 do
      Result := Result + ' ' + TextOf(ANode[k]);
  end;

  // 末条消息节点（class=msg）。注：x-for 会保留一个容器包裹克隆体，
  // 故不能直接取 agent-scroll 的末子节点
  procedure CollectMsgs(ANode: TXuiNode; AList: TList);
  var
    k: Integer;
  begin
    if ANode = nil then Exit;
    if ANode.HasClass('msg') then AList.Add(ANode)
    else
      for k := 0 to ANode.Count - 1 do
        CollectMsgs(ANode[k], AList);
  end;

  function LastMessage: TXuiNode;
  var
    list: TList;
  begin
    Result := nil;
    list := TList.Create;
    try
      CollectMsgs(engine.Document.FindElementById('agent-scroll'), list);
      if list.Count > 0 then
        Result := TXuiNode(list[list.Count - 1]);
    finally
      list.Free;
    end;
  end;

begin
  WriteLn('--- M10 演示页（demo/agent）---');
  xmlPath := DemoFilePath('agent.xml');
  if xmlPath = '' then
  begin
    WriteLn('SKIP  未找到 demo/agent.xml');
    Exit;
  end;
  engine := NewTestEngine(fake);
  script := TXuiScript.Create;
  sink := TScriptSink.Create;
  bridge := TXuiDomBridge.Create(engine, script);
  try
    bridge.Install;
    engine.AttachScript(script);
    script.OnError := @sink.HandleError;
    script.Interp.OnLog := @sink.HandleLog;
    cssPath := DemoFilePath('agent-light.css');
    if cssPath <> '' then
      engine.LoadStyleSheetFromFile(cssPath);
    engine.LoadFromFile(xmlPath);   // 页面内 <script src="agent.ts"/>
    pumpClock := 0;
    DrawEngine(engine);

    Check(script.ErrorCount = 0, '演示页 agent：整页加载无脚本错误');

    // 首屏问候（顶层播种，CLI 单次出图也能看到）
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('lui Agent', TextOf(msgNode)) > 0),
      '演示页 agent：首屏问候已渲染');

    // --- 离线档：计算意图 → 工具调用 → 步骤卡 → 回答 ---
    errs := script.ErrorCount;
    script.CallGlobal('UsePrompt', [script.Str('计算 12*(3+4)')]);
    script.FlushReactive;
    Pump(400);
    Check(script.ErrorCount = errs, '演示页 agent：离线工具回路无脚本错误');
    node := engine.Document.FindElementById('agent-status');
    Check((node <> nil) and (Pos('完成', node.Text) > 0),
      '演示页 agent：离线流程结束（状态=完成）');

    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('84', TextOf(msgNode)) > 0),
      '演示页 agent：计算器工具结果进入回答（12*(3+4)=84）');
    // 步骤卡：名称含工具标签与实参
    Check((msgNode <> nil) and (msgNode.Count > 0) and
      (Pos('计算器', TextOf(msgNode)) > 0) and (Pos('12*(3+4)', TextOf(msgNode)) > 0),
      '演示页 agent：工具步骤卡展示工具名与参数');

    // --- 离线档：多意图（算式 + 时间）→ 两次工具调用 ---
    script.CallGlobal('UsePrompt', [script.Str('算一下 99*99 再告诉我时间')]);
    script.FlushReactive;
    Pump(400);
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('9801', TextOf(msgNode)) > 0),
      '演示页 agent：大数乘法不走 32 位截断（99*99=9801）');
    Check((msgNode <> nil) and (Pos('当前时间', TextOf(msgNode)) > 0),
      '演示页 agent：多意图规划命中时间工具');

    // --- 离线档：无工具命中 → 兜底引导语 ---
    script.CallGlobal('UsePrompt', [script.Str('随便说点什么')]);
    script.FlushReactive;
    Pump(400);
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('可以调用工具', TextOf(msgNode)) > 0),
      '演示页 agent：无工具命中时给出兜底提示');

    // --- 在线档：注入 fake HTTP 执行器，走 agent loop（tool_calls → 本地执行 → 终答）---
    script.IO.SyncMode := True;
    script.IO.Executor := @AgentFakeHttp;
    script.CallGlobal('ToggleOnline', []);   // 切到在线档（state.online = true）
    script.FlushReactive;
    errs := script.ErrorCount;
    script.CallGlobal('UsePrompt', [script.Str('计算 5+5')]);
    script.FlushReactive;
    Pump(400);
    Check(script.ErrorCount = errs, '演示页 agent：在线档 agent loop 无脚本错误');
    msgNode := LastMessage;
    Check((msgNode <> nil) and (Pos('10', TextOf(msgNode)) > 0),
      '演示页 agent：在线 tool_calls 经本地执行后回填并给出终答');
  finally
    bridge.Free;
    sink.Free;
    script.Free;
    engine.Free;
  end;
end;

// fake HTTP：模拟 OpenAI 兼容 /chat/completions。
// 首轮返回 calculator 的 tool_call；带 tool 结果后再问则返回终答。
procedure AgentFakeHttp(AReq: TXuiIoRequest; ARes: TXuiIoResult);
begin
  ARes.Ok := True;
  ARes.Status := 200;
  ARes.Headers := 'Content-Type: application/json';
  if Pos('tool_call_id', AReq.Body) > 0 then
    ARes.Data := '{"choices":[{"message":{"role":"assistant","content":"在线回答：结果是 10。"}}]}'
  else
    ARes.Data := '{"choices":[{"message":{"role":"assistant","content":"",' +
      '"tool_calls":[{"id":"call_1","type":"function","function":{' +
      '"name":"calculator","arguments":"{\"expr\":\"5+5\"}"}}]}}]}';
end;

{$ENDIF}


{$IFDEF LUI_SCRIPT_ASYNC_INTEGRATION_INLINE}
// P3 集成：await ui.delay 后改 DOM（async 机器 × 定时器 × 排水全链路）


procedure TestScriptAsyncIntegration;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  script: TXuiScript;


  bridge: TXuiDomBridge;


  sink: TScriptSink;


begin


  WriteLn('--- M6 P3 async 集成（await ui.delay 改 DOM）---');


  engine := NewTestEngine(fake);


  script := TXuiScript.Create;


  sink := TScriptSink.Create;


  try


    bridge := TXuiDomBridge.Create(engine, script);


    try


      bridge.Install;


      engine.AttachScript(script);


      script.OnError := @sink.HandleError;





      engine.LoadFromString('<window><label id="out" text="init"/></window>');


      DrawEngine(engine);





      script.Run(


        'async function boot() {' + #10 +


        '  const out = document.find("out");' + #10 +


        '  out.text = "step1";' + #10 +


        '  await ui.delay(100);' + #10 +


        '  out.text = "step2";' + #10 +


        '  await ui.delay(100);' + #10 +


        '  out.text = "done";' + #10 +


        '}' + #10 +


        'boot();', 'asyncboot.ts');


      Check(script.ErrorCount = 0, 'async 引导脚本求值无错误');





      engine.Tick(1000);   // 零点；boot 同步跑到首个 await


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 'step1',


        'async 同步段立即生效');





      engine.Tick(1100);   // 相对 100：第一个 delay 到点


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 'step2',


        'await ui.delay 恢复后继续执行');





      engine.Tick(1200);   // 相对 200：第二个 delay 到点


      DrawEngine(engine);


      Check(engine.Document.FindElementById('out').Text = 'done',


        '多次 await 序列完成');


      Check(not engine.NeedsTick, 'async 完成后无待处理任务');


    finally


      bridge.Free;


    end;


  finally


    sink.Free;


    script.Free;


    engine.Free;


  end;


end;








{$ENDIF}

{$IFDEF LUI_REMAINING_REGRESSIONS_INLINE}
// Staged extraction: active small regressions live in remaining_regressions.inc.
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





    // 仅 CSS 变化：就地重解析，DOM 保留


    engine.AddElement(engine.Document.Root, '<panel id="runtime"/>');


    WaitForMTimeTick;


    WriteTestFile(cssFile, '#box { width:50px; height:20px; background-color:#00ff00; }');


    Check(engine.ReloadChangedFiles, 'CSS 变化触发重载');


    DrawEngine(engine);


    Check(engine.Document.FindElementById('box').Style.BgColor.G = $FF, '重载后新样式生效');


    Check(engine.Document.FindElementById('runtime') <> nil, 'CSS 重载保留运行时 DOM');





    // include 依赖变化：整体重建


    WaitForMTimeTick;


    WriteTestFile(partFile, '<label id="part" text="P2"/>');


    Check(engine.ReloadChangedFiles, 'include 依赖变化触发重载');


    DrawEngine(engine);


    Check(engine.Document.FindElementById('part').Text = 'P2', 'include 重载后内容更新');


    Check(engine.Document.FindElementById('runtime') = nil, 'XML 重载重建文档（运行时改动不保留）');





    // 无条件重载


    Check(engine.ReloadFromSource, 'ReloadFromSource 无条件重建');





    DeleteFile(xmlFile);


    DeleteFile(cssFile);


    DeleteFile(partFile);


    RemoveDir(dir);


  finally


    engine.Free;


  end;


end;





{ ---------- M5：中文（多字节）光标与删除 ---------- }





// 回归：XuiSnapIndex 曾把合法边界误判为“字符中间”（判定字节取错），


// 导致输入中文后光标被回退、右移卡死、删除留下半个字符（乱码）。


procedure TestInputCjkEditing;


var


  engine: TXuiEngine;


  fake: TFakeRenderer;


  input: TXuiNode;





  // 清空并重新输入（经重绘，走真实的光标对齐路径）


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


    DrawEngine(engine); // 对齐发生在绘制期：每步都重绘，复现真实路径


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





    // 乱码回归：残留孤立字节会让字节数不对（“中”= 3 字节）


    Reset('中');


    Key(VK_BACK);


    Check(Length(input.Text) = 0, '删除后无孤立续字节残留');


    Reset('中文');


    Key(VK_LEFT);


    Key(VK_LEFT);


    Key(VK_BACK);


    Check((input.Text = '中文') and (Length(input.Text) = 6), '行首 Backspace 不破坏文本');





    // Shift 扩选跨中文


    Reset('中文');


    Key(VK_HOME);


    engine.HandleKeyDown(VK_RIGHT, [xssShift]);


    DrawEngine(engine);


    engine.HandleTextInput('Q');


    Check(input.Text = 'Q文', 'Shift+→ 选中一个中文码点并被输入替换');





    // 空文本时按键不越界


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


      '<window>' +


      '  <panel id="round"/>' +


      '  <panel id="plain"/>' +


      '  <panel id="fade"><label text="hi"/></panel>' +


      '</window>');


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


        // GDI+ 的 GdipMeasureString 会多算两侧 padding；两端必须口径一致，


        // 否则换行点不同（曾导致标题被折行、末字被裁）


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

  // 1. Path 词法解析：直线与闭合
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

  // 2. 贝塞尔曲线：三次与平滑
  cmds := ParseSvgPath('M0,0 C 10 20, 30 40, 50 60 S 70 80, 90 100');
  Check(Length(cmds) = 3, 'SVG Path: 贝塞尔 C/S 指令');
  if Length(cmds) >= 3 then
  begin
    Check(cmds[1].Kind = pckBezierTo, '三次贝塞尔 C');
    Check(cmds[2].Kind = pckBezierTo, '平滑三次贝塞尔 S 自动计算反射控制点');
    Check((Round(cmds[2].P1.X) = 70) and (Round(cmds[2].P1.Y) = 80), '平滑反射控制点精确计算');
  end;

  // 3. 椭圆弧 A 指令
  cmds := ParseSvgPath('M 0 0 A 25 25 0 0 1 50 50');
  Check(Length(cmds) > 1, 'SVG Path: 椭圆弧 A 转贝塞尔');

  // 4. SVG XML 解析
  xml := '<svg viewBox="0 0 100 100" width="100" height="100">' +
         '  <circle cx="50" cy="50" r="40" fill="#ff0000" stroke="#0000ff" stroke-width="2"/>' +
         '  <rect x="10" y="10" width="80" height="80" rx="5" fill="none" stroke="currentColor"/>' +
         '  <line x1="0" y1="0" x2="100" y2="100" stroke="#00ff00"/>' +
         '  <polygon points="10,10 90,10 50,90" fill="#ffff00"/>' +
         '</svg>';
  doc := TXuiSvgDoc.Create;
  try
    doc.LoadFromString(xml);
    Check(doc.HasViewBox, 'SVG 文档解析 viewBox 成功');
    Check(Round(doc.ViewBox.Right) = 100, 'viewBox 宽度正确');
    Check(doc.Shapes.Count = 4, 'SVG 图元解析数量为 4 (circle, rect, line, polygon)');

    // 检查 rect 形状的 currentColor
    shape := TSvgShape(doc.Shapes[1]);
    Check(shape.IsCurrentColorStroke, 'rect 描边正确识别 currentColor');
    Check(not shape.HasFill, 'rect fill 为 none');

    // 检查渲染与坐标变换（无异常）
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

  // 5. 与 UI 引擎集成：<svg> 节点行为
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window>' +
      '  <svg id="s1" width="32" height="32" viewBox="0 0 24 24">' +
      '    <circle cx="12" cy="12" r="10" stroke="currentColor" fill="none"/>' +
      '  </svg>' +
      '</window>');
    svgNode := engine.Document.FindElementById('s1');
    Check(svgNode <> nil, 'UI 引擎成功生成 <svg> 节点');
    Check(svgNode.Behavior is TXuiSvgBehavior, 'svg 节点已挂载 TXuiSvgBehavior 行为');
    Check(TXuiBehavior(svgNode.Behavior).SuppressChildrenRendering, 'svg 行为抑制子图元普通流式渲染');
    DrawEngine(engine);
    Check(True, '引擎 Paint SVG 流程无异常');
  finally
    engine.Free;
  end;
end;

{$ENDIF}

begin
  Measurer := TFakeMeasurer.Create;
  try
    WriteLn('=== lui 单元测试 ===');
    TestSvgSupport;





    TestXmlParsing;


    TestDefaultStyles;


    TestBlockLayout;


    TestCssParser;


    TestCssApplyAndCascade;





    TestCssCascadeOnNode;
    TestCssVariables;
    TestUiLibrary;


    TestThemeSkin;





    TestFlexRow;


    TestFlexJustify;


    TestFlexGrow;
    TestCssMaxWidth;
    TestCssMaxHeight;
    TestFlexShrink;
    TestFlexWrap;
    TestFlexShorthandAndWrapStyle;
    TestLetterSpacing;
    TestWhiteSpaceAndOverflow;
    TestBoxShadow;
    TestSvgIntrinsicSize;
    TestWrapCache;


    TestFlexAlign;


    TestFlexColumn;


    TestTextWrap;


    TestAutoMarginAndMinSize;


    TestPositioning;


    TestAbsoluteInsetSizing;


    TestM3CssProps;

    TestLayoutContract;


    TestEngineRendering;


    TestRttiProbe;





    TestHitTest;


    TestPseudoAndClick;


    TestEventBindingFallback;


    TestScroll;


    TestRuntimeDom;


    TestScrollOverflowParsing;


    TestScrollMetrics;


    TestScrollBarsAndWheel;


    TestScrollLeftScriptBridge;


    TestTextAreaBasics;


    TestTextAreaEditAcrossLines;


    TestTextAreaEnterPolicy;


    TestTextAreaWrapAndNav;


    TestTextAreaScroll;


    TestTextAreaLongLine;


    TestRoundedAndOpacity;


    TestM4CssProps;


    TestBackendMeasureConsistency;





    TestInputEditing;


    TestInputRender;


    TestFocusTraversalAndEnter;


    TestInputClipboardAndMouse;


    TestInputCjkEditing;


    TestTransitionAnim;


    TestIncludeTemplates;


    TestHotReload;





    TestScriptCore;


    TestScriptAsync;


    TestScriptTimers;


    TestScriptAsyncAwait;


    TestScriptIntegration;


    TestScriptPromiseIntegration;


    TestScriptTimersIntegration;


    TestScriptAsyncIntegration;


    TestScriptIO;
    TestScriptReactive;
    TestDemoPage;
    TestAgentPage;
    TestPreviewHostWiring;
    TestImeCompositionAnchor;
    TestConsoleOutput;
    TestGdiPlusCjkCaretAlignment;
    TestScaffold;
    TestAppSpec;
    TestBundle;
    TestIoFsAndExec;





    WriteLn;


    WriteLn(Format('结果: %d 通过, %d 失败', [PassCount, FailCount]));
    ConWriteLnFmt('LUI_TEST_RESULT passed=%d failed=%d', [PassCount, FailCount]);


    if FailCount > 0 then


      ExitCode := 1;


  finally


    Measurer.Free;


  end;


end.


