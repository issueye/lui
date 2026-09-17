unit xui_render;

{$mode objfpc}{$H+}

{ 渲染抽象（抽象类，M1 仅 GDI 实现；M4 增加 GDI+ 后端）。
  抽象类而非接口：避免引用计数管理，宿主控件直接持有实例。 }

interface

uses
  Classes, SysUtils, Types, Graphics, LCLType, LCLIntf, Math, LazUTF8,
  xui_types, xui_style;

type
  // 渲染后端（xbAuto：Windows 上优先 GDI+，失败回退 GDI）
  TXuiBackend = (xbAuto, xbGdi, xbGdiPlus);

  TXuiPointF = record
    X, Y: Single;
  end;
  PXuiPointF = ^TXuiPointF;
  TXuiPointFArray = array of TXuiPointF;

  TXuiPathCmdKind = (pckMoveTo, pckLineTo, pckBezierTo, pckClose);
  TXuiPathCmd = record
    Kind: TXuiPathCmdKind;
    P1, P2, P3: TXuiPointF;
  end;
  TXuiPathCmdArray = array of TXuiPathCmd;

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
    // 矢量路径渲染（SVG 支持）：支持平滑贝塞尔、线段与闭合路径
    procedure RenderPath(const ACmds: TXuiPathCmdArray; const AFill, AStroke: TXuiColor;
      AStrokeWidth: Single); virtual;
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
    procedure RenderPath(const ACmds: TXuiPathCmdArray; const AFill, AStroke: TXuiColor;
      AStrokeWidth: Single); override;
  end;

function XuiPointF(AX, AY: Single): TXuiPointF; inline;
function XuiColorToTColor(const C: TXuiColor): TColor; inline;

implementation

function XuiPointF(AX, AY: Single): TXuiPointF;
begin
  Result.X := AX;
  Result.Y := AY;
end;

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

procedure TXuiCustomRenderer.RenderPath(const ACmds: TXuiPathCmdArray;
  const AFill, AStroke: TXuiColor; AStrokeWidth: Single);
begin
  // 默认空实现，由派生后端（TGdiRenderer / TGdiPlusRenderer）实现
end;

procedure TGdiRenderer.SetCanvas(ACanvas: TCanvas);
begin
  FCanvas := ACanvas;
end;

function GdiResolveFontFamily(const ACandidates: string): string;
var
  commaPos: Integer;
  item, s: string;
begin
  if Trim(ACandidates) = '' then
    Exit('Microsoft YaHei UI');
  s := ACandidates;
  while s <> '' do
  begin
    commaPos := Pos(',', s);
    if commaPos > 0 then
    begin
      item := Trim(Copy(s, 1, commaPos - 1));
      s := Trim(Copy(s, commaPos + 1, Length(s)));
    end
    else
    begin
      item := Trim(s);
      s := '';
    end;
    item := StringReplace(item, '"', '', [rfReplaceAll]);
    item := StringReplace(item, '''', '', [rfReplaceAll]);
    item := Trim(item);
    if (item <> '') and
       (not SameText(item, 'sans-serif')) and
       (not SameText(item, 'serif')) and
       (not SameText(item, 'monospace')) and
       (not SameText(item, 'system-ui')) then
      Exit(item);
  end;
  Result := 'Microsoft YaHei UI';
end;

procedure TGdiRenderer.ApplyFont(AStyle: TXuiStyle);
begin
  FCanvas.Font.Name := GdiResolveFontFamily(AStyle.FontFamily);
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
  x, y, cx, i: Integer;
  ch: string;
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

  // R7：letter-spacing —— GDI 没有可移植的字距开关，这里逐字绘制并自己推进字距，
  // 与 MeasureText 的“宽度 + 字距×(字数-1)”保持同一口径。
  if (AStyle.LetterSpacing <> 0) and (AText <> '') then
  begin
    cx := x;
    for i := 1 to UTF8Length(AText) do
    begin
      ch := UTF8Copy(AText, i, 1);
      FCanvas.TextOut(cx, y, ch);
      cx := cx + FCanvas.TextWidth(ch) + Round(AStyle.LetterSpacing);
    end;
  end
  else
    FCanvas.TextOut(x, y, AText);
end;

function TGdiRenderer.MeasureText(const AText: string; AStyle: TXuiStyle): TSize;
var
  n: Integer;
begin
  ApplyFont(AStyle);
  Result.cx := FCanvas.TextWidth(AText);
  Result.cy := FCanvas.TextHeight(AText);
  if (AStyle <> nil) and (AStyle.LetterSpacing <> 0) and (AText <> '') then
  begin
    n := UTF8Length(AText);
    if n > 1 then
      // 两套后端统一口径：字距 × (字数-1) 后取整（与断行累加保持同量级）
      Result.cx := Result.cx + Round(AStyle.LetterSpacing * (n - 1));
  end;
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

procedure TGdiRenderer.RenderPath(const ACmds: TXuiPathCmdArray;
  const AFill, AStroke: TXuiColor; AStrokeWidth: Single);
var
  i, step: Integer;
  cmd: TXuiPathCmd;
  curPt, pStart: TXuiPointF;
  pts: array of TPoint;
  ptCount: Integer;
  t, u, tt, uu, uuu, ttt: Single;
  bx, by: Single;

  procedure AddPoint(const P: TXuiPointF);
  begin
    Inc(ptCount);
    SetLength(pts, ptCount);
    pts[ptCount - 1] := Point(Round(P.X), Round(P.Y));
  end;

  procedure FlushSubPath(IsClosed: Boolean);
  begin
    if ptCount < 2 then
    begin
      ptCount := 0;
      SetLength(pts, 0);
      Exit;
    end;
    // 填充
    if (AFill.A > 0) and (FOpacity > 0.01) then
    begin
      FCanvas.Brush.Style := bsSolid;
      FCanvas.Brush.Color := XuiColorToTColor(AFill);
      FCanvas.Pen.Style := psClear;
      FCanvas.Polygon(pts);
    end;
    // 描边
    if (AStroke.A > 0) and (FOpacity > 0.01) and (AStrokeWidth > 0.01) then
    begin
      FCanvas.Brush.Style := bsClear;
      FCanvas.Pen.Style := psSolid;
      FCanvas.Pen.Width := Max(1, Round(AStrokeWidth));
      FCanvas.Pen.Color := XuiColorToTColor(AStroke);
      if IsClosed then
        FCanvas.Polygon(pts)
      else
        FCanvas.Polyline(pts);
    end;
    ptCount := 0;
    SetLength(pts, 0);
  end;

begin
  if Length(ACmds) = 0 then
    Exit;
  if FOpacity <= 0.01 then
    Exit;

  ptCount := 0;
  SetLength(pts, 0);
  curPt.X := 0;
  curPt.Y := 0;
  pStart.X := 0;
  pStart.Y := 0;

  for i := 0 to High(ACmds) do
  begin
    cmd := ACmds[i];
    case cmd.Kind of
      pckMoveTo:
      begin
        if ptCount > 0 then
          FlushSubPath(False);
        curPt := cmd.P1;
        pStart := curPt;
        AddPoint(curPt);
      end;
      pckLineTo:
      begin
        curPt := cmd.P1;
        AddPoint(curPt);
      end;
      pckBezierTo:
      begin
        for step := 1 to 16 do
        begin
          t := step / 16.0;
          u := 1.0 - t;
          tt := t * t;
          uu := u * u;
          uuu := uu * u;
          ttt := tt * t;
          bx := uuu * curPt.X + 3 * uu * t * cmd.P1.X + 3 * u * tt * cmd.P2.X + ttt * cmd.P3.X;
          by := uuu * curPt.Y + 3 * uu * t * cmd.P1.Y + 3 * u * tt * cmd.P2.Y + ttt * cmd.P3.Y;
          AddPoint(XuiPointF(bx, by));
        end;
        curPt := cmd.P3;
      end;
      pckClose:
      begin
        if (curPt.X <> pStart.X) or (curPt.Y <> pStart.Y) then
          AddPoint(pStart);
        FlushSubPath(True);
      end;
    end;
  end;

  if ptCount > 0 then
    FlushSubPath(False);
end;

end.
