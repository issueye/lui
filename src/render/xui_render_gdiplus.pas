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
  Windows, Classes, SysUtils, Types, Graphics, LCLType, Math, IniFiles,
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
  // 文本测量 memo 槽数（2 的幂）
  XuiMeasureSlots = 4096;
  // DrawText 行高 memo 槽数（2 的幂）
  XuiGpHeightSlots = 2048;
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
  // 文本测量 memo 槽（直接映射）：签名 + 文本 → 宽高
  TMeasureSlot = record
    Sig: string;      // 字体签名（'' = 空槽）
    Text: string;
    W, H: Integer;
  end;

  // 样式 → 字体签名 的短缓存（避免每次取字体都解析字体族并拼长 key）。
  // Font 为字体缓存 TGpFontEntry 的弱引用：字体缓存被清空时同步作废本缓存。
  TFontSigEntry = record
    Family: string;
    Size: Single;
    Bold: Boolean;
    Sig: string;
    Font: PGpFont;
  end;

  // DrawText 行高 memo 槽（直接映射）：键为 (字体对象, hint, 布局高取整)
  TGpHeightSlot = record
    Font: PGpFont;
    Hint: Integer;
    LayoutH: Integer;
    Text: string;
    H: Single;
    Wide: UnicodeString;   // 文本的 UTF-16 缓存（DrawText 直接复用，免逐次转换）
  end;

  // 字体缓存条目：一个 (family,size,bold) 组合对应的 GDI+ 字体族与字体对象
  TGpFontEntry = class
    Family: PGpFontFamily;
    Font: PGpFont;
    destructor Destroy; override;
  end;

  { TGdiPlusRenderer — 抗锯齿、真实 alpha；文本为 ClearType }
  TGdiPlusRenderer = class(TXuiCustomRenderer)
  private
    FCanvas: TCanvas;
    FGraphics: PGpGraphics;
    FMeasureGraphics: PGpGraphics;
    FMeasureDC: TGpHDC;
    FClipStack: array of TRect;
    FFonts: TStringList;              // 字体缓存：key → TGpFontEntry（OwnsObjects）
    FFont: PGpFont;                   // 当前字体（弱引用，属缓存）
    FSlots: array of TMeasureSlot;    // 文本测量 memo（直接映射表，签名+文本 → 宽高）
    FSigs: array[0..3] of TFontSigEntry; // 最近用过的字体签名（环形写入，线性命中）
    FSigCount: Integer;                   // 已填充条目数（≤ 4）
    FSigNext: Integer;                    // 下一条写入位置
    FGpSlots: array of TGpHeightSlot; // DrawText 行高 memo（直接映射表）
    FFormat: PGpStringFormat;
    FFormatAlign: TXuiTextAlign;
    FTextHint: Integer;   // 当前 GDI+ 文本渲染质量（-1 = 与 Graphics 实际状态未知）
    function EnsureGraphics: PGpGraphics;
    function MeasureGraphics: PGpGraphics;
    function EffectiveAlpha(const AColor: TXuiColor): LongWord;
    function MakeBrush(const AColor: TXuiColor): PGpBrush;
    function MakePen(const AColor: TXuiColor; AWidth: Single): PGpPen;
    function EnsureFont(AStyle: TXuiStyle): PGpFont;
    function FontSigOf(AStyle: TXuiStyle): string;
    procedure CacheFontInSig(AStyle: TXuiStyle; AFont: PGpFont);
    function MeasureSlotIndex(const ASig, AText: string): Integer;
    function GpSlotIndex(AFont: PGpFont; AHint, ALayoutH: Integer;
      const AText: string): Integer;
    // DrawText 行高/宽串的 memo 槽：按 (字体对象, hint, 布局高, 文本) 定位
    function GpSlotFor(AFont: PGpFont; AHint: Integer;
      const ALayout: TGpRectF; AFormat: PGpStringFormat; const AText: string): Integer;
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

destructor TGpFontEntry.Destroy;
begin
  if Font <> nil then
    GdipDeleteFont(Font);
  if Family <> nil then
    GdipDeleteFontFamily(Family);
  inherited Destroy;
end;

destructor TGdiPlusRenderer.Destroy;
begin
  if FFormat <> nil then
    GdipDeleteStringFormat(FFormat);
  FFonts.Free;   // 释放全部缓存字体（含 FFont 指向的对象）
  FFont := nil;
  SetLength(FGpSlots, 0);
  SetLength(FSlots, 0);
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
  FTextHint := -1;   // 新 Graphics 的渲染质量状态未知
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
  fontStyle: Integer;
  family, fallback: UnicodeString;
  resolvedName: string;
  idx: Integer;
  entry: TGpFontEntry;
begin
  // 一级：样式 → 字体对象 的短缓存（4 条线性命中）。
  // 命中即返回，完全不做字体族解析与 key 拼接——热路径上每段文本都要走这里。
  for idx := 0 to FSigCount - 1 do
    if (FSigs[idx].Family = AStyle.FontFamily) and (FSigs[idx].Size = AStyle.FontSize) and
       (FSigs[idx].Bold = AStyle.FontBold) and (FSigs[idx].Font <> nil) then
    begin
      FFont := FSigs[idx].Font;
      Exit(FFont);
    end;

  // 二级：字体缓存表（同 (family,size,bold) 复用 GDI+ 字体对象）
  resolvedName := ResolveFontFamilyName(AStyle.FontFamily);
  key := resolvedName + '|' + IntToStr(Round(AStyle.FontSize * 4)) +
    '|' + BoolToStr(AStyle.FontBold, 'B', 'R');
  if FFonts = nil then
  begin
    FFonts := TStringList.Create;
    FFonts.OwnsObjects := True;
  end;
  idx := FFonts.IndexOf(key);
  if idx >= 0 then
  begin
    FFont := TGpFontEntry(FFonts.Objects[idx]).Font;
    CacheFontInSig(AStyle, FFont);
    Exit(FFont);
  end;

  // 缓存上限：极端多字号场景整体清空（重新积累即可）
  if FFonts.Count >= 64 then
  begin
    FFonts.Clear;          // 释放字体对象：签名缓存里的弱引用同步作废
    FSigCount := 0;
    FSigNext := 0;
    FFont := nil;
  end;

  entry := TGpFontEntry.Create;
  // 使用经过候选栈探测后已验证存在的系统字体
  family := UnicodeString(resolvedName);
  if GdipCreateFontFamilyFromName(PWideChar(family), nil, entry.Family) <> 0 then
  begin
    entry.Family := nil;
    fallback := 'Microsoft YaHei UI';
    GdipCreateFontFamilyFromName(PWideChar(fallback), nil, entry.Family);
  end;
  if entry.Family = nil then
  begin
    entry.Free;
    FFont := nil;
    Exit(nil);
  end;

  fontStyle := FontStyleRegular;
  if AStyle.FontBold then
    fontStyle := FontStyleBold;
  if GdipCreateFont(entry.Family, Max(1, AStyle.FontSize), fontStyle, UnitPixel, entry.Font) <> 0 then
    entry.Font := nil;
  FFonts.AddObject(key, entry);
  FFont := entry.Font;
  CacheFontInSig(AStyle, entry.Font);
  Result := FFont;
end;

function TGdiPlusRenderer.GpSlotFor(AFont: PGpFont; AHint: Integer;
  const ALayout: TGpRectF; AFormat: PGpStringFormat; const AText: string): Integer;
var
  layoutH: Integer;
  bounds: TGpRectF;
begin
  // 布局矩形只有高度参与行高结果（NoWrap，宽度恒为 textW + 32 不会被裁剪）；
  // 键取字体对象指针 + hint + 布局高，避免逐次拼接字符串 key
  layoutH := Round(ALayout.Height);
  if FGpSlots = nil then
    SetLength(FGpSlots, XuiGpHeightSlots);
  Result := GpSlotIndex(AFont, AHint, layoutH, AText);
  if (FGpSlots[Result].Font = AFont) and (FGpSlots[Result].Hint = AHint) and
     (FGpSlots[Result].LayoutH = layoutH) and (FGpSlots[Result].Text = AText) then
    Exit;
  FGpSlots[Result].Font := AFont;
  FGpSlots[Result].Hint := AHint;
  FGpSlots[Result].LayoutH := layoutH;
  FGpSlots[Result].Text := AText;
  FGpSlots[Result].Wide := UnicodeString(AText);
  bounds.Height := 0;
  GdipMeasureString(FGraphics, PWideChar(FGpSlots[Result].Wide),
    Length(FGpSlots[Result].Wide), AFont, ALayout, AFormat, bounds, nil, nil);
  FGpSlots[Result].H := bounds.Height;
end;

function TGdiPlusRenderer.GpSlotIndex(AFont: PGpFont; AHint, ALayoutH: Integer;
  const AText: string): Integer;
var
  h: LongWord;
  i: Integer;
begin
  h := 2166136261 xor LongWord(PtrUInt(AFont)) xor LongWord(AHint) xor
    (LongWord(ALayoutH) * 2654435761);
  for i := 1 to Length(AText) do
    h := (h xor Byte(AText[i])) * 16777619;
  Result := Integer(h and (XuiGpHeightSlots - 1));
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
  wide: UnicodeString;
  textW, dy: Single;
  hint, slot: Integer;
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
    hint := TextRenderingHintAntiAliasGridFit
  else
    hint := TextRenderingHintClearTypeGridFit;
  if hint <> FTextHint then
  begin
    GdipSetTextRenderingHint(FGraphics, hint);
    FTextHint := hint;
  end;

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

  // 单行垂直居中（与 GDI 后端保持同一文本契约，并消除中文字体 baseline 视觉下沉）。
  // 行高与 UTF-16 文本都走 memo 槽（同一字体/文本下 GDI+ 排版结果恒定）
  slot := GpSlotFor(font, hint, layout, format, AText);
  wide := FGpSlots[slot].Wide;
  dy := ((R.Bottom - R.Top) - FGpSlots[slot].H) / 2;
  if dy > 0 then
  begin
    // 视觉重心微校正：中文字符字型中心微偏下，字号 <= 16 时向上微调 0.5px 使居中更挺拔
    if AStyle.FontSize <= 16 then
      dy := dy - 0.5;
    layout.Y := layout.Y + dy;
  end;

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
  weight: Integer;
  sig: string;
  slotIdx: Integer;
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
  // 同字体签名下结果恒定，命中即免去 GDI 调用。
  // 实现为直接映射表（签名 + 文本 → 宽高）：不拼长 key、不做 locale 比较。
  sig := FontSigOf(AStyle);
  if FSlots = nil then
    SetLength(FSlots, XuiMeasureSlots);
  slotIdx := MeasureSlotIndex(sig, AText);
  if (FSlots[slotIdx].Sig = sig) and (FSlots[slotIdx].Text = AText) then
  begin
    Result.cx := FSlots[slotIdx].W;
    Result.cy := FSlots[slotIdx].H;
    Exit;
  end;

  family := UnicodeString(ResolveFontFamilyName(AStyle.FontFamily));
  if AStyle.FontBold then
    weight := 700
  else
    weight := 400;
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
  SelectObject(FMeasureDC, oldFont);
  DeleteObject(font);

  FSlots[slotIdx].Sig := sig;
  FSlots[slotIdx].Text := AText;
  FSlots[slotIdx].W := Result.cx;
  FSlots[slotIdx].H := Result.cy;
end;

// 字体签名：family|size|bold（样式重复命中走 4 条短缓存，避免逐次解析字体族）
function TGdiPlusRenderer.FontSigOf(AStyle: TXuiStyle): string;
var
  i: Integer;
begin
  for i := 0 to FSigCount - 1 do
    if (FSigs[i].Family = AStyle.FontFamily) and (FSigs[i].Size = AStyle.FontSize) and
       (FSigs[i].Bold = AStyle.FontBold) then
      Exit(FSigs[i].Sig);
  Result := ResolveFontFamilyName(AStyle.FontFamily) + '|' +
    IntToStr(Round(AStyle.FontSize)) + '|' +
    IntToStr(Ord(AStyle.FontBold));
  // 环形写入：整条记录只在空闲槽位上赋值（不做记录搬移，避免托管字段引用计数错乱）
  i := FSigNext;
  FSigs[i].Family := AStyle.FontFamily;
  FSigs[i].Size := AStyle.FontSize;
  FSigs[i].Bold := AStyle.FontBold;
  FSigs[i].Sig := Result;
  FSigs[i].Font := nil;   // 由 EnsureFont 在创建/命中后回填
  FSigNext := (FSigNext + 1) and 3;
  if FSigCount < Length(FSigs) then
    Inc(FSigCount);
end;

// 把字体对象回填进签名缓存（同一 (family,size,bold) 后续直接命中）。
// 必须先经 FontSigOf 建立槽位：它写入真实签名，而签名是测量 memo 的键的一部分——
// 若这里写空签名，不同字号的样式会因"签名相同且文本相同"而互串测量结果。
procedure TGdiPlusRenderer.CacheFontInSig(AStyle: TXuiStyle; AFont: PGpFont);
var
  i: Integer;
begin
  FontSigOf(AStyle);
  for i := 0 to FSigCount - 1 do
    if (FSigs[i].Family = AStyle.FontFamily) and (FSigs[i].Size = AStyle.FontSize) and
       (FSigs[i].Bold = AStyle.FontBold) then
    begin
      FSigs[i].Font := AFont;
      Exit;
    end;
end;

// 直接映射槽位：文本与签名的 FNV-1a 混合
function TGdiPlusRenderer.MeasureSlotIndex(const ASig, AText: string): Integer;
var
  h: LongWord;
  i: Integer;
begin
  h := 2166136261;
  for i := 1 to Length(AText) do
    h := (h xor Byte(AText[i])) * 16777619;
  for i := 1 to Length(ASig) do
    h := (h xor Byte(ASig[i])) * 16777619;
  Result := Integer(h and (XuiMeasureSlots - 1));
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
