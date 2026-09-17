unit xui_events;

{$mode objfpc}{$H+}

{ 交互基础（M4）。纯逻辑、不依赖 LCL，便于单元测试：
  - 命中测试：逆绘制序递归，尊重 display:none 与滚动容器（hidden/auto/scroll）裁剪；
    R2/R3：滚动容器还要扣除已显示的滚动条条带（与绘制几何同源，见 xui_scroll）
  - 指针状态机：hover 链 / active / 按下节点（click = 按下与抬起的最近公共祖先）
  - 事件绑定：XML 的 on* 属性 → 宿主 published 方法，按名字解析（MethodAddress，
    与 RTL 的 DFM 事件绑定同一机制，见 classes/reader.inc: TReader.FindMethod） }

interface

uses
  Classes, SysUtils, Types, Contnrs, Math,
  xui_types, xui_style, xui_dom, xui_scroll;

type
  // 修饰键集合（引擎自有的轻量表示，不依赖 LCL 的 TShiftState）
  TXuiShiftState = set of (xssShift, xssCtrl, xssAlt);

  TXuiEventKind = (xevMouseDown, xevMouseUp, xevClick,
    xevMouseEnter, xevMouseLeave, xevWheel, xevFocus, xevBlur,
    // M5：指针移动（拖选）、文本输入结果、Enter 确认；以及不提供 XML 绑定的键盘原语
    xevMouseMove, xevInput, xevEnter, xevKeyDown, xevKeyUp, xevTextInput);

  // 事件载荷：鼠标坐标 / 滚轮量 / 按键码 / 修饰键 / 输入文本
  TXuiEvent = record
    Kind: TXuiEventKind;
    X, Y: Integer;         // 指针坐标（客户区，鼠标系事件有效）
    Delta: Integer;        // 滚轮增量
    Key: Word;             // 虚拟键码（键盘事件有效）
    Shift: TXuiShiftState;
    Text: string;          // xevTextInput：本次输入文本；xevInput：变动后的节点值
    Handled: Boolean;      // 行为置 True 表示已消费
  end;

  // 引擎级兜底通知（绑定不存在时仍能收到事件）
  TXuiEventNotify = procedure(ANode: TXuiNode; AKind: TXuiEventKind) of object;
  // 绑定解析失败时的兜底查找
  TXuiFindMethodFunc = function(const AName: string; out AHandler: TMethod): Boolean of object;

  TXuiEventBinding = class
  public
    Kind: TXuiEventKind;
    AttrName: string;    // 源属性名（小写，含 on 前缀）
    HandlerName: string; // XML 中书写的宿主方法名（避免与 TObject.MethodName 冲突）
    Handler: TMethod;    // 解析结果；Code = nil 表示未解析
  end;

const
  // 可 XML 绑定的属性名；空串 = 该事件种类不提供绑定（键盘原语无 TNotifyEvent 载荷）
  TXuiEventAttrs: array[TXuiEventKind] of string = (
    'onmousedown', 'onmouseup', 'onclick', 'onmouseenter', 'onmouseleave',
    'onwheel', 'onfocus', 'onblur', 'onmousemove', 'oninput', 'onenter',
    '', '', '');

function XuiEventAttrKind(const AName: string; out AKind: TXuiEventKind): Boolean;
function XuiEventAttrOf(AKind: TXuiEventKind): string;

// 构造滚轮事件载荷（R3：携带修饰键，供 Shift+滚轮横向滚动与脚本侧读取）
function XuiWheelEvent(AX, AY, ADelta: Integer; AShift: TXuiShiftState): TXuiEvent;

// 解析宿主 published 方法（AOwner = nil 或方法不存在时返回 False）
function XuiResolveMethod(AOwner: TObject; const AName: string;
  out AHandler: TMethod): Boolean;

// 命中测试：返回最深的可见命中节点（无命中返回 nil）
function XuiHitTest(ARoot: TXuiNode; AX, AY: Integer): TXuiNode;

function XuiIsDisabled(ANode: TXuiNode): Boolean;
// 最近公共祖先（click 归属；任一为 nil 返回 nil）
function XuiCommonAncestor(A, B: TXuiNode): TXuiNode;
// 子节点绘制序（与引擎一致）：普通流按文档序，随后定位元素按 z-index 升序
procedure XuiCollectDrawOrder(AParent: TXuiNode; AList: TList);

type
  TXuiPointerState = class
  private
    FRoot: TXuiNode;
    FHoverChain: TList;  // 弱引用：root → 最深命中
    FEntered: TList;     // 最近一次 MouseMove 新进入 hover 链的节点
    FLeft: TList;        // 最近一次 MouseMove/Leave 离开 hover 链的节点
    FActive: TXuiNode;
    FDown: TXuiNode;
    function ChainHas(ANode: TXuiNode): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // 文档重建后调用：清除全部 hover/active 状态
    procedure Reset;
    procedure SetRoot(ARoot: TXuiNode);
    // 以下均返回"伪类集是否变化"
    function MouseMove(AX, AY: Integer): Boolean;
    function MouseDown(AX, AY: Integer; out AHitNode: TXuiNode): Boolean;
    function MouseUp(AX, AY: Integer; out AHitNode, AClickNode: TXuiNode): Boolean;
    function Leave: Boolean;
    function Hover: TXuiNode;
    property Root: TXuiNode read FRoot;
    // 最近一次 MouseMove 的 enter / leave 差集（弱引用，勿保存）
    property Entered: TList read FEntered;
    property LeftNodes: TList read FLeft;
  end;

implementation

function XuiEventAttrKind(const AName: string; out AKind: TXuiEventKind): Boolean;
var
  k: TXuiEventKind;
  s: string;
begin
  s := LowerCase(Trim(AName));
  Result := False;
  if s = '' then
    Exit;
  for k := Low(TXuiEventKind) to High(TXuiEventKind) do
    if (TXuiEventAttrs[k] <> '') and (s = TXuiEventAttrs[k]) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function XuiEventAttrOf(AKind: TXuiEventKind): string;
begin
  Result := TXuiEventAttrs[AKind];
end;

// 构造滚轮事件载荷（R3）
function XuiWheelEvent(AX, AY, ADelta: Integer; AShift: TXuiShiftState): TXuiEvent;
begin
  Result := Default(TXuiEvent);
  Result.Kind := xevWheel;
  Result.X := AX;
  Result.Y := AY;
  Result.Delta := ADelta;
  Result.Shift := AShift;
end;

function XuiResolveMethod(AOwner: TObject; const AName: string;
  out AHandler: TMethod): Boolean;
begin
  AHandler.Code := nil;
  AHandler.Data := nil;
  Result := False;
  if (AOwner = nil) or (Trim(AName) = '') then
    Exit;
  AHandler.Code := AOwner.MethodAddress(AName);
  if AHandler.Code <> nil then
  begin
    AHandler.Data := AOwner;
    Result := True;
  end;
end;

function XuiIsDisabled(ANode: TXuiNode): Boolean;
begin
  Result := (ANode <> nil) and (xpDisabled in ANode.Pseudos);
end;

// 子节点绘制序（与引擎一致）：普通流按文档序，随后定位元素按 z-index 升序
procedure XuiCollectDrawOrder(AParent: TXuiNode; AList: TList);
var
  i, j, n, z: Integer;
  node: TXuiNode;
  zs: array of Integer;
  nodes: array of TXuiNode;
begin
  for i := 0 to AParent.Count - 1 do
    if (AParent[i].Style <> nil) and (AParent[i].Style.Position = xposStatic) then
      AList.Add(AParent[i]);

  n := 0;
  SetLength(nodes, AParent.Count);
  SetLength(zs, AParent.Count);
  for i := 0 to AParent.Count - 1 do
    if (AParent[i].Style <> nil) and (AParent[i].Style.Position <> xposStatic) then
    begin
      nodes[n] := AParent[i];
      zs[n] := AParent[i].Style.ZIndex;
      Inc(n);
    end;
  for i := 1 to n - 1 do
  begin
    node := nodes[i];
    z := zs[i];
    j := i - 1;
    while (j >= 0) and (zs[j] > z) do
    begin
      nodes[j + 1] := nodes[j];
      zs[j + 1] := zs[j];
      Dec(j);
    end;
    nodes[j + 1] := node;
    zs[j + 1] := z;
  end;
  for i := 0 to n - 1 do
    AList.Add(nodes[i]);
end;

function HitTestNode(ANode: TXuiNode; AX, AY: Integer; const AClip: TRect): TXuiNode;
var
  order: TList;
  i: Integer;
  child: TXuiNode;
  clip: TRect;
  found: TXuiNode;
begin
  Result := nil;
  if (ANode.Style = nil) or (ANode.Style.Display = xdispNone) then
    Exit;

  // 子节点的裁剪区：滚动容器收紧到 padding box，并扣除已显示的滚动条条带
  if XuiIsScrollContainer(ANode.Style) then
    clip := XuiScrollContentClip(ANode, AClip)
  else
    clip := AClip;

  // 逆绘制序：后绘制者在上，先测
  order := TList.Create;
  try
    XuiCollectDrawOrder(ANode, order);
    for i := order.Count - 1 downto 0 do
    begin
      child := TXuiNode(order[i]);
      found := HitTestNode(child, AX, AY, clip);
      if found <> nil then
        Exit(found);
    end;
  finally
    order.Free;
  end;

  if (AX >= ANode.BoxRect.Left) and (AX < ANode.BoxRect.Right) and
     (AY >= ANode.BoxRect.Top) and (AY < ANode.BoxRect.Bottom) and
     (AX >= AClip.Left) and (AX < AClip.Right) and
     (AY >= AClip.Top) and (AY < AClip.Bottom) then
    Result := ANode;
end;

function XuiHitTest(ARoot: TXuiNode; AX, AY: Integer): TXuiNode;
begin
  if ARoot = nil then
    Exit(nil);
  Result := HitTestNode(ARoot, AX, AY,
    Types.Rect(-MaxInt div 2, -MaxInt div 2, MaxInt div 2, MaxInt div 2));
end;

// B 是否在 ANode 的祖先链上（含自身）
function IsAncestorOrSelf(ACandidate, ANode: TXuiNode): Boolean;
var
  node: TXuiNode;
begin
  node := ANode;
  while node <> nil do
  begin
    if node = ACandidate then
      Exit(True);
    node := node.Parent;
  end;
  Result := False;
end;

function XuiCommonAncestor(A, B: TXuiNode): TXuiNode;
var
  node: TXuiNode;
begin
  Result := nil;
  if (A = nil) or (B = nil) then
    Exit;
  node := A;
  while node <> nil do
  begin
    if IsAncestorOrSelf(node, B) then
      Exit(node);
    node := node.Parent;
  end;
end;

{ TXuiPointerState }

constructor TXuiPointerState.Create;
begin
  inherited Create;
  FHoverChain := TList.Create;
  FEntered := TList.Create;
  FLeft := TList.Create;
end;

destructor TXuiPointerState.Destroy;
begin
  FLeft.Free;
  FEntered.Free;
  FHoverChain.Free;
  inherited Destroy;
end;

function TXuiPointerState.ChainHas(ANode: TXuiNode): Boolean;
begin
  Result := FHoverChain.IndexOf(ANode) >= 0;
end;

procedure TXuiPointerState.Reset;
var
  i: Integer;
begin
  FEntered.Clear;
  FLeft.Clear;
  for i := 0 to FHoverChain.Count - 1 do
    TXuiNode(FHoverChain[i]).Pseudos := TXuiNode(FHoverChain[i]).Pseudos - [xpHover];
  FHoverChain.Clear;
  if FActive <> nil then
  begin
    FActive.Pseudos := FActive.Pseudos - [xpActive];
    FActive := nil;
  end;
  FDown := nil;
end;

procedure TXuiPointerState.SetRoot(ARoot: TXuiNode);
begin
  Reset;
  FRoot := ARoot;
end;

function TXuiPointerState.Hover: TXuiNode;
begin
  if FHoverChain.Count > 0 then
    Result := TXuiNode(FHoverChain[FHoverChain.Count - 1])
  else
    Result := nil;
end;

function TXuiPointerState.MouseMove(AX, AY: Integer): Boolean;
var
  hit, node: TXuiNode;
  newChain: TList;
  i: Integer;
  changed: Boolean;
begin
  hit := XuiHitTest(FRoot, AX, AY);
  changed := False;
  FEntered.Clear;
  FLeft.Clear;

  newChain := TList.Create;
  try
    node := hit;
    while node <> nil do
    begin
      newChain.Add(node);
      node := node.Parent;
    end;

    // 旧链中已不在新链上的 → 去 hover + 记 leave
    for i := 0 to FHoverChain.Count - 1 do
    begin
      node := TXuiNode(FHoverChain[i]);
      if newChain.IndexOf(node) < 0 then
      begin
        node.Pseudos := node.Pseudos - [xpHover];
        FLeft.Add(node);
        changed := True;
      end;
    end;
    // 新链上原来没有的 → 加 hover + 记 enter
    for i := 0 to newChain.Count - 1 do
    begin
      node := TXuiNode(newChain[i]);
      if FHoverChain.IndexOf(node) < 0 then
      begin
        node.Pseudos := node.Pseudos + [xpHover];
        FEntered.Add(node);
        changed := True;
      end;
    end;

    FHoverChain.Clear;
    for i := 0 to newChain.Count - 1 do
      FHoverChain.Add(newChain[i]);
  finally
    newChain.Free;
  end;

  Result := changed;
end;

function TXuiPointerState.MouseDown(AX, AY: Integer;
  out AHitNode: TXuiNode): Boolean;
begin
  AHitNode := XuiHitTest(FRoot, AX, AY);
  Result := False;
  if FActive <> nil then
  begin
    FActive.Pseudos := FActive.Pseudos - [xpActive];
    FActive := nil;
    Result := True;
  end;
  FDown := AHitNode;
  if AHitNode <> nil then
  begin
    AHitNode.Pseudos := AHitNode.Pseudos + [xpActive];
    FActive := AHitNode;
    Result := True;
  end;
end;

function TXuiPointerState.MouseUp(AX, AY: Integer;
  out AHitNode, AClickNode: TXuiNode): Boolean;
begin
  AHitNode := XuiHitTest(FRoot, AX, AY);
  Result := False;
  if FActive <> nil then
  begin
    FActive.Pseudos := FActive.Pseudos - [xpActive];
    FActive := nil;
    Result := True;
  end;
  AClickNode := XuiCommonAncestor(FDown, AHitNode);
  FDown := nil;
end;

function TXuiPointerState.Leave: Boolean;
var
  i: Integer;
begin
  Result := FHoverChain.Count > 0;
  FEntered.Clear;
  FLeft.Clear;
  for i := 0 to FHoverChain.Count - 1 do
  begin
    TXuiNode(FHoverChain[i]).Pseudos := TXuiNode(FHoverChain[i]).Pseudos - [xpHover];
    FLeft.Add(FHoverChain[i]);
  end;
  FHoverChain.Clear;
  if FActive <> nil then
  begin
    FActive.Pseudos := FActive.Pseudos - [xpActive];
    FActive := nil;
    Result := True;
  end;
end;

end.
