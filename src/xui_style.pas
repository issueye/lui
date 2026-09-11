unit xui_style;

{$mode objfpc}{$H+}

{ 元素样式结构（M1：仅默认样式；M2 接入 CSS 解析与级联后由样式引擎填充）。 }

interface

uses
  SysUtils,
  xui_types;

type
  // 四边盒（margin/padding），M1 仅支持 px
  TXuiSides = record
    Left, Top, Right, Bottom: TXuiLength;
  end;

  TXuiStyle = class
  public
    Display: TXuiDisplay;
    Position: TXuiPosition;
    Width, Height: TXuiLength;
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
    procedure Assign(ASource: TXuiStyle);
    // 继承属性（颜色/字体）取自父样式，其余保持自身值
    procedure InheritTextFrom(ASource: TXuiStyle);
  end;

function SidesPx(AL, AT, AR, AB: Single): TXuiSides;
function DefaultStyleForTag(const ATag: string; AParentStyle: TXuiStyle): TXuiStyle;

implementation

function SidesPx(AL, AT, AR, AB: Single): TXuiSides;
begin
  Result.Left := XuiLengthPx(AL);
  Result.Top := XuiLengthPx(AT);
  Result.Right := XuiLengthPx(AR);
  Result.Bottom := XuiLengthPx(AB);
end;

procedure InitBase(AStyle: TXuiStyle);
begin
  AStyle.Display := xdispBlock;
  AStyle.Position := xposStatic;
  AStyle.Width := XuiLengthAuto;
  AStyle.Height := XuiLengthAuto;
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
end;

function DefaultStyleForTag(const ATag: string; AParentStyle: TXuiStyle): TXuiStyle;
begin
  Result := TXuiStyle.Create;
  InitBase(Result);

  // 继承父级文字样式（无父样式时保持默认）
  if AParentStyle <> nil then
    Result.InheritTextFrom(AParentStyle);

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
end;

procedure TXuiStyle.InheritTextFrom(ASource: TXuiStyle);
begin
  if ASource = nil then Exit;
  TextColor := ASource.TextColor;
  FontFamily := ASource.FontFamily;
  FontSize := ASource.FontSize;
  FontBold := ASource.FontBold;
  LineHeight := ASource.LineHeight;
  TextAlign := ASource.TextAlign;
end;

end.
