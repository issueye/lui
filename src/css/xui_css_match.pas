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

// transition: [all|<属性列表（逗号分隔，逗号后可留空格）>] <时长> [<时间函数>] [<延迟>]
// v1 仅单条规格（不支持逗号分列的多组 transition）
procedure ApplyTransition(AStyle: TXuiStyle; const AValue: string);
var
  value, propPart: string;
  tokens: TStringList;
  i, sp, timeCount: Integer;
  props: TXuiAnimPropSet;
  prop: TXuiAnimProp;
  timing: TXuiTimingFunction;
  times: array[0..1] of Single;

  function ParseTime(const AToken: string; out ASeconds: Single): Boolean;
  var
    t: string;
  begin
    t := LowerCase(Trim(AToken));
    ASeconds := -1;
    if (t = '') or (t[Length(t)] <> 's') then
      Exit(False);
    if (Length(t) > 2) and (t[Length(t) - 1] = 'm') then
      ASeconds := StrToFloatDef(Copy(t, 1, Length(t) - 2), -1) / 1000
    else
      ASeconds := StrToFloatDef(Copy(t, 1, Length(t) - 1), -1);
    Result := ASeconds >= 0;
  end;

begin
  value := Trim(AValue);
  AStyle.TransitionProps := [];
  AStyle.TransitionDuration := 0;
  AStyle.TransitionDelay := 0;
  AStyle.TransitionTiming := xtfEase;
  if value = '' then
    Exit;

  value := StringReplace(value, ', ', ',', [rfReplaceAll]);
  tokens := TStringList.Create;
  try
    ExtractStrings([' ', #9], [], PChar(value), tokens);
    if tokens.Count = 0 then
      Exit;

    propPart := LowerCase(tokens[0]);
    props := [];
    if propPart = 'all' then
      props := XuiAllAnimProps
    else
      while propPart <> '' do
      begin
        sp := Pos(',', propPart);
        if sp = 0 then
        begin
          if XuiAnimPropByName(propPart, prop) then
            Include(props, prop);
          Break;
        end;
        if XuiAnimPropByName(Copy(propPart, 1, sp - 1), prop) then
          Include(props, prop);
        propPart := Copy(propPart, sp + 1, Length(propPart));
      end;

    timeCount := 0;
    for i := 1 to tokens.Count - 1 do
    begin
      if (timeCount <= 1) and ParseTime(tokens[i], times[timeCount]) then
        Inc(timeCount)
      else if XuiTimingByName(tokens[i], timing) then
        AStyle.TransitionTiming := timing;
    end;
    AStyle.TransitionProps := props;
    if timeCount >= 1 then
      AStyle.TransitionDuration := times[0];
    if timeCount >= 2 then
      AStyle.TransitionDelay := times[1];
  finally
    tokens.Free;
  end;
end;

// CSS 自定义属性（--x）：只登记为变量，不参与普通属性应用
function IsCustomProperty(const AProp: string): Boolean;
begin
  Result := Pos('--', Trim(AProp)) = 1;
end;

// 值 token 重建会插入空格（'var ( --x )'）：把括号相邻空格规整掉再替换
function NormalizeParenSpacing(const S: string): string;
begin
  Result := StringReplace(S, ' (', '(', [rfReplaceAll]);
  Result := StringReplace(Result, '( ', '(', [rfReplaceAll]);
  Result := StringReplace(Result, ' )', ')', [rfReplaceAll]);
end;

// 大小写无关地查找 'var(' 的位置（0 = 未找到）
function FindVarStart(const S: string): Integer;
var
  k: Integer;
begin
  Result := 0;
  for k := 1 to Length(S) - 3 do
    if (UpCase(S[k]) = 'V') and (UpCase(S[k + 1]) = 'A') and
       (UpCase(S[k + 2]) = 'R') and (S[k + 3] = '(') then
      Exit(k);
end;

// 大小写无关地判断值里是否出现 var（token 重建后可能是 'var ('）
function ContainsVar(const S: string): Boolean;
var
  k: Integer;
begin
  Result := False;
  for k := 1 to Length(S) - 2 do
    if (UpCase(S[k]) = 'V') and (UpCase(S[k + 1]) = 'A') and
       (UpCase(S[k + 2]) = 'R') then
      Exit(True);
end;

// var(--x[, fallback]) 文本替换：以节点的变量表求值（值内可再含 var，最多解 4 层；
// 未定义且无回退时替换为空串 → 该声明随后被忽略）
function ResolveCssVars(const AValue: string; AVars: TStringList): string;
var
  pass, p, q, depth, k, commaPos: Integer;
  inner, name, fb, sub: string;
begin
  Result := AValue;
  if (AVars = nil) or (not ContainsVar(Result)) then
    Exit;
  Result := NormalizeParenSpacing(Result);
  for pass := 1 to 4 do
  begin
    p := FindVarStart(Result);
    if p = 0 then
      Break;
    depth := 0;
    q := 0;
    for k := p + 3 to Length(Result) do
    begin
      if Result[k] = '(' then
        Inc(depth)
      else if Result[k] = ')' then
      begin
        Dec(depth);
        if depth = 0 then
        begin
          q := k;
          Break;
        end;
      end;
    end;
    if q = 0 then
      Break;   // 括号不配对：原样保留（交由属性解析忽略）
    inner := Copy(Result, p + 4, q - p - 4);
    commaPos := Pos(',', inner);
    if commaPos > 0 then
    begin
      name := Trim(Copy(inner, 1, commaPos - 1));
      fb := Trim(Copy(inner, commaPos + 1, MaxInt));
    end
    else
    begin
      name := Trim(inner);
      fb := '';
    end;
    sub := AVars.Values[name];
    if sub = '' then
      sub := fb;
    Result := Copy(Result, 1, p - 1) + sub + Copy(Result, q + 1, MaxInt);
    if sub = '' then
      Break;
  end;
end;

// 变量表写入（同名后者胜；供级联按 普通 → 内联 → !important 顺序调用）
procedure SetCssVar(AVars: TStringList; const AProp, AValue: string);
begin
  if (AVars = nil) or (Trim(AProp) = '') then
    Exit;
  AVars.Values[Trim(AProp)] := Trim(AValue);
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

  if prop = 'position' then
  begin
    if vl = 'relative' then AStyle.Position := xposRelative
    else if vl = 'absolute' then AStyle.Position := xposAbsolute
    else AStyle.Position := xposStatic;
    Exit;
  end;

  if prop = 'top' then begin AStyle.Inset.Top := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'right' then begin AStyle.Inset.Right := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'bottom' then begin AStyle.Inset.Bottom := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'left' then begin AStyle.Inset.Left := ParseCssLength(AValue, AEmBase); Exit; end;

  if prop = 'z-index' then
  begin
    AStyle.ZIndex := StrToIntDef(vl, 0); Exit;
  end;

  if prop = 'overflow' then
  begin
    if (vl = 'hidden') or (vl = 'scroll') or (vl = 'auto') then
      AStyle.Overflow := xovHidden
    else
      AStyle.Overflow := xovVisible;
    Exit;
  end;

  if prop = 'visibility' then
  begin
    if (vl = 'hidden') or (vl = 'collapse') then
      AStyle.Visibility := xvisHidden
    else
      AStyle.Visibility := xvisVisible;
    Exit;
  end;

  if prop = 'min-width' then begin AStyle.MinWidth := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'min-height' then begin AStyle.MinHeight := ParseCssLength(AValue, AEmBase); Exit; end;

  if prop = 'flex-direction' then
  begin
    // row-reverse / column-reverse 不在 v1 子集内：保持原值
    if vl = 'column' then AStyle.FlexDirection := xfdColumn
    else if vl = 'row' then AStyle.FlexDirection := xfdRow;
    Exit;
  end;

  if prop = 'justify-content' then
  begin
    if vl = 'center' then AStyle.JustifyContent := xjcCenter
    else if (vl = 'flex-end') or (vl = 'end') then AStyle.JustifyContent := xjcEnd
    else if vl = 'space-between' then AStyle.JustifyContent := xjcSpaceBetween
    else if vl = 'space-around' then AStyle.JustifyContent := xjcSpaceAround
    else AStyle.JustifyContent := xjcStart;
    Exit;
  end;

  if prop = 'align-items' then
  begin
    if vl = 'center' then AStyle.AlignItems := xaiCenter
    else if (vl = 'flex-end') or (vl = 'end') then AStyle.AlignItems := xaiEnd
    else if vl = 'stretch' then AStyle.AlignItems := xaiStretch
    else AStyle.AlignItems := xaiStart;
    Exit;
  end;

  if prop = 'gap' then
  begin
    words := TStringList.Create;
    try
      SplitValueWords(AValue, words);
      if words.Count = 1 then
      begin
        AStyle.RowGap := ParseCssLength(words[0], AEmBase);
        AStyle.ColumnGap := AStyle.RowGap;
      end
      else if words.Count >= 2 then
      begin
        AStyle.RowGap := ParseCssLength(words[0], AEmBase);
        AStyle.ColumnGap := ParseCssLength(words[1], AEmBase);
      end;
    finally
      words.Free;
    end;
    Exit;
  end;
  if prop = 'row-gap' then begin AStyle.RowGap := ParseCssLength(AValue, AEmBase); Exit; end;
  if prop = 'column-gap' then begin AStyle.ColumnGap := ParseCssLength(AValue, AEmBase); Exit; end;

  if prop = 'flex-grow' then
  begin
    AStyle.FlexGrow := StrToFloatDef(vl, AStyle.FlexGrow); Exit;
  end;

  if prop = 'flex-basis' then
  begin
    AStyle.FlexBasis := ParseCssLength(AValue, AEmBase); Exit;
  end;

  if prop = 'flex' then
  begin
    // 简写：单个数值 → flex-grow=n + flex-basis=0（等价 CSS 的 flex: n，占满剩余空间）
    words := TStringList.Create;
    try
      SplitValueWords(AValue, words);
      if words.Count = 1 then
      begin
        AStyle.FlexGrow := StrToFloatDef(words[0], AStyle.FlexGrow);
        AStyle.FlexBasis := XuiLengthPx(0);
      end;
    finally
      words.Free;
    end;
    Exit;
  end;

  if prop = 'border-radius' then
  begin
    // v1 仅单值（px/em）；百分比不支持，按 px 解析
    AStyle.BorderRadius := Max(0, ParseCssLength(AValue, AEmBase).Value); Exit;
  end;

  if prop = 'opacity' then
  begin
    AStyle.Opacity := Min(1, Max(0, StrToFloatDef(vl, AStyle.Opacity))); Exit;
  end;

  if prop = 'transition' then
  begin
    ApplyTransition(AStyle, AValue); Exit;
  end;

  // 仍未实现（M5 后续）：box-sizing(content-box) / max-width / max-height / letter-spacing
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

  // 默认样式 + 继承（变量表亦随继承而来）
  style := DefaultStyleForTag(ANode.Tag, AParentStyle);

  // 内联 style="" 只解析一次：变量收集与应用共用
  inlineSheet := nil;
  inlineDecls := nil;
  if ANode.HasAttribute('style') then
  begin
    inlineSheet := TCssStyleSheet.Create;
    inlineDecls := inlineSheet.ParseDeclarations(ANode.AttributeValue('style'));
  end;
  try
    // 0) 变量收集（--x）：按级联优先级 普通 → 内联 → !important，同名后者胜
    for i := 0 to refCount - 1 do
      if (not refs[i].Decl.Important) and IsCustomProperty(refs[i].Decl.Prop) then
        SetCssVar(style.Vars, refs[i].Decl.Prop, refs[i].Decl.Value);
    for i := 0 to High(inlineDecls) do
      if IsCustomProperty(inlineDecls[i].Prop) then
        SetCssVar(style.Vars, inlineDecls[i].Prop, inlineDecls[i].Value);
    for i := 0 to refCount - 1 do
      if refs[i].Decl.Important and IsCustomProperty(refs[i].Decl.Prop) then
        SetCssVar(style.Vars, refs[i].Decl.Prop, refs[i].Decl.Value);

    // 1) 普通规则（em 基准取当前字号：font-size 先应用则后续 em 相对它，符合 CSS 直觉）
    for i := 0 to refCount - 1 do
      if (not refs[i].Decl.Important) and (not IsCustomProperty(refs[i].Decl.Prop)) then
        ApplyDeclaration(style, refs[i].Decl.Prop,
          ResolveCssVars(refs[i].Decl.Value, style.Vars), style.FontSize);

    // 2) 内联 style=""（介于普通规则与 !important 之间）
    for i := 0 to High(inlineDecls) do
      if not IsCustomProperty(inlineDecls[i].Prop) then
        ApplyDeclaration(style, inlineDecls[i].Prop,
          ResolveCssVars(inlineDecls[i].Value, style.Vars), style.FontSize);

    // 3) !important 规则（优先级最高）
    for i := 0 to refCount - 1 do
      if refs[i].Decl.Important and (not IsCustomProperty(refs[i].Decl.Prop)) then
        ApplyDeclaration(style, refs[i].Decl.Prop,
          ResolveCssVars(refs[i].Decl.Value, style.Vars), style.FontSize);
  finally
    inlineSheet.Free;
  end;

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
