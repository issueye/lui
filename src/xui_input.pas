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
  private
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
    procedure InsertText(const AText: string);
    function AlignOffset(ANode: TXuiNode; ATextW: Single): Single;
    function TextWidth(ANode: TXuiNode; const AText: string): Single;
    function PosFromX(ANode: TXuiNode; AX: Integer): Integer;
    function HandleEditingKey(ANode: TXuiNode; AKey: Word; AShift: TXuiShiftState): Boolean;
  public
    procedure HandleAttribute(const AName, AValue: string); override;
    function CanFocus: Boolean; override;
    function HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean; override;
    function RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
      AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean; override;
    function NeedsPointerCapture: Boolean; override;
    function WantsCaret: Boolean; override;
    function CaretRect(ANode: TXuiNode; out ARect: TRect): Boolean; override;
    procedure SetDisabled(AValue: Boolean); override;
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

// 把任意字节偏移对齐到码点边界（防止落在多字节序列中）
function XuiSnapIndex(const AText: string; APos: Integer): Integer;
begin
  Result := APos;
  if Result < 0 then
    Result := 0;
  if Result > Length(AText) then
    Result := Length(AText);
  while (Result > 0) and (Result <= Length(AText)) and
        ((Byte(AText[Result]) and $C0) = $80) do
    Dec(Result);
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

end.
