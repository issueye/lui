unit xui_render;

{$mode objfpc}{$H+}

{ 渲染抽象（抽象类，M1 仅 GDI 实现；M4 增加 GDI+ 后端）。
  抽象类而非接口：避免引用计数管理，宿主控件直接持有实例。 }

interface

uses
  Classes, SysUtils, Types, Graphics, LCLType, LCLIntf, Math,
  xui_types, xui_style;

type
  // 渲染后端（xbAuto：Windows 上优先 GDI+，失败回退 GDI）
  TXuiBackend = (xbAuto, xbGdi, xbGdiPlus);

  TXuiCustomRenderer = class
  protected
    FOpacity: Single;
  public
    constructor Create; overload;
    // 绘制前由引擎指定画布（假渲染器可忽略）
    procedure SetCanvas(ACanvas: TCanvas); virtual;
    // 当前元素（含祖先连乘）的不透明度：后端把它乘到颜色 alpha 上
    procedure SetOpacity(AValue: Single); virtual;
    property Opacity: Single read FOpacity;
    procedure FillRect(const R: TRect; const AColor: TXuiColor); virtual; abstract;
    procedure FrameRect(const R: TRect; const AColor: TXuiColor; AWidth: Single); virtual; abstract;
    procedure DrawText(const R: TRect; const AText: string; AStyle: TXuiStyle); virtual; abstract;
    function MeasureText(const AText: string; AStyle: TXuiStyle): TSize; virtual; abstract;
    procedure PushClip(const R: TRect); virtual; abstract;
    procedure PopClip; virtual; abstract;
    function LineHeight(ACurrent: TXuiStyle): Single; virtual; abstract;
    // 圆角（M4）：默认退化为直角，后端可覆写（GDI 近似、GDI+ 抗锯齿）
    procedure FillRoundRect(const R: TRect; ARadius: Single; const AColor: TXuiColor); virtual;
    procedure FrameRoundRect(const R: TRect; ARadius, AWidth: Single;
      const AColor: TXuiColor); virtual;
  end;

  { TGdiRenderer — 基于 LCL TCanvas（GDI）的实现。画布由宿主在绘制前指定。 }
  TGdiRenderer = class(TXuiCustomRenderer)
  private
    FCanvas: TCanvas;
    procedure ApplyFont(AStyle: TXuiStyle);
  public
    constructor Create(ACanvas: TCanvas); overload;
    property Canvas: TCanvas read FCanvas write FCanvas;
    procedure SetCanvas(ACanvas: TCanvas); override;
    procedure FillRect(const R: TRect; const AColor: TXuiColor); override;
    procedure FrameRect(const R: TRect; const AColor: TXuiColor; AWidth: Single); override;
    procedure DrawText(const R: TRect; const AText: string; AStyle: TXuiStyle); override;
    function MeasureText(const AText: string; AStyle: TXuiStyle): TSize; override;
    procedure PushClip(const R: TRect); override;
    procedure PopClip; override;
    function LineHeight(ACurrent: TXuiStyle): Single; override;
    procedure FillRoundRect(const R: TRect; ARadius: Single; const AColor: TXuiColor); override;
    procedure FrameRoundRect(const R: TRect; ARadius, AWidth: Single;
      const AColor: TXuiColor); override;
  end;

function XuiColorToTColor(const C: TXuiColor): TColor; inline;

implementation

function XuiColorToTColor(const C: TXuiColor): TColor;
begin
  // LCL TColor 为 $00BBGGRR
  Result := TColor(C.R or (C.G shl 8) or (C.B shl 16));
end;

{ TGdiRenderer }

constructor TGdiRenderer.Create(ACanvas: TCanvas);
begin
  inherited Create;
  FCanvas := ACanvas;
end;

constructor TXuiCustomRenderer.Create;
begin
  inherited Create;
  FOpacity := 1;
end;

procedure TXuiCustomRenderer.SetCanvas(ACanvas: TCanvas);
begin
  // 默认：无画布概念的渲染器无需实现
end;

procedure TXuiCustomRenderer.SetOpacity(AValue: Single);
begin
  FOpacity := AValue;
end;

procedure TXuiCustomRenderer.FillRoundRect(const R: TRect; ARadius: Single;
  const AColor: TXuiColor);
begin
  // 默认退化：直角填充
  FillRect(R, AColor);
end;

procedure TXuiCustomRenderer.FrameRoundRect(const R: TRect; ARadius, AWidth: Single;
  const AColor: TXuiColor);
begin
  FrameRect(R, AColor, AWidth);
end;

procedure TGdiRenderer.SetCanvas(ACanvas: TCanvas);
begin
  FCanvas := ACanvas;
end;

procedure TGdiRenderer.ApplyFont(AStyle: TXuiStyle);
begin
  FCanvas.Font.Name := AStyle.FontFamily;
  FCanvas.Font.Height := -Round(AStyle.FontSize); // 负值 = 像素高
  if AStyle.FontBold then
    FCanvas.Font.Style := FCanvas.Font.Style + [fsBold]
  else
    FCanvas.Font.Style := FCanvas.Font.Style - [fsBold];
end;

procedure TGdiRenderer.FillRect(const R: TRect; const AColor: TXuiColor);
begin
  // GDI 无 alpha 通道：仅跳过完全透明（opacity 的视觉效果需 GDI+ 后端）
  if (AColor.A = 0) or (FOpacity <= 0.01) then
    Exit;
  FCanvas.Brush.Style := bsSolid;
  FCanvas.Brush.Color := XuiColorToTColor(AColor);
  FCanvas.FillRect(R);
end;

procedure TGdiRenderer.FrameRect(const R: TRect; const AColor: TXuiColor; AWidth: Single);
var
  w: Integer;
begin
  if (AColor.A = 0) or (FOpacity <= 0.01) then
    Exit;
  w := Max(1, Round(AWidth));
  FCanvas.Pen.Style := psSolid;
  FCanvas.Pen.Width := w;
  FCanvas.Pen.Color := XuiColorToTColor(AColor);
  FCanvas.Brush.Style := bsClear;
  FCanvas.Rectangle(R.Left, R.Top, R.Right, R.Bottom);
  FCanvas.Pen.Width := 1;
end;

procedure TGdiRenderer.DrawText(const R: TRect; const AText: string; AStyle: TXuiStyle);
var
  sz: TSize;
  x, y: Integer;
  alignX: Integer;
begin
  if FOpacity <= 0.01 then
    Exit;
  ApplyFont(AStyle);
  sz := MeasureText(AText, AStyle);

  case AStyle.TextAlign of
    xtaCenter: alignX := (R.Right - R.Left - sz.cx) div 2;
    xtaRight:  alignX := (R.Right - R.Left - sz.cx);
  else
    alignX := 0;
  end;
  x := R.Left + Max(0, alignX);

  // M1：单行文本在内容盒内垂直居中（label 自适应高度时无差异，button 正好居中）
  y := R.Top + Max(0, (R.Bottom - R.Top - sz.cy) div 2);

  FCanvas.Font.Color := XuiColorToTColor(AStyle.TextColor);
  FCanvas.Brush.Style := bsClear;
  FCanvas.TextOut(x, y, AText);
end;

function TGdiRenderer.MeasureText(const AText: string; AStyle: TXuiStyle): TSize;
begin
  ApplyFont(AStyle);
  Result.cx := FCanvas.TextWidth(AText);
  Result.cy := FCanvas.TextHeight(AText);
end;

procedure TGdiRenderer.PushClip(const R: TRect);
begin
  SaveDC(FCanvas.Handle);
  IntersectClipRect(FCanvas.Handle, R.Left, R.Top, R.Right, R.Bottom);
end;

procedure TGdiRenderer.PopClip;
begin
  RestoreDC(FCanvas.Handle, -1);
end;

function TGdiRenderer.LineHeight(ACurrent: TXuiStyle): Single;
begin
  Result := ACurrent.FontSize * ACurrent.LineHeight;
end;

procedure TGdiRenderer.FillRoundRect(const R: TRect; ARadius: Single;
  const AColor: TXuiColor);
var
  rad: Integer;
begin
  if (AColor.A = 0) or (FOpacity <= 0.01) then
    Exit;
  rad := Round(ARadius);
  if rad <= 0 then
  begin
    FillRect(R, AColor);
    Exit;
  end;
  // GDI 的 RoundRect：圆角无抗锯齿（观感由 GDI+ 后端补齐）
  FCanvas.Brush.Style := bsSolid;
  FCanvas.Brush.Color := XuiColorToTColor(AColor);
  FCanvas.Pen.Style := psClear;
  FCanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, rad * 2, rad * 2);
  FCanvas.Pen.Style := psSolid;
end;

procedure TGdiRenderer.FrameRoundRect(const R: TRect; ARadius, AWidth: Single;
  const AColor: TXuiColor);
var
  rad, w: Integer;
begin
  if (AColor.A = 0) or (FOpacity <= 0.01) then
    Exit;
  rad := Round(ARadius);
  if rad <= 0 then
  begin
    FrameRect(R, AColor, AWidth);
    Exit;
  end;
  w := Max(1, Round(AWidth));
  FCanvas.Brush.Style := bsClear;
  FCanvas.Pen.Style := psSolid;
  FCanvas.Pen.Width := w;
  FCanvas.Pen.Color := XuiColorToTColor(AColor);
  FCanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, rad * 2, rad * 2);
  FCanvas.Pen.Width := 1;
end;

end.
