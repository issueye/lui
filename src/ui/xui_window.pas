unit xui_window;

{$mode objfpc}{$H+}

{ TXuiFramelessForm — 无边框窗口宿主的原生边缘缩放基类（M14）

  无边框窗口（BorderStyle = bsNone ⇒ WS_POPUP）不含任何可抓取的窗口边框：窗口过程里
  没有 WM_NCHITTEST 处理时，最外圈的命中结果恒为 HTCLIENT，系统不会启动缩放循环，
  用户拖窗口边界毫无反应；ui.window.startResize 发出的 WM_NCLBUTTONDOWN(HT*)
  也会被 User32 的 SC_SIZE 分支丢弃（该命令要求窗口带 WS_THICKFRAME）。

  这里把系统边框"借"回来，全部走 Windows 标准非客户区机制：

  - WS_THICKFRAME：SC_SIZE 的准入样式（句柄创建后补写，LCL 按 BorderStyle 只会给
    bsNone 分配 WS_POPUP，见 win32wsforms.CalcBorderStyleFlags）；
  - WM_NCCALCSIZE 返回 0：客户区仍覆盖整个窗口，不出现系统绘制的边框内缩；
  - WM_NCHITTEST 在最外圈 ResizeBorder 像素返回 HTLEFT / HTBOTTOMRIGHT 等命中码，
    交由 DefWindowProc 进入原生缩放循环（跟手、自带系统缩放光标、支持贴边吸附），
    最大化时直接放弃命中，避免拖边误触；
  - WM_GETMINMAXINFO：客户区等于整窗时系统仍按"带边框"推算最大化矩形，会溢出工作区，
    这里统一按监视器工作区兜底；同时给出交互最小尺寸，防止窗口被拖成不可用的极小尺寸；
  - DWM 关闭系统圆角与系统描边：窗口观感 100% 由应用自绘（含 1px 物理外边框）。

  这些消息 LCL 都直接转给 DefWindowProc，不进入 LCL 的消息分发（win32callback 的
  DoWindowProc 只对 WM_NCHITTEST 做了 LMessage 投递），所以在窗口过程层挂钩
  （SetWindowLongPtr + CallWindowProc 链）是最稳的做法；挂接点放在 CreateWnd 之后，
  句柄每次重建都会重装，不会丢。

  自绘画布 TXuiHost 覆盖整个客户区，会先接到 WM_NCHITTEST；它在命中缩放边框时返回
  HTTRANSPARENT，把判定权交还顶层窗口（Windows 文档：同线程内继续询问下层窗口），
  见 xui_host.pas。 }

interface

uses
  Classes, SysUtils, Types, Forms, Controls, LCLType, LMessages
  {$IFDEF WINDOWS}, Windows{$ENDIF};

const
  // 边缘命中宽度（物理像素）：与顶栏窗口按钮组的 6px 内缩严格对齐，
  // 保证最上沿 6px 既可用于缩放，又不会盖住 28×24 的最小化/最大化/关闭按钮。
  XuiDefaultResizeBorder = 6;
  // 无边框窗口的交互最小尺寸（防止被拖成 0 尺寸后无法恢复）
  XuiMinWindowWidth = 360;
  XuiMinWindowHeight = 240;

type
  { 无边框窗口基类：frameless 时以 Windows 标准非客户区机制还原边缘缩放 }
  TXuiFramelessForm = class(TForm)
  private
    FFrameless: Boolean;
    FFramelessResize: Boolean;
    FResizeBorder: Integer;
    FDefaultsReady: Boolean;
    {$IFDEF WINDOWS}
    FHookedWndProc: Pointer;   // 挂钩前的窗口过程（链尾交还 LCL）
    FWantClientW: Integer;     // LCL 最近一次请求的客户区尺寸（见 SetBounds）
    FWantClientH: Integer;
    FSizing: Boolean;          // 正在拖拽缩放/移动（WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE）
    {$ENDIF}
    procedure InitDefaults;
    procedure SetFrameless(const AValue: Boolean);
    procedure SetFramelessResize(const AValue: Boolean);
    procedure SetResizeBorder(const AValue: Integer);
    {$IFDEF WINDOWS}
    procedure ApplyFramelessStyle;
    procedure DisableOwnScrollBars;
    procedure EnsureFullClient;
    procedure RedrawFramelessContent;
    procedure SyncLclClientRectCache;
    procedure UnpinInheritedFrame(Info: PWINDOWPOS);
    function NcFrameDelta: TSize;
    procedure ApplyDwmFramelessLook;
    procedure InstallWndProcHook;
    procedure UninstallWndProcHook;
    procedure ApplyMaximizedBounds(AInfo: PMinMaxInfo);
    { 诊断开关（LUI_WINDOW_TRACE=1）：把关键原生消息的窗口/客户区矩形落盘，
      用于定位"拖动/缩放后界面残留旧版式"这类时序问题；未设置时零开销。 }
    procedure NativeWindowTrace(const ATag: string; Msg: UINT);
    { 顶层窗口的原生消息处理：返回 True 表示已给出 AResult，不再向下传递 }
    function HandleNativeMessage(Window: HWND; Msg: UINT; WParam: WPARAM;
      LParam: LPARAM; out AResult: LRESULT): Boolean; virtual;
    {$ENDIF}
  protected
    procedure CreateWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    {$IFDEF WINDOWS}
    procedure DestroyWnd; override;
    {$ENDIF}
    { 屏幕坐标 → 非客户区命中码：落在缩放边框返回 HTLEFT/HTBOTTOMRIGHT 等，
      其余（含最大化、禁用缩放、窗口外）返回 HTCLIENT。子控件在 WM_NCHITTEST
      里调用它决定是否让位给顶层窗口。 }
    function FramelessHitTest(const AScreenPoint: TPoint): Integer; virtual;
    { 无系统边框窗口（对应 BorderStyle = bsNone） }
    property Frameless: Boolean read FFrameless write SetFrameless default False;
    { 无边框下允许拖拽窗口边缘缩放（默认开） }
    property FramelessResize: Boolean read FFramelessResize write SetFramelessResize default True;
    { 边缘命中宽度（物理像素，<=0 视为关闭；默认 XuiDefaultResizeBorder） }
    property ResizeBorder: Integer read FResizeBorder write SetResizeBorder default XuiDefaultResizeBorder;
    {$IFDEF WINDOWS}
    { LCL 对窗体把 Width/Height 当"客户区尺寸"，落到 Win32 时会再加上一圈系统边框
      （win32int.AdjustFormClientToWindowSize 按当前窗口样式算）。无边框窗口的客户区
      等于整窗，这圈边框并不存在，多算会导致窗口比清单声明的大一圈。这里记下 LCL
      真正想要的客户区尺寸，由窗口过程在 WM_WINDOWPOSCHANGING 里钉回去。 }
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: Integer); override;
    {$ENDIF}
  end;

implementation

constructor TXuiFramelessForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  InitDefaults;
end;

constructor TXuiFramelessForm.CreateNew(AOwner: TComponent; Num: Integer = 0);
begin
  inherited CreateNew(AOwner, Num);
  InitDefaults;
end;

procedure TXuiFramelessForm.InitDefaults;
begin
  // Create / CreateNew 都会走到；只生效一次，避免覆盖调用方已设的显式值
  if FDefaultsReady then
    Exit;
  FDefaultsReady := True;
  FFramelessResize := True;
  FResizeBorder := XuiDefaultResizeBorder;
  DisableOwnScrollBars;
end;

procedure TXuiFramelessForm.SetFrameless(const AValue: Boolean);
begin
  if FFrameless = AValue then
    Exit;
  FFrameless := AValue;
  {$IFDEF WINDOWS}
  if HandleAllocated then
    ApplyFramelessStyle;
  {$ENDIF}
end;

procedure TXuiFramelessForm.SetFramelessResize(const AValue: Boolean);
begin
  if FFramelessResize = AValue then
    Exit;
  FFramelessResize := AValue;
  {$IFDEF WINDOWS}
  // 关闭时无需还原样式：FramelessHitTest 不再给出命中码，拖边自然不会触发缩放
  if HandleAllocated and FFrameless then
    ApplyFramelessStyle;
  {$ENDIF}
end;

procedure TXuiFramelessForm.SetResizeBorder(const AValue: Integer);
begin
  if AValue < 0 then
    FResizeBorder := 0
  else
    FResizeBorder := AValue;
end;

function TXuiFramelessForm.FramelessHitTest(const AScreenPoint: TPoint): Integer;
var
  R: TRect;
  Border: Integer;
  OnLeft, OnRight, OnTop, OnBottom: Boolean;
begin
  Result := HTCLIENT;
  if (not FFrameless) or (not FFramelessResize) or (FResizeBorder <= 0) then
    Exit;
  if not HandleAllocated then
    Exit;
  {$IFDEF WINDOWS}
  // 最大化/最小化时不做边缘缩放（最大化窗口拖边会把窗口拽回还原态，不符合直觉）
  if Windows.IsZoomed(Handle) or (WindowState = wsMinimized) then
    Exit;
  {$ENDIF}
  // 客户区等于整个窗口（WM_NCCALCSIZE 返回 0），窗口矩形即客户区矩形。
  // 这里取 Win32 真值：LCL 的 BoundsRect 在原生缩放/最大化的瞬间可能落后一帧，
  // 用缓存值会让边框命中区在拖动过程中错位。
  if not Windows.GetWindowRect(Handle, R) then
    Exit;
  Border := FResizeBorder;
  OnLeft := (AScreenPoint.X >= R.Left) and (AScreenPoint.X < R.Left + Border);
  OnRight := (AScreenPoint.X < R.Right) and (AScreenPoint.X >= R.Right - Border);
  OnTop := (AScreenPoint.Y >= R.Top) and (AScreenPoint.Y < R.Top + Border);
  OnBottom := (AScreenPoint.Y < R.Bottom) and (AScreenPoint.Y >= R.Bottom - Border);
  if OnTop and OnLeft then
    Result := HTTOPLEFT
  else if OnTop and OnRight then
    Result := HTTOPRIGHT
  else if OnBottom and OnRight then
    Result := HTBOTTOMRIGHT
  else if OnBottom and OnLeft then
    Result := HTBOTTOMLEFT
  else if OnLeft then
    Result := HTLEFT
  else if OnRight then
    Result := HTRIGHT
  else if OnTop then
    Result := HTTOP
  else if OnBottom then
    Result := HTBOTTOM;
end;

procedure TXuiFramelessForm.CreateWnd;
begin
  inherited CreateWnd;   // LCL 建窗并按 BorderStyle 分配样式，随后才是补写时机
  {$IFDEF WINDOWS}
  if FFrameless then
    ApplyFramelessStyle;
  {$ENDIF}
end;

{$IFDEF WINDOWS}

procedure TXuiFramelessForm.SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
begin
  // 句柄存在时 LCL 才会按"样式里的系统边框"给窗口加一圈并不存在的尺寸
  // （win32int.AdjustFormClientToWindowSize），这里记下它真正想要的客户区尺寸
  if FFrameless and HandleAllocated then
  begin
    FWantClientW := AWidth;
    FWantClientH := AHeight;
  end;
  inherited SetBounds(ALeft, ATop, AWidth, AHeight);
end;

// 监视器信息（winunits-base 的 multimon 单元只为这一个结构引入整包依赖，这里自带）
type
  TXuiMonitorInfo = record
    cbSize: DWORD;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: DWORD;
  end;

{ 窗口过程类型：不能直接用字体名 WNDPROC —— 在窗体方法里它与继承来的
  TControl.WndProc 同名（Pascal 不区分大小写），会被解析成方法调用 }
type
  TXuiWndProc = function(hwnd: HWND; uMsg: UINT; wParam: WPARAM;
    lParam: LPARAM): LRESULT; stdcall;

const
  XuiMonitorDefaultToNearest = 2;
  XuiDwmwaWindowCornerPreference = 33;
  XuiDwmwaBorderColor = 34;
  XuiDwmcpDoNotRound = 1;
  XuiDwmColorNone = DWORD($FFFFFFFE);

function XuiMonitorFromWindow(hWnd: HWND; dwFlags: DWORD): HMONITOR;
  stdcall; external 'user32.dll' name 'MonitorFromWindow';
function XuiGetMonitorInfo(hMonitor: HMONITOR; lpmi: Pointer): BOOL;
  stdcall; external 'user32.dll' name 'GetMonitorInfoW';
function XuiDwmSetWindowAttribute(hWnd: HWND; dwAttribute: DWORD;
  pvAttribute: Pointer; cbAttribute: DWORD): HRESULT;
  stdcall; external 'dwmapi.dll' name 'DwmSetWindowAttribute';

{ 这两个 API 属于较新的 user32（AdjustWindowRectExForDpi 需 Win10 1607+），
  用 GetProcAddress 动态取，取不到就退化为老 API }
type
  TXuiAdjustWindowRectExForDpi = function(lpRect: PRect; dwStyle: DWORD; bMenu: BOOL;
    dwExStyle: DWORD; dpi: UINT): BOOL; stdcall;
  TXuiGetDpiForWindow = function(hwnd: HWND): UINT; stdcall;

var
  XuiAdjustWindowRectExForDpi: TXuiAdjustWindowRectExForDpi = nil;
  XuiGetDpiForWindow: TXuiGetDpiForWindow = nil;

procedure XuiLoadDpiApis;
var
  Lib: HMODULE;
begin
  if XuiAdjustWindowRectExForDpi <> nil then
    Exit;
  Lib := GetModuleHandle('user32.dll');
  if Lib = 0 then
    Exit;
  XuiAdjustWindowRectExForDpi :=
    TXuiAdjustWindowRectExForDpi(GetProcAddress(Lib, 'AdjustWindowRectExForDpi'));
  XuiGetDpiForWindow := TXuiGetDpiForWindow(GetProcAddress(Lib, 'GetDpiForWindow'));
end;

{ 顶层窗口过程钩子：只接管无边框缩放相关的三条消息，其余原样交还 LCL 的窗口过程 }
function XuiFramelessWndProc(Window: HWND; Msg: UINT; WParam: WPARAM;
  LParam: LPARAM): LRESULT; stdcall;
var
  Form: TXuiFramelessForm;
  Res: LRESULT;
begin
  Form := TXuiFramelessForm(Windows.GetWindowLongPtrW(Window, GWLP_USERDATA));
  if Form = nil then
  begin
    Result := Windows.DefWindowProcW(Window, Msg, WParam, LParam);
    Exit;
  end;
  Res := 0;
  if Form.HandleNativeMessage(Window, Msg, WParam, LParam, Res) then
    Result := Res
  else
    Result := Windows.CallWindowProcW(TXuiWndProc(Form.FHookedWndProc), Window, Msg, WParam, LParam);
end;

{ LCL 会把"客户区尺寸 + 系统边框"下发给 Win32（AdjustFormClientToWindowSize 按当前
  窗口样式算），而无边框窗口客户区就是整窗：多算那一圈会让窗口凭空大一圈（启动时实测
  +7px/边），且 LCL 的尺寸下发是异步多次的，只校正一次还会被下一轮顶回去。

  这里按"LCL 的换算结果"精确识别（cx = 目标客户区宽 + 系统边框增量）并还原成客户区尺寸；
  校正一次即清空目标值，用户开始拖边（WM_ENTERSIZEMOVE）或最大化/最小化时也清空，
  因此原生缩放、贴边吸附、最大化都不受这条规则影响。 }
procedure TXuiFramelessForm.UnpinInheritedFrame(Info: PWINDOWPOS);
var
  Delta: TSize;
  WantW, WantH: Integer;
begin
  if (FWantClientW <= 0) or (Info = nil) then
    Exit;
  Delta := NcFrameDelta;
  WantW := FWantClientW;
  WantH := FWantClientH;
  if (Info^.cx = WantW + Delta.cx) and (Info^.cy = WantH + Delta.cy) and
     ((Delta.cx <> 0) or (Delta.cy <> 0)) then
  begin
    Info^.cx := WantW;
    Info^.cy := WantH;
    FWantClientW := 0;
    FWantClientH := 0;
  end;
end;

{ 诊断开关（LUI_WINDOW_TRACE=1）：把关键原生消息发生时的窗口/客户区矩形追加到
  %TEMP%\lui-window.log（时间戳 + 消息号 + 两个矩形），用于定位"拖动/缩放后界面
  残留旧版式"这类时序问题——本地实窗复现时能直接看到客户区是否被谁内缩过。
  未设置环境变量时是纯判断，无任何开销。 }
procedure TXuiFramelessForm.NativeWindowTrace(const ATag: string; Msg: UINT);
var
  tf: Text;
  tp: string;
  WR, CR: Windows.TRect;
begin
  if SysUtils.GetEnvironmentVariable('LUI_WINDOW_TRACE') = '' then
    Exit;
  WR := Types.Rect(0, 0, 0, 0);
  CR := WR;
  if HandleAllocated then
  begin
    Windows.GetWindowRect(Handle, WR);
    Windows.GetClientRect(Handle, CR);
  end;
  tp := SysUtils.GetEnvironmentVariable('TEMP') + '\lui-window.log';
  AssignFile(tf, tp);
  if FileExists(tp) then Append(tf) else Rewrite(tf);
  WriteLn(tf, Format('%s tag=%-16s msg=%-4d win=%d,%d,%d,%d client=%dx%d lclClient=%dx%d',
    [FormatDateTime('hh:nn:ss.zzz', Now), ATag, Msg,
     WR.Left, WR.Top, WR.Right, WR.Bottom,
     CR.Right - CR.Left, CR.Bottom - CR.Top,
     ClientWidth, ClientHeight]));
  CloseFile(tf);
end;

function TXuiFramelessForm.HandleNativeMessage(Window: HWND; Msg: UINT;
  WParam: WPARAM; LParam: LPARAM; out AResult: LRESULT): Boolean;
var
  Pt: TPoint;
  Hit: Integer;
  Style: LONG_PTR;
  Info: PWINDOWPOS;
  R: TRect;
begin
  Result := False;
  AResult := 0;
  if not FFrameless then
    Exit;
  case Msg of
    WM_ENTERSIZEMOVE:
      // 用户开始拖边/拖标题缩放：撤掉待校正尺寸，之后一切尺寸变更都不再干预
      begin
        NativeWindowTrace('entersizemove', Msg);
        FWantClientW := 0;
        FWantClientH := 0;
        FSizing := True;
      end;
    WM_EXITSIZEMOVE:
      begin
        NativeWindowTrace('exitsizemove', Msg);
        FSizing := False;
        // 拖拽结束后校准客户区并强制整窗重绘：移动循环里客户区可能被系统按边框
        // 内缩过又拉回，新并入的条带是"新暴露区"，只靠系统更新区重绘会在其余部分
        // 残留循环期间旧版式的自绘内容（a_da 实测：拖顶栏移动后右侧并排两条滚动条，
        // 缩放一次才消失——那条"多出来的"就是旧版式残影）。
        SyncLclClientRectCache;   // LCL 客户区缓存可能被留在"整窗-边框增量"，先对账
        RedrawFramelessContent;
      end;
    WM_SIZE, WM_WINDOWPOSCHANGED:
      begin
        if Msg = WM_SIZE then
          NativeWindowTrace('size wparam=' + IntToStr(PtrUInt(WParam)), Msg)
        else
          NativeWindowTrace('windowposchanged', Msg);
        // 最大化/最小化后不再干预尺寸
        if (Msg = WM_SIZE) and ((WParam = SIZE_MAXIMIZED) or (WParam = SIZE_MINIMIZED)) then
        begin
          FWantClientW := 0;
          FWantClientH := 0;
        end;
        // 自愈：客户区若被系统按边框内缩过，这里拉回整窗（正常情况直接返回，不产生消息）
        EnsureFullClient;
        // LCL 客户区缓存对账：移动循环里 LCL 可能把缓存留在"整窗-边框增量"，
        // 及时纠偏，避免 alClient 自绘画布被对齐到错值（残影源头）
        SyncLclClientRectCache;
      end;
    WM_NCACTIVATE:
      // 无边框窗口自己负责"激活/非激活"外观：直接返回 TRUE 并重绘，不走 DefWindowProc。
      // 否则系统会按 WS_THICKFRAME 重画一圈非客户区边框——a_da 实测：切换到别的窗口再切回来，
      // 窗口四周就出现一圈浅色边框（约 4px），而且不会自愈（客户区尺寸其实没变）。
      begin
        RedrawFramelessContent;
        AResult := 1;
        Result := True;
      end;
    WM_ACTIVATE, WM_ACTIVATEAPP:
      // 激活状态变化后重绘一次，盖掉任何残影（引擎整窗重绘，代价可控）
      RedrawFramelessContent;
    WM_NCCALCSIZE:
      // 客户区恒等于整窗（缩放能力由 WS_THICKFRAME + WM_NCHITTEST 提供）：
      //  - WParam <> 0：lParam 是 NCCALCSIZE_PARAMS，rgrc[0] 已是整窗矩形，返回 0 即可；
      //  - WParam  = 0：lParam 是 RECT，必须显式回填整窗矩形。漏掉这一支，系统会按
      //    "带边框"内缩客户区——窗口四周露出一圈系统绘制的浅色边框，且被 DWM 当成
      //    有边框窗口加圆角（a_da 实测：四周约 5px 白边 + 左下圆角异常）。
      begin
        if LParam = 0 then
        begin
          // 没有矩形可谈（非系统来路），交回默认处理——注意默认处理会按"带边框"
          // 内缩客户区，这里落一条诊断痕迹便于发现这类旁路
          NativeWindowTrace('nccalc-norect->default', Msg);
          Exit;
        end;
        if WParam = 0 then
          NativeWindowTrace('nccalc-w0', Msg)
        else
          NativeWindowTrace('nccalc-w1', Msg);
        if WParam = 0 then
        begin
          if not Windows.GetWindowRect(Window, R) then
            Exit;
          PRect(LParam)^ := R;
        end;
        AResult := 0;
        Result := True;
      end;
    WM_NCHITTEST:
      begin
        Pt.X := SmallInt(LParam and $FFFF);
        Pt.Y := SmallInt((LParam shr 16) and $FFFF);
        Hit := FramelessHitTest(Pt);
        if Hit <> HTCLIENT then
        begin
          AResult := Hit;
          Result := True;
        end;
      end;
    WM_GETMINMAXINFO:
      begin
        // 先让 LCL/系统填默认值（含 Constraints），再按工作区修正最大化矩形
        AResult := Windows.CallWindowProcW(TXuiWndProc(FHookedWndProc), Window, Msg, WParam, LParam);
        ApplyMaximizedBounds(PMinMaxInfo(LParam));
        Result := True;
      end;
    WM_STYLECHANGING:
      // LCL 在某些属性变化后会重算窗口样式并抹掉 WS_THICKFRAME，这里守住它
      if (WParam = GWL_STYLE) and (LParam <> 0) then
      begin
        Style := PSTYLESTRUCT(LParam)^.styleNew;
        if (Style and WS_THICKFRAME) = 0 then
          PSTYLESTRUCT(LParam)^.styleNew := Style or WS_THICKFRAME;
      end;
    WM_WINDOWPOSCHANGING:
      begin
        Info := PWINDOWPOS(LParam);
        if (Info <> nil) and ((Info^.flags and SWP_NOSIZE) = 0) then
          UnpinInheritedFrame(Info);
      end;
  end;
end;

{ 系统边框增量：与 LCL（win32int.AdjustFormClientToWindowSize）同口径——按当前窗口
  样式与 DPI 调 AdjustWindowRectExForDpi；老系统没有该 API 时退化为 AdjustWindowRectEx。 }
function TXuiFramelessForm.NcFrameDelta: TSize;
var
  R: TRect;
  Dpi: UINT;
begin
  R := Types.Rect(0, 0, 0, 0);
  Dpi := 0;
  if XuiGetDpiForWindow <> nil then
    Dpi := XuiGetDpiForWindow(Handle);
  if (Dpi = 0) or (XuiAdjustWindowRectExForDpi = nil) then
  begin
    AdjustWindowRectEx(R, DWORD(Windows.GetWindowLongPtrW(Handle, GWL_STYLE)), False,
      DWORD(Windows.GetWindowLongPtrW(Handle, GWL_EXSTYLE)));
  end
  else
    XuiAdjustWindowRectExForDpi(@R, DWORD(Windows.GetWindowLongPtrW(Handle, GWL_STYLE)),
      False, DWORD(Windows.GetWindowLongPtrW(Handle, GWL_EXSTYLE)), Dpi);
  Result.cx := R.Right - R.Left;
  Result.cy := R.Bottom - R.Top;
end;

procedure TXuiFramelessForm.ApplyFramelessStyle;
var
  Style: LONG_PTR;
begin
  if not HandleAllocated then
    Exit;
  DisableOwnScrollBars;
  // WS_THICKFRAME：User32 的 SC_SIZE 分支要求该样式，缺了它鼠标拖边与
  // WM_NCLBUTTONDOWN(HT*) 都不会进入缩放循环
  Style := Windows.GetWindowLongPtrW(Handle, GWL_STYLE);
  if (Style and WS_THICKFRAME) = 0 then
  begin
    Windows.SetWindowLongPtrW(Handle, GWL_STYLE, Style or WS_THICKFRAME);
    Windows.SetWindowPos(Handle, 0, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  end;
  XuiLoadDpiApis;
  ApplyDwmFramelessLook;
  InstallWndProcHook;
end;

{ 整窗自绘的窗口不该有自己的滚动条。TForm 继承自 TScrollingWinControl，AutoScroll 默认开启：
  一旦客户区小于它记账的滚动范围（缩窗、或范围因历史尺寸被抬高）就会冒出系统滚动条，
  与页面里自绘滚动的内容叠成"双滚动条"（a_da 实测：窗口缩小后右侧出现两条滚动条）。 }
procedure TXuiFramelessForm.DisableOwnScrollBars;
begin
  AutoScroll := False;
  HorzScrollBar.Visible := False;
  VertScrollBar.Visible := False;
end;

{ 无边框窗口激活/非激活切换后重绘：引擎整窗重绘，盖掉系统可能画上的非客户区边框残影。 }
procedure TXuiFramelessForm.RedrawFramelessContent;
var
  i: Integer;
begin
  if not HandleAllocated then
    Exit;
  EnsureFullClient;
  ApplyDwmFramelessLook;
  Invalidate;
  for i := 0 to ControlCount - 1 do
    if Controls[i] <> nil then
      Controls[i].Invalidate;
end;

{ LCL 表单的客户区缓存对账：无边框窗口的客户区恒等于整窗，但 LCL 在拖拽/移动过程中
  会把它的表单客户区缓存留在"整窗 - 系统边框增量"（a_da 实测 1080x720 的窗口拖一次
  顶栏后缓存变成 1066x706），随后 alClient 的自绘画布被 LCL 对齐到这个错值 —— 画布
  比真实客户区窄/矮一圈，右侧/底部露出的旧像素残影正是"双滚动条"的来源。
  这里在缓存与 Win32 真值出现偏差时强制缓存失效并重新对齐子控件；平时零开销。 }
procedure TXuiFramelessForm.SyncLclClientRectCache;
var
  CR: TRect;
begin
  if (not HandleAllocated) or FSizing then
    Exit;
  // 与 EnsureFullClient 同款守卫：缩放/移动的模态循环进行中绝不动窗口与子控件
  // （实测在循环里 ReAlign 会干扰原生缩放循环，把本次拖拽顶掉）
  if Windows.GetCapture = Handle then
    Exit;
  if not Windows.GetClientRect(Handle, CR) then
    Exit;
  if (ClientWidth = CR.Right) and (ClientHeight = CR.Bottom) then
    Exit;
  {$IFDEF WINDOWS}
  NativeWindowTrace('lcl-sync', 0);
  {$ENDIF}
  InvalidateClientRectCache(False);   // 下一次查询按 Win32 真值重算
  ReAlign;                            // 立即按正确客户区重新对齐 alClient 子控件
end;

{ 客户区必须等于整窗：一旦发现被系统按边框内缩（会露出系统边框并触发 DWM 圆角），
  用 SWP_FRAMECHANGED 重跑一遍 WM_NCCALCSIZE 拉回来。客户区已等于整窗时直接返回，
  不会发出额外消息（因此不会与 WM_WINDOWPOSCHANGED 形成递归）。
  校正确实发生时再整窗失效一次：刚扩进来的右/下条带属于"新暴露区"，其后 WM_PAINT
  的更新区只覆盖这一条，客户区其余部分会残留旧版式的自绘内容；整窗失效保证下一次
  绘制按真实客户区尺寸重排并覆盖全部（a_da 实测：拖顶栏移动后双滚动条即源于此）。 }
procedure TXuiFramelessForm.EnsureFullClient;
var
  WR, CR: TRect;
  i: Integer;
begin
  if (not HandleAllocated) or FSizing then
    Exit;
  DisableOwnScrollBars;   // 幂等：任何路径把系统滚动条放回来都会被立刻纠正
  // 拖拽/移动的模态循环里客户区与窗口矩形可能瞬时不同步，此时不能动窗口
  // （实测在缩放循环中调用会把窗口弹成屏幕高度）
  if Windows.GetCapture = Handle then
    Exit;
  if (not Windows.GetWindowRect(Handle, WR)) or
     (not Windows.GetClientRect(Handle, CR)) then
    Exit;
  if ((CR.Right - CR.Left) = (WR.Right - WR.Left)) and
     ((CR.Bottom - CR.Top) = (WR.Bottom - WR.Top)) then
    Exit;
  NativeWindowTrace('ensure-correct-before', 0);
  Windows.SetWindowPos(Handle, 0, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  NativeWindowTrace('ensure-correct-after', 0);
  ApplyDwmFramelessLook;   // 边框回来时 DWM 可能同时恢复圆角/描边，这里再压一次
  Invalidate;
  for i := 0 to ControlCount - 1 do
    if Controls[i] <> nil then
      Controls[i].Invalidate;
end;

procedure TXuiFramelessForm.ApplyDwmFramelessLook;
var
  Pref: Integer;
  BorderColor: DWORD;
begin
  // 带 WS_THICKFRAME 的窗口在 Win11 上会被 DWM 加圆角与系统描边，会盖住应用自绘的
  // 1px 外边框；老系统上这两个属性不存在，调用失败即可（不致命）。
  Pref := XuiDwmcpDoNotRound;
  XuiDwmSetWindowAttribute(Handle, XuiDwmwaWindowCornerPreference, @Pref, SizeOf(Pref));
  BorderColor := XuiDwmColorNone;
  XuiDwmSetWindowAttribute(Handle, XuiDwmwaBorderColor, @BorderColor, SizeOf(BorderColor));
end;

procedure TXuiFramelessForm.InstallWndProcHook;
var
  Prev: Pointer;
begin
  if (not HandleAllocated) or (FHookedWndProc <> nil) then
    Exit;
  Windows.SetWindowLongPtrW(Handle, GWLP_USERDATA, PtrInt(Self));
  Prev := Pointer(Windows.SetWindowLongPtrW(Handle, GWLP_WNDPROC,
    PtrInt(@XuiFramelessWndProc)));
  if Prev <> nil then
    FHookedWndProc := Prev;
end;

procedure TXuiFramelessForm.UninstallWndProcHook;
begin
  if (FHookedWndProc = nil) or (not HandleAllocated) then
    Exit;
  Windows.SetWindowLongPtrW(Handle, GWLP_WNDPROC, PtrInt(FHookedWndProc));
  Windows.SetWindowLongPtrW(Handle, GWLP_USERDATA, 0);
  FHookedWndProc := nil;
end;

procedure TXuiFramelessForm.ApplyMaximizedBounds(AInfo: PMinMaxInfo);
var
  Mon: HMONITOR;
  MI: TXuiMonitorInfo;
  MinW, MinH: LongInt;
begin
  if AInfo = nil then
    Exit;
  // 交互最小尺寸：不小于启动尺寸，避免把别人的小窗顶大
  MinW := XuiMinWindowWidth;
  if Width < MinW then
    MinW := Width;
  MinH := XuiMinWindowHeight;
  if Height < MinH then
    MinH := Height;
  if AInfo^.ptMinTrackSize.X < MinW then
    AInfo^.ptMinTrackSize.X := MinW;
  if AInfo^.ptMinTrackSize.Y < MinH then
    AInfo^.ptMinTrackSize.Y := MinH;

  Mon := XuiMonitorFromWindow(Handle, XuiMonitorDefaultToNearest);
  if Mon = 0 then
    Exit;
  MI.cbSize := SizeOf(TXuiMonitorInfo);
  if not XuiGetMonitorInfo(Mon, @MI) then
    Exit;
  // 客户区等于整窗，系统按"带边框"推算出的最大化矩形会比工作区大一圈，
  // 直接以监视器工作区为准（ptMaxPosition 相对显示器左上角）
  AInfo^.ptMaxPosition.X := MI.rcWork.Left - MI.rcMonitor.Left;
  AInfo^.ptMaxPosition.Y := MI.rcWork.Top - MI.rcMonitor.Top;
  AInfo^.ptMaxSize.X := MI.rcWork.Right - MI.rcWork.Left;
  AInfo^.ptMaxSize.Y := MI.rcWork.Bottom - MI.rcWork.Top;
end;

procedure TXuiFramelessForm.DestroyWnd;
begin
  UninstallWndProcHook;
  inherited DestroyWnd;
end;

{$ENDIF}

end.
