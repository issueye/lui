unit xui_input;

{$mode objfpc}{$H+}

{ 单行输入框行为（M5 产品化）。
  - 值即节点 Text（初值来自 value/text 属性）；编辑态（光标/选区/水平滚动）在行为对象内
  - 键盘：字符插入、Backspace/Delete、←/→/Home/End、Shift 扩选、Ctrl+A/C/X/V
  - 鼠标：点按定位光标；按住拖动选择（引擎指针捕捉把移动/抬起优先派发给本节点）
  - 绘制：RenderContent 自绘值/掩码/选区/光标/占位符（引擎的默认 RenderText 被跳过）
  - IME：上屏文本经引擎 HandleTextInput 到达（宿主转发 LCL 的 UTF8KeyPress）；
    组合窗定位由宿主用 CaretRect 完成 }

interface

uses
  Classes, SysUtils, Types, Math, Clipbrd, LCLType,
  xui_types, xui_style, xui_dom, xui_events, xui_render, xui_widget, xui_text;

type
  // 剪贴板钩子（默认走 LCL Clipboard；测试可替换，避免依赖系统剪贴板）
  TXuiClipboardGetFunc = function: string;
  TXuiClipboardSetProc = procedure(const AText: string);

var
  XuiClipboardGet: TXuiClipboardGetFunc = nil;
  XuiClipboardSet: TXuiClipboardSetProc = nil;

type
  TXuiInputBehavior = class(TXuiBehavior)
  protected
    FCaret: Integer;            // 光标字节偏移（0..Length(Text)）
    FAnchor: Integer;           // 选区锚点；= FCaret 表示无选区
    FScrollX: Single;           // 水平滚动（像素）
    FPassword: Boolean;
    FPlaceholder: string;
    FMaxLength: Integer;        // 0 = 不限（按码点数）
    FDragging: Boolean;
    FMeasure: TXuiMeasureFunc;  // 最近一次绘制的测量回调（鼠标定位复用）
    FCaretRect: TRect;          // 最近一次绘制后的光标矩形（客户区，IME 定位用）
    function SelLo: Integer;
    function SelHi: Integer;
    function HasSelection: Boolean;
    function DisplayText: string;
    function DisplayPrefix(AByteOffset: Integer): string;
    function ValueIndexByCount(ACount: Integer): Integer;
    procedure SetCaret(APos: Integer; AExtend: Boolean);
    procedure DeleteRange(ALo, AHi: Integer);
    // 插入文本（单行输入折叠换行；多行输入覆盖为保留换行）
    procedure InsertText(const AText: string); virtual;
    function AlignOffset(ANode: TXuiNode; ATextW: Single): Single;
    function TextWidth(ANode: TXuiNode; const AText: string): Single;
    function PosFromX(ANode: TXuiNode; AX: Integer): Integer;
    function HandleEditingKey(ANode: TXuiNode; AKey: Word; AShift: TXuiShiftState): Boolean;
  public
    procedure HandleAttribute(const AName, AValue: string); override;
    // M8：运行时属性（声明式绑定 :placeholder / :password / :maxlength）
    function SetRuntimeAttr(const AName, AValue: string): Boolean; override;
    function CanFocus: Boolean; override;
    function HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean; override;
    function RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
      AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean; override;
    function NeedsPointerCapture: Boolean; override;
    function WantsCaret: Boolean; override;
    function CaretRect(ANode: TXuiNode; out ARect: TRect): Boolean; override;
    procedure SetDisabled(AValue: Boolean); override;
  end;

  // R1：多行输入（textarea）。复用单行输入的编辑模型（值即 Node.Text、光标/选区为字节偏移），
  // 增加：按内容宽软换行、显式换行、行内定位（Home/End）、上下行移动（按像素亲和）、
  // 垂直+水平滚动（复用引擎滚动模型：上报 ContentHeight/ContentWidth + ScrollTop/ScrollLeft）。
  //
  // Enter 策略由属性 `enterkey` 选择（引擎不把应用策略写死）：
  //   enterkey="newline"（默认，贴近浏览器 textarea）：Enter 换行，Ctrl+Enter 提交（派发 onenter）
  //   enterkey="submit"（聊天/表单输入）：Enter 提交，Shift+Enter 换行
  //
  // 已知边界（与不支持清单同步）：不做自动增高上限（建议显式 CSS height）、Tab 仍是焦点遍历、
  // 不可断长词允许溢出（与引擎断行规则一致）、无撤销/重做。
  TXuiTextAreaBehavior = class(TXuiInputBehavior)
  private
    FSubmitOnEnter: Boolean;
    FScrollCaret: Integer;   // 上次执行光标跟随时的光标位置（-1 = 未跟随过）
    function LineHeightOf(ANode: TXuiNode): Single;
    function PosFromXY(ANode: TXuiNode; AX, AY: Integer): Integer;
    function HandleTextAreaKey(ANode: TXuiNode; AKey: Word;
      AShift: TXuiShiftState): Boolean;
  public
    constructor Create;
    procedure HandleAttribute(const AName, AValue: string); override;
    function HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean; override;
    procedure InsertText(const AText: string); override;
    function RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
      AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean; override;
  end;

implementation

const
  XuiMaskChar = '●';
  XuiCaretWidth = 1;

function XuiReadClipboard: string;
begin
  Result := '';
  if Assigned(XuiClipboardGet) then
    Exit(XuiClipboardGet());
  try
    Result := Clipboard.AsText;
  except
    Result := '';
  end;
end;

procedure XuiWriteClipboard(const AText: string);
begin
  if Assigned(XuiClipboardSet) then
  begin
    XuiClipboardSet(AText);
    Exit;
  end;
  try
    Clipboard.AsText := AText;
  except
    // 无剪贴板环境（控制台测试等）：忽略
  end;
end;

// 单行化：换行/制表折成空格
function XuiSingleLine(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
end;

// 截取前 ACount 个码点
function XuiTruncateUtf8(const AText: string; ACount: Integer): string;
var
  i, n, len: Integer;
begin
  Result := '';
  if ACount <= 0 then
    Exit;
  i := 1;
  n := 0;
  while (i <= Length(AText)) and (n < ACount) do
  begin
    Utf8CodeAt(AText, i, len);
    Inc(i, len);
    Inc(n);
  end;
  Result := Copy(AText, 1, i - 1);
end;

// 把字节偏移对齐到 UTF-8 码点边界。
// 位置 P 合法 ⇔ P 之后的那个字节不是续字节（$80-$BF）；若在字符中间则回退到该字符起点。
// 注意判定要看 P+1：合法边界处 AText[P] 是上一个字符的末尾（多字节时本身就是续字节）。
function XuiSnapIndex(const AText: string; APos: Integer): Integer;
begin
  Result := APos;
  if Result < 0 then
    Result := 0;
  if Result > Length(AText) then
    Result := Length(AText);
  while (Result > 0) and (Result < Length(AText)) and
        ((Byte(AText[Result + 1]) and $C0) = $80) do
    Dec(Result);
end;

{ ---------------- R1：多行输入（textarea） ---------------- }

type
  // 一个视觉行（软换行后）：值中的字节区间 + 行宽
  TTextAreaLine = record
    StartByte: Integer;
    Len: Integer;
    Width: Single;
  end;
  TTextAreaLineArray = array of TTextAreaLine;

// 与 xui_text 的 CJK 判定保持一致（可作为断行点）
function TextAreaBreakable(ACode: LongWord): Boolean;
begin
  Result :=
    ((ACode >= $2E80) and (ACode <= $9FFF)) or
    ((ACode >= $A960) and (ACode <= $A97F)) or
    ((ACode >= $AC00) and (ACode <= $D7AF)) or
    ((ACode >= $F900) and (ACode <= $FAFF)) or
    ((ACode >= $FE30) and (ACode <= $FE4F)) or
    ((ACode >= $FF00) and (ACode <= $FF60)) or
    ((ACode >= $FFE0) and (ACode <= $FFE6));
end;

function MeasureTextSimple(const AText: string; AStyle: TXuiStyle;
  AMeasure: TXuiMeasureFunc): Single;
begin
  if AStyle = nil then
    Exit(0);
  if AMeasure <> nil then
    Result := AMeasure(AText, AStyle).cx
  else
    Result := Length(AText) * AStyle.FontSize * 0.6;
end;

// 行内第 ACount 个码点对应的字节偏移（截断到行尾）
function TextAreaByteAtCount(const AValue: string; const ALine: TTextAreaLine;
  ACount: Integer): Integer;
var
  k, l, n: Integer;
begin
  k := ALine.StartByte;
  n := 0;
  while (n < ACount) and (k < ALine.StartByte + ALine.Len) do
  begin
    Utf8CodeAt(AValue, k + 1, l);
    Inc(k, l);
    Inc(n);
  end;
  Result := XuiSnapIndex(AValue, k);
end;

// 行内 x 像素 → 码点序号（就近取整）
function TextAreaCountAtX(const ALineText: string; AStyle: TXuiStyle;
  AMeasure: TXuiMeasureFunc; AX: Single): Integer;
var
  k, l, count: Integer;
  w, best: Single;
begin
  Result := 0;
  count := 0;
  best := Abs(AX);
  k := 1;
  while k <= Length(ALineText) do
  begin
    Utf8CodeAt(ALineText, k, l);
    Inc(k, l);
    Inc(count);
    w := MeasureTextSimple(Copy(ALineText, 1, k - 1), AStyle, AMeasure);
    if Abs(w - AX) < best then
    begin
      best := Abs(w - AX);
      Result := count;
    end;
  end;
end;

// 断行：先按 #10 切逻辑行，再按内容宽软断行；空格与 CJK 处可断，不可断长词允许溢出
procedure BuildTextAreaLines(const AValue: string; AStyle: TXuiStyle;
  AMaxW: Single; AMeasure: TXuiMeasureFunc; out ALines: TTextAreaLineArray);
var
  n, pos, nlPos, i, next, lastBreak, len: Integer;
  code: LongWord;
  progressed: Boolean;

  procedure Emit(AStart, ALen: Integer);
  begin
    if n >= Length(ALines) then
      SetLength(ALines, n * 2 + 8);
    ALines[n].StartByte := AStart;
    ALines[n].Len := ALen;
    ALines[n].Width := MeasureTextSimple(Copy(AValue, AStart + 1, ALen), AStyle, AMeasure);
    Inc(n);
  end;

begin
  n := 0;
  SetLength(ALines, 0);
  pos := 0;
  while pos <= Length(AValue) do
  begin
    nlPos := pos;
    while (nlPos < Length(AValue)) and (AValue[nlPos + 1] <> #10) do
      Inc(nlPos);

    if nlPos = pos then
      Emit(pos, 0) // 空逻辑行（连续换行 / 结尾换行）
    else
    // 软断行 [pos, nlPos)：每轮至少产出一行，避免死循环
    while pos < nlPos do
    begin
      lastBreak := -1;
      i := pos;
      progressed := False;
      while i < nlPos do
      begin
        code := Utf8CodeAt(AValue, i + 1, len);
        next := i + len;
        // 先判溢出：优先在“当前字符之前”的最后一个可断点断行（空格 / CJK）
        if (AMaxW > 0) and
           (MeasureTextSimple(Copy(AValue, pos + 1, next - pos), AStyle, AMeasure) > AMaxW) then
        begin
          if lastBreak > pos then
          begin
            Emit(pos, lastBreak - pos);
            pos := lastBreak;
            while (pos < nlPos) and (AValue[pos + 1] = ' ') do
              Inc(pos);
            progressed := True;
            Break;
          end
          else if i > pos then
          begin
            // 无可断点：按字符硬断（textarea 语义：长串也要换行，不横向溢出）
            Emit(pos, i - pos);
            pos := i;
            // 新行首的空白丢弃（与引擎断行规则一致，避免行首缩进空档）
            while (pos < nlPos) and (AValue[pos + 1] = ' ') do
              Inc(pos);
            progressed := True;
            Break;
          end;
          // 单字符就超宽：放行该字符（避免死循环），下一字符再判
        end;
        if code = 32 then
          lastBreak := i
        else if TextAreaBreakable(code) then
          lastBreak := next;
        i := next;
      end;
      if not progressed then
      begin
        Emit(pos, nlPos - pos);
        pos := nlPos;
      end;
    end;
    pos := nlPos + 1; // 跳过换行符
  end;
  SetLength(ALines, n);
end;

// 光标所在的视觉行：最后一个 StartByte <= AByte 的行
function TextAreaLineAtByte(const ALines: TTextAreaLineArray; AByte: Integer): Integer;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(ALines) do
    if ALines[k].StartByte <= AByte then
      Result := k;
end;

{ TXuiTextAreaBehavior }

function TXuiTextAreaBehavior.LineHeightOf(ANode: TXuiNode): Single;
begin
  Result := 0;
  if ANode.Style = nil then
    Exit;
  Result := LineHeightPx(ANode.Style);
  if Result <= 0 then
    Result := ANode.Style.FontSize * 1.4;
end;

constructor TXuiTextAreaBehavior.Create;
begin
  inherited Create;
  FScrollCaret := -1;
end;

procedure TXuiTextAreaBehavior.HandleAttribute(const AName, AValue: string);
begin
  inherited HandleAttribute(AName, AValue);
  if FNode <> nil then
    FNode.SelfScrolls := True; // 滚动范围由本行为上报
  if CompareText(AName, 'enterkey') = 0 then
    FSubmitOnEnter := CompareText(Trim(AValue), 'submit') = 0;
end;

procedure TXuiTextAreaBehavior.InsertText(const AText: string);
var
  text, value, prefix, suffix: string;
  lo, hi, keep: Integer;
begin
  if (FNode = nil) or (AText = '') then
    Exit;
  // 多行：保留换行（统一为 LF）；制表符折叠为空格（引擎无制表位模型）
  text := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  text := StringReplace(text, #13, #10, [rfReplaceAll]);
  text := StringReplace(text, #9, ' ', [rfReplaceAll]);
  if text = '' then
    Exit;
  value := FNode.Text;
  lo := SelLo;
  hi := SelHi;
  prefix := Copy(value, 1, lo);
  suffix := Copy(value, hi + 1, Length(value));
  if FMaxLength > 0 then
  begin
    keep := FMaxLength - Utf8Length(prefix) - Utf8Length(suffix);
    if keep <= 0 then
      Exit;
    text := XuiTruncateUtf8(text, keep);
  end;
  FNode.Text := prefix + text + suffix;
  FCaret := lo + Length(text);
  FAnchor := FCaret;
end;

function TXuiTextAreaBehavior.PosFromXY(ANode: TXuiNode; AX, AY: Integer): Integer;
var
  lines: TTextAreaLineArray;
  content: TRect;
  lineH: Single;
  idx: Integer;
begin
  Result := FCaret;
  if (ANode.Style = nil) or (FNode <> ANode) then
    Exit;
  content := ANode.ContentBox;
  BuildTextAreaLines(FNode.Text, ANode.Style, content.Right - content.Left, FMeasure, lines);
  if Length(lines) = 0 then
    Exit(0);
  lineH := LineHeightOf(ANode);
  if lineH <= 0 then
    Exit(FCaret);
  idx := Trunc((AY - content.Top + ANode.ScrollTop) / lineH);
  if idx < 0 then
    idx := 0;
  if idx > High(lines) then
    idx := High(lines);
  Result := TextAreaByteAtCount(FNode.Text, lines[idx],
    TextAreaCountAtX(Copy(FNode.Text, lines[idx].StartByte + 1, lines[idx].Len),
      ANode.Style, FMeasure, AX - content.Left + ANode.ScrollLeft));
end;

function TXuiTextAreaBehavior.HandleTextAreaKey(ANode: TXuiNode; AKey: Word;
  AShift: TXuiShiftState): Boolean;
var
  lines: TTextAreaLineArray;
  content: TRect;
  idx, target, col: Integer;
  caretX: Single;
  prefix: string;
  extend: Boolean;
begin
  Result := False;
  if (ANode.Style = nil) or (FNode <> ANode) then
    Exit;
  content := ANode.ContentBox;
  BuildTextAreaLines(FNode.Text, ANode.Style, content.Right - content.Left, FMeasure, lines);
  if Length(lines) = 0 then
    Exit;
  extend := xssShift in AShift;
  idx := TextAreaLineAtByte(lines, FCaret);
  case AKey of
    VK_RETURN:
      if FSubmitOnEnter then
      begin
        // submit 策略：Enter 提交（交引擎派发 onenter），Shift+Enter 换行
        if xssShift in AShift then
        begin
          InsertText(#10);
          Result := True;
        end;
      end
      else if xssCtrl in AShift then
        Result := False // 默认策略：Ctrl+Enter 提交
      else
      begin
        InsertText(#10);
        Result := True;
      end;
    VK_UP, VK_DOWN:
      begin
        prefix := Copy(FNode.Text, lines[idx].StartByte + 1, FCaret - lines[idx].StartByte);
        caretX := MeasureTextSimple(prefix, ANode.Style, FMeasure);
        if AKey = VK_UP then
          target := idx - 1
        else
          target := idx + 1;
        if (target >= 0) and (target <= High(lines)) then
        begin
          col := TextAreaCountAtX(Copy(FNode.Text, lines[target].StartByte + 1, lines[target].Len),
            ANode.Style, FMeasure, caretX);
          SetCaret(TextAreaByteAtCount(FNode.Text, lines[target], col), extend);
        end
        else
          SetCaret(FCaret, extend);
        Result := True;
      end;
    VK_HOME:
      begin
        if xssCtrl in AShift then
          SetCaret(0, extend)
        else
          SetCaret(lines[idx].StartByte, extend);
        Result := True;
      end;
    VK_END:
      begin
        if xssCtrl in AShift then
          SetCaret(Length(FNode.Text), extend)
        else
          SetCaret(lines[idx].StartByte + lines[idx].Len, extend);
        Result := True;
      end;
  end;
end;

function TXuiTextAreaBehavior.HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
begin
  Result := False;
  if XuiIsDisabled(ANode) then
    Exit;
  case AEvent.Kind of
    xevKeyDown:
      begin
        if HandleTextAreaKey(ANode, AEvent.Key, AEvent.Shift) then
          Exit(True);
        // 其余编辑键与文本输入复用单行输入实现（InsertText 已被覆盖）
        Exit(inherited HandleEvent(ANode, AEvent));
      end;
    xevMouseDown:
      begin
        FDragging := True;
        SetCaret(PosFromXY(ANode, AEvent.X, AEvent.Y), False);
        Exit(True);
      end;
    xevMouseMove:
      if FDragging then
      begin
        SetCaret(PosFromXY(ANode, AEvent.X, AEvent.Y), True);
        Exit(True);
      end;
    xevMouseUp:
      begin
        FDragging := False;
        Exit(False);
      end;
  end;
  Result := inherited HandleEvent(ANode, AEvent);
end;

function TXuiTextAreaBehavior.RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
  AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean;
var
  style: TXuiStyle;
  content: TRect;
  lines: TTextAreaLineArray;
  lineH, maxW, totalH, maxScroll, lineTop, x, y, x1, x2, prefixW: Single;
  i, caretLine, aLo, aHi, lo, hi: Integer;
  focused: Boolean;
  selColor, savedColor: TXuiColor;
  lineText, prefix: string;
  caretX, caretY: Integer;
begin
  Result := False;
  if (ANode = nil) or (ANode.Style = nil) or (FNode <> ANode) then
    Exit;
  Result := True;
  style := ANode.Style;
  FMeasure := AMeasure;
  FCaret := XuiSnapIndex(FNode.Text, FCaret);
  FAnchor := XuiSnapIndex(FNode.Text, FAnchor);
  content := ANode.ContentBox;
  focused := xpFocus in ANode.Pseudos;
  lineH := LineHeightOf(ANode);
  if lineH <= 0 then
    Exit;

  BuildTextAreaLines(FNode.Text, style, content.Right - content.Left, AMeasure, lines);
  if Length(lines) = 0 then
  begin
    SetLength(lines, 1);
    lines[0].StartByte := 0;
    lines[0].Len := 0;
    lines[0].Width := 0;
  end;

  totalH := Length(lines) * lineH;
  maxW := 0;
  for i := 0 to High(lines) do
    maxW := Max(maxW, lines[i].Width);

  // 上报滚动范围：引擎据此驱动滚轮、夹取与滚动条
  ANode.ContentHeight := totalH;
  ANode.ContentWidth := Max(content.Right - content.Left, maxW);
  caretLine := TextAreaLineAtByte(lines, FCaret);

  // 光标跟随：仅在光标变化时执行（否则滚轮/滚动条滚动会被每帧拉回光标处）
  if focused and (FCaret <> FScrollCaret) then
  begin
    lineTop := caretLine * lineH;
    if lineTop < ANode.ScrollTop then
      ANode.ScrollTop := lineTop;
    if lineTop + lineH > ANode.ScrollTop + (content.Bottom - content.Top) then
      ANode.ScrollTop := lineTop + lineH - (content.Bottom - content.Top);
  end;
  FScrollCaret := FCaret;
  maxScroll := Max(0, totalH - (content.Bottom - content.Top));
  if ANode.ScrollTop > maxScroll then
    ANode.ScrollTop := maxScroll;
  if ANode.ScrollTop < 0 then
    ANode.ScrollTop := 0;

  selColor := XuiMixColor(style.TextColor, style.BgColor, 0.75);
  aLo := SelLo;
  aHi := SelHi;

  ARenderer.PushClip(content);
  try
    if (FNode.Text = '') and (FPlaceholder <> '') then
    begin
      savedColor := style.TextColor;
      style.TextColor := XuiMixColor(style.TextColor, style.BgColor, 0.55);
      x := content.Left - ANode.ScrollLeft;
      y := content.Top - ANode.ScrollTop;
      ARenderer.DrawText(Rect(Round(x), Round(y),
        Round(x + MeasureTextSimple(FPlaceholder, style, AMeasure)) + 4, Round(y + lineH)),
        FPlaceholder, style);
      style.TextColor := savedColor;
    end
    else
    begin
      for i := 0 to High(lines) do
      begin
        lineText := Copy(FNode.Text, lines[i].StartByte + 1, lines[i].Len);
        x := content.Left - ANode.ScrollLeft;
        y := content.Top - ANode.ScrollTop + i * lineH;
        if focused and (aLo < aHi) then
        begin
          lo := Max(aLo, lines[i].StartByte);
          hi := Min(aHi, lines[i].StartByte + lines[i].Len);
          if lo < hi then
          begin
            x1 := x + MeasureTextSimple(Copy(lineText, 1, lo - lines[i].StartByte), style, AMeasure);
            x2 := x + MeasureTextSimple(Copy(lineText, 1, hi - lines[i].StartByte), style, AMeasure);
            ARenderer.FillRect(Rect(Round(x1), Round(y), Round(x2), Round(y + lineH)), selColor);
          end;
        end;
        if lineText <> '' then
          ARenderer.DrawText(Rect(Round(x), Round(y), Round(x + lines[i].Width) + 4,
            Round(y + lineH)), lineText, style);
      end;
    end;

    prefix := Copy(FNode.Text, lines[caretLine].StartByte + 1, FCaret - lines[caretLine].StartByte);
    prefixW := MeasureTextSimple(prefix, style, AMeasure);
    caretX := Round(content.Left - ANode.ScrollLeft + prefixW);
    caretY := Round(content.Top - ANode.ScrollTop + caretLine * lineH);
    if focused and ACaretVisible then
      ARenderer.FillRect(Rect(caretX, caretY, caretX + XuiCaretWidth, caretY + Round(lineH)),
        style.TextColor);
    FCaretRect := Rect(caretX, caretY, caretX + XuiCaretWidth, caretY + Round(lineH));
  finally
    ARenderer.PopClip;
  end;
end;

{ TXuiInputBehavior }

function TXuiInputBehavior.SelLo: Integer;
begin
  Result := Min(FCaret, FAnchor);
end;

function TXuiInputBehavior.SelHi: Integer;
begin
  Result := Max(FCaret, FAnchor);
end;

function TXuiInputBehavior.HasSelection: Boolean;
begin
  Result := FCaret <> FAnchor;
end;

function TXuiInputBehavior.DisplayText: string;
begin
  if FPassword then
    Result := DisplayPrefix(Length(FNode.Text))
  else
    Result := FNode.Text;
end;

// 值的前 AByteOffset 个字节在屏幕上的文本（密码模式替换为掩码）
function TXuiInputBehavior.DisplayPrefix(AByteOffset: Integer): string;
var
  n, i: Integer;
begin
  if not FPassword then
    Exit(Copy(FNode.Text, 1, AByteOffset));
  n := Utf8Length(Copy(FNode.Text, 1, AByteOffset));
  Result := '';
  for i := 1 to n do
    Result := Result + XuiMaskChar;
end;

// 值中的第 ACount 个码点之后的字节偏移
function TXuiInputBehavior.ValueIndexByCount(ACount: Integer): Integer;
var
  pos, k: Integer;
begin
  pos := 0;
  for k := 1 to ACount do
    pos := Utf8NextIndex(FNode.Text, pos);
  Result := XuiSnapIndex(FNode.Text, pos);
end;

procedure TXuiInputBehavior.SetCaret(APos: Integer; AExtend: Boolean);
begin
  FCaret := XuiSnapIndex(FNode.Text, APos);
  if not AExtend then
    FAnchor := FCaret;
end;

procedure TXuiInputBehavior.DeleteRange(ALo, AHi: Integer);
begin
  if ALo >= AHi then
    Exit;
  FNode.Text := Copy(FNode.Text, 1, ALo) + Copy(FNode.Text, AHi + 1, Length(FNode.Text));
  FCaret := ALo;
  FAnchor := ALo;
end;

procedure TXuiInputBehavior.InsertText(const AText: string);
var
  text, value, prefix, suffix: string;
  lo, hi, keep: Integer;
begin
  if (FNode = nil) or (AText = '') then
    Exit;
  text := XuiSingleLine(AText);
  if text = '' then
    Exit;
  value := FNode.Text;
  lo := SelLo;
  hi := SelHi;
  prefix := Copy(value, 1, lo);
  suffix := Copy(value, hi + 1, Length(value));
  if FMaxLength > 0 then
  begin
    keep := FMaxLength - Utf8Length(prefix) - Utf8Length(suffix);
    if keep <= 0 then
      Exit;
    text := XuiTruncateUtf8(text, keep);
  end;
  FNode.Text := prefix + text + suffix;
  FCaret := lo + Length(text);
  FAnchor := FCaret;
end;

function TXuiInputBehavior.AlignOffset(ANode: TXuiNode; ATextW: Single): Single;
var
  boxW: Single;
begin
  Result := 0;
  if ANode.Style = nil then
    Exit;
  boxW := ANode.ContentBox.Right - ANode.ContentBox.Left;
  case ANode.Style.TextAlign of
    xtaCenter: Result := Max(0, (boxW - ATextW) / 2);
    xtaRight: Result := Max(0, boxW - ATextW);
  end;
end;

function TXuiInputBehavior.TextWidth(ANode: TXuiNode; const AText: string): Single;
begin
  if (FMeasure = nil) or (ANode.Style = nil) then
    Exit(0);
  Result := FMeasure(AText, ANode.Style).cx;
end;

function TXuiInputBehavior.PosFromX(ANode: TXuiNode; AX: Integer): Integer;
var
  disp: string;
  content: TRect;
  x, w, bestDist: Single;
  i, len, count, bestCount: Integer;
begin
  Result := FCaret;
  if (ANode.Style = nil) or (FMeasure = nil) then
    Exit;
  content := ANode.ContentBox;
  x := AX - content.Left + FScrollX - AlignOffset(ANode, TextWidth(ANode, DisplayText));
  disp := DisplayText;
  bestCount := 0;
  bestDist := Abs(x);
  count := 0;
  i := 1;
  while i <= Length(disp) do
  begin
    Utf8CodeAt(disp, i, len);
    Inc(i, len);
    Inc(count);
    w := TextWidth(ANode, Copy(disp, 1, i - 1));
    if Abs(w - x) < bestDist then
    begin
      bestDist := Abs(w - x);
      bestCount := count;
    end;
  end;
  Result := ValueIndexByCount(bestCount);
end;

function TXuiInputBehavior.HandleEditingKey(ANode: TXuiNode;
  AKey: Word; AShift: TXuiShiftState): Boolean;
var
  value, sel: string;
  extend, ctrl, handled: Boolean;
  newCaret: Integer;

  function PrevWord(APos: Integer): Integer;
  begin
    Result := APos;
    while (Result > 0) and (Byte(value[Result]) <= 32) do
      Result := Utf8PrevIndex(value, Result);
    while (Result > 0) and (Byte(value[Result]) > 32) do
      Result := Utf8PrevIndex(value, Result);
  end;

  function NextWord(APos: Integer): Integer;
  var
    len: Integer;
    code: LongWord;
  begin
    Result := APos;
    while Result < Length(value) do
    begin
      code := Utf8CodeAt(value, Result + 1, len);
      if code > 32 then
        Break;
      Result := Utf8NextIndex(value, Result);
    end;
    while Result < Length(value) do
    begin
      code := Utf8CodeAt(value, Result + 1, len);
      if code <= 32 then
        Break;
      Result := Utf8NextIndex(value, Result);
    end;
  end;

begin
  handled := True;
  extend := xssShift in AShift;
  ctrl := xssCtrl in AShift;
  value := FNode.Text;

  case AKey of
    VK_BACK:
      if HasSelection then
        DeleteRange(SelLo, SelHi)
      else if FCaret > 0 then
        DeleteRange(Utf8PrevIndex(value, FCaret), FCaret);
    VK_DELETE:
      if HasSelection then
        DeleteRange(SelLo, SelHi)
      else if FCaret < Length(value) then
        DeleteRange(FCaret, Utf8NextIndex(value, FCaret));
    VK_LEFT:
      begin
        if ctrl then
          newCaret := PrevWord(FCaret)
        else if (not extend) and HasSelection then
          newCaret := SelLo
        else
          newCaret := Utf8PrevIndex(value, FCaret);
        SetCaret(newCaret, extend);
      end;
    VK_RIGHT:
      begin
        if ctrl then
          newCaret := NextWord(FCaret)
        else if (not extend) and HasSelection then
          newCaret := SelHi
        else
          newCaret := Utf8NextIndex(value, FCaret);
        SetCaret(newCaret, extend);
      end;
    VK_HOME:
      SetCaret(0, extend);
    VK_END:
      SetCaret(Length(value), extend);
    Ord('A'):
      if ctrl then
      begin
        FCaret := Length(value);
        FAnchor := 0;
      end
      else
        handled := False;
    Ord('C'):
      if ctrl then
      begin
        if HasSelection then
          XuiWriteClipboard(Copy(value, SelLo + 1, SelHi - SelLo));
      end
      else
        handled := False;
    Ord('X'):
      if ctrl then
      begin
        if HasSelection then
        begin
          sel := Copy(value, SelLo + 1, SelHi - SelLo);
          XuiWriteClipboard(sel);
          DeleteRange(SelLo, SelHi);
        end;
      end
      else
        handled := False;
    Ord('V'):
      if ctrl then
        InsertText(XuiReadClipboard)
      else
        handled := False;
  else
    handled := False;
  end;
  Result := handled;
end;

procedure TXuiInputBehavior.HandleAttribute(const AName, AValue: string);
begin
  inherited HandleAttribute(AName, AValue);
  if (CompareText(AName, 'text') = 0) or (CompareText(AName, 'value') = 0) then
  begin
    FNode.Text := AValue;
    FCaret := 0;
    FAnchor := 0;
  end
  else if CompareText(AName, 'password') = 0 then
    FPassword := XuiAttributeIsTrue(AValue)
  else if CompareText(AName, 'placeholder') = 0 then
    FPlaceholder := AValue
  else if CompareText(AName, 'maxlength') = 0 then
  begin
    FMaxLength := StrToIntDef(Trim(AValue), 0);
    if FMaxLength < 0 then
      FMaxLength := 0;
  end
  else if CompareText(AName, 'disabled') = 0 then
    SetDisabled(XuiAttributeIsTrue(AValue));
end;

// M8：运行时属性（声明式绑定 :placeholder / :password / :maxlength）
function TXuiInputBehavior.SetRuntimeAttr(const AName, AValue: string): Boolean;
begin
  Result := True;
  if CompareText(AName, 'placeholder') = 0 then
    FPlaceholder := AValue
  else if CompareText(AName, 'password') = 0 then
    FPassword := XuiAttributeIsTrue(AValue)
  else if CompareText(AName, 'maxlength') = 0 then
  begin
    FMaxLength := StrToIntDef(Trim(AValue), 0);
    if FMaxLength < 0 then
      FMaxLength := 0;
  end
  else
    Result := False;
end;

function TXuiInputBehavior.CanFocus: Boolean;
begin
  Result := True;
end;

function TXuiInputBehavior.NeedsPointerCapture: Boolean;
begin
  Result := True;
end;

function TXuiInputBehavior.WantsCaret: Boolean;
begin
  Result := (FNode <> nil) and (not XuiIsDisabled(FNode));
end;

procedure TXuiInputBehavior.SetDisabled(AValue: Boolean);
begin
  inherited SetDisabled(AValue);
  if AValue then
    FDragging := False;
end;

function TXuiInputBehavior.HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
begin
  Result := False;
  if XuiIsDisabled(ANode) then
    Exit;
  case AEvent.Kind of
    xevMouseDown:
      begin
        FDragging := True;
        SetCaret(PosFromX(ANode, AEvent.X), False);
        Result := True;
      end;
    xevMouseMove:
      if FDragging then
      begin
        SetCaret(PosFromX(ANode, AEvent.X), True);
        Result := True;
      end;
    xevMouseUp:
      FDragging := False; // 不消费：click 仍按常规派发
    xevKeyDown:
      Result := HandleEditingKey(ANode, AEvent.Key, AEvent.Shift);
    xevTextInput:
      begin
        InsertText(AEvent.Text);
        Result := True;
      end;
    xevBlur:
      FDragging := False;
  end;
end;

function TXuiInputBehavior.CaretRect(ANode: TXuiNode; out ARect: TRect): Boolean;
begin
  ARect := FCaretRect;
  Result := (FNode <> nil) and (FNode = ANode) and (FCaretRect.Right > FCaretRect.Left);
end;

function TXuiInputBehavior.RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
  AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean;
var
  style: TXuiStyle;
  content: TRect;
  disp, prefix: string;
  textW, prefixW, alignOff, x, boxW: Single;
  caretH, caretY: Integer;
  caretX: Integer;
  focused, showPlaceholder: Boolean;
  savedColor: TXuiColor;
  selColor: TXuiColor;
  aLo, aHi: Integer;
  x1, x2: Single;
begin
  Result := False;
  if (ANode = nil) or (ANode.Style = nil) or (FNode <> ANode) then
    Exit;
  Result := True;
  style := ANode.Style;
  FMeasure := AMeasure;
  FCaret := XuiSnapIndex(FNode.Text, FCaret);
  FAnchor := XuiSnapIndex(FNode.Text, FAnchor);
  content := ANode.ContentBox;
  boxW := content.Right - content.Left;
  focused := xpFocus in ANode.Pseudos;
  disp := DisplayText;
  prefix := DisplayPrefix(FCaret);
  textW := TextWidth(ANode, disp);
  prefixW := TextWidth(ANode, prefix);

  // 水平滚动：光标可见；文本放得下就不滚动（失焦/清空后回到起点）
  if (not focused) or (textW <= boxW) then
    FScrollX := 0
  else
  begin
    if prefixW - FScrollX > boxW - XuiCaretWidth then
      FScrollX := prefixW - boxW + XuiCaretWidth;
    if prefixW - FScrollX < 0 then
      FScrollX := prefixW;
  end;
  if FScrollX < 0 then
    FScrollX := 0;
  if FScrollX > Max(0, textW - boxW) then
    FScrollX := Max(0, textW - boxW);

  alignOff := AlignOffset(ANode, textW);
  caretH := Round(Min(style.FontSize + 4, content.Bottom - content.Top));
  caretY := content.Top + (content.Bottom - content.Top - caretH) div 2;
  caretX := Round(content.Left + alignOff + prefixW - FScrollX);

  ARenderer.PushClip(content);
  try
    // 选区高亮（聚焦时可见）
    if focused and HasSelection and (disp <> '') then
    begin
      aLo := SelLo;
      aHi := SelHi;
      x1 := content.Left + alignOff + TextWidth(ANode, DisplayPrefix(aLo)) - FScrollX;
      x2 := content.Left + alignOff + TextWidth(ANode, DisplayPrefix(aHi)) - FScrollX;
      selColor := XuiMixColor(style.TextColor, style.BgColor, 0.75);
      ARenderer.FillRect(Rect(Round(x1), content.Top + 1, Round(x2), content.Bottom - 1), selColor);
    end;

    // 值 / 占位符
    if (FNode.Text = '') and (FPlaceholder <> '') then
    begin
      savedColor := style.TextColor;
      style.TextColor := XuiMixColor(style.TextColor, style.BgColor, 0.55);
      x := content.Left + alignOff - FScrollX;
      ARenderer.DrawText(Rect(Round(x), content.Top, Round(x + TextWidth(ANode, FPlaceholder)) + 4,
        content.Bottom), FPlaceholder, style);
      style.TextColor := savedColor;
    end
    else if disp <> '' then
    begin
      x := content.Left + alignOff - FScrollX;
      ARenderer.DrawText(Rect(Round(x), content.Top, Round(x + textW) + 4, content.Bottom), disp, style);
    end;

    // 光标
    if focused and ACaretVisible then
      ARenderer.FillRect(Rect(caretX, caretY, caretX + XuiCaretWidth, caretY + caretH),
        style.TextColor);
  finally
    ARenderer.PopClip;
  end;

  FCaretRect := Rect(caretX, caretY, caretX + XuiCaretWidth, caretY + caretH);
end;

initialization
  RegisterBehavior('input', TXuiInputBehavior);
  RegisterBehavior('textarea', TXuiTextAreaBehavior);

end.
