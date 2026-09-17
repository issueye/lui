unit xui_render_gdiplus;

{$mode objfpc}{$H+}

{ GDI+ 渲染后端（M4）：直接声明 gdiplus.dll 的平铺 API。

  - gdiplus.dll 是 Windows 系统组件，仍满足"零第三方依赖"（N1）
  - 提供抗锯齿圆角、真实 alpha 混合（opacity 生效）与 ClearType 文本
  - 初始化失败（GdiPlusAvailable = False）时引擎自动回退 GDI 后端
  - 仅 64 位：win32 下这些导出名带 @N 修饰，需要另行声明 name }

{$IFDEF WINDOWS}
interface

uses
  Windows, Classes, SysUtils, Types, Graphics, LCLType, Math, IniFiles, LazUTF8,
  xui_types, xui_style, xui_render;

type
  GpStatus = Integer;
  PGpGraphics = Pointer;
  PGpBrush = Pointer;
  PGpPen = Pointer;
  PGpPath = Pointer;
  PGpFont = Pointer;
  PGpFontFamily = Pointer;
  PGpStringFormat = Pointer;

  PGpRectF = ^TGpRectF;
  TGpRectF = record
    X, Y, Width, Height: Single;
  end;

  PGdiplusStartupInput = ^TGdiplusStartupInput;
  TGdiplusStartupInput = record
    GdiplusVersion: LongWord;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: LongBool;
    SuppressExternalCodecs: LongBool;
  end;

  PGdiplusStartupOutput = ^TGdiplusStartupOutput;
  TGdiplusStartupOutput = record
    NotificationHook: Pointer;
    NotificationUnhook: Pointer;
  end;

const
  SmoothingModeAntiAlias = 4;
  TextRenderingHintAntiAliasGridFit = 3;
  TextRenderingHintAntiAlias = 4;
  TextRenderingHintClearTypeGridFit = 5;
  PixelOffsetModeHalf = 4;
  UnitPixel = 2;
  FontStyleRegular = 0;
  FontStyleBold = 1;
  StringAlignmentNear = 0;
  StringAlignmentCenter = 1;
  StringAlignmentFar = 2;
  StringFormatFlagsNoWrap = $1000;
  FillModeAlternate = 0;
  CombineModeReplace = 0;

type
  // HDC 在 Windows 与 LCLType 中都有定义，这里用指针宽度的别名避免歧义
  TGpHDC = PtrUInt;

function GdiplusStartup(out AToken: PtrUInt; AInput: PGdiplusStartupInput;
  AOutput: PGdiplusStartupOutput): GpStatus; stdcall; external 'gdiplus.dll';
procedure GdiplusShutdown(AToken: PtrUInt); stdcall; external 'gdiplus.dll';
function GdipCreateFromHDC(ADC: TGpHDC; out AGraphics: PGpGraphics): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipDeleteGraphics(AGraphics: PGpGraphics): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetSmoothingMode(AGraphics: PGpGraphics; AMode: Integer): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetTextRenderingHint(AGraphics: PGpGraphics; AMode: Integer): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetPixelOffsetMode(AGraphics: PGpGraphics; AMode: Integer): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetTextContrast(AGraphics: PGpGraphics; AContrast: LongWord): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipCreateSolidFill(AColor: LongWord; out ABrush: PGpBrush): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipDeleteBrush(ABrush: PGpBrush): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipFillRectangle(AGraphics: PGpGraphics; ABrush: PGpBrush;
  AX, AY, AWidth, AHeight: Single): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDrawRectangle(AGraphics: PGpGraphics; APen: PGpPen;
  AX, AY, AWidth, AHeight: Single): GpStatus; stdcall; external 'gdiplus.dll';
function GdipFillPath(AGraphics: PGpGraphics; ABrush: PGpBrush;
  APath: PGpPath): GpStatus; stdcall; external 'gdiplus.dll';
function GdipCreatePen1(AColor: LongWord; AWidth: Single; AUnit: Integer;
  out APen: PGpPen): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDeletePen(APen: PGpPen): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDrawPath(AGraphics: PGpGraphics; APen: PGpPen;
  APath: PGpPath): GpStatus; stdcall; external 'gdiplus.dll';
function GdipCreatePath(ABrushMode: Integer; out APath: PGpPath): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipDeletePath(APath: PGpPath): GpStatus; stdcall; external 'gdiplus.dll';
function GdipAddPathArc(APath: PGpPath; AX, AY, AWidth, AHeight,
  AStartAngle, ASweepAngle: Single): GpStatus; stdcall; external 'gdiplus.dll';
function GdipAddPathLine(APath: PGpPath; X1, Y1, X2, Y2: Single): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipAddPathBezier(APath: PGpPath; X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipStartPathFigure(APath: PGpPath): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipClosePathFigure(APath: PGpPath): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipCreateFontFamilyFromName(AName: PWideChar;
  AFontCollection: Pointer; out AFamily: PGpFontFamily): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipDeleteFontFamily(AFamily: PGpFontFamily): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipCreateFont(AFamily: PGpFontFamily; AEmSize: Single; AStyle,
  AUnit: Integer; out AFont: PGpFont): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDeleteFont(AFont: PGpFont): GpStatus; stdcall; external 'gdiplus.dll';
function GdipCreateStringFormat(AFormatAttributes: Integer; ALanguage: Word;
  out AFormat: PGpStringFormat): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDeleteStringFormat(AFormat: PGpStringFormat): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetStringFormatAlign(AFormat: PGpStringFormat;
  AAlign: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipSetStringFormatLineAlign(AFormat: PGpStringFormat;
  AAlign: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipSetStringFormatFlags(AFormat: PGpStringFormat;
  AFlags: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDrawString(AGraphics: PGpGraphics; AText: PWideChar;
  ALength: Integer; AFont: PGpFont; const ALayoutRect: TGpRectF;
  AFormat: PGpStringFormat; ABrush: PGpBrush): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipMeasureString(AGraphics: PGpGraphics; AText: PWideChar;
  ALength: Integer; AFont: PGpFont; const ALayoutRect: TGpRectF;
  AFormat: PGpStringFormat; out ABoundingBox: TGpRectF;
  ACodepointsFitted: PInteger; ALinesFilled: PInteger): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipSetClipRect(AGraphics: PGpGraphics; AX, AY, AWidth, AHeight: Single;
  ACombineMode: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipResetClip(AGraphics: PGpGraphics): GpStatus;
  stdcall; external 'gdiplus.dll';

type
  { TGdiPlusRenderer — 抗锯齿、真实 alpha；文本为 ClearType }
  TGdiPlusRenderer = class(TXuiCustomRenderer)
  private
    FCanvas: TCanvas;
    FGraphics: PGpGraphics;
    FMeasureGraphics: PGpGraphics;
    FMeasureDC: TGpHDC;
    FClipStack: array of TRect;
    FFontFamily: PGpFontFamily;
    FFont: PGpFont;
    FFontKey: string;
    FMeasureCache: THashedStringList; // 文本测量 memo：'family|size|bold|text' → 打包 cx,cy
    FFormat: PGpStringFormat;
    FFormatAlign: TXuiTextAlign;
    function EnsureGraphics: PGpGraphics;
    function MeasureGraphics: PGpGraphics;
    function EffectiveAlpha(const AColor: TXuiColor): LongWord;
    function MakeBrush(const AColor: TXuiColor): PGpBrush;
    function MakePen(const AColor: TXuiColor; AWidth: Single): PGpPen;
    function EnsureFont(AStyle: TXuiStyle): PGpFont;
    function EnsureFormat(AStyle: TXuiStyle): PGpStringFormat;
    procedure DrawRoundPath(x, y, w, h: Single; ARadius: Single; ABrush: PGpBrush;
      APen: PGpPen);
    procedure ApplyClip(const ARect: TRect);
  public
    constructor Create(ACanvas: TCanvas); overload;
    destructor Destroy; override;
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

var
  GdiPlusAvailable: Boolean;
  GdiPlusToken: PtrUInt;

implementation

function GdiPlusStartupOnce: Boolean;
var
  input: TGdiplusStartupInput;
  output: TGdiplusStartupOutput;
begin
  FillChar(input, SizeOf(input), 0);
  input.GdiplusVersion := 1;
  Result := GdiplusStartup(GdiPlusToken, @input, @output) = 0;
end;

var
  GFontResolverCache: TStringList = nil;

function ResolveFontFamilyName(const ACandidates: string): string;
var
  list: TStringList;
  i, idx: Integer;
  item: string;
  testFam: PGpFontFamily;
  wide: UnicodeString;
  found: Boolean;
const
  FALLBACK_FONTS: array[0..5] of string = (
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'PingFang SC',
    'Tahoma',
    'Arial'
  );
begin
  if Trim(ACandidates) = '' then
    Exit('Microsoft YaHei UI');

  if GFontResolverCache = nil then
    GFontResolverCache := TStringList.Create;

  idx := GFontResolverCache.IndexOfName(ACandidates);
  if idx >= 0 then
    Exit(GFontResolverCache.ValueFromIndex[idx]);

  Result := '';
  found := False;
  list := TStringList.Create;
  try
    list.Delimiter := ',';
    list.StrictDelimiter := True;
    list.DelimitedText := ACandidates;
    for i := 0 to list.Count - 1 do
    begin
      item := Trim(list[i]);
      item := StringReplace(item, '"', '', [rfReplaceAll]);
      item := StringReplace(item, '''', '', [rfReplaceAll]);
      item := Trim(item);
      if (item = '') or
         (SameText(item, 'sans-serif')) or
         (SameText(item, 'serif')) or
         (SameText(item, 'monospace')) or
         (SameText(item, 'system-ui')) or
         (SameText(item, 'cursive')) or
         (SameText(item, 'fantasy')) then
        Continue;

      testFam := nil;
      wide := UnicodeString(item);
      if (GdipCreateFontFamilyFromName(PWideChar(wide), nil, testFam) = 0) and (testFam <> nil) then
      begin
        GdipDeleteFontFamily(testFam);
        Result := item;
        found := True;
        Break;
      end;
    end;

    if not found then
    begin
      for i := Low(FALLBACK_FONTS) to High(FALLBACK_FONTS) do
      begin
        item := FALLBACK_FONTS[i];
        testFam := nil;
        wide := UnicodeString(item);
        if (GdipCreateFontFamilyFromName(PWideChar(wide), nil, testFam) = 0) and (testFam <> nil) then
        begin
          GdipDeleteFontFamily(testFam);
          Result := item;
          found := True;
          Break;
        end;
      end;
    end;

    if not found then
      Result := 'Microsoft YaHei UI';

    GFontResolverCache.Values[ACandidates] := Result;
  finally
    list.Free;
  end;
end;

{ TGdiPlusRenderer }

constructor TGdiPlusRenderer.Create(ACanvas: TCanvas);
begin
  inherited Create;
  SetCanvas(ACanvas);
end;

destructor TGdiPlusRenderer.Destroy;
begin
  if FFormat <> nil then
    GdipDeleteStringFormat(FFormat);
  if FFont <> nil then
    GdipDeleteFont(FFont);
  if FFontFamily <> nil then
    GdipDeleteFontFamily(FFontFamily);
  FMeasureCache.Free;
  if FMeasureGraphics <> nil then
    GdipDeleteGraphics(FMeasureGraphics);
  if FMeasureDC <> 0 then
    DeleteDC(FMeasureDC);
  if FGraphics <> nil then
    GdipDeleteGraphics(FGraphics);
  inherited Destroy;
end;

procedure TGdiPlusRenderer.SetCanvas(ACanvas: TCanvas);
var
  hdc: TGpHDC;
begin
  FCanvas := ACanvas;
  hdc := 0;
  if ACanvas <> nil then
    hdc := TGpHDC(ACanvas.Handle);
  if FGraphics <> nil then
  begin
    GdipDeleteGraphics(FGraphics);
    FGraphics := nil;
  end;
  SetLength(FClipStack, 0);
  if hdc <> 0 then
    GdipCreateFromHDC(hdc, FGraphics);
  if FGraphics <> nil then
  begin
    GdipSetSmoothingMode(FGraphics, SmoothingModeAntiAlias);
    GdipSetTextRenderingHint(FGraphics, TextRenderingHintClearTypeGridFit);
    GdipSetPixelOffsetMode(FGraphics, PixelOffsetModeHalf);
    GdipSetTextContrast(FGraphics, 3);
  end;
end;

function TGdiPlusRenderer.EnsureGraphics: PGpGraphics;
begin
  Result := FGraphics;
end;

function TGdiPlusRenderer.MeasureGraphics: PGpGraphics;
begin
  if FMeasureDC = 0 then
    FMeasureDC := TGpHDC(CreateCompatibleDC(0));
  if (FMeasureGraphics = nil) and (FMeasureDC <> 0) then
  begin
    GdipCreateFromHDC(FMeasureDC, FMeasureGraphics);
    if FMeasureGraphics <> nil then
    begin
      GdipSetTextRenderingHint(FMeasureGraphics, TextRenderingHintClearTypeGridFit);
      GdipSetPixelOffsetMode(FMeasureGraphics, PixelOffsetModeHalf);
      GdipSetTextContrast(FMeasureGraphics, 3);
    end;
  end;
  Result := FMeasureGraphics;
end;

function TGdiPlusRenderer.EffectiveAlpha(const AColor: TXuiColor): LongWord;
var
  a: Integer;
begin
  a := Round(AColor.A * FOpacity);
  if a < 0 then a := 0;
  if a > 255 then a := 255;
  Result := (LongWord(a) shl 24) or (LongWord(AColor.R) shl 16) or
    (LongWord(AColor.G) shl 8) or LongWord(AColor.B);
end;

function TGdiPlusRenderer.MakeBrush(const AColor: TXuiColor): PGpBrush;
begin
  Result := nil;
  GdipCreateSolidFill(EffectiveAlpha(AColor), Result);
end;

function TGdiPlusRenderer.MakePen(const AColor: TXuiColor; AWidth: Single): PGpPen;
begin
  Result := nil;
  GdipCreatePen1(EffectiveAlpha(AColor), Max(1, AWidth), UnitPixel, Result);
end;

function TGdiPlusRenderer.EnsureFont(AStyle: TXuiStyle): PGpFont;
var
  key: string;
  style: Integer;
  family: UnicodeString;
  resolvedName: string;
begin
  resolvedName := ResolveFontFamilyName(AStyle.FontFamily);
  key := resolvedName + '|' + IntToStr(Round(AStyle.FontSize * 4)) +
    '|' + BoolToStr(AStyle.FontBold, 'B', 'R');
  if (FFont <> nil) and (key = FFontKey) then
    Exit(FFont);

  if FFont <> nil then
  begin
    GdipDeleteFont(FFont);
    FFont := nil;
  end;
  if FFontFamily <> nil then
  begin
    GdipDeleteFontFamily(FFontFamily);
    FFontFamily := nil;
  end;
  if FMeasureGraphics = nil then
    MeasureGraphics;
  // 使用经过候选栈探测后已验证存在的系统字体
  family := UnicodeString(resolvedName);
  if GdipCreateFontFamilyFromName(PWideChar(family), nil, FFontFamily) <> 0 then
  begin
    FFontFamily := nil;
    family := 'Microsoft YaHei UI';
    GdipCreateFontFamilyFromName(PWideChar(family), nil, FFontFamily);
  end;
  if FFontFamily = nil then
  begin
    FFontKey := key;
    Exit(nil);
  end;

  style := FontStyleRegular;
  if AStyle.FontBold then
    style := FontStyleBold;
  GdipCreateFont(FFontFamily, Max(1, AStyle.FontSize), style, UnitPixel, FFont);
  FFontKey := key;
  Result := FFont;
end;

function TGdiPlusRenderer.EnsureFormat(AStyle: TXuiStyle): PGpStringFormat;
begin
  if FFormat <> nil then
    Exit(FFormat);
  GdipCreateStringFormat(0, 0, FFormat);
  if FFormat = nil then
    Exit(nil);
  // 水平与垂直对齐均保持 Near（起始锚点已在 DrawText 中按 AStyle.TextAlign 手动计算精确像素，
  // 避免 GDI+ 在布局矩形内进行二次居中叠加，防止居中按钮文字向右偏斜）
  GdipSetStringFormatAlign(FFormat, StringAlignmentNear);
  GdipSetStringFormatLineAlign(FFormat, StringAlignmentNear);
  GdipSetStringFormatFlags(FFormat, StringFormatFlagsNoWrap);
  Result := FFormat;
end;

procedure TGdiPlusRenderer.FillRect(const R: TRect; const AColor: TXuiColor);
var
  brush: PGpBrush;
begin
  if (FGraphics = nil) or (FOpacity <= 0.001) then
    Exit;
  brush := MakeBrush(AColor);
  if brush = nil then
    Exit;
  GdipFillRectangle(FGraphics, brush, R.Left, R.Top,
    R.Right - R.Left, R.Bottom - R.Top);
  GdipDeleteBrush(brush);
end;

procedure TGdiPlusRenderer.FrameRect(const R: TRect; const AColor: TXuiColor;
  AWidth: Single);
begin
  // 直角边框：圆角 0 的路径
  FrameRoundRect(R, 0, AWidth, AColor);
end;

procedure TGdiPlusRenderer.DrawRoundPath(x, y, w, h: Single; ARadius: Single;
  ABrush: PGpBrush; APen: PGpPen);
var
  path: PGpPath;
  d: Single;
begin
  if (FGraphics = nil) or ((ABrush = nil) and (APen = nil)) then
    Exit;
  if (w <= 0) or (h <= 0) then
    Exit;
  GdipCreatePath(FillModeAlternate, path);
  if path = nil then
    Exit;
  d := Min(Min(ARadius * 2, w), h);
  if d > 0 then
  begin
    // 四段圆弧依序连接（GDI+ 会自动用直线连接相邻弧起点）
    GdipAddPathArc(path, x, y, d, d, 180, 90);              // 左上
    GdipAddPathArc(path, x + w - d, y, d, d, 270, 90);      // 右上
    GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0, 90);// 右下
    GdipAddPathArc(path, x, y + h - d, d, d, 90, 90);       // 左下
  end
  else
  begin
    GdipAddPathArc(path, x, y, 0, 0, 0, 0); // 直角：退化为矩形路径
    GdipAddPathArc(path, x + w, y, 0, 0, 0, 0);
    GdipAddPathArc(path, x + w, y + h, 0, 0, 0, 0);
    GdipAddPathArc(path, x, y + h, 0, 0, 0, 0);
  end;
  GdipClosePathFigure(path);
  if ABrush <> nil then
    GdipFillPath(FGraphics, ABrush, path);
  if APen <> nil then
    GdipDrawPath(FGraphics, APen, path);
  GdipDeletePath(path);
end;

procedure TGdiPlusRenderer.FillRoundRect(const R: TRect; ARadius: Single;
  const AColor: TXuiColor);
var
  brush: PGpBrush;
begin
  if (FGraphics = nil) or (FOpacity <= 0.001) then
    Exit;
  brush := MakeBrush(AColor);
  if brush = nil then
    Exit;
  if ARadius <= 0 then
    GdipFillRectangle(FGraphics, brush, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top)
  else
    DrawRoundPath(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, ARadius, brush, nil);
  GdipDeleteBrush(brush);
end;

procedure TGdiPlusRenderer.FrameRoundRect(const R: TRect; ARadius, AWidth: Single;
  const AColor: TXuiColor);
var
  pen: PGpPen;
  half: Single;
  x, y, w, h, strokeRad: Single;
begin
  if (FGraphics = nil) or (FOpacity <= 0.001) or (AWidth <= 0) then
    Exit;
  pen := MakePen(AColor, AWidth);
  if pen = nil then
    Exit;

  // 关键：笔触中心线内缩 AWidth * 0.5（Half Stroke Inset）。
  // 1. 彻底解决 1px 边框在居中描边模型下跨两个物理像素被羽化成 2px 粗糙虚边的问题，线条极致锐利细腻；
  // 2. 严格将边框闭合在 BoxRect 内部，绝不向外溢出 0.5px 污染父级背景。
  half := AWidth * 0.5;
  x := R.Left + half;
  y := R.Top + half;
  w := (R.Right - R.Left) - AWidth;
  h := (R.Bottom - R.Top) - AWidth;

  if (w > 0) and (h > 0) then
  begin
    strokeRad := Max(0, ARadius - half);
    if strokeRad > 0 then
      DrawRoundPath(x, y, w, h, strokeRad, nil, pen)
    else
      GdipDrawRectangle(FGraphics, pen, x, y, w, h);
  end;

  GdipDeletePen(pen);
end;

procedure TGdiPlusRenderer.DrawText(const R: TRect; const AText: string;
  AStyle: TXuiStyle);
var
  font: PGpFont;
  format: PGpStringFormat;
  brush: PGpBrush;
  layout: TGpRectF;
  bounds: TGpRectF;
  wide, ch: UnicodeString;
  textW, cursor: Single;
  dy: Single;
  one: TGpRectF;
  i: Integer;
begin
  if (FGraphics = nil) or (AText = '') or (FOpacity <= 0.001) then
    Exit;
  font := EnsureFont(AStyle);
  if font = nil then
    Exit;
  format := EnsureFormat(AStyle);
  if format = nil then
    Exit;
  brush := MakeBrush(AStyle.TextColor);
  if brush = nil then
    Exit;

  // 渲染质量与透明度自适应：
  // 当整体透明度或文本颜色存在半透明时，ClearType 亚像素在无衬底区域容易产生彩边杂色；
  // 此时自动切换为灰度抗锯齿平滑；而在常规不透明状态下保持亚像素 ClearType。
  if (FOpacity < 0.99) or (AStyle.TextColor.A < 250) then
    GdipSetTextRenderingHint(FGraphics, TextRenderingHintAntiAliasGridFit)
  else
    GdipSetTextRenderingHint(FGraphics, TextRenderingHintClearTypeGridFit);

  wide := UnicodeString(AText);
  // GDI+ 会按布局矩形裁剪文本，且自身排版取整会吃掉末尾字符。
  // 这里自算锚点（宽度用与 GDI 后端一致的测量值）并给出宽裕矩形，避免任何裁剪，
  // 等价于 GDI 后端 TextOut 的行为（超出内容盒也照画）。
  textW := MeasureText(AText, AStyle).cx;
  case AStyle.TextAlign of
    xtaCenter: layout.X := R.Left + ((R.Right - R.Left) - textW) / 2;
    xtaRight: layout.X := R.Right - textW;
  else
    layout.X := R.Left;
  end;
  layout.Y := R.Top;
  layout.Width := textW + 32;
  layout.Height := Max(1, R.Bottom - R.Top);

  // 单行垂直居中（与 GDI 后端保持同一文本契约，并消除中文字体 baseline 视觉下沉）
  GdipMeasureString(FGraphics, PWideChar(wide), Length(wide), font, layout,
    format, bounds, nil, nil);
  dy := ((R.Bottom - R.Top) - bounds.Height) / 2;
  if dy > 0 then
  begin
    // 视觉重心微校正：中文字符字型中心微偏下，字号 <= 16 时向上微调 0.5px 使居中更挺拔
    if AStyle.FontSize <= 16 then
      dy := dy - 0.5;
    layout.Y := layout.Y + dy;
  end;

  // R7/R8：letter-spacing —— GDI+ 没有字距开关，逐字推进字距；
  // 与 MeasureText 的口径一致（宽度 + 字距×(字数-1)），保证断行与绘制对齐。
  if AStyle.LetterSpacing <> 0 then
  begin
    cursor := layout.X;
    for i := 1 to UTF8Length(AText) do
    begin
      ch := UnicodeString(UTF8Copy(AText, i, 1));
      one := layout;
      one.X := cursor;
      one.Width := MeasureText(ch, AStyle).cx + 32;
      GdipDrawString(FGraphics, PWideChar(ch), Length(ch), font, one, format, brush);
      cursor := cursor + MeasureText(ch, AStyle).cx + AStyle.LetterSpacing;
    end;
  end
  else
    GdipDrawString(FGraphics, PWideChar(wide), Length(wide), font, layout,
      format, brush);
  GdipDeleteBrush(brush);
end;

function TGdiPlusRenderer.MeasureText(const AText: string; AStyle: TXuiStyle): TSize;
var
  oldFont: HGDIOBJ;
  font: HGDIOBJ;
  size: Windows.TSize;
  wide: UnicodeString;
  family: UnicodeString;
  resolvedName: string;
  weight: Integer;
  key: string;
  idx, n: Integer;
  packed2: Int64;
begin
  // GDI+ 的 GdipMeasureString 会额外计入两侧内边距（比实际字宽大 5-7px），
  // 直接用于断行会导致文字被过度换行。这里改用 GDI 度量：
  // 与 TGdiRenderer（TCanvas.TextWidth → GetTextExtentPoint32）完全一致，
  // 保证两套后端的换行结果相同。
  Result.cx := 0;
  Result.cy := 0;
  if AText = '' then
    Exit;
  if FMeasureDC = 0 then
    MeasureGraphics;
  if FMeasureDC = 0 then
    Exit;

  // 测量结果 memo：断行布局对同一段文本反复度量（前缀/逐词），
  // 同字体签名下结果恒定，命中即免去 GDI 调用
  if AStyle.FontBold then
    weight := 700
  else
    weight := 400;
  resolvedName := ResolveFontFamilyName(AStyle.FontFamily);
  key := resolvedName + '|' + IntToStr(Round(AStyle.FontSize)) + '|' +
    IntToStr(weight) + '|' + IntToStr(Round(AStyle.LetterSpacing * 10)) + '|' + AText;
  if FMeasureCache = nil then
    FMeasureCache := THashedStringList.Create;
  idx := FMeasureCache.IndexOf(key);
  if idx >= 0 then
  begin
    packed2 := Int64(PtrUInt(FMeasureCache.Objects[idx]));
    Result.cx := Integer(packed2 shr 32);
    Result.cy := Integer(LongWord(packed2));
    Exit;
  end;

  family := UnicodeString(resolvedName);
  font := CreateFontW(-Round(Max(1, AStyle.FontSize)), 0, 0, 0, weight, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, PWideChar(family));
  if font = 0 then
    Exit;
  oldFont := SelectObject(FMeasureDC, font);
  wide := UnicodeString(AText);
  if GetTextExtentPoint32W(FMeasureDC, PWideChar(wide), Length(wide), size) then
  begin
    Result.cx := size.cx;
    Result.cy := size.cy;
  end;
  // R7/R8：letter-spacing —— 与 GDI 后端同一口径（字距 × (字数-1)），
  // 使断行、测量与实际绘制三者一致（此前 GDI+ 完全忽略字距）。
  if (AStyle <> nil) and (AStyle.LetterSpacing <> 0) and (AText <> '') then
  begin
    n := UTF8Length(AText);
    if n > 1 then
      Result.cx := Result.cx + Round(AStyle.LetterSpacing * (n - 1));
  end;
  SelectObject(FMeasureDC, oldFont);
  DeleteObject(font);

  // 上限截断：极端多样文本时整体清空（测量是纯函数，重新积累即可）
  if FMeasureCache.Count >= 16384 then
    FMeasureCache.Clear;
  FMeasureCache.AddObject(key, TObject(PtrUInt(
    (Int64(Result.cx) shl 32) or LongWord(Result.cy))));
end;

procedure TGdiPlusRenderer.ApplyClip(const ARect: TRect);
var
  r: TRect;
begin
  if FGraphics = nil then
    Exit;
  r := Types.Rect(ARect.Left, ARect.Top, Max(ARect.Left + 1, ARect.Right),
    Max(ARect.Top + 1, ARect.Bottom));
  GdipSetClipRect(FGraphics, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
    CombineModeReplace);
end;

procedure TGdiPlusRenderer.PushClip(const R: TRect);
var
  n: Integer;
  clip: TRect;
begin
  if FGraphics = nil then
    Exit;
  n := Length(FClipStack);
  if n = 0 then
    clip := R
  else
    clip := Types.Rect(
      Max(FClipStack[n - 1].Left, R.Left), Max(FClipStack[n - 1].Top, R.Top),
      Min(FClipStack[n - 1].Right, R.Right), Min(FClipStack[n - 1].Bottom, R.Bottom));
  SetLength(FClipStack, n + 1);
  FClipStack[n] := clip;
  ApplyClip(clip);
end;

procedure TGdiPlusRenderer.PopClip;
var
  n: Integer;
begin
  if FGraphics = nil then
    Exit;
  n := Length(FClipStack);
  if n = 0 then
    Exit;
  SetLength(FClipStack, n - 1);
  if n - 1 = 0 then
    GdipResetClip(FGraphics)
  else
    ApplyClip(FClipStack[n - 2]);
end;

function TGdiPlusRenderer.LineHeight(ACurrent: TXuiStyle): Single;
begin
  Result := ACurrent.FontSize * ACurrent.LineHeight;
end;

procedure TGdiPlusRenderer.RenderPath(const ACmds: TXuiPathCmdArray;
  const AFill, AStroke: TXuiColor; AStrokeWidth: Single);
var
  g: PGpGraphics;
  path: PGpPath;
  brush: PGpBrush;
  pen: PGpPen;
  curPt: TXuiPointF;
  i: Integer;
  cmd: TXuiPathCmd;
  hasFill, hasStroke: Boolean;
begin
  if (Length(ACmds) = 0) or (FOpacity <= 0.01) then
    Exit;
  hasFill := (AFill.A > 0) and (EffectiveAlpha(AFill) > 0);
  hasStroke := (AStroke.A > 0) and (EffectiveAlpha(AStroke) > 0) and (AStrokeWidth > 0.01);
  if (not hasFill) and (not hasStroke) then
    Exit;

  g := EnsureGraphics;
  if g = nil then
    Exit;

  if GdipCreatePath(FillModeAlternate, path) <> 0 then
    Exit;

  curPt.X := 0;
  curPt.Y := 0;

  for i := 0 to High(ACmds) do
  begin
    cmd := ACmds[i];
    case cmd.Kind of
      pckMoveTo:
      begin
        GdipStartPathFigure(path);
        curPt := cmd.P1;
      end;
      pckLineTo:
      begin
        GdipAddPathLine(path, curPt.X, curPt.Y, cmd.P1.X, cmd.P1.Y);
        curPt := cmd.P1;
      end;
      pckBezierTo:
      begin
        GdipAddPathBezier(path, curPt.X, curPt.Y, cmd.P1.X, cmd.P1.Y,
          cmd.P2.X, cmd.P2.Y, cmd.P3.X, cmd.P3.Y);
        curPt := cmd.P3;
      end;
      pckClose:
      begin
        GdipClosePathFigure(path);
      end;
    end;
  end;

  if hasFill then
  begin
    brush := MakeBrush(AFill);
    if brush <> nil then
    begin
      GdipFillPath(g, brush, path);
      GdipDeleteBrush(brush);
    end;
  end;

  if hasStroke then
  begin
    pen := MakePen(AStroke, AStrokeWidth);
    if pen <> nil then
    begin
      GdipDrawPath(g, pen, path);
      GdipDeletePen(pen);
    end;
  end;

  GdipDeletePath(path);
end;

initialization
  GdiPlusAvailable := GdiPlusStartupOnce;

finalization
  if GFontResolverCache <> nil then
    FreeAndNil(GFontResolverCache);
  if GdiPlusAvailable then
    GdiplusShutdown(GdiPlusToken);

{$ENDIF}

end.
