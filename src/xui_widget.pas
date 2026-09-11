unit xui_widget;

{$mode objfpc}{$H+}

{ 元素行为与工厂。
  设计：绘制由引擎按计算样式统一完成；行为类只负责解释业务属性与承载交互（M4 扩展）。
  XML 未知标签回退为 panel 容器并继续渲染。 }

interface

uses
  Classes, SysUtils, Contnrs, Types,
  xui_types, xui_style, xui_dom, xui_events, xui_render, xui_text;

type
  TXuiBehavior = class
  protected
    FNode: TXuiNode;
  public
    destructor Destroy; override;
    procedure Attach(ANode: TXuiNode); virtual;
    // XML 属性逐个通知（text/id/class 之外的业务属性）
    procedure HandleAttribute(const AName, AValue: string); virtual;
    // 能否通过点击/键盘(Tab)获得焦点（:focus）
    function CanFocus: Boolean; virtual;
    // 事件钩子：返回 True 表示已处理（阻止继续向祖先冒泡）
    function HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean; virtual;
    // 自绘内容（返回 True 表示已接管该节点的文本绘制；引擎跳过默认 RenderText）
    function RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
      AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean; virtual;
    // 鼠标按下后是否请求指针捕捉（拖选等：移动/抬起事件优先派发给本节点）
    function NeedsPointerCapture: Boolean; virtual;
    // 是否需要光标闪烁的周期刷新（输入类节点）
    function WantsCaret: Boolean; virtual;
    // 光标矩形（客户区坐标；IME 候选窗定位/宿主查询用）
    function CaretRect(ANode: TXuiNode; out ARect: TRect): Boolean; virtual;
    // 焦点在本节点时，Enter 是否等价点击
    function ActivatesOnEnter: Boolean; virtual;
    // 切换 disabled 状态（默认落到伪类，样式引擎据此匹配 :disabled）
    procedure SetDisabled(AValue: Boolean); virtual;
    property Node: TXuiNode read FNode;
  end;

  // label：文本来自 text 属性（优先）或文本子节点
  TXuiLabelBehavior = class(TXuiBehavior)
  public
    procedure HandleAttribute(const AName, AValue: string); override;
  end;

  // button：可聚焦、可禁用、Enter 激活；点击行为由事件绑定（onclick）承载
  TXuiButtonBehavior = class(TXuiLabelBehavior)
  public
    procedure HandleAttribute(const AName, AValue: string); override;
    function CanFocus: Boolean; override;
    function ActivatesOnEnter: Boolean; override;
  end;

  TXuiBehaviorClass = class of TXuiBehavior;

// 注册/创建；返回的 Behavior 已 Attach(ANode)，由节点通过 Behavior 字段弱引用持有
procedure RegisterBehavior(const ATag: string; AClass: TXuiBehaviorClass);
function CreateBehavior(const ATag: string; ANode: TXuiNode): TXuiBehavior;

// "disabled" 属性值的真值判断（''/true/1/yes 为真，false/0/no 为假）
function XuiAttributeIsTrue(const AValue: string): Boolean;

// 按文档序收集可聚焦节点（Tab 序遍历用；跳过 disabled / display:none / visibility:hidden）
procedure XuiCollectFocusables(ARoot: TXuiNode; AList: TList);

implementation

var
  // 平行数组：tag 名 → 行为类指针
  Tags: TStringList;
  BehaviorClasses: TObjectList; // 存 TXuiBehaviorClass 类指针（不拥有对象）

{ TXuiBehavior }

destructor TXuiBehavior.Destroy;
begin
  // FNode 为弱引用，不释放
  inherited Destroy;
end;

procedure TXuiBehavior.Attach(ANode: TXuiNode);
begin
  FNode := ANode;
end;

procedure TXuiBehavior.HandleAttribute(const AName, AValue: string);
begin
  // 默认忽略
end;

function TXuiBehavior.CanFocus: Boolean;
begin
  Result := False;
end;

function TXuiBehavior.HandleEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
begin
  Result := False;
end;

function TXuiBehavior.RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
  AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean;
begin
  Result := False; // 默认：交给引擎按 TextLines 绘制
end;

function TXuiBehavior.NeedsPointerCapture: Boolean;
begin
  Result := False;
end;

function TXuiBehavior.WantsCaret: Boolean;
begin
  Result := False;
end;

function TXuiBehavior.CaretRect(ANode: TXuiNode; out ARect: TRect): Boolean;
begin
  ARect := Types.Rect(0, 0, 0, 0);
  Result := False;
end;

function TXuiBehavior.ActivatesOnEnter: Boolean;
begin
  Result := False;
end;

procedure TXuiBehavior.SetDisabled(AValue: Boolean);
begin
  if FNode = nil then
    Exit;
  if AValue then
    FNode.Pseudos := FNode.Pseudos + [xpDisabled]
  else
    FNode.Pseudos := FNode.Pseudos - [xpDisabled];
end;

{ TXuiLabelBehavior }

procedure TXuiLabelBehavior.HandleAttribute(const AName, AValue: string);
begin
  inherited HandleAttribute(AName, AValue);
  if CompareText(AName, 'text') = 0 then
    FNode.Text := AValue;
end;

{ TXuiButtonBehavior }

procedure TXuiButtonBehavior.HandleAttribute(const AName, AValue: string);
begin
  inherited HandleAttribute(AName, AValue);
  if CompareText(AName, 'disabled') = 0 then
    SetDisabled(XuiAttributeIsTrue(AValue));
end;

function TXuiButtonBehavior.CanFocus: Boolean;
begin
  Result := True;
end;

function TXuiButtonBehavior.ActivatesOnEnter: Boolean;
begin
  Result := True;
end;

function XuiAttributeIsTrue(const AValue: string): Boolean;
var
  v: string;
begin
  v := LowerCase(Trim(AValue));
  Result := (v = '') or (v = 'true') or (v = '1') or (v = 'yes') or (v = 'on');
end;

procedure CollectFocusables(ANode: TXuiNode; AList: TList);
var
  i: Integer;
begin
  if ANode.Style <> nil then
  begin
    if (ANode.Style.Display = xdispNone) or (ANode.Style.Visibility <> xvisVisible) then
      Exit;
    if XuiIsDisabled(ANode) then
      Exit;
  end;
  if (ANode.Behavior is TXuiBehavior) and TXuiBehavior(ANode.Behavior).CanFocus then
    AList.Add(ANode);
  for i := 0 to ANode.Count - 1 do
    CollectFocusables(ANode[i], AList);
end;

procedure XuiCollectFocusables(ARoot: TXuiNode; AList: TList);
begin
  if ARoot <> nil then
    CollectFocusables(ARoot, AList);
end;

procedure RegisterBehavior(const ATag: string; AClass: TXuiBehaviorClass);
var
  idx: Integer;
begin
  // Tags 是排序表：Add 返回实际插入位置，行为类必须插到同一位置，否则两表错位
  idx := Tags.Add(LowerCase(ATag));
  BehaviorClasses.Insert(idx, TObject(Pointer(AClass)));
end;

function CreateBehavior(const ATag: string; ANode: TXuiNode): TXuiBehavior;
var
  idx: Integer;
  cls: TXuiBehaviorClass;
begin
  Result := nil;
  idx := Tags.IndexOf(LowerCase(ATag));
  if idx < 0 then
    Exit;
  cls := TXuiBehaviorClass(Pointer(BehaviorClasses[idx]));
  if cls = nil then
    Exit;
  Result := cls.Create;
  Result.Attach(ANode);
  ANode.Behavior := Result;
end;

initialization
  Tags := TStringList.Create;
  Tags.Sorted := True;
  BehaviorClasses := TObjectList.Create(False);
  RegisterBehavior('label', TXuiLabelBehavior);
  RegisterBehavior('button', TXuiButtonBehavior);

finalization
  BehaviorClasses.Free;
  Tags.Free;

end.
