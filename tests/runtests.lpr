program runtests;

{$mode objfpc}{$H+}

{ lui M1 单元测试（控制台）：XML 解析 → 节点树、默认样式、块级布局。
  约定：全部通过退出码 0，存在失败输出 FAIL 明细并退出码 1。 }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Classes, SysUtils, Types, Math, Contnrs, Graphics, LCLType,
  xui_types, xui_style, xui_dom, xui_xml, xui_layout, xui_text,
  xui_css_token, xui_css_parser, xui_css_match, xui_render, xui_engine,
  xui_events, xui_widget, xui_input
  {$IFDEF WINDOWS}, xui_render_gdiplus{$ENDIF};

var
  FailCount, PassCount: Integer;

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
begin
  Result.cx := Utf8CharCount(AText) * 8;
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

procedure TestXmlParsing;
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

procedure TestDefaultStyles;
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

procedure TestCssParser;
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

procedure TestCssApplyAndCascade;
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

procedure TestThemeSkin;
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

procedure TestCssCascadeOnNode;
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

procedure TestBlockLayout;
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

{ ---------- M3：假渲染器与辅助 ---------- }

type
  TFakeRenderer = class(TXuiCustomRenderer)
  private
    FKinds: TStringList;  // 调用序列：fill / frame / roundfill / roundframe / text / push / pop
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

{ ---------- M3：flex ---------- }

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

{ ---------- M5：热重载 ---------- }

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
    WriteTestFile(cssFile, '#box { width:50px; height:20px; background-color:#00ff00; }');
    FileSetDate(cssFile, FileAge(cssFile) + 4); // 制造时间戳差异（FileAge 2 秒粒度）
    Check(engine.ReloadChangedFiles, 'CSS 变化触发重载');
    DrawEngine(engine);
    Check(engine.Document.FindElementById('box').Style.BgColor.G = $FF, '重载后新样式生效');
    Check(engine.Document.FindElementById('runtime') <> nil, 'CSS 重载保留运行时 DOM');

    // include 依赖变化：整体重建
    WriteTestFile(partFile, '<label id="part" text="P2"/>');
    FileSetDate(partFile, FileAge(partFile) + 4);
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

begin
  Measurer := TFakeMeasurer.Create;
  try
    WriteLn('=== lui 单元测试 ===');

    TestXmlParsing;
    TestDefaultStyles;
    TestBlockLayout;
    TestCssParser;
    TestCssApplyAndCascade;

    TestCssCascadeOnNode;
    TestThemeSkin;

    TestFlexRow;
    TestFlexJustify;
    TestFlexGrow;
    TestFlexAlign;
    TestFlexColumn;
    TestTextWrap;
    TestAutoMarginAndMinSize;
    TestPositioning;
    TestM3CssProps;
    TestEngineRendering;
    TestRttiProbe;

    TestHitTest;
    TestPseudoAndClick;
    TestEventBindingFallback;
    TestScroll;
    TestRuntimeDom;
    TestRoundedAndOpacity;
    TestM4CssProps;
    TestBackendMeasureConsistency;

    TestInputEditing;
    TestInputRender;
    TestFocusTraversalAndEnter;
    TestInputClipboardAndMouse;
    TestTransitionAnim;
    TestIncludeTemplates;
    TestHotReload;

    WriteLn;
    WriteLn(Format('结果: %d 通过, %d 失败', [PassCount, FailCount]));
    if FailCount > 0 then
      ExitCode := 1;
  finally
    Measurer.Free;
  end;
end.
