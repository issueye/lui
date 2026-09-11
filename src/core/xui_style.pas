unit xui_style;

{$mode objfpc}{$H+}

{ 元素样式结构：M1 默认样式 → M2 由 CSS 级联填充 → M3 扩展 flex/定位/尺寸约束。 }

interface

uses
  SysUtils,
  xui_types;

type
  // 四边盒（margin/padding/inset），支持 px/%/auto
  TXuiSides = record
    Left, Top, Right, Bottom: TXuiLength;
  end;

  // ---- 过渡动画（M5）：可动画属性白名单 + 时间函数 ----
  TXuiAnimProp = (xapOpacity, xapBgColor, xapTextColor, xapBorderColor, xapBorderRadius);
  TXuiAnimPropSet = set of TXuiAnimProp;
  TXuiTimingFunction = (xtfLinear, xtfEase, xtfEaseIn, xtfEaseOut, xtfEaseInOut);

const
  XuiAllAnimProps = [xapOpacity, xapBgColor, xapTextColor, xapBorderColor, xapBorderRadius];
  // 属性名 ↔ 枚举（解析/测试用；顺序与 TXuiAnimProp 一致）
  XuiAnimPropNames: array[TXuiAnimProp] of string = (
    'opacity', 'background-color', 'color', 'border-color', 'border-radius');

function XuiAnimPropByName(const AName: string; out AProp: TXuiAnimProp): Boolean;
// 时间函数求值（t ∈ [0,1] → 缓动后的进度）
function XuiTimingEval(AKind: TXuiTimingFunction; AT: Single): Single;
function XuiTimingByName(const AName: string; out AKind: TXuiTimingFunction): Boolean;

type
  TXuiStyle = class
  public
    Display: TXuiDisplay;
    Position: TXuiPosition;
    Width, Height: TXuiLength;
    MinWidth, MinHeight: TXuiLength;
    Inset: TXuiSides;            // top/right/bottom/left；auto 表示未指定
    Margin: TXuiSides;
    Padding: TXuiSides;
    BorderWidth: Single;
    BorderColor: TXuiColor;
    BgColor: TXuiColor;          // A=0 为透明
    TextColor: TXuiColor;
    FontFamily: string;
    FontSize: Single;           // px
    FontBold: Boolean;
    TextAlign: TXuiTextAlign;
    LineHeight: Single;         // 倍数，行高 = FontSize * LineHeight
    // M3：flex 子集 + 盒约束 + 定位
    FlexDirection: TXuiFlexDirection;
    JustifyContent: TXuiJustify;
    AlignItems: TXuiAlign;
    FlexGrow: Single;
    FlexBasis: TXuiLength;
    RowGap, ColumnGap: TXuiLength;
    Overflow: TXuiOverflow;
    Visibility: TXuiVisibility;
    ZIndex: Integer;
    BorderRadius: Single;       // px，0 = 直角
    Opacity: Single;            // 0..1，绘制时乘到颜色的 alpha（近似实现）
    // M5 过渡：声明了过渡的属性在计算值变化时按 Duration 插值（白名单见 XuiAnimProp）
    TransitionProps: TXuiAnimPropSet;
    TransitionDuration: Single; // 秒
    TransitionDelay: Single;    // 秒
    TransitionTiming: TXuiTimingFunction;
    procedure Assign(ASource: TXuiStyle);
    // 继承属性（颜色/字体 + visibility）取自父样式，其余保持自身值
    procedure InheritFrom(ASource: TXuiStyle);
  end;

function SidesPx(AL, AT, AR, AB: Single): TXuiSides;
function SidesAuto: TXuiSides;
function DefaultStyleForTag(const ATag: string; AParentStyle: TXuiStyle): TXuiStyle;

implementation

function XuiAnimPropByName(const AName: string; out AProp: TXuiAnimProp): Boolean;
var
  p: TXuiAnimProp;
  s: string;
begin
  s := LowerCase(Trim(AName));
  for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
    if XuiAnimPropNames[p] = s then
    begin
      AProp := p;
      Exit(True);
    end;
  Result := False;
end;

function XuiTimingByName(const AName: string; out AKind: TXuiTimingFunction): Boolean;
var
  s: string;
begin
  s := LowerCase(Trim(AName));
  if s = 'linear' then AKind := xtfLinear
  else if s = 'ease' then AKind := xtfEase
  else if s = 'ease-in' then AKind := xtfEaseIn
  else if s = 'ease-out' then AKind := xtfEaseOut
  else if s = 'ease-in-out' then AKind := xtfEaseInOut
  else
    Exit(False);
  Result := True;
end;

// 三次贝塞尔（与 CSS 同名曲线一致）：x1,y1,x2,y2；先解 x(t)=AT，再取 y(t)
function CubicBezier(AX1, AY1, AX2, AY2, AT: Single): Single;
var
  lo, hi, mid, xt: Single;
  i: Integer;

  function SampleX(AU: Single): Single;
  begin
    Result := 3 * (1 - AU) * (1 - AU) * AU * AX1 +
      3 * (1 - AU) * AU * AU * AX2 + AU * AU * AU;
  end;

  function SampleY(AU: Single): Single;
  begin
    Result := 3 * (1 - AU) * (1 - AU) * AU * AY1 +
      3 * (1 - AU) * AU * AU * AY2 + AU * AU * AU;
  end;

begin
  if AT <= 0 then
    Exit(0);
  if AT >= 1 then
    Exit(1);
  lo := 0;
  hi := 1;
  mid := AT;
  for i := 1 to 24 do
  begin
    mid := (lo + hi) / 2;
    xt := SampleX(mid);
    if xt < AT then
      lo := mid
    else
      hi := mid;
  end;
  Result := SampleY((lo + hi) / 2);
end;

function XuiTimingEval(AKind: TXuiTimingFunction; AT: Single): Single;
begin
  if AT <= 0 then
    Exit(0);
  if AT >= 1 then
    Exit(1);
  case AKind of
    xtfLinear: Result := AT;
    xtfEase: Result := CubicBezier(0.25, 0.1, 0.25, 1, AT);
    xtfEaseIn: Result := CubicBezier(0.42, 0, 1, 1, AT);
    xtfEaseOut: Result := CubicBezier(0, 0, 0.58, 1, AT);
    xtfEaseInOut: Result := CubicBezier(0.42, 0, 0.58, 1, AT);
  else
    Result := AT;
  end;
end;

function SidesPx(AL, AT, AR, AB: Single): TXuiSides;
begin
  Result.Left := XuiLengthPx(AL);
  Result.Top := XuiLengthPx(AT);
  Result.Right := XuiLengthPx(AR);
  Result.Bottom := XuiLengthPx(AB);
end;

function SidesAuto: TXuiSides;
begin
  Result.Left := XuiLengthAuto;
  Result.Top := XuiLengthAuto;
  Result.Right := XuiLengthAuto;
  Result.Bottom := XuiLengthAuto;
end;

procedure InitBase(AStyle: TXuiStyle);
begin
  AStyle.Display := xdispBlock;
  AStyle.Position := xposStatic;
  AStyle.Width := XuiLengthAuto;
  AStyle.Height := XuiLengthAuto;
  AStyle.MinWidth := XuiLengthAuto;
  AStyle.MinHeight := XuiLengthAuto;
  AStyle.Inset := SidesAuto;
  AStyle.Margin := SidesPx(0, 0, 0, 0);
  AStyle.Padding := SidesPx(0, 0, 0, 0);
  AStyle.BorderWidth := 0;
  AStyle.BorderColor := XuiRGB(200, 200, 200);
  AStyle.BgColor := XuiRGBA(255, 255, 255, 0);
  AStyle.TextColor := XuiRGB(34, 34, 34);
  AStyle.FontFamily := 'Microsoft YaHei UI';
  AStyle.FontSize := 14;
  AStyle.FontBold := False;
  AStyle.TextAlign := xtaLeft;
  AStyle.LineHeight := 1.4;
  AStyle.FlexDirection := xfdRow;
  AStyle.JustifyContent := xjcStart;
  AStyle.AlignItems := xaiStretch;
  AStyle.FlexGrow := 0;
  AStyle.FlexBasis := XuiLengthAuto;
  AStyle.RowGap := XuiLengthPx(0);
  AStyle.ColumnGap := XuiLengthPx(0);
  AStyle.Overflow := xovVisible;
  AStyle.Visibility := xvisVisible;
  AStyle.ZIndex := 0;
  AStyle.BorderRadius := 0;
  AStyle.Opacity := 1;
  AStyle.TransitionProps := [];
  AStyle.TransitionDuration := 0;
  AStyle.TransitionDelay := 0;
  AStyle.TransitionTiming := xtfEase;
end;

function DefaultStyleForTag(const ATag: string; AParentStyle: TXuiStyle): TXuiStyle;
begin
  Result := TXuiStyle.Create;
  InitBase(Result);

  // 继承父级文字样式（无父样式时保持默认）
  if AParentStyle <> nil then
    Result.InheritFrom(AParentStyle);

  if ATag = 'window' then
  begin
    Result.BgColor := XuiRGB(255, 255, 255);
    Result.Padding := SidesPx(0, 0, 0, 0);
  end
  else if (ATag = 'button') then
  begin
    Result.BgColor := XuiRGB(74, 125, 240);
    Result.TextColor := XuiRGB(255, 255, 255);
    Result.TextAlign := xtaCenter;
    Result.Height := XuiLengthPx(32);
    Result.Padding := SidesPx(12, 0, 12, 0);
    Result.Margin := SidesPx(0, 6, 0, 0);
  end
  else if (ATag = 'input') then
  begin
    Result.BgColor := XuiRGB(255, 255, 255);
    Result.BorderWidth := 1;
    Result.Height := XuiLengthPx(28);
    Result.Padding := SidesPx(6, 0, 6, 0);
    Result.Margin := SidesPx(0, 2, 0, 0);
  end
  else if ATag = 'label' then
  begin
    Result.Margin := SidesPx(0, 2, 0, 0);
  end
  else if ATag = 'image' then
  begin
    // M4 实现
  end
  else
  begin
    // panel / div / 未知标签：纯容器
  end;
end;

{ TXuiStyle }

procedure TXuiStyle.Assign(ASource: TXuiStyle);
begin
  if ASource = nil then Exit;
  Display := ASource.Display;
  Position := ASource.Position;
  Width := ASource.Width;
  Height := ASource.Height;
  MinWidth := ASource.MinWidth;
  MinHeight := ASource.MinHeight;
  Inset := ASource.Inset;
  Margin := ASource.Margin;
  Padding := ASource.Padding;
  BorderWidth := ASource.BorderWidth;
  BorderColor := ASource.BorderColor;
  BgColor := ASource.BgColor;
  TextColor := ASource.TextColor;
  FontFamily := ASource.FontFamily;
  FontSize := ASource.FontSize;
  FontBold := ASource.FontBold;
  TextAlign := ASource.TextAlign;
  LineHeight := ASource.LineHeight;
  FlexDirection := ASource.FlexDirection;
  JustifyContent := ASource.JustifyContent;
  AlignItems := ASource.AlignItems;
  FlexGrow := ASource.FlexGrow;
  FlexBasis := ASource.FlexBasis;
  RowGap := ASource.RowGap;
  ColumnGap := ASource.ColumnGap;
  Overflow := ASource.Overflow;
  Visibility := ASource.Visibility;
  ZIndex := ASource.ZIndex;
  BorderRadius := ASource.BorderRadius;
  Opacity := ASource.Opacity;
  TransitionProps := ASource.TransitionProps;
  TransitionDuration := ASource.TransitionDuration;
  TransitionDelay := ASource.TransitionDelay;
  TransitionTiming := ASource.TransitionTiming;
end;

procedure TXuiStyle.InheritFrom(ASource: TXuiStyle);
begin
  if ASource = nil then Exit;
  TextColor := ASource.TextColor;
  FontFamily := ASource.FontFamily;
  FontSize := ASource.FontSize;
  FontBold := ASource.FontBold;
  LineHeight := ASource.LineHeight;
  TextAlign := ASource.TextAlign;
  Visibility := ASource.Visibility;
end;

end.
