unit xui_text;

{$mode objfpc}{$H+}

{ 文本排版（M3）：按可用宽度断行。
  测量通过回调注入（生产环境绑渲染器，测试注入假测量器），本单元不依赖 LCL。

  断行规则（v1 子集）：
  - CJK 字符（含全角标点、假名、谚文）可逐字断行；
  - 拉丁词按空白断行，空白折叠为单个空格且不留在行尾；
  - 单个不可断单元超过可用宽度时允许溢出（不硬切词）。 }

interface

uses
  SysUtils, Types, Math,
  xui_types, xui_style;

type
  // 文本测量回调：由引擎绑定到渲染器（测试可注入假测量）
  TXuiMeasureFunc = function(const AText: string; AStyle: TXuiStyle): TSize of object;
  TXuiLineArray = array of string;

// 行高（像素）= FontSize * LineHeight
function LineHeightPx(AStyle: TXuiStyle): Single;

// ---- UTF-8 码点工具（M5 输入框复用：光标按码点移动/删除）----

// 前导字节对应的 UTF-8 序列长度（非法字节按 1 处理）
function Utf8SeqLen(AByte: Byte): Integer;
// 取 S[AByteIndex]（1 基）起一个码点，ALen 返回字节数
function Utf8CodeAt(const S: string; AByteIndex: Integer; out ALen: Integer): LongWord;
// 下一码点起点（0 基字节偏移；已到末尾返回 Length(S)）
function Utf8NextIndex(const S: string; AByteIndex: Integer): Integer;
// 上一码点起点（0 基字节偏移；到头部返回 0）
function Utf8PrevIndex(const S: string; AByteIndex: Integer): Integer;
// 码点个数
function Utf8Length(const S: string): Integer;

// 按 AMaxWidth 断行；返回文本总高（行数 × 行高）
function WrapText(const AText: string; AStyle: TXuiStyle; AMaxWidth: Single;
  AMeasure: TXuiMeasureFunc; out ALines: TXuiLineArray): Single;

// 断行后的尺寸：宽 = 最长行宽，高 = 总高
function MeasureWrapped(const AText: string; AStyle: TXuiStyle;
  AMaxWidth: Single; AMeasure: TXuiMeasureFunc): TSize;

implementation

type
  TBreakUnit = record
    Text: string;
    IsSpace: Boolean;
  end;
  TBreakUnitArray = array of TBreakUnit;

function Utf8SeqLen(AByte: Byte): Integer;
begin
  if AByte < $80 then Result := 1
  else if (AByte and $E0) = $C0 then Result := 2
  else if (AByte and $F0) = $E0 then Result := 3
  else if (AByte and $F8) = $F0 then Result := 4
  else Result := 1;
end;

// 取 S[AByteIndex] 起一个 UTF-8 字符的码点，ALen 返回字节数
function Utf8CodeAt(const S: string; AByteIndex: Integer; out ALen: Integer): LongWord;
var
  b: Byte;
  i: Integer;
begin
  b := Byte(S[AByteIndex]);
  ALen := Utf8SeqLen(b);
  if AByteIndex + ALen - 1 > Length(S) then
    ALen := 1;
  if ALen = 1 then
    Exit(b);
  Result := b and ($FF shr (ALen + 1));
  for i := 1 to ALen - 1 do
    Result := (Result shl 6) or (Byte(S[AByteIndex + i]) and $3F);
end;

function Utf8NextIndex(const S: string; AByteIndex: Integer): Integer;
var
  len: Integer;
begin
  if AByteIndex >= Length(S) then
    Exit(Length(S));
  Utf8CodeAt(S, AByteIndex + 1, len);
  Result := AByteIndex + len;
  if Result > Length(S) then
    Result := Length(S);
end;

// 上一码点起点（0 基字节偏移；到头部返回 0）
function Utf8PrevIndex(const S: string; AByteIndex: Integer): Integer;
var
  i: Integer;
begin
  i := AByteIndex;
  while (i > 1) and ((Byte(S[i]) and $C0) = $80) do
    Dec(i);
  Result := i - 1;
  if Result < 0 then
    Result := 0;
end;

function Utf8Length(const S: string): Integer;
var
  i, len: Integer;
begin
  Result := 0;
  i := 1;
  while i <= Length(S) do
  begin
    Utf8CodeAt(S, i, len);
    Inc(i, len);
    Inc(Result);
  end;
end;

function IsCjkCode(ACode: LongWord): Boolean;
begin
  Result :=
    ((ACode >= $2E80) and (ACode <= $9FFF)) or   // CJK 部首/标点/假名/汉字
    ((ACode >= $A960) and (ACode <= $A97F)) or   // 谚文扩展
    ((ACode >= $AC00) and (ACode <= $D7AF)) or   // 谚文音节
    ((ACode >= $F900) and (ACode <= $FAFF)) or   // 兼容汉字
    ((ACode >= $FE30) and (ACode <= $FE4F)) or   // CJK 兼容形式
    ((ACode >= $FF00) and (ACode <= $FF60)) or   // 全角字符
    ((ACode >= $FFE0) and (ACode <= $FFE6));     // 全角符号
end;

procedure SplitUnits(const AText: string; out AUnits: TBreakUnitArray);
var
  count, i, len, start: Integer;
  code: LongWord;

  procedure AddUnit(const S: string; ASpace: Boolean);
  begin
    if count >= Length(AUnits) then
      SetLength(AUnits, count * 2 + 16);
    AUnits[count].Text := S;
    AUnits[count].IsSpace := ASpace;
    Inc(count);
  end;

begin
  count := 0;
  SetLength(AUnits, 0);
  i := 1;
  while i <= Length(AText) do
  begin
    code := Utf8CodeAt(AText, i, len);
    if (code = 32) or ((code >= 9) and (code <= 13)) then
    begin
      // 连续空白折叠为一个空格单元
      while (i <= Length(AText)) and (Byte(AText[i]) <= 32) do
        Inc(i);
      AddUnit(' ', True);
    end
    else if IsCjkCode(code) then
    begin
      AddUnit(Copy(AText, i, len), False);
      Inc(i, len);
    end
    else
    begin
      // 拉丁词：延续到空白或 CJK 之前
      start := i;
      while i <= Length(AText) do
      begin
        code := Utf8CodeAt(AText, i, len);
        if (code <= 32) or IsCjkCode(code) then
          Break;
        Inc(i, len);
      end;
      AddUnit(Copy(AText, start, i - start), False);
    end;
  end;
  SetLength(AUnits, count);
end;

function UnitWidth(const AUnit: string; AStyle: TXuiStyle;
  AMeasure: TXuiMeasureFunc): Single;
begin
  if AMeasure <> nil then
    Result := AMeasure(AUnit, AStyle).cx
  else
    Result := Length(AUnit) * AStyle.FontSize * 0.6;
end;

function LineHeightPx(AStyle: TXuiStyle): Single;
begin
  if (AStyle <> nil) and (AStyle.LineHeight > 0) then
    Result := AStyle.FontSize * AStyle.LineHeight
  else if AStyle <> nil then
    Result := AStyle.FontSize * 1.4
  else
    Result := 0;
end;

// R7：按可用宽度把一行截断并追加省略号（逐码点收缩，保证不切多字节字符）
function EllipsizeLine(const AText: string; AStyle: TXuiStyle;
  AMaxWidth: Single; AMeasure: TXuiMeasureFunc): string;
var
  i, len: Integer;
  prefix: string;
begin
  Result := '…';
  if UnitWidth(Result, AStyle, AMeasure) > AMaxWidth then
  begin
    Result := '';
    Exit;
  end;
  i := 1;
  while i <= Length(AText) do
  begin
    Utf8CodeAt(AText, i, len);
    Inc(i, len);
    prefix := Copy(AText, 1, i - 1);
    if UnitWidth(prefix + '…', AStyle, AMeasure) > AMaxWidth then
      Break;
    Result := prefix + '…';
  end;
end;

function WrapText(const AText: string; AStyle: TXuiStyle; AMaxWidth: Single;
  AMeasure: TXuiMeasureFunc; out ALines: TXuiLineArray): Single;
var
  units: TBreakUnitArray;
  i, count: Integer;
  cur: string;
  curW, w: Single;

  procedure AddLine(const ALine: string);
  begin
    if ALine = '' then
      Exit;
    if count >= Length(ALines) then
      SetLength(ALines, count * 2 + 8);
    ALines[count] := ALine;
    Inc(count);
  end;

begin
  count := 0;
  SetLength(ALines, 0);
  if (AText = '') or (AMaxWidth <= 0) then
  begin
    if AText <> '' then
    begin
      SetLength(ALines, 1);
      ALines[0] := AText;
      Exit(LineHeightPx(AStyle));
    end;
    Exit(0);
  end;

  // R7：white-space:nowrap 不做软换行，整段作为一行，溢出交给 text-overflow / clip
  if AStyle.WhiteSpace = xwsNoWrap then
  begin
    SetLength(ALines, 1);
    ALines[0] := TrimRight(AText);
    if (AStyle.TextOverflow = xtoEllipsis) and
       (UnitWidth(ALines[0], AStyle, AMeasure) > AMaxWidth) then
      ALines[0] := EllipsizeLine(ALines[0], AStyle, AMaxWidth, AMeasure);
    Exit(LineHeightPx(AStyle));
  end;

  SplitUnits(AText, units);
  cur := '';
  curW := 0;
  for i := 0 to High(units) do
  begin
    if units[i].IsSpace and (cur = '') then
      Continue; // 行首空白丢弃
    w := UnitWidth(units[i].Text, AStyle, AMeasure);
    if cur = '' then
    begin
      cur := units[i].Text;
      curW := w;
      Continue;
    end;
    if curW + w <= AMaxWidth then
    begin
      cur := cur + units[i].Text;
      curW := curW + w;
      Continue;
    end;
    AddLine(TrimRight(cur));
    if units[i].IsSpace then
    begin
      cur := '';
      curW := 0;
    end
    else
    begin
      cur := units[i].Text;
      curW := w;
    end;
  end;
  AddLine(TrimRight(cur));

  SetLength(ALines, count);

  // R7：text-overflow:ellipsis —— 任何仍超宽的行（含不可断长串）截断并加省略号
  if AStyle.TextOverflow = xtoEllipsis then
    for i := 0 to count - 1 do
      if UnitWidth(ALines[i], AStyle, AMeasure) > AMaxWidth then
        ALines[i] := EllipsizeLine(ALines[i], AStyle, AMaxWidth, AMeasure);

  Result := count * LineHeightPx(AStyle);
end;

function MeasureWrapped(const AText: string; AStyle: TXuiStyle;
  AMaxWidth: Single; AMeasure: TXuiMeasureFunc): TSize;
var
  lines: TXuiLineArray;
  i: Integer;
  h: Single;
begin
  h := WrapText(AText, AStyle, AMaxWidth, AMeasure, lines);
  Result.cx := 0;
  for i := 0 to High(lines) do
    Result.cx := Round(Max(Single(Result.cx), UnitWidth(lines[i], AStyle, AMeasure)));
  Result.cy := Round(h);
end;

end.
