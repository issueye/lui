unit xui_host;

{$mode objfpc}{$H+}

{ TXuiHost — 引擎在 Lazarus 窗体上的宿主控件（整个引擎唯一的原生控件入口）。
  负责：
  - 转发系统绘制/尺寸/鼠标/键盘消息给引擎；
  - 以按需启停的 Timer 驱动引擎 Tick（光标闪烁；M5 后续：过渡动画、热重载轮询）；
  - Windows 下用 imm32 把 IME 组合窗定位到引擎光标处（上屏文本走 LCL 的 UTF8KeyPress）。 }

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, ExtCtrls, LCLType, LMessages,
  xui_types, xui_style, xui_dom, xui_engine, xui_render, xui_events,
  xui_script, xui_script_dom;

const
  // Windows IME 消息号（自带常量，避免接口段依赖 Windows 单元）
  XuiWMIMEStartComposition = $010D;
  XuiWMIMEComposition = $010F;

// IME 组合窗锚点：Win32 约定 COMPOSITIONFORM.ptCurrentPos 相对宿主窗口左上角
// （即客户区坐标），不是屏幕坐标。单独抽出这个纯函数，是为了让坐标系约定可被
// 单元测试直接锁定（跨平台编译，不依赖 Windows 单元）。
function XuiImeCompositionPoint(const ACaretRect: TRect): TPoint;

type
  TXuiHost = class(TCustomControl)
  private
    FEngine: TXuiEngine;
    FTimer: TTimer;
    FScript: TXuiScript;
    FBridge: TXuiDomBridge;
    {$IFDEF WINDOWS}
    FTraceOn: Boolean; // 构造时读一次 LUI_WINDOW_TRACE，避免每条消息查环境变量
    {$ENDIF}
    procedure SetXmlFile(const AValue: string);
    procedure SetBackend(const AValue: TXuiBackend);
    function GetBackend: TXuiBackend;
    function GetEventTarget: TObject;
    procedure SetEventTarget(const AValue: TObject);
    // 控件客户区真值（见实现说明）
    function RealClientRect: TRect;
    // 自愈：宿主画布必须铺满父客户区（alClient 偶发没跟上时会出现没被绘制的空白）
    procedure EnsureCoversParent;
    {$IFDEF WINDOWS}
    // 诊断开关（LUI_WINDOW_TRACE=1）：落盘宿主矩形与父客户区（见实现说明）
    procedure NativeHostTrace(const ATag: string);
    // 中文输入链路取证（同一开关）：IME 消息 / 上屏字符 / 键码 / 引擎文本快照
    procedure TraceIme(const ATag, ADetail: string);
    function ImeSnapshot: string;
    function ImeCompositionDump(ALParam: PtrUInt): string;
    {$ENDIF}
    procedure HandleEngineChange(Sender: TObject);
    procedure HandleTimer(Sender: TObject);
    procedure HandleScriptError(const AFile, AMessage: string;
      ALine, ACol: Integer; AStage: TXuiScriptStage);
    // 引擎是否需要周期 Tick → 启停 Timer（避免空转）
    procedure SyncTimer;
    {$IFDEF WINDOWS}
    procedure PositionImeWindow;
    {$ENDIF}
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure Loaded; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    // 无边框窗口的边缘缩放：命中缩放边框时把鼠标消息让给顶层窗口（见实现）
    procedure WndProc(var TheMessage: TLMessage); override;
    // 输入转发（M4 鼠标 / M5 键盘）
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    {$IFDEF WINDOWS}
    // IME：组合开始时把系统组合窗/候选窗移到引擎光标处
    procedure WMImeStartComposition(var Msg: TLMessage); message XuiWMIMEStartComposition;
    procedure WMImeComposition(var Msg: TLMessage); message XuiWMIMEComposition;
    {$ENDIF}
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadFromFile(const AFileName: string);
    // 依据根元素 width/height 属性调整宿主尺寸（demo 用）
    procedure FitToDocumentDefaultSize;
    property Engine: TXuiEngine read FEngine;
    // 脚本门面（懒创建；宿主已自动装配 DOM 桥与错误路由）
    property Script: TXuiScript read FScript;
    // 事件绑定的宿主对象：XML 里 onclick="MethodName" 解析到它的 published 方法
    property EventTarget: TObject read GetEventTarget write SetEventTarget;
    property Backend: TXuiBackend read GetBackend write SetBackend;
  published
    property XmlFile: string write SetXmlFile;
    property Align;
    property Anchors;
    property Color;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnEnter;
    property OnExit;
    property OnKeyDown;
    property OnKeyPress;
    property OnKeyUp;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

implementation

uses
  {$IFDEF WINDOWS}Windows, {$ENDIF}
  xui_window;   // 无边框窗口的边缘缩放基类（TXuiFramelessForm）

{$IFDEF WINDOWS}
const
  CFS_POINT = $0002;         // 组合窗定位方式：锚点
  GCS_COMPSTR = $0008;       // 组合中字符串变更
  GCS_RESULTSTR = $0800;     // 上屏结果串变更
  Imm32Dll = 'imm32.dll';

type
  // FPC 的 Windows 单元未声明 IME 相关类型，这里按 Win32 定义补齐
  HIMC = THandle;

  TImmCompositionForm = record
    dwStyle: DWORD;
    ptCurrentPos: TPoint;
    rcArea: TRect;
  end;

function ImmGetContext(AWnd: HWND): HIMC; stdcall; external Imm32Dll name 'ImmGetContext';
function ImmReleaseContext(AWnd: HWND; AHimc: HIMC): BOOL; stdcall;
  external Imm32Dll name 'ImmReleaseContext';
function ImmSetCompositionWindow(AHimc: HIMC; var AForm: TImmCompositionForm): BOOL; stdcall;
  external Imm32Dll name 'ImmSetCompositionWindow';
function ImmGetCompositionStringW(AHimc: HIMC; AIndex: DWORD; ABuf: Pointer;
  ALen: DWORD): Integer; stdcall; external Imm32Dll name 'ImmGetCompositionStringW';
{$ENDIF}

function XuiImeCompositionPoint(const ACaretRect: TRect): TPoint;
begin
  Result.X := ACaretRect.Left;   // 锚点 = 引擎光标左下角（宿主客户区坐标）
  Result.Y := ACaretRect.Bottom;
end;

function XuiShiftStateOf(Shift: TShiftState): TXuiShiftState;
begin
  Result := [];
  if ssShift in Shift then
    Include(Result, xssShift);
  if ssCtrl in Shift then
    Include(Result, xssCtrl);
  if ssAlt in Shift then
    Include(Result, xssAlt);
end;

function XuiNowMs: Int64;
begin
  {$IFDEF WINDOWS}
  Result := GetTickCount64;
  {$ELSE}
  Result := GetTickCount;
  {$ENDIF}
end;

{ TXuiHost }

constructor TXuiHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 320;
  Height := 240;
  DoubleBuffered := True;
  // 引擎自绘全部像素，告诉 LCL 不要擦背景（避免闪烁）
  ControlStyle := ControlStyle + [csOpaque];
  Color := clWhite;
  TabStop := True; // 需要接收键盘消息
  FEngine := TXuiEngine.Create;
  FEngine.OnChange := @HandleEngineChange;
  // 脚本：门面 + DOM 桥（未加载脚本的应用零额外开销）
  FScript := TXuiScript.Create;
  FScript.OnError := @HandleScriptError;
  FBridge := TXuiDomBridge.Create(FEngine, FScript);
  FBridge.Install;
  FEngine.AttachScript(FScript);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 16;
  FTimer.Enabled := False;
  FTimer.OnTimer := @HandleTimer;
  {$IFDEF WINDOWS}
  FTraceOn := SysUtils.GetEnvironmentVariable('LUI_WINDOW_TRACE') <> '';
  {$ENDIF}
end;

destructor TXuiHost.Destroy;
begin
  FTimer.Enabled := False;
  FTimer.Free;
  FBridge.Free;
  FScript.Free;
  FEngine.Free;
  inherited Destroy;
end;

// 脚本错误路由：写日志文件（GUI 程序无控制台）+ 尝试写入页面的 #msg 节点
procedure TXuiHost.HandleScriptError(const AFile, AMessage: string;
  ALine, ACol: Integer; AStage: TXuiScriptStage);
var
  list: TStringList;
  msg: TXuiNode;
  line: string;
begin
  line := Format('[%s] %s:%d:%d %s', [
    BoolToStr(AStage = ssCompile, 'compile', 'runtime'), AFile, ALine, ACol, AMessage]);
  list := TStringList.Create;
  try
    list.Add(line);
    list.SaveToFile(ExtractFilePath(ParamStr(0)) + 'script-error.txt');
  finally
    list.Free;
  end;
  // 页面内提示（只有存在 #msg 时才写，避免影响普通页面）
  if (FEngine <> nil) and (FEngine.Document <> nil) then
  begin
    msg := FEngine.Document.FindElementById('msg');
    if msg <> nil then
      FEngine.SetText(msg, '脚本错误：' + AMessage);
  end;
end;

procedure TXuiHost.HandleEngineChange(Sender: TObject);
begin
  // 引擎状态变化（伪类/滚动/文档改动/光标闪烁）→ 重绘
  Invalidate;
  // 过渡动画在绘制阶段才启动（此刻 NeedsTick 可能还是 False），先开定时器：
  // 每轮 Tick 后由 SyncTimer 按需关闭，避免空转
  if FTimer <> nil then
    FTimer.Enabled := True;
end;

procedure TXuiHost.HandleTimer(Sender: TObject);
begin
  if FEngine = nil then
    Exit;
  FEngine.Tick(XuiNowMs);
  SyncTimer;
end;

procedure TXuiHost.SyncTimer;
begin
  if (FTimer = nil) or (FEngine = nil) then
    Exit;
  FTimer.Enabled := FEngine.NeedsTick;
end;

procedure TXuiHost.DoEnter;
begin
  inherited DoEnter;
  if FEngine <> nil then
    FEngine.SetHostActive(True);
  SyncTimer;
end;

procedure TXuiHost.DoExit;
begin
  if FEngine <> nil then
    FEngine.SetHostActive(False);
  SyncTimer;
  inherited DoExit;
end;

procedure TXuiHost.SetBackend(const AValue: TXuiBackend);
begin
  FEngine.Backend := AValue;
  Invalidate;
end;

function TXuiHost.GetBackend: TXuiBackend;
begin
  Result := FEngine.Backend;
end;

function TXuiHost.GetEventTarget: TObject;
begin
  Result := FEngine.EventTarget;
end;

procedure TXuiHost.SetEventTarget(const AValue: TObject);
begin
  if FEngine.EventTarget = AValue then
    Exit;
  FEngine.EventTarget := AValue;
  FEngine.RebindEvents; // 换宿主对象后重新解析全部 on* 绑定
  Invalidate;
end;

procedure TXuiHost.Loaded;
begin
  inherited Loaded;
  // DFM 流加载完成后若指定了 XmlFile，此处已被 SetXmlFile 处理
end;

procedure TXuiHost.SetXmlFile(const AValue: string);
begin
  LoadFromFile(AValue);
end;

procedure TXuiHost.LoadFromFile(const AFileName: string);
begin
  FEngine.LoadFromFile(AFileName);
  Invalidate;
end;

procedure TXuiHost.FitToDocumentDefaultSize;
var
  root: TXuiNode;
  v, w, h: Integer;
begin
  root := FEngine.Document.Root;
  if root = nil then
    Exit;
  // 读取根元素 width/height 属性（引擎 M1 中样式为惰性计算，此处直接取属性）
  w := 0;
  h := 0;
  if TryStrToInt(Trim(root.AttributeValue('width')), v) then
    w := v;
  if TryStrToInt(Trim(root.AttributeValue('height')), v) then
    h := v;
  // 填充父窗体时改窗体尺寸（自身尺寸会被 alClient 覆盖），否则改自身
  if (w > 0) and (h > 0) and (Align = alClient) and (Parent is TCustomForm) then
  begin
    TCustomForm(Parent).ClientWidth := w;
    TCustomForm(Parent).ClientHeight := h;
  end
  else
  begin
    if w > 0 then
      ClientWidth := w;
    if h > 0 then
      ClientHeight := h;
  end;
end;

{ 控件客户区真值。LCL 的 ClientWidth/ClientHeight 是缓存值，在 resize 回调触发的那一刻
  可能还是旧尺寸；拿它设引擎视口/绘制区域，就会留下一块没被引擎绘制的空白
  （a_da 实测：深色主题下窗口右侧/底部偶发一条白边）。Windows 下直接问窗口要真值。 }
function TXuiHost.RealClientRect: TRect;
begin
  Result := Types.Rect(0, 0, ClientWidth, ClientHeight);
  {$IFDEF WINDOWS}
  if HandleAllocated then
    Windows.GetClientRect(Handle, Result);
  {$ENDIF}
end;

{ alClient 铺满的宿主画布偶发没跟上父客户区（例如客户区在边框层面刚变大、LCL 排布尚未重跑），
  此时画布右侧/底部会露出一条没被绘制的空白。这里在绘制前校准一次自己的边界。 }
procedure TXuiHost.EnsureCoversParent;
var
  PR: TRect;
  NeedW, NeedH: Integer;
begin
  if (Parent = nil) or (Align <> alClient) or (not HandleAllocated) then
    Exit;
  NeedW := Parent.ClientWidth;
  NeedH := Parent.ClientHeight;
  {$IFDEF WINDOWS}
  if Parent.HandleAllocated and Windows.GetClientRect(Parent.Handle, PR) then
  begin
    NeedW := PR.Right;
    NeedH := PR.Bottom;
  end;
  {$ENDIF}
  if (Left <> 0) or (Top <> 0) or (Width <> NeedW) or (Height <> NeedH) then
    SetBounds(0, 0, NeedW, NeedH);
end;

{$IFDEF WINDOWS}

{ 诊断取证公共件：一行一条，字段值一律纯 ASCII + 十六进制字节，
  避免中文在控制台/日志编码里被二次转码，干扰"到底上屏了什么"的判定。 }

procedure XuiTraceLine(const ALine: string);
var
  tf: Text;
  tp: string;
begin
  tp := SysUtils.GetEnvironmentVariable('TEMP') + '\lui-window.log';
  AssignFile(tf, tp);
  if FileExists(tp) then Append(tf) else Rewrite(tf);
  WriteLn(tf, ALine);
  CloseFile(tf);
end;

function XuiBytesHex(P: PByte; AN: Integer): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to AN - 1 do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + IntToHex(P^, 2);
    Inc(P);
  end;
  if Result = '' then Result := '-';
end;

{$ENDIF}

{ 诊断开关（LUI_WINDOW_TRACE=1）：落盘宿主自身 Win32 矩形 / 父窗体真实客户区，
  用于定位"拖动/缩放后界面残留旧版式"——若宿主矩形与父客户区脱节（LCL 缓存 vs
  Win32 真值不同步），这里一眼可见。未设置环境变量时是纯判断，无任何开销。 }
procedure TXuiHost.NativeHostTrace(const ATag: string);
var
  R: TRect;
  PR: TRect;
begin
  {$IFDEF WINDOWS}
  if SysUtils.GetEnvironmentVariable('LUI_WINDOW_TRACE') = '' then
    Exit;
  R := Types.Rect(0, 0, 0, 0);
  PR := R;
  if HandleAllocated then
    Windows.GetClientRect(Handle, R);
  if (Parent <> nil) and Parent.HandleAllocated then
    Windows.GetClientRect(Parent.Handle, PR);
  XuiTraceLine(Format('%s tag=%-16s msg=host hostRect=%dx%d parentClient=%dx%d',
    [FormatDateTime('hh:nn:ss.zzz', Now), ATag, R.Right, R.Bottom,
     PR.Right, PR.Bottom]));
  {$ENDIF}
end;

{$IFDEF WINDOWS}

procedure TXuiHost.TraceIme(const ATag, ADetail: string);
begin
  if not FTraceOn then Exit;
  XuiTraceLine(Format('%s tag=%-14s %s',
    [FormatDateTime('hh:nn:ss.zzz', Now), ATag, ADetail]));
end;

{ 聚焦节点的当前文本（UTF-8 字节）+ 引擎光标矩形：
  文本字节与 caret 横坐标对不上，就是"末尾一串空白"的直接证据。 }
function TXuiHost.ImeSnapshot: string;
var
  r: TRect;
  t: string;
  hex: string;
begin
  r := Types.Rect(0, 0, 0, 0);
  if FEngine <> nil then
    FEngine.CaretRect(r);
  t := '';
  if (FEngine <> nil) and (FEngine.FocusNode <> nil) then
    t := FEngine.FocusNode.Text;
  if t <> '' then
    hex := XuiBytesHex(PByte(@t[1]), Length(t))
  else
    hex := '-';
  Result := Format('textLen=%d caret=(%d,%d,%d,%d) textHex=%s',
    [Length(t), r.Left, r.Top, r.Right, r.Bottom, hex]);
end;

{ 把 IME 交来的组合串/上屏结果串按 UTF-8 字节落盘（未变更时为 '-'） }
function TXuiHost.ImeCompositionDump(ALParam: PtrUInt): string;
var
  ic: HIMC;
  buf: array[0..511] of WideChar;

  function ReadHex(AIndex: DWORD): string;
  var
    w: UnicodeString;
    u: RawByteString;
    n: Integer;
  begin
    Result := '-';
    if (ALParam and AIndex) = 0 then Exit;
    FillChar(buf[0], SizeOf(buf), 0);
    n := ImmGetCompositionStringW(ic, AIndex, @buf[0], SizeOf(buf));
    if n <= 0 then Exit;
    if n > SizeOf(buf) then n := SizeOf(buf);
    SetLength(w, n div 2);
    if Length(w) > 0 then
      Move(buf[0], w[1], Length(w) * SizeOf(WideChar));
    u := UTF8Encode(w);
    if Length(u) > 0 then
      Result := XuiBytesHex(PByte(@u[1]), Length(u));
  end;

begin
  Result := 'lp=0 comp=- result=-';
  if not HandleAllocated then Exit;
  ic := ImmGetContext(Handle);
  if ic = 0 then Exit;
  try
    Result := Format('lp=%s comp=%s result=%s',
      [IntToHex(UInt64(ALParam), 8), ReadHex(GCS_COMPSTR), ReadHex(GCS_RESULTSTR)]);
  finally
    ImmReleaseContext(Handle, ic);
  end;
end;

{$ENDIF}

procedure TXuiHost.Paint;
var
  R: TRect;
begin
  if FEngine = nil then Exit;
  NativeHostTrace('host-paint-in');
  EnsureCoversParent;
  // 每次绘制前把视口校到客户区真值：双保险，杜绝"用旧尺寸绘制"留下空白边
  R := RealClientRect;
  FEngine.SetViewport(R.Right, R.Bottom);
  // 引擎自绘全部内容
  FEngine.Draw(Canvas, R);
  NativeHostTrace('host-paint-out');
end;

procedure TXuiHost.Resize;
var
  R: TRect;
begin
  inherited Resize;
  NativeHostTrace('host-resize');
  // 注意：构造函数中设置初始尺寸时引擎尚未创建
  if FEngine = nil then Exit;
  R := RealClientRect;
  FEngine.SetViewport(R.Right, R.Bottom);
  Invalidate;
end;

{ 输入转发：先给引擎，再走 LCL 的常规事件（用户的 OnMouseXxx / OnKeyXxx 仍可用） }

{ 鼠标消息里高低位打包的屏幕坐标（需符号扩展：多显示器下存在负坐标） }
function XuiScreenPointOf(APacked: LPARAM): TPoint;
begin
  Result.X := SmallInt(APacked and $FFFF);
  Result.Y := SmallInt((APacked shr 16) and $FFFF);
end;

{ 无边框窗口的边缘缩放在顶层窗口判定，但自绘画布 alClient 覆盖整个客户区，
  系统问到的只会是画布本身（默认 HTCLIENT），窗口最外圈因此永远拿不到缩放命中。
  这里在命中缩放边框时回答 HTTRANSPARENT——按 Windows 的命中测试规则，消息会继续
  在同线程内询问下层窗口，最终由顶层窗口给出 HTLEFT / HTBOTTOMRIGHT 等非客户区命中码，
  交给 DefWindowProc 进入原生缩放循环。 }
procedure TXuiHost.WndProc(var TheMessage: TLMessage);
var
  Form: TCustomForm;
begin
  {$IFDEF WINDOWS}
  // 中文输入取证（LUI_WINDOW_TRACE=1）：按键/字符/IME 消息全序列
  if FTraceOn then
    case TheMessage.Msg of
      $0100: TraceIme('keydown', 'vk=' + IntToHex(UInt64(TheMessage.WParam), 4));
      $0102: TraceIme('char', 'ch=' + IntToHex(UInt64(TheMessage.WParam), 4));
      $0109: TraceIme('unichar', 'ch=' + IntToHex(UInt64(TheMessage.WParam), 4));
      $010C..$010F, $0281..$028F:
        begin
          TraceIme('ime-msg', 'msg=' + IntToHex(UInt64(TheMessage.Msg), 4) +
            ' lp=' + IntToHex(UInt64(TheMessage.LParam), 8));
          if TheMessage.Msg = $010F then // WM_IME_COMPOSITION
            TraceIme('ime-comp',
              ImeCompositionDump(PtrUInt(TheMessage.LParam)) + ' ' + ImeSnapshot);
        end;
    end;
  {$ENDIF}
  if TheMessage.Msg = LM_NCHITTEST then
  begin
    Form := GetParentForm(Self);
    if (Form is TXuiFramelessForm) and
       (TXuiFramelessForm(Form).FramelessHitTest(XuiScreenPointOf(TheMessage.LParam)) <> HTCLIENT) then
    begin
      TheMessage.Result := HTTRANSPARENT;
      Exit;
    end;
  end;
  inherited WndProc(TheMessage);
end;

procedure TXuiHost.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  if FEngine <> nil then
    FEngine.HandleMouseMove(X, Y);
  inherited MouseMove(Shift, X, Y);
end;

procedure TXuiHost.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (FEngine <> nil) and (Button = mbLeft) then
    FEngine.HandleMouseDown(X, Y);
  // 键盘消息只发给有焦点的窗口：点击自绘界面时把焦点拿到本控件
  if CanFocus and (not Focused) then
    SetFocus;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TXuiHost.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (FEngine <> nil) and (Button = mbLeft) then
    FEngine.HandleMouseUp(X, Y);
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TXuiHost.MouseLeave;
begin
  if FEngine <> nil then
    FEngine.HandleMouseLeave;
  inherited MouseLeave;
end;

function TXuiHost.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := False;
  // R3：Shift+滚轮横向滚动；修饰键与键盘路径共用同一转换
  if FEngine <> nil then
    Result := FEngine.HandleMouseWheel(MousePos.X, MousePos.Y, WheelDelta,
      XuiShiftStateOf(Shift));
  if not Result then
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

procedure TXuiHost.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (FEngine <> nil) and FEngine.HandleKeyDown(Key, XuiShiftStateOf(Shift)) then
  begin
    Key := 0; // 已消费：阻止 LCL 的默认处理（Tab 导航、默认按钮等）
    SyncTimer;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TXuiHost.KeyUp(var Key: Word; Shift: TShiftState);
begin
  if (FEngine <> nil) and FEngine.HandleKeyUp(Key, XuiShiftStateOf(Shift)) then
  begin
    Key := 0;
    SyncTimer;
  end;
  inherited KeyUp(Key, Shift);
end;

procedure TXuiHost.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  consumed: Boolean;
  inHex: string;
begin
  // 普通字符与 IME 上屏文本都从这里进入引擎
  consumed := (FEngine <> nil) and FEngine.HandleTextInput(UTF8Key);
  {$IFDEF WINDOWS}
  if FTraceOn then
  begin
    if Length(UTF8Key) > 0 then
      inHex := XuiBytesHex(PByte(@UTF8Key[1]), Length(UTF8Key))
    else
      inHex := '-';
    TraceIme('text-in', 'in=' + inHex +
      ' consumed=' + BoolToStr(consumed, 'yes', 'no') + ' ' + ImeSnapshot);
  end;
  {$ENDIF}
  if consumed then
  begin
    UTF8Key := ''; // 已被输入框消费
    SyncTimer;
  end
  else
    inherited UTF8KeyPress(UTF8Key);
end;

{$IFDEF WINDOWS}

procedure TXuiHost.PositionImeWindow;
var
  ic: HIMC;
  form: TImmCompositionForm;
  r: TRect;
begin
  if (FEngine = nil) or (not FEngine.CaretRect(r)) then
    Exit;
  ic := ImmGetContext(Handle);
  if ic = 0 then
    Exit;
  try
    // ptCurrentPos 必须是宿主客户区坐标：曾误传 ClientToScreen 的屏幕坐标，
    // 组合串会被推到窗口外再被系统裁剪，表现为中文输入"字形移位"。
    form.dwStyle := CFS_POINT;
    form.ptCurrentPos := XuiImeCompositionPoint(r);
    form.rcArea := Types.Rect(0, 0, 0, 0);
    ImmSetCompositionWindow(ic, form);
    if FTraceOn then
      TraceIme('ime-anchor', Format('caret=(%d,%d,%d,%d) anchor=(%d,%d)',
        [r.Left, r.Top, r.Right, r.Bottom,
         form.ptCurrentPos.X, form.ptCurrentPos.Y]));
  finally
    ImmReleaseContext(Handle, ic);
  end;
end;

procedure TXuiHost.WMImeStartComposition(var Msg: TLMessage);
begin
  // 组合开始：把系统组合窗/候选窗移到引擎光标处；组合串由系统窗口显示
  PositionImeWindow;
  Msg.Result := 0; // 0 → 继续走 DefWindowProc（保留系统默认行为）
end;

procedure TXuiHost.WMImeComposition(var Msg: TLMessage);
begin
  if (Msg.LParam and GCS_COMPSTR) <> 0 then
    PositionImeWindow;
  Msg.Result := 0;
end;

{$ENDIF}

end.
