unit xui_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

{ lui 引擎基础类型：颜色、长度、对齐、脏标记。

  约定：
  - 颜色统一使用 TXuiColor（RGBA 四字节），A=0 表示完全透明；
  - 长度统一使用 TXuiLength（px / % / auto），布局阶段才解析为像素。 }

interface

uses
  SysUtils, Types;

type
  TXuiColor = record
    R, G, B, A: Byte;
  end;

  TXuiLengthKind = (xlkAuto, xlkPx, xlkPercent);

  TXuiLength = record
    Kind: TXuiLengthKind;
    Value: Single;
    function IsAuto: Boolean; inline;
    function Resolve(AFull: Single): Single; inline; // 解析为像素；auto 按 0
  end;

  TXuiTextAlign = (xtaLeft, xtaCenter, xtaRight);

  TXuiDisplay = (xdispBlock, xdispFlex, xdispNone);
  TXuiPosition = (xposStatic, xposRelative, xposAbsolute);

  // M3：flex 子集与盒约束
  TXuiFlexDirection = (xfdRow, xfdColumn);
  TXuiJustify = (xjcStart, xjcCenter, xjcEnd, xjcSpaceBetween, xjcSpaceAround);
  TXuiAlign = (xaiStart, xaiCenter, xaiEnd, xaiStretch);
  // R2/R3：visible = 不裁剪不滚动；hidden = 裁剪 + 可编程滚动（无滚动条，保持 v1 语义）；
  //        auto = 裁剪 + 滚动 + 按需显示滚动条；scroll = 裁剪 + 滚动 + 常显滚动条
  TXuiOverflow = (xovVisible, xovHidden, xovAuto, xovScroll);
  TXuiVisibility = (xvisVisible, xvisHidden);

  // 伪类状态（M2 仅用于选择器匹配；M4 接入交互状态机）
  TXuiPseudo = (xpHover, xpActive, xpFocus, xpDisabled);
  TXuiPseudoSet = set of TXuiPseudo;

  // 三级脏标记：样式 → 布局 → 绘制
  TXuiDirtyFlags = set of (xdStyle, xdLayout, xdPaint);

function XuiRGB(AR, AG, AB: Byte): TXuiColor; inline;
function XuiRGBA(AR, AG, AB, AA: Byte): TXuiColor; inline;
function XuiSameColor(const A, B: TXuiColor): Boolean; inline;
// 颜色混合：结果 = A*(1-ARatio) + B*ARatio（占位符/选区等需要与背景混色时用，两后端表现一致）
function XuiMixColor(const A, B: TXuiColor; ARatio: Single): TXuiColor;
function XuiHexColor(const S: string): TXuiColor; // '#rgb' / '#rrggbb'
function XuiLengthPx(AValue: Single): TXuiLength; inline;
function XuiLengthPercent(AValue: Single): TXuiLength; inline;
function XuiLengthAuto: TXuiLength; inline;

implementation

function XuiRGB(AR, AG, AB: Byte): TXuiColor;
begin
  Result.R := AR; Result.G := AG; Result.B := AB; Result.A := 255;
end;

function XuiRGBA(AR, AG, AB, AA: Byte): TXuiColor;
begin
  Result.R := AR; Result.G := AG; Result.B := AB; Result.A := AA;
end;

function XuiSameColor(const A, B: TXuiColor): Boolean;
begin
  Result := (A.R = B.R) and (A.G = B.G) and (A.B = B.B) and (A.A = B.A);
end;

function XuiHexColor(const S: string): TXuiColor;
var
  t: string;
  v: Int64;
begin
  Result := XuiRGB(0, 0, 0);
  t := Trim(S);
  if t = '' then
    Exit;
  if t[1] = '#' then
    t := Copy(t, 2, MaxInt);
  case Length(t) of
    3: t := Format('%s%s%s%s%s%s', [t[1], t[1], t[2], t[2], t[3], t[3]]);
    6: ;
  else
    Exit;
  end;
  if TryStrToInt64('$' + t, v) then
  begin
    Result.R := (v shr 16) and $FF;
    Result.G := (v shr 8) and $FF;
    Result.B := v and $FF;
    Result.A := 255;
  end;
end;

function XuiMixColor(const A, B: TXuiColor; ARatio: Single): TXuiColor;
begin
  if ARatio < 0 then ARatio := 0;
  if ARatio > 1 then ARatio := 1;
  Result.R := Round(A.R + (B.R - A.R) * ARatio);
  Result.G := Round(A.G + (B.G - A.G) * ARatio);
  Result.B := Round(A.B + (B.B - A.B) * ARatio);
  Result.A := Round(A.A + (B.A - A.A) * ARatio);
end;

function XuiLengthPx(AValue: Single): TXuiLength;
begin
  Result.Kind := xlkPx; Result.Value := AValue;
end;

function XuiLengthPercent(AValue: Single): TXuiLength;
begin
  Result.Kind := xlkPercent; Result.Value := AValue;
end;

function XuiLengthAuto: TXuiLength;
begin
  Result.Kind := xlkAuto; Result.Value := 0;
end;

{ TXuiLength }

function TXuiLength.IsAuto: Boolean;
begin
  Result := Kind = xlkAuto;
end;

function TXuiLength.Resolve(AFull: Single): Single;
begin
  case Kind of
    xlkPx: Result := Value;
    xlkPercent: Result := Value * AFull / 100.0;
  else
    Result := 0;
  end;
end;

end.
