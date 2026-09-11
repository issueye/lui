unit xui_css_match;

{$mode objfpc}{$H+}

{ CSS 匹配与级联（v1）：
  - 选择器匹配：后代(空格) / 子代(>) 组合器，:hover :active :focus :disabled 伪类
  - 级联：规则按 (特异性, 源顺序) 升序应用；内联 style 介于普通与 !important 之间
  - 值解析：颜色(#/rgb()/rgba()/命名/transparent)、长度(px/%/em/auto)、简写展开
  本单元不依赖 LCL，便于单元测试。 }

interface

uses
  Classes, SysUtils, StrUtils, Contnrs, Math,
  xui_types, xui_style, xui_dom, xui_css_parser;

// 命中节点是否匹配整条选择器链
function MatchSelector(ANode: TXuiNode; ASelector: TCssSelector): Boolean;

// 颜色/长度解析（供声明应用与测试）
function ParseCssColor(const AValue: string): TXuiColor;
function ParseCssLength(const AValue: string; AEmBase: Single): TXuiLength;
function IsCssNamedColor(const AWord: string): Boolean;

// 把一条声明写入样式（em 相对值以 AEmBase 为参照）
procedure ApplyDeclaration(AStyle: TXuiStyle; const AProp, AValue: string;
  AEmBase: Single);

// 对整棵树计算样式：先默认样式+继承，再应用命中的 CSS 规则与内联样式
procedure ComputeDocumentStyles(ADoc: TXuiDocument; ASheets: TObjectList);

implementation

type
  TCssAppliedDecl = record
    Decl: TCssDeclaration;
    SpecA, SpecB, SpecC: Integer;
    Order: Integer;
  end;

function PseudoToSet(const AName: string; out AMember: TXuiPseudo): Boolean;
begin
  Result := True;
  if AName = 'hover' then AMember := xpHover
  else if AName = 'active' then AMember := xpActive
  else if AName = 'focus' then AMember := xpFocus
  else if AName = 'disabled' then AMember := xpDisabled
  else Result := False;
end;

function MatchCompound(ANode: TXuiNode; APart: TCssSelectorPart): Boolean;
var
  i: Integer;
  pseudo: TXuiPseudo;
begin
  if (APart.Tag <> '') and (APart.Tag <> '*') and (ANode.Tag <> APart.Tag) then
    Exit(False);
  if (APart.Id <> '') and (ANode.Id <> APart.Id) then
    Exit(False);
  for i := 0 to APart.Classes.Count - 1 do
    if not ANode.HasClass(APart.Classes[i]) then
      Exit(False);
  for i := 0 to APart.Pseudos.Count - 1 do
  begin
    if not PseudoToSet(APart.Pseudos[i], pseudo) then
      Exit(False); // 不认识的伪类一律不匹配
    if not (pseudo in ANode.Pseudos) then
      Exit(False);
  end;
  Result := True;
end;

// parts[0..AIndex] 是否以 ANode 为末端全部匹配（右向左回溯）
function MatchPartsFrom(ANode: TXuiNode; ASelector: TCssSelector;
  AIndex: Integer): Boolean;
var
  part: TCssSelectorPart;
  anc: TXuiNode;
begin
  part := TCssSelectorPart(ASelector.Parts[AIndex]);
  if not MatchCompound(ANode, part) then
    Exit(False);
  if AIndex = 0 then
    Exit(True);

  case part.Combinator of
    ccChild:
    begin
      if ANode.Parent = nil then
        Exit(False);
      Result := MatchPartsFrom(ANode.Parent, ASelector, AIndex - 1);
    end;
    ccDescendant:
    begin
      anc := ANode.Parent;
      while anc <> nil do
      begin
        if MatchPartsFrom(anc, ASelector, AIndex - 1) then
          Exit(True);
        anc := anc.Parent;
      end;
      Result := False;
    end;
  else
    Result := False;
  end;
end;

function MatchSelector(ANode: TXuiNode; ASelector: TCssSelector): Boolean;
begin
  if (ASelector = nil) or (ASelector.Parts.Count = 0) then
    Exit(False);
  Result := MatchPartsFrom(ANode, ASelector, ASelector.Parts.Count - 1);
end;

function IsCssNamedColor(const AWord: string): Boolean;
const
  Names: array[0..22] of string = (
    'white', 'black', 'red', 'green', 'lime', 'blue', 'navy', 'silver',
    'gray', 'grey', 'maroon', 'olive', 'teal', 'aqua', 'cyan', 'fuchsia',
    'magenta', 'orange', 'pink', 'brown', 'gold', 'yellow', 'purple');
var
  i: Integer;
begin
  Result := False;
  for i := Low(Names) to High(Names) do
    if SameText(AWord, Names[i]) then
      Exit(True);
end;

function ParseCssColor(const AValue: string): TXuiColor;
var
  s, inner: string;
  parts: TStringList;
  r, g, b: Integer;
  a: Double;
  code: Integer;
begin
  s := StringReplace(LowerCase(Trim(AValue)), ' ', '', [rfReplaceAll]);
  Result := XuiRGB(0, 0, 0);

  if s = '' then Exit;
  if s = 'transparent' then begin Result := XuiRGBA(0, 0, 0, 0); Exit; end;
  if s[1] = '#' then begin Result := XuiHexColor(s); Exit; end;

  if (Copy(s, 1, 5) = 'rgba(') and (s[Length(s)] = ')') then
  begin
    inner := Copy(s, 6, Length(s) - 6);
    parts := TStringList.Create;
    try
      parts.CommaText := inner;
      if parts.Count = 4 then
      begin
        Val(parts[0], r, code); Val(parts[1], g, code); Val(parts[2], b, code);
        Val(parts[3], a, code);
        Result := XuiRGBA(Byte(r), Byte(g), Byte(b), Byte(Round(a * 255)));
      end;
    finally
      parts.Free;
    end;
    Exit;
  end;

  if (Copy(s, 1, 4) = 'rgb(') and (s[Length(s)] = ')') then
  begin
    inner := Copy(s, 5, Length(s) - 5);
    parts := TStringList.Create;
    try
      parts.CommaText := inner;
      if parts.Count = 3 then
      begin
        Val(parts[0], r, code); Val(parts[1], g, code); Val(parts[2], b, code);
        Result := XuiRGB(Byte(r), Byte(g), Byte(b));
      end;
    finally
      parts.Free;
    end;
    Exit;
  end;

  // 常用命名色
  if s = 'white' then Result := XuiRGB(255, 255, 255)
  else if s = 'black' then Result := XuiRGB(0, 0, 0)
  else if s = 'red' then Result := XuiRGB(255, 0, 0)
  else if s = 'green' then Result := XuiRGB(0, 128, 0)
  else if s = 'lime' then Result := XuiRGB(0, 255, 0)
  else if s = 'blue' then Result := XuiRGB(0, 0, 255)
  else if s = 'navy' then Result := XuiRGB(0, 0, 128)
  else if s = 'silver' then Result := XuiRGB(192, 192, 192)
  else if (s = 'gray') or (s = 'grey') then Result := XuiRGB(128, 128, 128)
  else if s = 'maroon' then Result := XuiRGB(128, 0, 0)
  else if s = 'olive' then Result := XuiRGB(128, 128, 0)
  else if s = 'teal' then Result := XuiRGB(0, 128, 128)
  else if (s = 'aqua') or (s = 'cyan') then Result := XuiRGB(0, 255, 255)
  else if (s = 'fuchsia') or (s = 'magenta') then Result := XuiRGB(255, 0, 255)
  else if s = 'orange' then Result := XuiRGB(255, 165, 0)
  else if s = 'pink' then Result := XuiRGB(255, 192, 203)
  else if s = 'brown' then Result := XuiRGB(165, 42, 42)
  else if s = 'gold' then Result := XuiRGB(255, 215, 0)
  else if s = 'yellow' then Result := XuiRGB(255, 255, 0)
  else if s = 'purple' then Result := XuiRGB(128, 0, 128);
end;

function ParseCssLength(const AValue: string; AEmBase: Single): TXuiLength;
var
  s: string;
  v: Double;
  code: Integer;
begin
  s := LowerCase(Trim(AValue));
  if s = 'auto' then
    Exit(XuiLengthAuto);
  if s = '' then
    Exit(XuiLengthPx(0));

  if Copy(s, Length(s) - 1, 2) = 'px' then
    s := Copy(s, 1, Length(s) - 2)
  else if Copy(s, Length(s) - 1, 2) = 'em' then
  begin
    s := Copy(s, 1, Length(s) - 2);
    Val(s, v, code);
    if code = 0 then
      Exit(XuiLengthPx(v * AEmBase));
    Exit(XuiLengthPx(0));
  end
  else if s[Length(s)] = '%' then
  begin
    s := Copy(s, 1, Length(s) - 1);
    Val(s, v, code);
    if code = 0 then
      Exit(XuiLengthPercent(v));
    Exit(XuiLengthPx(0));
  end;

  Val(s, v, code);
  if code = 0 then
    Result := XuiLengthPx(v)
  else
    Result := XuiLengthPx(0);
end;

procedure SplitValueWords(const AValue: string; AList: TStringList);
var
  part, w: string;
begin
  AList.Clear;
  for part in SplitString(Trim(AValue), ' ') do
  begin
    w := Trim(part);
    if w <> '' then
      AList.Add(w);
  end;
end;

function TryParseColorWord(const AWord: string; out AColor: TXuiColor): Boolean;
begin
  AColor := ParseCssColor(AWord);
  // ParseCssColor 对未知输入返回黑色；用特征判断是否是颜色词
  Result := (AWord <> '') and
    ((AWord[1] = '#') or (Copy(LowerCase(AWord), 1, 4) = 'rgb(') or
     (Copy(LowerCase(AWord), 1, 5) = 'rgba(') or
     (LowerCase(AWord) = 'transparent') or IsCssNamedColor(AWord));
end;

procedure ApplySidesShorthand(var ASides: TXuiSides; const AValue: string;
  AEmBase: Single);
var
  words: TStringList;
  i: Integer;
  lens: array[0..3] of TXuiLength;
begin
  words := TStringList.Create;
  try
    SplitValueWords(AValue, words);
    if words.Count = 0 then Exit;
    for i := 0 to Min(3, words.Count - 1) do
      lens[i] := ParseCssLength(words[i], AEmBase);
    case Min(4, words.Count) of
      1: begin
        ASides.Top := lens[0]; ASides.Right := lens[0];
        ASides.Bottom := lens[0]; ASides.Left := lens[0];
      end;
      2: begin
        ASides.Top := lens[0]; ASides.Bottom := lens[0];
        ASides.Right := lens[1]; ASides.Left := lens[1];
      end;
      3: begin
        ASides.Top := lens[0]; ASides.Right := lens[1];
        ASides.Bottom := lens[2]; ASides.Left := lens[1];
      end;
      4: begin
        ASides.Top := lens[0]; ASides.Right := lens[1];
        ASides.Bottom := lens[2]; ASides.Left := lens[3];
      end;
    end;
  finally
    words.Free;
  end;
end;

procedure ApplyDeclaration(AStyle: TXuiStyle; const AProp, AValue: string;
  AEmBase: Single);
var
  prop, vl, first: string;
  words: TStringList;
  i: Integer;
  c: TXuiColor;
begin
  prop := LowerCase(Trim(AProp));
  vl := LowerCase(Trim(AValue));

  if prop = 'display' then
  begin
    if vl = 'none' then AStyle.Display := xdispNone
    else if vl = 'flex' then AStyle.Display := xdispFlex
    else AStyle.Display := xdispBlock;
    Exit;
  end;

  if prop = 'width' then
  begin
    AStyle.Width := ParseCssLength(AValue, AEmBase); Exit;
  end;
  if prop = 'height' then
  begin
    AStyle.Height := ParseCssLength(AValue, AEmBase); Exit;
  end;

  if prop = 'margin' then
  begin
    ApplySidesShorthand(AStyle.Margin, AValue, AEmBase); Exit;
  end;
  if prop = 'margin-top' then begin AStyle.Margin.Top := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'margin-right' then begin AStyle.Margin.Right := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'margin-bottom' then begin AStyle.Margin.Bottom := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'margin-left' then begin AStyle.Margin.Left := ParseCssLength(AValue, AEmBase); Exit; end;

  if prop = 'padding' then
  begin
    ApplySidesShorthand(AStyle.Padding, AValue, AEmBase); Exit;
  end;
  if prop = 'padding-top' then begin AStyle.Padding.Top := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'padding-right' then begin AStyle.Padding.Right := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'padding-bottom' then begin AStyle.Padding.Bottom := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'padding-left' then begin AStyle.Padding.Left := ParseCssLength(AValue, AEmBase); Exit; end;

  if prop = 'border' then
  begin
    words := TStringList.Create;
    try
      SplitValueWords(AValue, words);
      for i := 0 to words.Count - 1 do
      begin
        first := words[i];
        if (first = 'none') or (first = 'hidden') then
          AStyle.BorderWidth := 0
        else if (first = 'solid') or (first = 'dotted') or (first = 'dashed') then
          Continue // 仅支持实线
        else if TryParseColorWord(first, c) then
          AStyle.BorderColor := c
        else
        begin
          // 宽度（如 1px）
          AStyle.BorderWidth := ParseCssLength(first, AEmBase).Value;
        end;
      end;
    finally
      words.Free;
    end;
    Exit;
  end;
  if prop = 'border-width' then
  begin
    AStyle.BorderWidth := ParseCssLength(AValue, AEmBase).Value; Exit;
  end;
  if prop = 'border-color' then
  begin
    AStyle.BorderColor := ParseCssColor(AValue); Exit;
  end;
  if prop = 'border-style' then
  begin
    if (vl = 'none') or (vl = 'hidden') then
      AStyle.BorderWidth := 0;
    Exit;
  end;

  if (prop = 'background-color') then
  begin
    AStyle.BgColor := ParseCssColor(AValue); Exit;
  end;
  if (prop = 'background') then
  begin
    if vl = 'none' then
      AStyle.BgColor := XuiRGBA(0, 0, 0, 0)
    else
      AStyle.BgColor := ParseCssColor(AValue);
    Exit;
  end;

  if prop = 'color' then
  begin
    AStyle.TextColor := ParseCssColor(AValue); Exit;
  end;

  if prop = 'font-family' then
  begin
    first := Trim(AValue);
    i := Pos(',', first);
    if i > 0 then
      first := Copy(first, 1, i - 1);
    first := StringReplace(first, '"', '', [rfReplaceAll]);
    first := StringReplace(first, '''', '', [rfReplaceAll]);
    if Trim(first) <> '' then
      AStyle.FontFamily := Trim(first);
    Exit;
  end;

  if prop = 'font-size' then
  begin
    // em/% 相对父字号（AEmBase）
    AStyle.FontSize := ParseCssLength(AValue, AEmBase).Value; Exit;
  end;

  if prop = 'font-weight' then
  begin
    if vl = 'bold' then
      AStyle.FontBold := True
    else if (vl = 'normal') or (vl = '400') then
      AStyle.FontBold := False
    else
    begin
      i := StrToIntDef(vl, 400);
      AStyle.FontBold := i >= 600;
    end;
    Exit;
  end;

  if prop = 'text-align' then
  begin
    if vl = 'center' then AStyle.TextAlign := xtaCenter
    else if vl = 'right' then AStyle.TextAlign := xtaRight
    else AStyle.TextAlign := xtaLeft;
    Exit;
  end;

  if prop = 'line-height' then
  begin
    // 纯数字为倍数；带单位 px 换算为倍数
    words := TStringList.Create;
    try
      SplitValueWords(AValue, words);
      if words.Count = 1 then
      begin
        vl := words[0];
        if vl <> '' then
        begin
          if vl[Length(vl)] = '%' then
          begin
            SetLength(vl, Length(vl) - 1);
            AStyle.LineHeight := StrToFloatDef(vl, 140) / 100;
          end
          else if (Pos('px', vl) > 0) and (AStyle.FontSize > 0) then
          begin
            SetLength(vl, Length(vl) - 2);
            AStyle.LineHeight := StrToFloatDef(vl, 0) / AStyle.FontSize;
          end
          else
            AStyle.LineHeight := StrToFloatDef(vl, 1.4);
        end;
      end;
    finally
      words.Free;
    end;
    Exit;
  end;

  // 以下属性接受但不处理（M3/M4 实现）：position / z-index / overflow /
  // opacity / border-radius / box-sizing / visibility / min-width / min-height
end;

procedure ComputeNodeStyles(ANode: TXuiNode; ASheets: TObjectList;
  var AOrder: Integer; AParentStyle: TXuiStyle);
var
  sheetIdx, ruleIdx, declIdx, i: Integer;
  sheet: TCssStyleSheet;
  rule: TCssRule;
  refs: array of TCssAppliedDecl;
  refCount: Integer;
  style: TXuiStyle;
  swapped: Boolean;
  tmp: TCssAppliedDecl;
  inlineSheet: TCssStyleSheet;
  inlineDecls: TCssDeclArray;
begin
  // 收集命中的声明
  refCount := 0;
  SetLength(refs, 0);
  for sheetIdx := 0 to ASheets.Count - 1 do
  begin
    sheet := TCssStyleSheet(ASheets[sheetIdx]);
    for ruleIdx := 0 to sheet.RuleCount - 1 do
    begin
      rule := sheet[ruleIdx];
      if not MatchSelector(ANode, rule.Selector) then
        Continue;
      for declIdx := 0 to High(rule.Declarations) do
      begin
        if refCount >= Length(refs) then
          SetLength(refs, refCount * 2 + 16);
        refs[refCount].Decl := rule.Declarations[declIdx];
        refs[refCount].SpecA := rule.SpecA;
        refs[refCount].SpecB := rule.SpecB;
        refs[refCount].SpecC := rule.SpecC;
        refs[refCount].Order := AOrder;
        Inc(AOrder);
        Inc(refCount);
      end;
    end;
  end;

  // 排序：(SpecA, SpecB, SpecC, Order) 升序
  repeat
    swapped := False;
    for i := 0 to refCount - 2 do
    begin
      if (refs[i].SpecA > refs[i+1].SpecA) or
         ((refs[i].SpecA = refs[i+1].SpecA) and (refs[i].SpecB > refs[i+1].SpecB)) or
         ((refs[i].SpecA = refs[i+1].SpecA) and (refs[i].SpecB = refs[i+1].SpecB) and
          (refs[i].SpecC > refs[i+1].SpecC)) or
         ((refs[i].SpecA = refs[i+1].SpecA) and (refs[i].SpecB = refs[i+1].SpecB) and
          (refs[i].SpecC = refs[i+1].SpecC) and (refs[i].Order > refs[i+1].Order)) then
      begin
        tmp := refs[i]; refs[i] := refs[i+1]; refs[i+1] := tmp;
        swapped := True;
      end;
    end;
  until not swapped;

  // 默认样式 + 继承
  style := DefaultStyleForTag(ANode.Tag, AParentStyle);

  // 1) 普通规则（em 基准取当前字号：font-size 先应用则后续 em 相对它，符合 CSS 直觉）
  for i := 0 to refCount - 1 do
    if not refs[i].Decl.Important then
      ApplyDeclaration(style, refs[i].Decl.Prop, refs[i].Decl.Value, style.FontSize);

  // 2) 内联 style=""（介于普通规则与 !important 之间）
  if ANode.HasAttribute('style') then
  begin
    inlineSheet := TCssStyleSheet.Create;
    try
      inlineDecls := inlineSheet.ParseDeclarations(ANode.AttributeValue('style'));
      for i := 0 to High(inlineDecls) do
        ApplyDeclaration(style, inlineDecls[i].Prop, inlineDecls[i].Value,
          style.FontSize);
    finally
      inlineSheet.Free;
    end;
  end;

  // 3) !important 规则（优先级最高）
  for i := 0 to refCount - 1 do
    if refs[i].Decl.Important then
      ApplyDeclaration(style, refs[i].Decl.Prop, refs[i].Decl.Value, style.FontSize);

  ANode.Style.Free;
  ANode.Style := style;

  for i := 0 to ANode.Count - 1 do
    ComputeNodeStyles(ANode[i], ASheets, AOrder, style);
end;

procedure ComputeDocumentStyles(ADoc: TXuiDocument; ASheets: TObjectList);
var
  order: Integer;
begin
  if (ADoc = nil) or (ADoc.Root = nil) then
    Exit;
  order := 0;
  ComputeNodeStyles(ADoc.Root, ASheets, order, nil);
end;

end.
