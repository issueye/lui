program runtests;

{$mode objfpc}{$H+}

{ lui M1 单元测试（控制台）：XML 解析 → 节点树、默认样式、块级布局。
  约定：全部通过退出码 0，存在失败输出 FAIL 明细并退出码 1。 }

uses
  Classes, SysUtils, Types, Math, Contnrs,
  xui_types, xui_style, xui_dom, xui_xml, xui_layout,
  xui_css_token, xui_css_parser, xui_css_match;

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

type
  // 假测量器：每字符 8px 宽，行高固定 20px
  TFakeMeasurer = class
  public
    function Measure(const AText: string; AStyle: TXuiStyle): TSize;
  end;

function TFakeMeasurer.Measure(const AText: string; AStyle: TXuiStyle): TSize;
begin
  Result.cx := Length(AText) * 8;
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

begin
  FailCount := 0;
  PassCount := 0;
  Measurer := TFakeMeasurer.Create;
  try
    WriteLn('=== lui M1 单元测试 ===');

    TestXmlParsing;
    TestDefaultStyles;
    TestBlockLayout;
    TestCssParser;

    TestCssCascadeOnNode;
    TestThemeSkin;

    WriteLn;
    WriteLn(Format('结果: %d 通过, %d 失败', [PassCount, FailCount]));
    if FailCount > 0 then
      ExitCode := 1;
  finally
    Measurer.Free;
  end;
end.
