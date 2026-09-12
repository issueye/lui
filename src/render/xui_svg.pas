unit xui_svg;

{$mode objfpc}{$H+}

{ SVG 矢量图形解析与渲染模块。
  零外部第三方依赖：使用 FPC RTL + LazUtils（laz2_DOM / laz2_XMLRead）。
  
  核心特性：
  - 支持标准 <svg viewBox="..." width="..." height="..."> 根节点；
  - 支持图元：<path>、<rect>、<circle>、<ellipse>、<line>、<polyline>、<polygon>；
  - 图元统一归一化为 TXuiPathCmdArray 矢量指令流；
  - 支持三阶贝塞尔、二阶贝塞尔（自动升阶）、平滑贝塞尔（S/T 反射控制点）、椭圆弧（A 指令）；
  - 支持分组 <g> 属性继承（fill、stroke、stroke-width、opacity）；
  - 支持 currentColor 动态继承宿主字体前景色；
  - 支持十六进制颜色、rgb()、rgba() 与标准 CSS 颜色名；
  - 支持 viewBox 等比自适应缩放（meet 模式）与居中对齐。 }

interface

uses
  Classes, SysUtils, Types, Math, StrUtils,
  laz2_dom, laz2_xmlread,
  xui_types, xui_style, xui_dom, xui_render, xui_css_match;

type
  { SVG 单个矢量图元 }
  TSvgShape = class
  public
    Cmds: TXuiPathCmdArray;
    Fill: TXuiColor;
    Stroke: TXuiColor;
    StrokeWidth: Single;
    HasFill: Boolean;
    HasStroke: Boolean;
    IsCurrentColorFill: Boolean;
    IsCurrentColorStroke: Boolean;
    Opacity: Single;
    FillOpacity: Single;
    StrokeOpacity: Single;
    constructor Create;
  end;

  { SVG 文档对象 }
  TXuiSvgDoc = class
  private
    FShapes: TFPList;
    FViewBox: TRectF;
    FHasViewBox: Boolean;
    FWidth: Single;
    FHeight: Single;
    procedure ParseNode(ANode: TDOMNode; const AParentFill, AParentStroke: string;
      AParentStrokeWidth, AParentOpacity: Single);
    procedure ParsePathElement(AEl: TDOMElement; const AFill, AStroke: string;
      AStrokeWidth, AOpacity: Single);
    procedure ParseRectElement(AEl: TDOMElement; const AFill, AStroke: string;
      AStrokeWidth, AOpacity: Single);
    procedure ParseCircleElement(AEl: TDOMElement; const AFill, AStroke: string;
      AStrokeWidth, AOpacity: Single);
    procedure ParseEllipseElement(AEl: TDOMElement; const AFill, AStroke: string;
      AStrokeWidth, AOpacity: Single);
    procedure ParseLineElement(AEl: TDOMElement; const AFill, AStroke: string;
      AStrokeWidth, AOpacity: Single);
    procedure ParsePolyElement(AEl: TDOMElement; IsPolygon: Boolean;
      const AFill, AStroke: string; AStrokeWidth, AOpacity: Single);
    procedure ApplyStyles(AShape: TSvgShape; AEl: TDOMElement;
      const AParentFill, AParentStroke: string;
      AParentStrokeWidth, AParentOpacity: Single;
      DefaultHasFill: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFromString(const AXml: string);
    procedure LoadFromFile(const AFileName: string);
    procedure LoadFromXuiNode(ANode: TXuiNode);
    procedure Render(ARenderer: TXuiCustomRenderer; const ARect: TRect;
      const ACurrentColor: TXuiColor);
    property ViewBox: TRectF read FViewBox;
    property HasViewBox: Boolean read FHasViewBox;
    property Width: Single read FWidth;
    property Height: Single read FHeight;
    property Shapes: TFPList read FShapes;
  end;

{ 解析 SVG path 字符串为统一矢量指令数组 }
function ParseSvgPath(const AD: string): TXuiPathCmdArray;
{ 辅助：安全解析浮点数（固定小数点 .，不受地域影响） }
function SvgParseFloat(const S: string; ADefault: Single = 0.0): Single;

implementation

constructor TSvgShape.Create;
begin
  inherited Create;
  SetLength(Cmds, 0);
  Fill := XuiRGB(0, 0, 0);
  Stroke := XuiRGB(0, 0, 0);
  StrokeWidth := 1.0;
  HasFill := True;
  HasStroke := False;
  IsCurrentColorFill := False;
  IsCurrentColorStroke := False;
  Opacity := 1.0;
  FillOpacity := 1.0;
  StrokeOpacity := 1.0;
end;

function XuiRectF(ALeft, ATop, ARight, ABottom: Single): TRectF; inline;
begin
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Right := ARight;
  Result.Bottom := ABottom;
end;

{ 辅助：安全解析浮点数（固定小数点 .，不受地域影响） }
function SvgParseFloat(const S: string; ADefault: Single = 0.0): Single;
var
  code: Integer;
  valD: Double;
  trimmed: string;
begin
  trimmed := Trim(S);
  if trimmed = '' then
    Exit(ADefault);
  // 移除常见单位 px
  if EndsText('px', trimmed) then
    trimmed := Trim(Copy(trimmed, 1, Length(trimmed) - 2));
  Val(trimmed, valD, code);
  if code = 0 then
    Result := Single(valD)
  else
    Result := ADefault;
end;

{ 辅助：从 style 属性读取 CSS 键值对 }
function GetInlineStyle(AEl: TDOMElement; const AKey: string): string;
var
  styleStr, item, k, v: string;
  parts, pair: TStringList;
  i: Integer;
begin
  Result := '';
  if not AEl.HasAttribute('style') then
    Exit;
  styleStr := AEl.GetAttribute('style');
  parts := TStringList.Create;
  pair := TStringList.Create;
  try
    parts.Delimiter := ';';
    parts.StrictDelimiter := True;
    parts.DelimitedText := styleStr;
    for i := 0 to parts.Count - 1 do
    begin
      item := Trim(parts[i]);
      if item = '' then Continue;
      pair.Clear;
      pair.Delimiter := ':';
      pair.StrictDelimiter := True;
      pair.DelimitedText := item;
      if pair.Count >= 2 then
      begin
        k := LowerCase(Trim(pair[0]));
        v := Trim(pair[1]);
        if k = LowerCase(AKey) then
        begin
          Result := v;
          Break;
        end;
      end;
    end;
  finally
    pair.Free;
    parts.Free;
  end;
end;

{ 辅助：获取元素样式或属性（style 优先于 XML 属性） }
function GetAttrOrStyle(AEl: TDOMElement; const AName: string; const ADefault: string = ''): string;
begin
  Result := GetInlineStyle(AEl, AName);
  if Result = '' then
  begin
    if AEl.HasAttribute(AName) then
      Result := AEl.GetAttribute(AName)
    else
      Result := ADefault;
  end;
end;

{ 辅助：椭圆弧转换为三阶贝塞尔曲线 }
procedure ArcToBeziers(const P0: TXuiPointF; rx, ry, xAxisRotation: Single;
  largeArcFlag, sweepFlag: Boolean; const P1: TXuiPointF; var OutCmds: TXuiPathCmdArray);
var
  dx, dy, x1p, y1p, rxSq, rySq, x1pSq, y1pSq, radSq, sign, factor, cxp, cyp: Double;
  phi, cosPhi, sinPhi, cx, cy, theta1, deltaTheta, thetaEnd, stepTheta, curTheta, nextTheta: Double;
  alpha, t1, t2: Double;
  segments, i: Integer;
  cmd: TXuiPathCmd;
  ptStart, ptEnd, cp1, cp2: TXuiPointF;
begin
  if (P0.X = P1.X) and (P0.Y = P1.Y) then
    Exit;
  if (rx <= 0.0001) or (ry <= 0.0001) then
  begin
    cmd.Kind := pckLineTo;
    cmd.P1 := P1;
    cmd.P2 := P1;
    cmd.P3 := P1;
    SetLength(OutCmds, Length(OutCmds) + 1);
    OutCmds[High(OutCmds)] := cmd;
    Exit;
  end;

  rx := Abs(rx);
  ry := Abs(ry);
  phi := xAxisRotation * Pi / 180.0;
  cosPhi := Cos(phi);
  sinPhi := Sin(phi);

  dx := (P0.X - P1.X) / 2.0;
  dy := (P0.Y - P1.Y) / 2.0;
  x1p := cosPhi * dx + sinPhi * dy;
  y1p := -sinPhi * dx + cosPhi * dy;

  rxSq := rx * rx;
  rySq := ry * ry;
  x1pSq := x1p * x1p;
  y1pSq := y1p * y1p;

  radSq := x1pSq / rxSq + y1pSq / rySq;
  if radSq > 1.0 then
  begin
    rx := rx * Sqrt(radSq);
    ry := ry * Sqrt(radSq);
    rxSq := rx * rx;
    rySq := ry * ry;
  end;

  factor := (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq);
  if factor < 0 then factor := 0;
  if largeArcFlag = sweepFlag then
    sign := -1.0
  else
    sign := 1.0;
  factor := sign * Sqrt(factor);

  cxp := factor * (rx * y1p / ry);
  cyp := factor * (-ry * x1p / rx);

  cx := cosPhi * cxp - sinPhi * cyp + (P0.X + P1.X) / 2.0;
  cy := sinPhi * cxp + cosPhi * cyp + (P0.Y + P1.Y) / 2.0;

  theta1 := ArcTan2((y1p - cyp) / ry, (x1p - cxp) / rx);
  thetaEnd := ArcTan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
  deltaTheta := thetaEnd - theta1;

  if (not sweepFlag) and (deltaTheta > 0) then
    deltaTheta := deltaTheta - 2.0 * Pi
  else if sweepFlag and (deltaTheta < 0) then
    deltaTheta := deltaTheta + 2.0 * Pi;

  segments := Ceil(Abs(deltaTheta) / (Pi / 2.0));
  if segments < 1 then segments := 1;
  stepTheta := deltaTheta / segments;

  ptStart := P0;
  curTheta := theta1;

  for i := 1 to segments do
  begin
    nextTheta := curTheta + stepTheta;
    alpha := (4.0 / 3.0) * Tan((nextTheta - curTheta) / 4.0);

    t1 := curTheta;
    t2 := nextTheta;

    // 起点切线方向控制点
    cp1.X := Single(cx + cosPhi * rx * Cos(t1) - sinPhi * ry * Sin(t1) -
             alpha * (cosPhi * rx * Sin(t1) + sinPhi * ry * Cos(t1)));
    cp1.Y := Single(cy + sinPhi * rx * Cos(t1) + cosPhi * ry * Sin(t1) -
             alpha * (sinPhi * rx * Sin(t1) - cosPhi * ry * Cos(t1)));

    // 终点坐标与反向控制点
    ptEnd.X := Single(cx + cosPhi * rx * Cos(t2) - sinPhi * ry * Sin(t2));
    ptEnd.Y := Single(cy + sinPhi * rx * Cos(t2) + cosPhi * ry * Sin(t2));

    cp2.X := Single(ptEnd.X + alpha * (cosPhi * rx * Sin(t2) + sinPhi * ry * Cos(t2)));
    cp2.Y := Single(ptEnd.Y + alpha * (sinPhi * rx * Sin(t2) - cosPhi * ry * Cos(t2)));

    cmd.Kind := pckBezierTo;
    cmd.P1 := cp1;
    cmd.P2 := cp2;
    cmd.P3 := ptEnd;

    SetLength(OutCmds, Length(OutCmds) + 1);
    OutCmds[High(OutCmds)] := cmd;

    curTheta := nextTheta;
    ptStart := ptEnd;
  end;
end;

{ 词法扫描器：解析 SVG path 数据流 }
type
  TSvgPathScanner = class
  private
    FText: string;
    FPos: Integer;
    FLen: Integer;
    procedure SkipWhitespaceAndCommas;
  public
    constructor Create(const S: string);
    function HasMore: Boolean;
    function NextToken(out ACmd: Char; out ANumber: Single; out IsNumber: Boolean): Boolean;
  end;

constructor TSvgPathScanner.Create(const S: string);
begin
  inherited Create;
  FText := S;
  FPos := 1;
  FLen := Length(S);
end;

procedure TSvgPathScanner.SkipWhitespaceAndCommas;
begin
  while (FPos <= FLen) and ((FText[FPos] <= ' ') or (FText[FPos] = ',')) do
    Inc(FPos);
end;

function TSvgPathScanner.HasMore: Boolean;
begin
  SkipWhitespaceAndCommas;
  Result := FPos <= FLen;
end;

function TSvgPathScanner.NextToken(out ACmd: Char; out ANumber: Single; out IsNumber: Boolean): Boolean;
var
  startPos: Integer;
  numStr: string;
  ch: Char;
  code: Integer;
  valD: Double;
  hasDot, hasExp: Boolean;
begin
  ACmd := #0;
  ANumber := 0;
  IsNumber := False;
  SkipWhitespaceAndCommas;
  if FPos > FLen then
    Exit(False);

  ch := FText[FPos];

  // 字母指令
  if (ch in ['A'..'Z', 'a'..'z']) and (ch <> 'e') and (ch <> 'E') then
  begin
    ACmd := ch;
    Inc(FPos);
    IsNumber := False;
    Exit(True);
  end;

  // 数字扫描
  if (ch in ['0'..'9', '+', '-', '.']) then
  begin
    startPos := FPos;
    hasDot := ch = '.';
    hasExp := False;
    Inc(FPos);

    while FPos <= FLen do
    begin
      ch := FText[FPos];
      if (ch in ['0'..'9']) then
        Inc(FPos)
      else if (ch = '.') and (not hasDot) and (not hasExp) then
      begin
        hasDot := True;
        Inc(FPos);
      end
      else if (ch in ['e', 'E']) and (not hasExp) then
      begin
        hasExp := True;
        Inc(FPos);
        if (FPos <= FLen) and (FText[FPos] in ['+', '-']) then
          Inc(FPos);
      end
      else
        Break;
    end;

    numStr := Copy(FText, startPos, FPos - startPos);
    Val(numStr, valD, code);
    if code = 0 then
      ANumber := Single(valD)
    else
      ANumber := 0;
    IsNumber := True;
    Result := True;
  end
  else
  begin
    Inc(FPos);
    Result := False;
  end;
end;

function ParseSvgPath(const AD: string): TXuiPathCmdArray;
var
  scanner: TSvgPathScanner;
  ch, currentCmd: Char;
  num: Single;
  isNum: Boolean;
  curPt, startPt, lastCtrl: TXuiPointF;

  function ReadNumber: Single;
  var
    dummyCh: Char;
  begin
    if scanner.NextToken(dummyCh, Result, isNum) and isNum then
      Exit
    else
      Result := 0;
  end;

  procedure AddCmd(AKind: TXuiPathCmdKind; const P1, P2, P3: TXuiPointF);
  var
    n: Integer;
  begin
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Kind := AKind;
    Result[n].P1 := P1;
    Result[n].P2 := P2;
    Result[n].P3 := P3;
  end;

var
  x, y, x1, y1, x2, y2, rx, ry, rot: Single;
  largeArc, sweep: Boolean;
  qp, cp1, cp2: TXuiPointF;
begin
  SetLength(Result, 0);
  if Trim(AD) = '' then
    Exit;

  scanner := TSvgPathScanner.Create(AD);
  try
    curPt.X := 0;
    curPt.Y := 0;
    startPt := curPt;
    lastCtrl := curPt;
    currentCmd := #0;

    while scanner.HasMore do
    begin
      if not scanner.NextToken(ch, num, isNum) then
        Break;

      if not isNum then
      begin
        currentCmd := ch;
      end
      else
      begin
        // 如果连续出现数字，继承前一条指令，M/m 紧随的数字当作 L/l 处理
        if currentCmd = 'M' then currentCmd := 'L'
        else if currentCmd = 'm' then currentCmd := 'l';
      end;

      case currentCmd of
        'M', 'm':
        begin
          if isNum then x := num else x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 'm' then
          begin
            x := curPt.X + x;
            y := curPt.Y + y;
          end;
          curPt := XuiPointF(x, y);
          startPt := curPt;
          lastCtrl := curPt;
          AddCmd(pckMoveTo, curPt, curPt, curPt);
        end;

        'L', 'l':
        begin
          if isNum then x := num else x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 'l' then
          begin
            x := curPt.X + x;
            y := curPt.Y + y;
          end;
          curPt := XuiPointF(x, y);
          lastCtrl := curPt;
          AddCmd(pckLineTo, curPt, curPt, curPt);
        end;

        'H', 'h':
        begin
          if isNum then x := num else x := ReadNumber;
          if currentCmd = 'h' then
            x := curPt.X + x;
          curPt.X := x;
          lastCtrl := curPt;
          AddCmd(pckLineTo, curPt, curPt, curPt);
        end;

        'V', 'v':
        begin
          if isNum then y := num else y := ReadNumber;
          if currentCmd = 'v' then
            y := curPt.Y + y;
          curPt.Y := y;
          lastCtrl := curPt;
          AddCmd(pckLineTo, curPt, curPt, curPt);
        end;

        'C', 'c':
        begin
          if isNum then x1 := num else x1 := ReadNumber;
          y1 := ReadNumber;
          x2 := ReadNumber;
          y2 := ReadNumber;
          x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 'c' then
          begin
            x1 := curPt.X + x1; y1 := curPt.Y + y1;
            x2 := curPt.X + x2; y2 := curPt.Y + y2;
            x := curPt.X + x;   y := curPt.Y + y;
          end;
          curPt := XuiPointF(x, y);
          lastCtrl := XuiPointF(x2, y2);
          AddCmd(pckBezierTo, XuiPointF(x1, y1), lastCtrl, curPt);
        end;

        'S', 's':
        begin
          if isNum then x2 := num else x2 := ReadNumber;
          y2 := ReadNumber;
          x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 's' then
          begin
            x2 := curPt.X + x2; y2 := curPt.Y + y2;
            x := curPt.X + x;   y := curPt.Y + y;
          end;
          // 反射前一控制点
          cp1.X := 2.0 * curPt.X - lastCtrl.X;
          cp1.Y := 2.0 * curPt.Y - lastCtrl.Y;
          lastCtrl := XuiPointF(x2, y2);
          curPt := XuiPointF(x, y);
          AddCmd(pckBezierTo, cp1, lastCtrl, curPt);
        end;

        'Q', 'q':
        begin
          if isNum then x1 := num else x1 := ReadNumber;
          y1 := ReadNumber;
          x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 'q' then
          begin
            x1 := curPt.X + x1; y1 := curPt.Y + y1;
            x2 := curPt.X + x2; y2 := curPt.Y + y2;
            x := curPt.X + x;   y := curPt.Y + y;
          end;
          qp := XuiPointF(x1, y1);
          lastCtrl := qp;
          // 二次贝塞尔升阶转三次
          cp1.X := curPt.X + (2.0 / 3.0) * (qp.X - curPt.X);
          cp1.Y := curPt.Y + (2.0 / 3.0) * (qp.Y - curPt.Y);
          cp2.X := x + (2.0 / 3.0) * (qp.X - x);
          cp2.Y := y + (2.0 / 3.0) * (qp.Y - y);
          curPt := XuiPointF(x, y);
          AddCmd(pckBezierTo, cp1, cp2, curPt);
        end;

        'T', 't':
        begin
          if isNum then x := num else x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 't' then
          begin
            x := curPt.X + x;
            y := curPt.Y + y;
          end;
          qp.X := 2.0 * curPt.X - lastCtrl.X;
          qp.Y := 2.0 * curPt.Y - lastCtrl.Y;
          lastCtrl := qp;
          cp1.X := curPt.X + (2.0 / 3.0) * (qp.X - curPt.X);
          cp1.Y := curPt.Y + (2.0 / 3.0) * (qp.Y - curPt.Y);
          cp2.X := x + (2.0 / 3.0) * (qp.X - x);
          cp2.Y := y + (2.0 / 3.0) * (qp.Y - y);
          curPt := XuiPointF(x, y);
          AddCmd(pckBezierTo, cp1, cp2, curPt);
        end;

        'A', 'a':
        begin
          if isNum then rx := num else rx := ReadNumber;
          ry := ReadNumber;
          rot := ReadNumber;
          largeArc := ReadNumber > 0.5;
          sweep := ReadNumber > 0.5;
          x := ReadNumber;
          y := ReadNumber;
          if currentCmd = 'a' then
          begin
            x := curPt.X + x;
            y := curPt.Y + y;
          end;
          ArcToBeziers(curPt, rx, ry, rot, largeArc, sweep, XuiPointF(x, y), Result);
          curPt := XuiPointF(x, y);
          lastCtrl := curPt;
        end;

        'Z', 'z':
        begin
          AddCmd(pckClose, startPt, startPt, startPt);
          curPt := startPt;
          lastCtrl := curPt;
        end;
      end;
    end;
  finally
    scanner.Free;
  end;
end;

{ TXuiSvgDoc }

constructor TXuiSvgDoc.Create;
begin
  inherited Create;
  FShapes := TFPList.Create;
  FHasViewBox := False;
  FWidth := 0;
  FHeight := 0;
end;

destructor TXuiSvgDoc.Destroy;
begin
  Clear;
  FShapes.Free;
  inherited Destroy;
end;

procedure TXuiSvgDoc.Clear;
var
  i: Integer;
begin
  for i := 0 to FShapes.Count - 1 do
    TSvgShape(FShapes[i]).Free;
  FShapes.Clear;
  FHasViewBox := False;
  FWidth := 0;
  FHeight := 0;
end;

procedure TXuiSvgDoc.ApplyStyles(AShape: TSvgShape; AEl: TDOMElement;
  const AParentFill, AParentStroke: string;
  AParentStrokeWidth, AParentOpacity: Single;
  DefaultHasFill: Boolean);
var
  fillStr, strokeStr, swStr, opStr, fOpStr, sOpStr: string;
begin
  fillStr := GetAttrOrStyle(AEl, 'fill', AParentFill);
  strokeStr := GetAttrOrStyle(AEl, 'stroke', AParentStroke);
  swStr := GetAttrOrStyle(AEl, 'stroke-width', '');
  opStr := GetAttrOrStyle(AEl, 'opacity', '');
  fOpStr := GetAttrOrStyle(AEl, 'fill-opacity', '');
  sOpStr := GetAttrOrStyle(AEl, 'stroke-opacity', '');

  // 不透明度
  if opStr <> '' then
    AShape.Opacity := AParentOpacity * SvgParseFloat(opStr, 1.0)
  else
    AShape.Opacity := AParentOpacity;

  if fOpStr <> '' then
    AShape.FillOpacity := SvgParseFloat(fOpStr, 1.0)
  else
    AShape.FillOpacity := 1.0;

  if sOpStr <> '' then
    AShape.StrokeOpacity := SvgParseFloat(sOpStr, 1.0)
  else
    AShape.StrokeOpacity := 1.0;

  // 填充
  if fillStr = '' then
  begin
    AShape.HasFill := DefaultHasFill;
    AShape.Fill := XuiRGB(0, 0, 0);
  end
  else if SameText(fillStr, 'none') then
  begin
    AShape.HasFill := False;
  end
  else if SameText(fillStr, 'currentColor') then
  begin
    AShape.HasFill := True;
    AShape.IsCurrentColorFill := True;
  end
  else
  begin
    AShape.HasFill := True;
    AShape.Fill := ParseCssColor(fillStr);
  end;

  // 描边
  if (strokeStr = '') or SameText(strokeStr, 'none') then
  begin
    AShape.HasStroke := False;
  end
  else if SameText(strokeStr, 'currentColor') then
  begin
    AShape.HasStroke := True;
    AShape.IsCurrentColorStroke := True;
  end
  else
  begin
    AShape.HasStroke := True;
    AShape.Stroke := ParseCssColor(strokeStr);
  end;

  // 线宽
  if swStr <> '' then
    AShape.StrokeWidth := SvgParseFloat(swStr, 1.0)
  else
    AShape.StrokeWidth := AParentStrokeWidth;
end;

procedure TXuiSvgDoc.ParsePathElement(AEl: TDOMElement; const AFill, AStroke: string;
  AStrokeWidth, AOpacity: Single);
var
  d: string;
  shape: TSvgShape;
begin
  d := AEl.GetAttribute('d');
  if Trim(d) = '' then Exit;

  shape := TSvgShape.Create;
  ApplyStyles(shape, AEl, AFill, AStroke, AStrokeWidth, AOpacity, True);
  shape.Cmds := ParseSvgPath(d);
  FShapes.Add(shape);
end;

procedure TXuiSvgDoc.ParseRectElement(AEl: TDOMElement; const AFill, AStroke: string;
  AStrokeWidth, AOpacity: Single);
var
  x, y, w, h, rx, ry, dx, dy: Single;
  shape: TSvgShape;
  k: Single;

  procedure Add(AKind: TXuiPathCmdKind; const P1, P2, P3: TXuiPointF);
  var
    n: Integer;
  begin
    n := Length(shape.Cmds);
    SetLength(shape.Cmds, n + 1);
    shape.Cmds[n].Kind := AKind;
    shape.Cmds[n].P1 := P1;
    shape.Cmds[n].P2 := P2;
    shape.Cmds[n].P3 := P3;
  end;

begin
  x := SvgParseFloat(AEl.GetAttribute('x'), 0);
  y := SvgParseFloat(AEl.GetAttribute('y'), 0);
  w := SvgParseFloat(AEl.GetAttribute('width'), 0);
  h := SvgParseFloat(AEl.GetAttribute('height'), 0);
  rx := SvgParseFloat(AEl.GetAttribute('rx'), 0);
  ry := SvgParseFloat(AEl.GetAttribute('ry'), 0);

  if (w <= 0) or (h <= 0) then Exit;
  if (rx > 0) and (ry = 0) then ry := rx
  else if (ry > 0) and (rx = 0) then rx := ry;

  rx := Min(rx, w / 2.0);
  ry := Min(ry, h / 2.0);

  shape := TSvgShape.Create;
  ApplyStyles(shape, AEl, AFill, AStroke, AStrokeWidth, AOpacity, True);

  if (rx <= 0) and (ry <= 0) then
  begin
    Add(pckMoveTo, XuiPointF(x, y), XuiPointF(x, y), XuiPointF(x, y));
    Add(pckLineTo, XuiPointF(x + w, y), XuiPointF(x + w, y), XuiPointF(x + w, y));
    Add(pckLineTo, XuiPointF(x + w, y + h), XuiPointF(x + w, y + h), XuiPointF(x + w, y + h));
    Add(pckLineTo, XuiPointF(x, y + h), XuiPointF(x, y + h), XuiPointF(x, y + h));
    Add(pckClose, XuiPointF(x, y), XuiPointF(x, y), XuiPointF(x, y));
  end
  else
  begin
    k := 0.55228475;
    dx := rx * k;
    dy := ry * k;
    Add(pckMoveTo, XuiPointF(x + rx, y), XuiPointF(x + rx, y), XuiPointF(x + rx, y));
    Add(pckLineTo, XuiPointF(x + w - rx, y), XuiPointF(x + w - rx, y), XuiPointF(x + w - rx, y));
    Add(pckBezierTo, XuiPointF(x + w - rx + dx, y), XuiPointF(x + w, y + ry - dy), XuiPointF(x + w, y + ry));
    Add(pckLineTo, XuiPointF(x + w, y + h - ry), XuiPointF(x + w, y + h - ry), XuiPointF(x + w, y + h - ry));
    Add(pckBezierTo, XuiPointF(x + w, y + h - ry + dy), XuiPointF(x + w - rx + dx, y + h), XuiPointF(x + w - rx, y + h));
    Add(pckLineTo, XuiPointF(x + rx, y + h), XuiPointF(x + rx, y + h), XuiPointF(x + rx, y + h));
    Add(pckBezierTo, XuiPointF(x + rx - dx, y + h), XuiPointF(x, y + h - ry + dy), XuiPointF(x, y + h - ry));
    Add(pckLineTo, XuiPointF(x, y + ry), XuiPointF(x, y + ry), XuiPointF(x, y + ry));
    Add(pckBezierTo, XuiPointF(x, y + ry - dy), XuiPointF(x + rx - dx, y), XuiPointF(x + rx, y));
    Add(pckClose, XuiPointF(x + rx, y), XuiPointF(x + rx, y), XuiPointF(x + rx, y));
  end;

  FShapes.Add(shape);
end;

procedure TXuiSvgDoc.ParseCircleElement(AEl: TDOMElement; const AFill, AStroke: string;
  AStrokeWidth, AOpacity: Single);
var
  cx, cy, r: Single;
begin
  cx := SvgParseFloat(AEl.GetAttribute('cx'), 0);
  cy := SvgParseFloat(AEl.GetAttribute('cy'), 0);
  r := SvgParseFloat(AEl.GetAttribute('r'), 0);
  if r <= 0 then Exit;

  // 复用 Ellipse
  AEl.SetAttribute('rx', FloatToStr(r));
  AEl.SetAttribute('ry', FloatToStr(r));
  ParseEllipseElement(AEl, AFill, AStroke, AStrokeWidth, AOpacity);
end;

procedure TXuiSvgDoc.ParseEllipseElement(AEl: TDOMElement; const AFill, AStroke: string;
  AStrokeWidth, AOpacity: Single);
var
  cx, cy, rx, ry, dx, dy, k: Single;
  shape: TSvgShape;

  procedure Add(AKind: TXuiPathCmdKind; const P1, P2, P3: TXuiPointF);
  var
    n: Integer;
  begin
    n := Length(shape.Cmds);
    SetLength(shape.Cmds, n + 1);
    shape.Cmds[n].Kind := AKind;
    shape.Cmds[n].P1 := P1;
    shape.Cmds[n].P2 := P2;
    shape.Cmds[n].P3 := P3;
  end;

begin
  cx := SvgParseFloat(AEl.GetAttribute('cx'), 0);
  cy := SvgParseFloat(AEl.GetAttribute('cy'), 0);
  rx := SvgParseFloat(AEl.GetAttribute('rx'), 0);
  ry := SvgParseFloat(AEl.GetAttribute('ry'), 0);
  if (rx <= 0) or (ry <= 0) then Exit;

  shape := TSvgShape.Create;
  ApplyStyles(shape, AEl, AFill, AStroke, AStrokeWidth, AOpacity, True);

  k := 0.55228475;
  dx := rx * k;
  dy := ry * k;

  Add(pckMoveTo, XuiPointF(cx + rx, cy), XuiPointF(cx + rx, cy), XuiPointF(cx + rx, cy));
  Add(pckBezierTo, XuiPointF(cx + rx, cy + dy), XuiPointF(cx + dx, cy + ry), XuiPointF(cx, cy + ry));
  Add(pckBezierTo, XuiPointF(cx - dx, cy + ry), XuiPointF(cx - rx, cy + dy), XuiPointF(cx - rx, cy));
  Add(pckBezierTo, XuiPointF(cx - rx, cy - dy), XuiPointF(cx - dx, cy - ry), XuiPointF(cx, cy - ry));
  Add(pckBezierTo, XuiPointF(cx + dx, cy - ry), XuiPointF(cx + rx, cy - dy), XuiPointF(cx + rx, cy));
  Add(pckClose, XuiPointF(cx + rx, cy), XuiPointF(cx + rx, cy), XuiPointF(cx + rx, cy));

  FShapes.Add(shape);
end;

procedure TXuiSvgDoc.ParseLineElement(AEl: TDOMElement; const AFill, AStroke: string;
  AStrokeWidth, AOpacity: Single);
var
  x1, y1, x2, y2: Single;
  shape: TSvgShape;
begin
  x1 := SvgParseFloat(AEl.GetAttribute('x1'), 0);
  y1 := SvgParseFloat(AEl.GetAttribute('y1'), 0);
  x2 := SvgParseFloat(AEl.GetAttribute('x2'), 0);
  y2 := SvgParseFloat(AEl.GetAttribute('y2'), 0);

  shape := TSvgShape.Create;
  ApplyStyles(shape, AEl, 'none', AStroke, AStrokeWidth, AOpacity, False);
  SetLength(shape.Cmds, 2);
  shape.Cmds[0].Kind := pckMoveTo;
  shape.Cmds[0].P1 := XuiPointF(x1, y1);
  shape.Cmds[1].Kind := pckLineTo;
  shape.Cmds[1].P1 := XuiPointF(x2, y2);

  FShapes.Add(shape);
end;

procedure TXuiSvgDoc.ParsePolyElement(AEl: TDOMElement; IsPolygon: Boolean;
  const AFill, AStroke: string; AStrokeWidth, AOpacity: Single);
var
  pointsStr: string;
  scanner: TSvgPathScanner;
  x, y: Single;
  first: Boolean;
  shape: TSvgShape;
  firstPt: TXuiPointF;

  procedure Add(AKind: TXuiPathCmdKind; const P: TXuiPointF);
  var
    n: Integer;
  begin
    n := Length(shape.Cmds);
    SetLength(shape.Cmds, n + 1);
    shape.Cmds[n].Kind := AKind;
    shape.Cmds[n].P1 := P;
    shape.Cmds[n].P2 := P;
    shape.Cmds[n].P3 := P;
  end;

var
  dummyCh: Char;
  isNum: Boolean;
begin
  pointsStr := AEl.GetAttribute('points');
  if Trim(pointsStr) = '' then Exit;

  shape := TSvgShape.Create;
  ApplyStyles(shape, AEl, AFill, AStroke, AStrokeWidth, AOpacity, IsPolygon);

  scanner := TSvgPathScanner.Create(pointsStr);
  try
    first := True;
    firstPt := XuiPointF(0, 0);
    while scanner.HasMore do
    begin
      if not (scanner.NextToken(dummyCh, x, isNum) and isNum) then Break;
      if not (scanner.NextToken(dummyCh, y, isNum) and isNum) then Break;

      if first then
      begin
        firstPt := XuiPointF(x, y);
        Add(pckMoveTo, firstPt);
        first := False;
      end
      else
        Add(pckLineTo, XuiPointF(x, y));
    end;

    if IsPolygon and (not first) then
      Add(pckClose, firstPt);
  finally
    scanner.Free;
  end;

  FShapes.Add(shape);
end;

procedure TXuiSvgDoc.ParseNode(ANode: TDOMNode; const AParentFill, AParentStroke: string;
  AParentStrokeWidth, AParentOpacity: Single);
var
  child: TDOMNode;
  el: TDOMElement;
  tag: string;
  curFill, curStroke: string;
  curSW, curOp: Single;
begin
  if ANode.NodeType <> ELEMENT_NODE then Exit;
  el := TDOMElement(ANode);
  tag := LowerCase(el.TagName);

  // 分组或当前节点属性继承
  curFill := GetAttrOrStyle(el, 'fill', AParentFill);
  curStroke := GetAttrOrStyle(el, 'stroke', AParentStroke);
  curSW := SvgParseFloat(GetAttrOrStyle(el, 'stroke-width', ''), AParentStrokeWidth);
  curOp := AParentOpacity * SvgParseFloat(GetAttrOrStyle(el, 'opacity', ''), 1.0);

  if tag = 'path' then
    ParsePathElement(el, curFill, curStroke, curSW, curOp)
  else if tag = 'rect' then
    ParseRectElement(el, curFill, curStroke, curSW, curOp)
  else if tag = 'circle' then
    ParseCircleElement(el, curFill, curStroke, curSW, curOp)
  else if tag = 'ellipse' then
    ParseEllipseElement(el, curFill, curStroke, curSW, curOp)
  else if tag = 'line' then
    ParseLineElement(el, curFill, curStroke, curSW, curOp)
  else if tag = 'polyline' then
    ParsePolyElement(el, False, curFill, curStroke, curSW, curOp)
  else if tag = 'polygon' then
    ParsePolyElement(el, True, curFill, curStroke, curSW, curOp)
  else
  begin
    // 递归子节点（如 <svg>、<g>、<a>）
    child := el.FirstChild;
    while child <> nil do
    begin
      ParseNode(child, curFill, curStroke, curSW, curOp);
      child := child.NextSibling;
    end;
  end;
end;

procedure TXuiSvgDoc.LoadFromString(const AXml: string);
var
  stream: TStringStream;
  doc: TXMLDocument;
  root: TDOMElement;
  vbStr: string;
  vbScanner: TSvgPathScanner;
  vbx, vby, vbw, vbh: Single;
  dummyCh: Char;
  isNum: Boolean;
begin
  Clear;
  if Trim(AXml) = '' then Exit;

  stream := TStringStream.Create(AXml);
  doc := nil;
  try
    try
      ReadXMLFile(doc, stream);
    except
      Exit;
    end;
    if doc = nil then Exit;

    root := doc.DocumentElement;
    if root = nil then Exit;

    FWidth := SvgParseFloat(root.GetAttribute('width'), 0);
    FHeight := SvgParseFloat(root.GetAttribute('height'), 0);

    // 解析 viewBox
    vbStr := root.GetAttribute('viewBox');
    if vbStr <> '' then
    begin
      vbScanner := TSvgPathScanner.Create(vbStr);
      try
        if (vbScanner.NextToken(dummyCh, vbx, isNum) and isNum) and
           (vbScanner.NextToken(dummyCh, vby, isNum) and isNum) and
           (vbScanner.NextToken(dummyCh, vbw, isNum) and isNum) and
           (vbScanner.NextToken(dummyCh, vbh, isNum) and isNum) then
        begin
          FViewBox := XuiRectF(vbx, vby, vbx + vbw, vby + vbh);
          FHasViewBox := (vbw > 0) and (vbh > 0);
          if FWidth <= 0 then FWidth := vbw;
          if FHeight <= 0 then FHeight := vbh;
        end;
      finally
        vbScanner.Free;
      end;
    end;

    // 解析所有子图元
    ParseNode(root, 'currentColor', '', 1.0, 1.0);
  finally
    if doc <> nil then doc.Free;
    stream.Free;
  end;
end;

procedure TXuiSvgDoc.LoadFromFile(const AFileName: string);
var
  list: TStringList;
begin
  if not FileExists(AFileName) then Exit;
  list := TStringList.Create;
  try
    list.LoadFromFile(AFileName);
    LoadFromString(list.Text);
  finally
    list.Free;
  end;
end;

procedure TXuiSvgDoc.LoadFromXuiNode(ANode: TXuiNode);
var
  vbStr: string;
  vbScanner: TSvgPathScanner;
  vbx, vby, vbw, vbh: Single;
  dummyCh: Char;
  isNum: Boolean;

  procedure ParseXuiNode(N: TXuiNode; const AParentFill, AParentStroke: string;
    AParentStrokeWidth, AParentOpacity: Single);
  var
    tag, curFill, curStroke: string;
    curSW, curOp: Single;
    shape: TSvgShape;
    k: Single;
    x, y, w, h, rx, ry, dx, dy: Single;
    cx, cy, r: Single;
    x1, y1, x2, y2: Single;
    pointsStr: string;
    sc: TSvgPathScanner;
    first: Boolean;
    firstPt: TXuiPointF;
    ch: Char;
    idx: Integer;

    function GetNAttr(const AName: string; const ADef: string = ''): string;
    begin
      if N.Attributes <> nil then
        Result := N.Attributes.Values[AName]
      else
        Result := '';
      if Result = '' then Result := ADef;
    end;

    procedure ApplyXuiStyles(AShape: TSvgShape; DefFill: Boolean);
    var
      fillStr, strokeStr, swStr, opStr: string;
    begin
      fillStr := GetNAttr('fill', AParentFill);
      strokeStr := GetNAttr('stroke', AParentStroke);
      swStr := GetNAttr('stroke-width', '');
      opStr := GetNAttr('opacity', '');
      if opStr <> '' then
        AShape.Opacity := AParentOpacity * SvgParseFloat(opStr, 1.0)
      else
        AShape.Opacity := AParentOpacity;

      if fillStr = '' then
      begin
        AShape.HasFill := DefFill;
        AShape.Fill := XuiRGB(0, 0, 0);
      end
      else if SameText(fillStr, 'none') then
        AShape.HasFill := False
      else if SameText(fillStr, 'currentColor') then
      begin
        AShape.HasFill := True;
        AShape.IsCurrentColorFill := True;
      end
      else
      begin
        AShape.HasFill := True;
        AShape.Fill := ParseCssColor(fillStr);
      end;

      if (strokeStr = '') or SameText(strokeStr, 'none') then
        AShape.HasStroke := False
      else if SameText(strokeStr, 'currentColor') then
      begin
        AShape.HasStroke := True;
        AShape.IsCurrentColorStroke := True;
      end
      else
      begin
        AShape.HasStroke := True;
        AShape.Stroke := ParseCssColor(strokeStr);
      end;

      if swStr <> '' then
        AShape.StrokeWidth := SvgParseFloat(swStr, 1.0)
      else
        AShape.StrokeWidth := AParentStrokeWidth;
    end;

    procedure AddShapeCmd(AKind: TXuiPathCmdKind; const P1, P2, P3: TXuiPointF);
    var
      cmdLen: Integer;
    begin
      cmdLen := Length(shape.Cmds);
      SetLength(shape.Cmds, cmdLen + 1);
      shape.Cmds[cmdLen].Kind := AKind;
      shape.Cmds[cmdLen].P1 := P1;
      shape.Cmds[cmdLen].P2 := P2;
      shape.Cmds[cmdLen].P3 := P3;
    end;

  begin
    if N = nil then Exit;
    tag := LowerCase(N.Tag);
    curFill := GetNAttr('fill', AParentFill);
    curStroke := GetNAttr('stroke', AParentStroke);
    curSW := SvgParseFloat(GetNAttr('stroke-width', ''), AParentStrokeWidth);
    curOp := AParentOpacity * SvgParseFloat(GetNAttr('opacity', ''), 1.0);

    if tag = 'path' then
    begin
      if GetNAttr('d') <> '' then
      begin
        shape := TSvgShape.Create;
        ApplyXuiStyles(shape, True);
        shape.Cmds := ParseSvgPath(GetNAttr('d'));
        FShapes.Add(shape);
      end;
    end
    else if tag = 'rect' then
    begin
      x := SvgParseFloat(GetNAttr('x'), 0);
      y := SvgParseFloat(GetNAttr('y'), 0);
      w := SvgParseFloat(GetNAttr('width'), 0);
      h := SvgParseFloat(GetNAttr('height'), 0);
      rx := SvgParseFloat(GetNAttr('rx'), 0);
      ry := SvgParseFloat(GetNAttr('ry'), 0);
      if (w > 0) and (h > 0) then
      begin
        shape := TSvgShape.Create;
        ApplyXuiStyles(shape, True);
        if (rx <= 0) and (ry <= 0) then
        begin
          AddShapeCmd(pckMoveTo, XuiPointF(x, y), XuiPointF(x, y), XuiPointF(x, y));
          AddShapeCmd(pckLineTo, XuiPointF(x + w, y), XuiPointF(x + w, y), XuiPointF(x + w, y));
          AddShapeCmd(pckLineTo, XuiPointF(x + w, y + h), XuiPointF(x + w, y + h), XuiPointF(x + w, y + h));
          AddShapeCmd(pckLineTo, XuiPointF(x, y + h), XuiPointF(x, y + h), XuiPointF(x, y + h));
          AddShapeCmd(pckClose, XuiPointF(x, y), XuiPointF(x, y), XuiPointF(x, y));
        end
        else
        begin
          if (rx > 0) and (ry = 0) then ry := rx
          else if (ry > 0) and (rx = 0) then rx := ry;
          rx := Min(rx, w / 2.0);
          ry := Min(ry, h / 2.0);
          k := 0.55228475;
          dx := rx * k;
          dy := ry * k;
          AddShapeCmd(pckMoveTo, XuiPointF(x + rx, y), XuiPointF(x + rx, y), XuiPointF(x + rx, y));
          AddShapeCmd(pckLineTo, XuiPointF(x + w - rx, y), XuiPointF(x + w - rx, y), XuiPointF(x + w - rx, y));
          AddShapeCmd(pckBezierTo, XuiPointF(x + w - rx + dx, y), XuiPointF(x + w, y + ry - dy), XuiPointF(x + w, y + ry));
          AddShapeCmd(pckLineTo, XuiPointF(x + w, y + h - ry), XuiPointF(x + w, y + h - ry), XuiPointF(x + w, y + h - ry));
          AddShapeCmd(pckBezierTo, XuiPointF(x + w, y + h - ry + dy), XuiPointF(x + w - rx + dx, y + h), XuiPointF(x + w - rx, y + h));
          AddShapeCmd(pckLineTo, XuiPointF(x + rx, y + h), XuiPointF(x + rx, y + h), XuiPointF(x + rx, y + h));
          AddShapeCmd(pckBezierTo, XuiPointF(x + rx - dx, y + h), XuiPointF(x, y + h - ry + dy), XuiPointF(x, y + h - ry));
          AddShapeCmd(pckLineTo, XuiPointF(x, y + ry), XuiPointF(x, y + ry), XuiPointF(x, y + ry));
          AddShapeCmd(pckBezierTo, XuiPointF(x, y + ry - dy), XuiPointF(x + rx - dx, y), XuiPointF(x + rx, y));
          AddShapeCmd(pckClose, XuiPointF(x + rx, y), XuiPointF(x + rx, y), XuiPointF(x + rx, y));
        end;
        FShapes.Add(shape);
      end;
    end
    else if tag = 'circle' then
    begin
      cx := SvgParseFloat(GetNAttr('cx'), 0);
      cy := SvgParseFloat(GetNAttr('cy'), 0);
      r := SvgParseFloat(GetNAttr('r'), 0);
      if r > 0 then
      begin
        shape := TSvgShape.Create;
        ApplyXuiStyles(shape, True);
        k := 0.55228475;
        dx := r * k;
        dy := r * k;
        AddShapeCmd(pckMoveTo, XuiPointF(cx + r, cy), XuiPointF(cx + r, cy), XuiPointF(cx + r, cy));
        AddShapeCmd(pckBezierTo, XuiPointF(cx + r, cy + dy), XuiPointF(cx + dx, cy + r), XuiPointF(cx, cy + r));
        AddShapeCmd(pckBezierTo, XuiPointF(cx - dx, cy + r), XuiPointF(cx - r, cy + dy), XuiPointF(cx - r, cy));
        AddShapeCmd(pckBezierTo, XuiPointF(cx - r, cy - dy), XuiPointF(cx - dx, cy - r), XuiPointF(cx, cy - r));
        AddShapeCmd(pckBezierTo, XuiPointF(cx + dx, cy - r), XuiPointF(cx + r, cy - dy), XuiPointF(cx + r, cy));
        AddShapeCmd(pckClose, XuiPointF(cx + r, cy), XuiPointF(cx + r, cy), XuiPointF(cx + r, cy));
        FShapes.Add(shape);
      end;
    end
    else if tag = 'line' then
    begin
      x1 := SvgParseFloat(GetNAttr('x1'), 0);
      y1 := SvgParseFloat(GetNAttr('y1'), 0);
      x2 := SvgParseFloat(GetNAttr('x2'), 0);
      y2 := SvgParseFloat(GetNAttr('y2'), 0);
      shape := TSvgShape.Create;
      ApplyXuiStyles(shape, False);
      AddShapeCmd(pckMoveTo, XuiPointF(x1, y1), XuiPointF(x1, y1), XuiPointF(x1, y1));
      AddShapeCmd(pckLineTo, XuiPointF(x2, y2), XuiPointF(x2, y2), XuiPointF(x2, y2));
      FShapes.Add(shape);
    end
    else if (tag = 'polyline') or (tag = 'polygon') then
    begin
      pointsStr := GetNAttr('points');
      if Trim(pointsStr) <> '' then
      begin
        shape := TSvgShape.Create;
        ApplyXuiStyles(shape, tag = 'polygon');
        sc := TSvgPathScanner.Create(pointsStr);
        try
          first := True;
          firstPt := XuiPointF(0, 0);
          while sc.HasMore do
          begin
            if not (sc.NextToken(ch, x, isNum) and isNum) then Break;
            if not (sc.NextToken(ch, y, isNum) and isNum) then Break;
            if first then
            begin
              firstPt := XuiPointF(x, y);
              AddShapeCmd(pckMoveTo, firstPt, firstPt, firstPt);
              first := False;
            end
            else
              AddShapeCmd(pckLineTo, XuiPointF(x, y), XuiPointF(x, y), XuiPointF(x, y));
          end;
          if (tag = 'polygon') and (not first) then
            AddShapeCmd(pckClose, firstPt, firstPt, firstPt);
        finally
          sc.Free;
        end;
        FShapes.Add(shape);
      end;
    end;

    // 递归子节点
    for idx := 0 to N.Count - 1 do
      ParseXuiNode(N[idx], curFill, curStroke, curSW, curOp);
  end;

begin
  Clear;
  if ANode = nil then Exit;

  if (ANode.Attributes <> nil) then
  begin
    FWidth := SvgParseFloat(ANode.Attributes.Values['width'], 0);
    FHeight := SvgParseFloat(ANode.Attributes.Values['height'], 0);
    vbStr := ANode.Attributes.Values['viewbox'];
    if vbStr = '' then vbStr := ANode.Attributes.Values['viewBox'];
  end
  else
  begin
    FWidth := 0;
    FHeight := 0;
    vbStr := '';
  end;

  if vbStr <> '' then
  begin
    vbScanner := TSvgPathScanner.Create(vbStr);
    try
      if (vbScanner.NextToken(dummyCh, vbx, isNum) and isNum) and
         (vbScanner.NextToken(dummyCh, vby, isNum) and isNum) and
         (vbScanner.NextToken(dummyCh, vbw, isNum) and isNum) and
         (vbScanner.NextToken(dummyCh, vbh, isNum) and isNum) then
      begin
        FViewBox := XuiRectF(vbx, vby, vbx + vbw, vby + vbh);
        FHasViewBox := (vbw > 0) and (vbh > 0);
        if FWidth <= 0 then FWidth := vbw;
        if FHeight <= 0 then FHeight := vbh;
      end;
    finally
      vbScanner.Free;
    end;
  end;

  ParseXuiNode(ANode, 'currentColor', '', 1.0, 1.0);
end;

procedure TXuiSvgDoc.Render(ARenderer: TXuiCustomRenderer; const ARect: TRect;
  const ACurrentColor: TXuiColor);
var
  i, j: Integer;
  shape: TSvgShape;
  vbW, vbH, destW, destH, scaleX, scaleY, scale, dx, dy: Single;
  fillCol, strokeCol: TXuiColor;
  screenCmds: TXuiPathCmdArray;
  cmd: TXuiPathCmd;

  function TransformPt(const P: TXuiPointF): TXuiPointF;
  begin
    Result.X := P.X * scale + dx;
    Result.Y := P.Y * scale + dy;
  end;

begin
  if (ARenderer = nil) or (FShapes.Count = 0) then Exit;

  destW := ARect.Right - ARect.Left;
  destH := ARect.Bottom - ARect.Top;
  if (destW <= 0) or (destH <= 0) then Exit;

  // 坐标系映射计算
  if FHasViewBox and ((FViewBox.Right - FViewBox.Left) > 0) and ((FViewBox.Bottom - FViewBox.Top) > 0) then
  begin
    vbW := FViewBox.Right - FViewBox.Left;
    vbH := FViewBox.Bottom - FViewBox.Top;
    scaleX := destW / vbW;
    scaleY := destH / vbH;
    scale := Min(scaleX, scaleY);
    dx := ARect.Left + (destW - vbW * scale) / 2.0 - FViewBox.Left * scale;
    dy := ARect.Top + (destH - vbH * scale) / 2.0 - FViewBox.Top * scale;
  end
  else if (FWidth > 0) and (FHeight > 0) then
  begin
    scaleX := destW / FWidth;
    scaleY := destH / FHeight;
    scale := Min(scaleX, scaleY);
    dx := ARect.Left + (destW - FWidth * scale) / 2.0;
    dy := ARect.Top + (destH - FHeight * scale) / 2.0;
  end
  else
  begin
    scale := 1.0;
    dx := ARect.Left;
    dy := ARect.Top;
  end;

  for i := 0 to FShapes.Count - 1 do
  begin
    shape := TSvgShape(FShapes[i]);
    if Length(shape.Cmds) = 0 then Continue;

    // 填充颜色处理
    if shape.IsCurrentColorFill then
      fillCol := ACurrentColor
    else if shape.HasFill then
      fillCol := shape.Fill
    else
      fillCol.A := 0;

    if fillCol.A > 0 then
      fillCol.A := Round(fillCol.A * shape.Opacity * shape.FillOpacity);

    // 描边颜色处理
    if shape.IsCurrentColorStroke then
      strokeCol := ACurrentColor
    else if shape.HasStroke then
      strokeCol := shape.Stroke
    else
      strokeCol.A := 0;

    if strokeCol.A > 0 then
      strokeCol.A := Round(strokeCol.A * shape.Opacity * shape.StrokeOpacity);

    if (fillCol.A = 0) and (strokeCol.A = 0) then
      Continue;

    // 坐标变换
    SetLength(screenCmds, Length(shape.Cmds));
    for j := 0 to High(shape.Cmds) do
    begin
      cmd := shape.Cmds[j];
      case cmd.Kind of
        pckMoveTo, pckLineTo:
        begin
          cmd.P1 := TransformPt(cmd.P1);
        end;
        pckBezierTo:
        begin
          cmd.P1 := TransformPt(cmd.P1);
          cmd.P2 := TransformPt(cmd.P2);
          cmd.P3 := TransformPt(cmd.P3);
        end;
        pckClose: ;
      end;
      screenCmds[j] := cmd;
    end;

    // 发起矢量渲染
    ARenderer.RenderPath(screenCmds, fillCol, strokeCol, shape.StrokeWidth * scale);
  end;
end;

end.
