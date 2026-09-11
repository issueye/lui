unit xui_engine;

{$mode objfpc}{$H+}

{ 引擎门面：加载 XML → 应用默认样式 → 布局 → 渲染。
  宿主控件（xui_host）在 Paint 时调用 Draw；尺寸变化时调 SetViewport 使布局失效。 }

interface

uses
  Classes, SysUtils, StrUtils, Types, Graphics, Contnrs, Math, LCLType,
  xui_types, xui_style, xui_dom, xui_xml, xui_render, xui_layout, xui_widget,
  xui_css_parser, xui_css_match, xui_text, xui_events, xui_input, xui_anim
  {$IFDEF WINDOWS}, xui_render_gdiplus{$ENDIF};

const
  // 每格滚轮的滚动像素
  XuiWheelStep = 48;

type
  TXuiEngine = class
  private
    FDocument: TXuiDocument;
    FRenderer: TXuiCustomRenderer;
    FStyleSheets: TObjectList; // TCssStyleSheet，加载顺序即应用顺序
    FViewportWidth, FViewportHeight: Integer;
    FLayoutValid: Boolean;
    FDocumentDirty: Boolean;  // 文档/样式表变更：需重建行为与样式
    FNeedsLayout: Boolean;    // 尺寸变更：需重算布局
    FPointer: TXuiPointerState;
    FEventTarget: TObject;    // 事件绑定的宿主对象（published 方法）
    FFocusNode: TXuiNode;
    FCaptureNode: TXuiNode;   // 指针捕捉节点（拖选：移动/抬起优先派发）
    FHostActive: Boolean;     // 宿主窗口是否有键盘焦点（失焦时光标不闪烁）
    FCaretVisible: Boolean;
    FLastCaretToggle: Int64;  // 上次光标相位翻转时刻；-1 = 待初始化
    FTransitions: TXuiTransitionSet; // 属性过渡（M5）
    FClock: Int64;            // 最近一次 Tick 注入的时间（ms）；0 = 尚未注入
    FHotReload: Boolean;      // 开启后按文件时间戳自动重载（Tick 中轮询）
    FReloadIntervalMs: Integer;
    FLastReloadCheck: Int64;
    FDocWatch: TStringList;   // XML 与 include 依赖：Name=路径, Value=加载时 FileAge
    FOnEvent: TXuiEventNotify;
    FOnFindMethod: TXuiFindMethodFunc;
    FOnChange: TNotifyEvent;
    FBackend: TXuiBackend;

    function DoMeasure(const AText: string; AStyle: TXuiStyle): TSize;
    procedure EnsureRenderer(ACanvas: TCanvas);
    procedure DoChange;
    // 样式/布局失效并通知宿主（伪类、类名、文本变化等）
    procedure InvalidateStyles;
    procedure ApplyNodeDataRecursive(ANode: TXuiNode);
    procedure ResolveBindings(ANode: TXuiNode);
    function DispatchEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
    function DispatchKind(ANode: TXuiNode; AKind: TXuiEventKind): Boolean;
    function BlockedByDisabled(ANode: TXuiNode): Boolean;
    function FindFocusTarget(ANode: TXuiNode): TXuiNode;
    function SetFocusNode(ANode: TXuiNode): Boolean;
    function FocusWantsCaret: Boolean;
    function ScrollableAncestor(ANode: TXuiNode): TXuiNode;
    function MaxScrollTop(ANode: TXuiNode): Single;
    procedure RenderNode(ANode: TXuiNode; ACanvas: TCanvas; AOpacity: Single);
    procedure RenderChildren(ANode: TXuiNode; ACanvas: TCanvas; AOpacity: Single);
    procedure RenderText(ANode: TXuiNode);
    // 记录 XML/include 依赖的时间戳（热重载监测）
    procedure RecordDocSources;
    procedure SetHotReload(AValue: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromFile(const AFileName: string);
    procedure LoadFromString(const AXMLContent: string);

    // 样式表：可叠加多张，后加载的胜出（同特异性时）
    procedure LoadStyleSheetFromFile(const AFileName: string);
    procedure LoadStyleSheetFromString(const AContent: string);
    procedure ClearStyleSheets;

    // 尺寸变化后布局失效，下次 Draw 时重新布局
    procedure SetViewport(AWidth, AHeight: Integer);
    procedure InvalidateLayout;

    // 在指定画布上完成（必要时）布局与绘制
    procedure Draw(ACanvas: TCanvas; const ABounds: TRect);

    // ---- 输入（宿主转发坐标/按键）----
    procedure HandleMouseMove(AX, AY: Integer);
    procedure HandleMouseDown(AX, AY: Integer);
    procedure HandleMouseUp(AX, AY: Integer);
    procedure HandleMouseLeave;
    function HandleMouseWheel(AX, AY, ADelta: Integer): Boolean;
    function HitTest(AX, AY: Integer): TXuiNode;
    // 键盘：返回 True 表示已消费（宿主据此把 Key 置 0）
    function HandleKeyDown(AKey: Word; AShift: TXuiShiftState): Boolean;
    function HandleKeyUp(AKey: Word; AShift: TXuiShiftState): Boolean;
    // UTF-8 文本输入（含 IME 上屏，可能一次多字符）
    function HandleTextInput(const AText: string): Boolean;
    // Tab / Shift+Tab 焦点遍历
    function FocusNext(AForward: Boolean): Boolean;
    // 聚焦输入框的光标矩形（客户区坐标；IME 组合窗定位/宿主查询用）
    function CaretRect(out ARect: TRect): Boolean;
    // 宿主窗口获得/失去键盘焦点
    procedure SetHostActive(AValue: Boolean);
    // 定时驱动（宿主 Timer）：光标闪烁、过渡动画、热重载轮询
    procedure Tick(ANowMs: Int64);
    // 是否需要周期性 Tick（宿主据此启停 Timer）
    function NeedsTick: Boolean;

    // ---- 热重载（M5）----
    // 无条件按当前来源重建文档（保留样式表；运行时 DOM 改动不保留）
    function ReloadFromSource: Boolean;
    // 按文件时间戳检查：XML/include 变化 → 重建文档；仅 CSS 变化 → 就地重解析（保留 DOM）
    function ReloadChangedFiles: Boolean;
    property HotReload: Boolean read FHotReload write SetHotReload;
    property ReloadIntervalMs: Integer read FReloadIntervalMs write FReloadIntervalMs;

    // ---- 运行时 DOM ----
    function AddElement(AParent: TXuiNode; const AXMLFragment: string): TXuiNode;
    procedure RemoveElement(ANode: TXuiNode);
    procedure ClearChildren(AParent: TXuiNode);
    procedure SetText(ANode: TXuiNode; const AText: string);
    procedure SetClass(ANode: TXuiNode; const AClassName: string);
    procedure SetDisabled(ANode: TXuiNode; AValue: Boolean);
    // 换事件宿主对象后重新解析全部 on* 绑定
    procedure RebindEvents;

    property Document: TXuiDocument read FDocument;
    property Renderer: TXuiCustomRenderer read FRenderer write FRenderer;
    property Pointer: TXuiPointerState read FPointer;
    property FocusNode: TXuiNode read FFocusNode;
    property EventTarget: TObject read FEventTarget write FEventTarget;
    property OnEvent: TXuiEventNotify read FOnEvent write FOnEvent;
    property OnFindMethod: TXuiFindMethodFunc read FOnFindMethod write FOnFindMethod;
    // 需要重绘时通知宿主（宿主接 Invalidate）
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Backend: TXuiBackend read FBackend write FBackend;
  end;

implementation

{ TXuiEngine }

// 系统单调时钟（ms）：宿主 Tick 尚未注入时间时的兜底
function XuiNowMs: Int64;
begin
  {$IFDEF WINDOWS}
  Result := GetTickCount64;
  {$ELSE}
  Result := GetTickCount;
  {$ENDIF}
end;

constructor TXuiEngine.Create;
begin
  inherited Create;
  FStyleSheets := TObjectList.Create(True);
  FPointer := TXuiPointerState.Create;
  FViewportWidth := 0;
  FViewportHeight := 0;
  FLayoutValid := False;
  FDocumentDirty := False;
  FNeedsLayout := False;
  FCaptureNode := nil;
  FHostActive := True;
  FCaretVisible := True;
  FLastCaretToggle := -1;
  FTransitions := TXuiTransitionSet.Create;
  FClock := 0;
  FHotReload := False;
  FReloadIntervalMs := 500;
  FLastReloadCheck := 0;
  FDocWatch := TStringList.Create;
  FBackend := xbAuto;
end;

destructor TXuiEngine.Destroy;
begin
  FDocWatch.Free;
  FPointer.Free;
  FStyleSheets.Free;
  FTransitions.Free;
  FRenderer.Free;
  FDocument.Free;
  inherited Destroy;
end;

procedure TXuiEngine.LoadFromFile(const AFileName: string);
var
  doc: TXuiDocument;
begin
  doc := LoadDocumentFromFile(AFileName); // 解析失败时抛异常，保留旧文档
  FTransitions.Reset;
  FDocument.Free;
  FDocument := doc;
  if FDocument.Root <> nil then
    ApplyNodeDataRecursive(FDocument.Root);
  FPointer.SetRoot(FDocument.Root);
  FFocusNode := nil;
  FCaptureNode := nil;
  FDocumentDirty := True;
  FNeedsLayout := True;
  RecordDocSources;
  DoChange;
end;

procedure TXuiEngine.LoadFromString(const AXMLContent: string);
var
  doc: TXuiDocument;
begin
  doc := LoadDocumentFromXML(AXMLContent); // 解析失败时抛异常，保留旧文档
  FTransitions.Reset;
  FDocument.Free;
  FDocument := doc;
  if FDocument.Root <> nil then
    ApplyNodeDataRecursive(FDocument.Root);
  FPointer.SetRoot(FDocument.Root);
  FFocusNode := nil;
  FCaptureNode := nil;
  FDocumentDirty := True;
  FNeedsLayout := True;
  DoChange;
end;

procedure TXuiEngine.SetViewport(AWidth, AHeight: Integer);
begin
  if (AWidth <> FViewportWidth) or (AHeight <> FViewportHeight) then
  begin
    FViewportWidth := AWidth;
    FViewportHeight := AHeight;
    FNeedsLayout := True;
  end;
end;

procedure TXuiEngine.InvalidateLayout;
begin
  FNeedsLayout := True;
end;

procedure TXuiEngine.LoadStyleSheetFromFile(const AFileName: string);
var
  list: TStringList;
  sheet: TCssStyleSheet;
begin
  list := TStringList.Create;
  try
    list.LoadFromFile(AFileName);
    sheet := TCssStyleSheet.Create;
    sheet.ParseStyleSheet(list.Text);
    sheet.SourceFile := ExpandFileName(AFileName);
    sheet.SourceMTime := FileAge(AFileName);
    FStyleSheets.Add(sheet);
  finally
    list.Free;
  end;
  FDocumentDirty := True;
  FNeedsLayout := True;
  DoChange;
end;

procedure TXuiEngine.LoadStyleSheetFromString(const AContent: string);
var
  sheet: TCssStyleSheet;
begin
  sheet := TCssStyleSheet.Create;
  sheet.ParseStyleSheet(AContent);
  FStyleSheets.Add(sheet);
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.ClearStyleSheets;
begin
  FStyleSheets.Clear;
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

// 加载成功后记录 XML 源与 include 依赖的当前时间戳
procedure TXuiEngine.RecordDocSources;
var
  i: Integer;
  path: string;
begin
  FDocWatch.Clear;
  if (FDocument = nil) or (FDocument.SourceFile = '') then
    Exit;
  path := FDocument.SourceFile;
  FDocWatch.Values[path] := IntToStr(FileAge(path));
  for i := 0 to FDocument.Dependencies.Count - 1 do
  begin
    path := FDocument.Dependencies[i];
    FDocWatch.Values[path] := IntToStr(FileAge(path));
  end;
end;

procedure TXuiEngine.SetHotReload(AValue: Boolean);
begin
  if FHotReload = AValue then
    Exit;
  FHotReload := AValue;
  FLastReloadCheck := FClock; // 开启后从下一个轮询周期开始检查
  DoChange;                   // 通知宿主同步 Timer
end;

function TXuiEngine.ReloadFromSource: Boolean;
var
  source: string;
begin
  Result := False;
  if (FDocument = nil) or (FDocument.SourceFile = '') then
    Exit;
  source := FDocument.SourceFile;
  LoadFromFile(source); // 重新解析（含 include）、重建行为/绑定、记录监测表
  Result := True;
end;

function TXuiEngine.ReloadChangedFiles: Boolean;
var
  i, age: Integer;
  sheet: TCssStyleSheet;
  cssChanged, docChanged: Boolean;
  list: TStringList;
begin
  Result := False;
  if FDocument = nil then
    Exit;

  // XML 及 include 依赖变化 → 重建文档（运行时 DOM 改动不保留）
  docChanged := False;
  for i := 0 to FDocWatch.Count - 1 do
  begin
    age := FileAge(FDocWatch.Names[i]);
    if (age <> -1) and (age <> StrToIntDef(FDocWatch.ValueFromIndex[i], -1)) then
    begin
      docChanged := True;
      Break;
    end;
  end;
  if docChanged then
    Exit(ReloadFromSource);

  // 仅样式表变化 → 就地重解析（DOM/焦点/滚动/运行时改动保留）
  for i := 0 to FStyleSheets.Count - 1 do
  begin
    sheet := TCssStyleSheet(FStyleSheets[i]);
    if sheet.SourceFile = '' then
      Continue;
    age := FileAge(sheet.SourceFile);
    if (age = -1) or (age = sheet.SourceMTime) then
      Continue;
    list := TStringList.Create;
    try
      list.LoadFromFile(sheet.SourceFile);
      sheet.ClearRules;
      sheet.ParseStyleSheet(list.Text);
      sheet.SourceMTime := age;
    finally
      list.Free;
    end;
    cssChanged := True;
  end;
  if cssChanged then
  begin
    FDocumentDirty := True;
    FNeedsLayout := True;
    DoChange;
    Result := True;
  end;
end;

procedure TXuiEngine.ApplyNodeDataRecursive(ANode: TXuiNode);
var
  i: Integer;
  behavior: TXuiBehavior;
begin
  if ANode.Behavior = nil then
  begin
    behavior := CreateBehavior(ANode.Tag, ANode); // 未注册的标签返回 nil
    if behavior <> nil then
      for i := 0 to ANode.Attributes.Count - 1 do
        behavior.HandleAttribute(ANode.Attributes.Names[i],
          ANode.Attributes.ValueFromIndex[i]);
  end;
  ResolveBindings(ANode);
  for i := 0 to ANode.Count - 1 do
    ApplyNodeDataRecursive(ANode[i]);
end;

// XML 的 on* 属性 → 宿主 published 方法（MethodAddress）；解析失败留给兜底回调
procedure TXuiEngine.ResolveBindings(ANode: TXuiNode);
var
  i: Integer;
  kind: TXuiEventKind;
  attrName, handlerName: string;
  binding: TXuiEventBinding;
begin
  ANode.Bindings.Clear;
  for i := 0 to ANode.Attributes.Count - 1 do
  begin
    attrName := ANode.Attributes.Names[i];
    if not XuiEventAttrKind(attrName, kind) then
      Continue;
    handlerName := Trim(ANode.Attributes.ValueFromIndex[i]);
    binding := TXuiEventBinding.Create;
    binding.Kind := kind;
    binding.AttrName := LowerCase(attrName);
    binding.HandlerName := handlerName;
    if not XuiResolveMethod(FEventTarget, handlerName, binding.Handler) then
      if FOnFindMethod <> nil then
        FOnFindMethod(handlerName, binding.Handler);
    ANode.Bindings.Add(binding);
  end;
end;

function TXuiEngine.DispatchEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
var
  node: TXuiNode;
  i: Integer;
  binding: TXuiEventBinding;
begin
  Result := False;
  node := ANode;
  while node <> nil do
  begin
    for i := 0 to node.Bindings.Count - 1 do
    begin
      binding := TXuiEventBinding(node.Bindings[i]);
      if (binding.Kind = AEvent.Kind) and (binding.Handler.Code <> nil) then
      begin
        // Sender = 承载绑定的节点（等价 DFM 里 Sender = 控件）
        TNotifyEvent(binding.Handler)(node);
        // v1：绑定命中即消费该事件，不再向祖先冒泡
        Exit(True);
      end;
    end;
    if (node.Behavior is TXuiBehavior) and
       TXuiBehavior(node.Behavior).HandleEvent(node, AEvent) then
      Exit(True);
    node := node.Parent;
  end;
  // 兜底：无人处理时通知外部（适合动态界面）
  if (not Result) and (FOnEvent <> nil) then
    FOnEvent(ANode, AEvent.Kind);
end;

// 无载荷事件的便捷派发（focus/blur/click/mouseenter/mouseleave）
function TXuiEngine.DispatchKind(ANode: TXuiNode; AKind: TXuiEventKind): Boolean;
var
  ev: TXuiEvent;
begin
  ev := Default(TXuiEvent);
  ev.Kind := AKind;
  Result := DispatchEvent(ANode, ev);
end;

// 命中链上存在 disabled → 阻断点击类事件（视觉上仍可 :hover，与浏览器一致）
function TXuiEngine.BlockedByDisabled(ANode: TXuiNode): Boolean;
var
  node: TXuiNode;
begin
  Result := False;
  node := ANode;
  while node <> nil do
  begin
    if XuiIsDisabled(node) then
      Exit(True);
    node := node.Parent;
  end;
end;

function TXuiEngine.FindFocusTarget(ANode: TXuiNode): TXuiNode;
var
  node: TXuiNode;
begin
  Result := nil;
  node := ANode;
  while node <> nil do
  begin
    if XuiIsDisabled(node) then
      Exit(nil);
    if (node.Behavior is TXuiBehavior) and TXuiBehavior(node.Behavior).CanFocus then
      Exit(node);
    node := node.Parent;
  end;
end;

function TXuiEngine.SetFocusNode(ANode: TXuiNode): Boolean;
begin
  Result := False;
  if ANode = FFocusNode then
    Exit;
  if FFocusNode <> nil then
  begin
    FFocusNode.Pseudos := FFocusNode.Pseudos - [xpFocus];
    DispatchKind(FFocusNode, xevBlur);
    Result := True;
  end;
  FFocusNode := ANode;
  FCaretVisible := True;
  FLastCaretToggle := -1; // 新焦点重新开始闪烁相位
  if FFocusNode <> nil then
  begin
    FFocusNode.Pseudos := FFocusNode.Pseudos + [xpFocus];
    DispatchKind(FFocusNode, xevFocus);
    Result := True;
  end;
end;

// 焦点节点是否需要光标闪烁
function TXuiEngine.FocusWantsCaret: Boolean;
begin
  Result := (FFocusNode <> nil) and (FFocusNode.Behavior is TXuiBehavior) and
    TXuiBehavior(FFocusNode.Behavior).WantsCaret;
end;

procedure TXuiEngine.HandleMouseMove(AX, AY: Integer);
var
  changed: Boolean;
  i: Integer;
  ev: TXuiEvent;
begin
  if FPointer.Root = nil then
    Exit;
  changed := FPointer.MouseMove(AX, AY);
  for i := 0 to FPointer.LeftNodes.Count - 1 do
    DispatchKind(TXuiNode(FPointer.LeftNodes[i]), xevMouseLeave);
  for i := 0 to FPointer.Entered.Count - 1 do
    DispatchKind(TXuiNode(FPointer.Entered[i]), xevMouseEnter);
  ev := Default(TXuiEvent);
  ev.Kind := xevMouseMove;
  ev.X := AX;
  ev.Y := AY;
  if FCaptureNode <> nil then
  begin
    if DispatchEvent(FCaptureNode, ev) then
      DoChange; // 行为已消费（如拖选改变光标/选区）
  end
  else if (FPointer.Hover <> nil) and DispatchEvent(FPointer.Hover, ev) then
    DoChange;
  if changed then
    InvalidateStyles;
end;

procedure TXuiEngine.HandleMouseDown(AX, AY: Integer);
var
  hit: TXuiNode;
  changed: Boolean;
  ev: TXuiEvent;
begin
  if FPointer.Root = nil then
    Exit;
  changed := FPointer.MouseDown(AX, AY, hit);
  if SetFocusNode(FindFocusTarget(hit)) then
    changed := True;
  if (hit <> nil) and (hit.Behavior is TXuiBehavior) and
     TXuiBehavior(hit.Behavior).NeedsPointerCapture then
    FCaptureNode := hit
  else
    FCaptureNode := nil;
  if (hit <> nil) and (not BlockedByDisabled(hit)) then
  begin
    ev := Default(TXuiEvent);
    ev.Kind := xevMouseDown;
    ev.X := AX;
    ev.Y := AY;
    if DispatchEvent(hit, ev) then
      DoChange; // 行为已消费（输入框点按定位光标）
  end;
  if changed then
    InvalidateStyles;
end;

procedure TXuiEngine.HandleMouseUp(AX, AY: Integer);
var
  hit, clickNode: TXuiNode;
  changed, handled: Boolean;
  ev: TXuiEvent;
begin
  if FPointer.Root = nil then
    Exit;
  handled := False;
  changed := FPointer.MouseUp(AX, AY, hit, clickNode);
  ev := Default(TXuiEvent);
  ev.Kind := xevMouseUp;
  ev.X := AX;
  ev.Y := AY;
  if (FCaptureNode <> nil) and (FCaptureNode <> hit) then
  begin
    if DispatchEvent(FCaptureNode, ev) then
      handled := True;
  end;
  FCaptureNode := nil;
  if (hit <> nil) and (not BlockedByDisabled(hit)) then
  begin
    if DispatchEvent(hit, ev) then
      handled := True;
  end;
  if (clickNode <> nil) and (not BlockedByDisabled(clickNode)) then
    DispatchKind(clickNode, xevClick);
  if handled then
    DoChange;
  if changed then
    InvalidateStyles;
end;

procedure TXuiEngine.HandleMouseLeave;
var
  i: Integer;
begin
  if FPointer.Root = nil then
    Exit;
  if FPointer.Leave then
  begin
    for i := 0 to FPointer.LeftNodes.Count - 1 do
      DispatchKind(TXuiNode(FPointer.LeftNodes[i]), xevMouseLeave);
    InvalidateStyles;
  end;
end;

function TXuiEngine.MaxScrollTop(ANode: TXuiNode): Single;
var
  boxH: Single;
begin
  if ANode.Style = nil then
    Exit(0);
  boxH := ANode.ContentBox.Bottom - ANode.ContentBox.Top;
  Result := Max(0, ANode.ContentHeight - boxH);
end;

function TXuiEngine.ScrollableAncestor(ANode: TXuiNode): TXuiNode;
var
  node: TXuiNode;
begin
  Result := nil;
  node := ANode;
  while node <> nil do
  begin
    if (node.Style <> nil) and (node.Style.Overflow = xovHidden) and
       (MaxScrollTop(node) > 0) then
      Exit(node);
    node := node.Parent;
  end;
end;

function TXuiEngine.HandleMouseWheel(AX, AY, ADelta: Integer): Boolean;
var
  hit, target: TXuiNode;
  newTop: Single;
  ev: TXuiEvent;
begin
  Result := False;
  if FPointer.Root = nil then
    Exit;
  hit := HitTest(AX, AY);
  ev := Default(TXuiEvent);
  ev.Kind := xevWheel;
  ev.X := AX;
  ev.Y := AY;
  ev.Delta := ADelta;
  if DispatchEvent(hit, ev) then
    Exit(True); // 绑定或行为已处理
  target := ScrollableAncestor(hit);
  if target = nil then
    Exit;
  newTop := Min(MaxScrollTop(target),
    Max(0, target.ScrollTop - ADelta / 120 * XuiWheelStep));
  if newTop <> target.ScrollTop then
  begin
    target.ScrollTop := newTop;
    FNeedsLayout := True;
    DoChange;
    Result := True;
  end;
end;

function TXuiEngine.HitTest(AX, AY: Integer): TXuiNode;
begin
  Result := XuiHitTest(FPointer.Root, AX, AY);
end;

{ ---- 键盘 ---- }

// 沿焦点链派发键盘事件；未消费时走内置（Tab 遍历 / Enter 激活）
function TXuiEngine.HandleKeyDown(AKey: Word; AShift: TXuiShiftState): Boolean;
var
  ev: TXuiEvent;
  before: string;
begin
  Result := False;
  if FFocusNode = nil then
  begin
    // 无焦点时 Tab 仍可聚焦第一个可聚焦节点（浏览器语义）
    if AKey = VK_TAB then
    begin
      Result := FocusNext(not (xssShift in AShift));
      if Result then
        DoChange;
    end;
    Exit;
  end;
  ev := Default(TXuiEvent);
  ev.Kind := xevKeyDown;
  ev.Key := AKey;
  ev.Shift := AShift;
  before := FFocusNode.Text;
  Result := DispatchEvent(FFocusNode, ev);

  // 编辑类按键改变了值：置布局脏 + 派发 oninput（显示与语法一致：用户改动才触发）
  if Result and (FFocusNode.Text <> before) then
  begin
    FNeedsLayout := True;
    DispatchKind(FFocusNode, xevInput);
  end;

  // 内置：Tab / Shift+Tab 焦点遍历
  if (not Result) and (AKey = VK_TAB) then
    Result := FocusNext(not (xssShift in AShift));

  // 内置：Enter（按钮 = 等价点击；输入框等 = 派发 onenter 供表单提交）
  if (not Result) and (AKey = VK_RETURN) then
  begin
    if (FFocusNode.Behavior is TXuiBehavior) and
       TXuiBehavior(FFocusNode.Behavior).ActivatesOnEnter and
       (not BlockedByDisabled(FFocusNode)) then
    begin
      DispatchKind(FFocusNode, xevClick);
      Result := True;
    end
    else
    begin
      ev.Kind := xevEnter;
      Result := DispatchEvent(FFocusNode, ev);
    end;
  end;

  if Result then
    DoChange;
end;

function TXuiEngine.HandleKeyUp(AKey: Word; AShift: TXuiShiftState): Boolean;
var
  ev: TXuiEvent;
begin
  Result := False;
  if FFocusNode = nil then
    Exit;
  ev := Default(TXuiEvent);
  ev.Kind := xevKeyUp;
  ev.Key := AKey;
  ev.Shift := AShift;
  Result := DispatchEvent(FFocusNode, ev);
end;

// 文本输入（UTF-8，IME 上屏可能一次多字符）：沿焦点链交给行为
function TXuiEngine.HandleTextInput(const AText: string): Boolean;
var
  ev: TXuiEvent;
  before: string;
begin
  Result := False;
  if (AText = '') or (FFocusNode = nil) or BlockedByDisabled(FFocusNode) then
    Exit;
  ev := Default(TXuiEvent);
  ev.Kind := xevTextInput;
  ev.Text := AText;
  before := FFocusNode.Text;
  Result := DispatchEvent(FFocusNode, ev);
  if Result then
  begin
    if FFocusNode.Text <> before then
    begin
      FNeedsLayout := True;
      DispatchKind(FFocusNode, xevInput);
    end;
    DoChange;
  end;
end;

function TXuiEngine.FocusNext(AForward: Boolean): Boolean;
var
  list: TList;
  i, idx: Integer;
  target: TXuiNode;
begin
  Result := False;
  if (FDocument = nil) or (FDocument.Root = nil) then
    Exit;
  list := TList.Create;
  try
    XuiCollectFocusables(FDocument.Root, list);
    if list.Count = 0 then
      Exit;
    idx := -1;
    for i := 0 to list.Count - 1 do
      if TXuiNode(list[i]) = FFocusNode then
      begin
        idx := i;
        Break;
      end;
    if idx < 0 then
    begin
      if AForward then
        target := TXuiNode(list[0])
      else
        target := TXuiNode(list[list.Count - 1]);
    end
    else if AForward then
      target := TXuiNode(list[(idx + 1) mod list.Count])
    else
      target := TXuiNode(list[(idx - 1 + list.Count) mod list.Count]);
    if SetFocusNode(target) then
    begin
      InvalidateStyles;
      Result := True;
    end;
  finally
    list.Free;
  end;
end;

function TXuiEngine.CaretRect(out ARect: TRect): Boolean;
begin
  ARect := Types.Rect(0, 0, 0, 0);
  Result := (FFocusNode <> nil) and (FFocusNode.Behavior is TXuiBehavior) and
    TXuiBehavior(FFocusNode.Behavior).CaretRect(FFocusNode, ARect);
end;

procedure TXuiEngine.SetHostActive(AValue: Boolean);
begin
  if FHostActive = AValue then
    Exit;
  FHostActive := AValue;
  // 失焦窗口不显示光标（与浏览器一致）；重新获得焦点立即显示
  FCaretVisible := AValue;
  FLastCaretToggle := -1;
  DoChange;
end;

procedure TXuiEngine.Tick(ANowMs: Int64);
var
  blink: Boolean;
begin
  FClock := ANowMs;

  // 热重载轮询（节流）
  if FHotReload and (ANowMs - FLastReloadCheck >= FReloadIntervalMs) then
  begin
    FLastReloadCheck := ANowMs;
    ReloadChangedFiles;
  end;

  // 过渡动画推进
  if FTransitions.Advance(ANowMs) then
    DoChange;

  blink := FHostActive and FocusWantsCaret;
  if not blink then
  begin
    // 未聚焦/无光标：隐藏光标（失焦窗口的光标常亮会干扰截图与观感）
    if FCaretVisible then
    begin
      FCaretVisible := False;
      DoChange;
    end;
    Exit;
  end;
  if not FCaretVisible then
  begin
    FCaretVisible := True;
    FLastCaretToggle := ANowMs;
    DoChange;
    Exit;
  end;
  if FLastCaretToggle < 0 then
    FLastCaretToggle := ANowMs
  else if ANowMs - FLastCaretToggle >= 500 then
  begin
    FLastCaretToggle := ANowMs;
    FCaretVisible := not FCaretVisible;
    DoChange;
  end;
end;

function TXuiEngine.NeedsTick: Boolean;
begin
  Result := FHotReload or FTransitions.HasActive or (FHostActive and FocusWantsCaret);
end;

procedure TXuiEngine.InvalidateStyles;
begin
  FDocumentDirty := True;
  FNeedsLayout := True;
  DoChange;
end;

procedure TXuiEngine.DoChange;
begin
  if FOnChange <> nil then
    FOnChange(Self);
end;

function TXuiEngine.AddElement(AParent: TXuiNode; const AXMLFragment: string): TXuiNode;
var
  doc: TXuiDocument;
  i: Integer;
  baseDir: string;
begin
  Result := nil;
  if AParent = nil then
    Exit;
  // 片段里的 <include> 按当前文档目录解析
  baseDir := '';
  if (FDocument <> nil) and (FDocument.SourceFile <> '') then
    baseDir := ExtractFileDir(FDocument.SourceFile);
  doc := LoadDocumentFromXML('<xui-fragment>' + AXMLFragment + '</xui-fragment>', baseDir);
  try
    if (doc.Root <> nil) and (doc.Root.Count > 0) then
    begin
      Result := doc.Root[0];
      doc.Root.RemoveChild(Result); // 摘出，避免随包裹文档释放
    end;
    // include 依赖并入文档（热重载监测用）
    if FDocument <> nil then
    begin
      for i := 0 to doc.Dependencies.Count - 1 do
        if FDocument.Dependencies.IndexOf(doc.Dependencies[i]) < 0 then
          FDocument.Dependencies.Add(doc.Dependencies[i]);
      RecordDocSources;
    end;
  finally
    doc.Free;
  end;
  if Result = nil then
    Exit;
  AParent.AddChild(Result);
  ApplyNodeDataRecursive(Result);
  InvalidateStyles;
end;

procedure TXuiEngine.RemoveElement(ANode: TXuiNode);
begin
  if ANode = nil then
    Exit;
  FPointer.Reset; // 悬停链可能引用待释放节点
  FTransitions.Reset; // 过渡状态可能引用待释放节点
  if FCaptureNode = ANode then
    FCaptureNode := nil;
  if ANode.Parent <> nil then
    ANode.Parent.RemoveChild(ANode);
  ANode.Free;
  if (FFocusNode <> nil) and (FFocusNode.Root <> FDocument.Root) then
    FFocusNode := nil; // 焦点节点已被摘除
  InvalidateStyles;
end;

procedure TXuiEngine.ClearChildren(AParent: TXuiNode);
var
  child: TXuiNode;
begin
  if AParent = nil then
    Exit;
  FPointer.Reset;
  FTransitions.Reset; // 过渡状态可能引用待释放节点
  if (FCaptureNode <> nil) and (FCaptureNode.Root <> FDocument.Root) then
    FCaptureNode := nil;
  while AParent.Count > 0 do
  begin
    child := AParent[0];
    AParent.RemoveChild(child);
    child.Free;
  end;
  if (FFocusNode <> nil) and (FFocusNode.Root <> FDocument.Root) then
    FFocusNode := nil;
  InvalidateStyles;
end;

procedure TXuiEngine.SetText(ANode: TXuiNode; const AText: string);
begin
  if ANode = nil then
    Exit;
  if ANode.Text = AText then
    Exit;
  ANode.Text := AText;
  FNeedsLayout := True;
  DoChange;
end;

procedure TXuiEngine.SetClass(ANode: TXuiNode; const AClassName: string);
var
  part: string;
begin
  if ANode = nil then
    Exit;
  ANode.ClassList.Clear;
  for part in SplitString(Trim(AClassName), ' ') do
    if Trim(part) <> '' then
      ANode.ClassList.Add(Trim(part));
  InvalidateStyles;
end;

procedure TXuiEngine.SetDisabled(ANode: TXuiNode; AValue: Boolean);
begin
  if ANode = nil then
    Exit;
  if ANode.Behavior is TXuiBehavior then
    TXuiBehavior(ANode.Behavior).SetDisabled(AValue)
  else if AValue then
    ANode.Pseudos := ANode.Pseudos + [xpDisabled]
  else
    ANode.Pseudos := ANode.Pseudos - [xpDisabled];
  InvalidateStyles;
end;

procedure TXuiEngine.RebindEvents;

  procedure Walk(ANode: TXuiNode);
  var
    i: Integer;
  begin
    ResolveBindings(ANode);
    for i := 0 to ANode.Count - 1 do
      Walk(ANode[i]);
  end;

begin
  if (FDocument = nil) or (FDocument.Root = nil) then
    Exit;
  Walk(FDocument.Root);
end;

function TXuiEngine.DoMeasure(const AText: string; AStyle: TXuiStyle): TSize;
begin
  if FRenderer <> nil then
    Result := FRenderer.MeasureText(AText, AStyle)
  else
  begin
    Result.cx := Round(Length(AText) * AStyle.FontSize * 0.6);
    Result.cy := Round(AStyle.FontSize * AStyle.LineHeight);
  end;
end;

procedure TXuiEngine.EnsureRenderer(ACanvas: TCanvas);
begin
  if FRenderer = nil then
  begin
    {$IFDEF WINDOWS}
    if (FBackend = xbGdiPlus) or ((FBackend = xbAuto) and GdiPlusAvailable) then
      FRenderer := TGdiPlusRenderer.Create(ACanvas)
    else
    {$ENDIF}
      FRenderer := TGdiRenderer.Create(ACanvas);
  end;
  FRenderer.SetCanvas(ACanvas);
  FRenderer.SetOpacity(1);
end;

procedure TXuiEngine.Draw(ACanvas: TCanvas; const ABounds: TRect);
begin
  if (FDocument = nil) or (FDocument.Root = nil) then
    Exit;
  EnsureRenderer(ACanvas);

  SetViewport(ABounds.Right - ABounds.Left, ABounds.Bottom - ABounds.Top);

  if FDocumentDirty or (not FLayoutValid) then
  begin
    // 过渡：重算前记录显示值 → 重算 → diff 启动/重启 → 立即写回插值
    FTransitions.Capture(FDocument);
    ComputeDocumentStyles(FDocument, FStyleSheets);
    if FClock = 0 then
      FClock := XuiNowMs; // 宿主尚未提供时间（未 Tick）：用系统时钟兜底
    FTransitions.Resolve(FDocument, FClock);
    FDocumentDirty := False;
    FLayoutValid := True;
    FNeedsLayout := True;
  end;
  if FNeedsLayout then
  begin
    LayoutDocument(FDocument, FViewportWidth, FViewportHeight, @DoMeasure);
    FNeedsLayout := False;
  end;

  RenderNode(FDocument.Root, ACanvas, 1);
end;

procedure TXuiEngine.RenderNode(ANode: TXuiNode; ACanvas: TCanvas; AOpacity: Single);
var
  style: TXuiStyle;
  op: Single;
begin
  if (ANode.Style = nil) or (ANode.Style.Display = xdispNone) then
    Exit;
  style := ANode.Style;
  op := AOpacity * style.Opacity;
  if op <= 0 then
    Exit;
  FRenderer.SetOpacity(op);

  // visibility:hidden 不绘制自身，但子级可覆盖回 visible（继承语义）
  if style.Visibility = xvisVisible then
  begin
    if style.BgColor.A > 0 then
    begin
      if style.BorderRadius > 0 then
        FRenderer.FillRoundRect(ANode.BoxRect, style.BorderRadius, style.BgColor)
      else
        FRenderer.FillRect(ANode.BoxRect, style.BgColor);
    end;
    if style.BorderWidth > 0 then
    begin
      if style.BorderRadius > 0 then
        FRenderer.FrameRoundRect(ANode.BoxRect, style.BorderRadius,
          style.BorderWidth, style.BorderColor)
      else
        FRenderer.FrameRect(ANode.BoxRect, style.BorderColor, style.BorderWidth);
    end;
    if (ANode.Behavior is TXuiBehavior) and
       TXuiBehavior(ANode.Behavior).RenderContent(ANode, FRenderer, @DoMeasure, FCaretVisible) then
    begin
      // 行为已自绘（输入框：值/掩码/选区/光标/占位符）
    end
    else if (ANode.Text <> '') and (ANode.Count = 0) then
      RenderText(ANode);
  end;

  if ANode.Count > 0 then
  begin
    if style.Overflow = xovHidden then
      FRenderer.PushClip(ANode.PaddingBox);
    RenderChildren(ANode, ACanvas, op);
    if style.Overflow = xovHidden then
      FRenderer.PopClip;
  end;
end;

procedure TXuiEngine.RenderText(ANode: TXuiNode);
var
  contentRect: TRect;
  count, i: Integer;
  lineH, y: Single;
  lineRect: TRect;
begin
  contentRect := ANode.ContentBox;
  count := Length(ANode.TextLines);
  if count = 0 then
  begin
    // 未经过布局（或空文本）：按单行绘制
    FRenderer.DrawText(contentRect, ANode.Text, ANode.Style);
    Exit;
  end;
  if count = 1 then
  begin
    // 单行：内容盒内垂直居中（保持 button/input 观感）
    FRenderer.DrawText(contentRect, ANode.TextLines[0], ANode.Style);
    Exit;
  end;

  // 多行：自内容盒顶部按行高排布（水平方向由文本对齐决定）
  lineH := LineHeightPx(ANode.Style);
  y := contentRect.Top;
  for i := 0 to count - 1 do
  begin
    lineRect := Types.Rect(contentRect.Left, Round(y), contentRect.Right, Round(y + lineH));
    FRenderer.DrawText(lineRect, ANode.TextLines[i], ANode.Style);
    y := y + lineH;
  end;
end;

procedure TXuiEngine.RenderChildren(ANode: TXuiNode; ACanvas: TCanvas; AOpacity: Single);
var
  i: Integer;
  order: TList;
begin
  // 绘制序与命中测试共用（xui_events）：普通流按文档序，定位元素按 z-index 升序
  order := TList.Create;
  try
    XuiCollectDrawOrder(ANode, order);
    for i := 0 to order.Count - 1 do
      RenderNode(TXuiNode(order[i]), ACanvas, AOpacity);
  finally
    order.Free;
  end;
end;

end.
