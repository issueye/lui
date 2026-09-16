unit xui_dom;

{$mode objfpc}{$H+}

{ lui 文档模型：元素节点树。
  M1 阶段节点同时承担"结构 + 样式 + 布局结果"，后续按设计文档拆分行为类。 }

interface

uses
  Classes, SysUtils, Contnrs, Types,
  xui_types, xui_style, xui_text;

type
  TXuiNode = class
  private
    FChildren: TObjectList;   // 拥有子节点
    function GetCount: Integer; inline;
    function GetChild(AIndex: Integer): TXuiNode; inline;
  public
    Tag: string;              // 元素类型（小写）
    Id: string;
    Text: string;             // 业务文本（text 属性或文本子节点）
    Attributes: TStringList;  // 原始属性 name=value
    ClassList: TStringList;   // class 拆分后的类名
    Parent: TXuiNode;
    Style: TXuiStyle;         // 计算样式
    Pseudos: TXuiPseudoSet;   // 伪类状态（:hover 等，M4 由交互状态机填充）
    BoxRect: TRect;           // 布局结果：border-box（绝对坐标）
    TextLines: TXuiLineArray; // 布局期断行结果（绘制期直接使用，避免重复测量）
    ContentHeight: Single;    // 布局期记录的自然内容高（滚动范围用）
    ContentWidth: Single;     // 布局期记录的自然内容宽（R3 横向滚动范围用）
    ScrollTop: Single;        // 纵向滚动偏移（overflow 容器）
    ScrollLeft: Single;       // 横向滚动偏移（R3）
    SelfScrolls: Boolean;     // R1：自绘内容的滚动范围由行为上报（多行输入置位；布局不再清零）
    Bindings: TObjectList;    // TXuiEventBinding 列表（xui_events，节点拥有）
    Behavior: TObject;        // 元素行为（xui_widget，节点拥有；行为内 FNode 为弱引用）
    InlineStyleCache: TObject; // 内联 style 解析缓存（xui_css_match 维护，按原文失效）
    constructor Create(const ATag: string);
    destructor Destroy; override;
    procedure AddChild(AChild: TXuiNode);
    procedure InsertChild(AIndex: Integer; AChild: TXuiNode); // 原位插入（x-if 恢复用）
    procedure RemoveChild(AChild: TXuiNode); // 仅解除父子关系，不释放
    function IndexOfChild(AChild: TXuiNode): Integer;
    property Count: Integer read GetCount;
    property Child[AIndex: Integer]: TXuiNode read GetChild; default;
    function HasClass(const AName: string): Boolean;
    function AttributeValue(const AName: string; const ADefault: string = ''): string;
    function HasAttribute(const AName: string): Boolean;
    function FindById(const AId: string): TXuiNode; // 深度优先查找
    function Root: TXuiNode;
    // 盒模型各层矩形（须在布局后读取）
    function PaddingBox: TRect;  // border 之内（绝对定位包含块 / 裁剪区）
    function ContentBox: TRect;  // border + padding 之内
  end;

  TXuiDocument = class
  private
    FRoot: TXuiNode;
    FTitle: string;
    FSourceFile: string;      // XML 源文件（热重载用；来自字符串时为空）
    FDependencies: TStringList; // 依赖文件（include 展开的全部来源；热重载监测）
    FScripts: TStringList;    // <script src> 收集（按 XML 出现顺序；M6 脚本引擎）
  public
    constructor Create;
    destructor Destroy; override;
    property Root: TXuiNode read FRoot write FRoot;
    property Title: string read FTitle write FTitle; // 来自 window/@title
    property SourceFile: string read FSourceFile write FSourceFile;
    property Dependencies: TStringList read FDependencies;
    property Scripts: TStringList read FScripts;
    function FindElementById(const AId: string): TXuiNode;
  end;

implementation

{ TXuiNode }

constructor TXuiNode.Create(const ATag: string);
begin
  inherited Create;
  Tag := LowerCase(ATag);
  FChildren := TObjectList.Create(True);
  Bindings := TObjectList.Create(True);
  Attributes := TStringList.Create;
  ClassList := TStringList.Create;
  Pseudos := [];
  ScrollTop := 0;
  ScrollLeft := 0;
  ContentHeight := 0;
  ContentWidth := 0;
  SelfScrolls := False;
  Style := nil; // 由样式阶段填充
end;

destructor TXuiNode.Destroy;
begin
  Behavior.Free; // 节点拥有行为对象，行为持有节点为弱引用
  InlineStyleCache.Free;
  Bindings.Free;
  Style.Free;
  ClassList.Free;
  Attributes.Free;
  FChildren.Free;
  inherited Destroy;
end;

procedure TXuiNode.AddChild(AChild: TXuiNode);
begin
  AChild.Parent := Self;
  FChildren.Add(AChild);
end;

procedure TXuiNode.InsertChild(AIndex: Integer; AChild: TXuiNode);
begin
  AChild.Parent := Self;
  FChildren.Insert(AIndex, AChild);
end;

procedure TXuiNode.RemoveChild(AChild: TXuiNode);
var
  idx: Integer;
begin
  idx := FChildren.IndexOf(AChild);
  if idx >= 0 then
  begin
    FChildren.Extract(AChild);
    AChild.Parent := nil;
  end;
end;

function TXuiNode.IndexOfChild(AChild: TXuiNode): Integer;
begin
  Result := FChildren.IndexOf(AChild);
end;

function TXuiNode.GetCount: Integer;
begin
  Result := FChildren.Count;
end;

function TXuiNode.GetChild(AIndex: Integer): TXuiNode;
begin
  Result := TXuiNode(FChildren[AIndex]);
end;

function TXuiNode.HasClass(const AName: string): Boolean;
begin
  Result := (ClassList.IndexOf(AName) >= 0);
end;

function TXuiNode.AttributeValue(const AName: string; const ADefault: string): string;
begin
  Result := ADefault;
  if Attributes.IndexOfName(AName) >= 0 then
    Result := Attributes.Values[AName];
end;

function TXuiNode.HasAttribute(const AName: string): Boolean;
begin
  Result := Attributes.IndexOfName(AName) >= 0;
end;

function TXuiNode.FindById(const AId: string): TXuiNode;
var
  i: Integer;
  found: TXuiNode;
begin
  if (AId <> '') and (Self.Id = AId) then
    Exit(Self);
  for i := 0 to Count - 1 do
  begin
    found := Child[i].FindById(AId);
    if found <> nil then
      Exit(found);
  end;
  Result := nil;
end;

function TXuiNode.Root: TXuiNode;
begin
  Result := Self;
  while Result.Parent <> nil do
    Result := Result.Parent;
end;

function TXuiNode.PaddingBox: TRect;
var
  b: Integer;
begin
  b := Round(Style.BorderWidth);
  Result := Types.Rect(BoxRect.Left + b, BoxRect.Top + b,
    BoxRect.Right - b, BoxRect.Bottom - b);
end;

function TXuiNode.ContentBox: TRect;
var
  r: TRect;
  w: Single;
begin
  r := PaddingBox;
  w := BoxRect.Right - BoxRect.Left;
  Result := Types.Rect(
    r.Left + Round(Style.Padding.Left.Resolve(w)),
    r.Top + Round(Style.Padding.Top.Resolve(w)),
    r.Right - Round(Style.Padding.Right.Resolve(w)),
    r.Bottom - Round(Style.Padding.Bottom.Resolve(w)));
end;

{ TXuiDocument }

constructor TXuiDocument.Create;
begin
  inherited Create;
  FDependencies := TStringList.Create;
  FScripts := TStringList.Create;
end;

destructor TXuiDocument.Destroy;
begin
  FScripts.Free;
  FDependencies.Free;
  FRoot.Free;
  inherited Destroy;
end;

function TXuiDocument.FindElementById(const AId: string): TXuiNode;
begin
  if (AId <> '') and (FRoot <> nil) then
    Result := FRoot.FindById(AId)
  else
    Result := nil;
end;

end.
