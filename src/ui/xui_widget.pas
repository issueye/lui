unit xui_widget;

{$mode objfpc}{$H+}

{ 元素行为与工厂。
  设计：绘制由引擎按计算样式统一完成；行为类只负责解释业务属性与承载交互（M4 扩展）。
  XML 未知标签回退为 panel 容器并继续渲染。 }

interface

uses
  Classes, SysUtils, Contnrs, Types, StrUtils,
  xui_types, xui_style, xui_dom, xui_events, xui_render, xui_text, xui_svg;

type
  TXuiBehavior = class
  protected
    FNode: TXuiNode;
  public
    destructor Destroy; override;
    procedure Attach(ANode: TXuiNode); virtual;
    // XML 属性逐个通知（text/id/class 之外的业务属性）
    procedure HandleAttribute(const AName, AValue: string); virtual;
    // M8：运行时属性设置（声明式绑定用，如 :placeholder / :password）。
    // 返回 True 表示已处理；默认不处理（行为只在装配期读属性）。
    function SetRuntimeAttr(const AName, AValue: string): Boolean; virtual;
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
    // 是否抑制引擎对子节点的默认流式渲染（如 SVG 等复合自绘图元）
    function SuppressChildrenRendering: Boolean; virtual;
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

  // svg：矢量图形显示；支持 src 属性加载外部 SVG 文件或内联 SVG 图元。
  // 子树属性运行时更新（绑定 :d/:fill 等）后经 MarkDirty 触发重解析（图标库动态换图）。
  TXuiSvgBehavior = class(TXuiBehavior)
  private
    FDoc: TXuiSvgDoc;
    FSrc: string;
    FDirty: Boolean;
    procedure EnsureDoc;
  public
    destructor Destroy; override;
    procedure HandleAttribute(const AName, AValue: string); override;
    function SetRuntimeAttr(const AName, AValue: string): Boolean; override;
    function RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
      AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean; override;
    function SuppressChildrenRendering: Boolean; override;
    // 子树内容变化（绑定引擎写属性/文本）后调用：下次渲染重新解析
    procedure MarkDirty;
    property Doc: TXuiSvgDoc read FDoc;
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

function TXuiBehavior.SetRuntimeAttr(const AName, AValue: string): Boolean;
begin
  Result := False;
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

function TXuiBehavior.SuppressChildrenRendering: Boolean;
begin
  Result := False;
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

{ TXuiSvgBehavior }

destructor TXuiSvgBehavior.Destroy;
begin
  if FDoc <> nil then FDoc.Free;
  inherited Destroy;
end;

procedure TXuiSvgBehavior.EnsureDoc;
begin
  if FDoc = nil then
    FDoc := TXuiSvgDoc.Create;
end;

procedure TXuiSvgBehavior.MarkDirty;
begin
  FDirty := True;
end;

procedure TXuiSvgBehavior.HandleAttribute(const AName, AValue: string);
var
  v: Single;
begin
  inherited HandleAttribute(AName, AValue);
  if SameText(AName, 'src') then
  begin
    FSrc := AValue;
    EnsureDoc;
    if FileExists(AValue) then
      FDoc.LoadFromFile(AValue);
  end
  else if SameText(AName, 'width') then
  begin
    v := SvgParseFloat(AValue, 0);
    if (v > 0) and (FNode <> nil) and (FNode.Style <> nil) and FNode.Style.Width.IsAuto then
      FNode.Style.Width := XuiLengthPx(v);
  end
  else if SameText(AName, 'height') then
  begin
    v := SvgParseFloat(AValue, 0);
    if (v > 0) and (FNode <> nil) and (FNode.Style <> nil) and FNode.Style.Height.IsAuto then
      FNode.Style.Height := XuiLengthPx(v);
  end;
end;

function TXuiSvgBehavior.SetRuntimeAttr(const AName, AValue: string): Boolean;
var
  v: Single;
begin
  if SameText(AName, 'src') then
  begin
    FSrc := AValue;
    EnsureDoc;
    if FileExists(AValue) then
      FDoc.LoadFromFile(AValue)
    else
      FDoc.Clear;
    Result := True;
  end
  else if SameText(AName, 'width') then
  begin
    v := SvgParseFloat(AValue, 0);
    if (v > 0) and (FNode <> nil) and (FNode.Style <> nil) and FNode.Style.Width.IsAuto then
      FNode.Style.Width := XuiLengthPx(v);
    Result := True;
  end
  else if SameText(AName, 'height') then
  begin
    v := SvgParseFloat(AValue, 0);
    if (v > 0) and (FNode <> nil) and (FNode.Style <> nil) and FNode.Style.Height.IsAuto then
      FNode.Style.Height := XuiLengthPx(v);
    Result := True;
  end
  else
    Result := inherited SetRuntimeAttr(AName, AValue);
end;

function TXuiSvgBehavior.SuppressChildrenRendering: Boolean;
begin
  Result := True;
end;

function TXuiSvgBehavior.RenderContent(ANode: TXuiNode; ARenderer: TXuiCustomRenderer;
  AMeasure: TXuiMeasureFunc; ACaretVisible: Boolean): Boolean;
var
  innerXml: string;
  textColor: TXuiColor;
  r: TRect;
begin
  EnsureDoc;

  // 1. 脏（子树属性被绑定更新）或尚未解析且有子节点：按内存 XuiNode 结构加载
  if FDirty or ((FDoc.Shapes.Count = 0) and (ANode.Count > 0)) then
  begin
    FDoc.Clear;
    FDoc.LoadFromXuiNode(ANode);
    FDirty := False;
  end;

  // 2. 若尚未解析图形且有文本内容
  if (FDoc.Shapes.Count = 0) and (ANode.Text <> '') then
  begin
    innerXml := Trim(ANode.Text);
    if StartsText('<', innerXml) then
      FDoc.LoadFromString(innerXml)
    else if FileExists(innerXml) then
      FDoc.LoadFromFile(innerXml);
  end;

  // 3. 发起渲染
  if FDoc.Shapes.Count > 0 then
  begin
    textColor := XuiRGB(0, 0, 0);
    if ANode.Style <> nil then
      textColor := ANode.Style.TextColor;
    r := ANode.ContentBox;
    if (r.Right <= r.Left) or (r.Bottom <= r.Top) then
    begin
      // 容错：若父级容器未计算盒模型尺寸，依 SVG 声明的真实尺寸或 viewBox 绘制
      if (FDoc.Width > 0) and (FDoc.Height > 0) then
        r := Rect(r.Left, r.Top, r.Left + Round(FDoc.Width), r.Top + Round(FDoc.Height))
      else if FDoc.HasViewBox then
        r := Rect(r.Left, r.Top, r.Left + Round(FDoc.ViewBox.Right - FDoc.ViewBox.Left),
                                r.Top + Round(FDoc.ViewBox.Bottom - FDoc.ViewBox.Top))
      else
        r := Rect(r.Left, r.Top, r.Left + 16, r.Top + 16);
    end;
    FDoc.Render(ARenderer, r, textColor);
    Result := True;
  end
  else
    Result := False;
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
  RegisterBehavior('svg', TXuiSvgBehavior);

finalization
  BehaviorClasses.Free;
  Tags.Free;

end.
