unit xui_dom;

{$mode objfpc}{$H+}

{ lui 文档模型：元素节点树。
  M1 阶段节点同时承担"结构 + 样式 + 布局结果"，后续按设计文档拆分行为类。 }

interface

uses
  Classes, SysUtils, Contnrs, Types,
  xui_types, xui_style;

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
    Behavior: TObject;        // 元素行为（xui_widget，节点拥有；行为内 FNode 为弱引用）
    constructor Create(const ATag: string);
    destructor Destroy; override;
    procedure AddChild(AChild: TXuiNode);
    property Count: Integer read GetCount;
    property Child[AIndex: Integer]: TXuiNode read GetChild; default;
    function HasClass(const AName: string): Boolean;
    function AttributeValue(const AName: string; const ADefault: string = ''): string;
    function HasAttribute(const AName: string): Boolean;
    function FindById(const AId: string): TXuiNode; // 深度优先查找
    function Root: TXuiNode;
    // 内容盒（border-box 减去 border 与 padding），须在布局后读取
    function ContentRect: TRect;
    function PaddingRect: TRect;
  end;

  TXuiDocument = class
  private
    FRoot: TXuiNode;
    FTitle: string;
  public
    destructor Destroy; override;
    property Root: TXuiNode read FRoot write FRoot;
    property Title: string read FTitle write FTitle; // 来自 window/@title
    function FindElementById(const AId: string): TXuiNode;
  end;

implementation

{ TXuiNode }

constructor TXuiNode.Create(const ATag: string);
begin
  inherited Create;
  Tag := LowerCase(ATag);
  FChildren := TObjectList.Create(True);
  Attributes := TStringList.Create;
  ClassList := TStringList.Create;
  Pseudos := [];
  Style := nil; // 由样式阶段填充
end;

destructor TXuiNode.Destroy;
begin
  Behavior.Free; // 节点拥有行为对象，行为持有节点为弱引用
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

function TXuiNode.PaddingRect: TRect;
begin
  Result := BoxRect;
  Result.Left := Result.Left + Round(Style.BorderWidth);
  Result.Top := Result.Top + Round(Style.BorderWidth);
  Result.Right := Result.Right - Round(Style.BorderWidth);
  Result.Bottom := Result.Bottom - Round(Style.BorderWidth);
  Result.Left := Result.Left + Round(Style.Padding.Left.Resolve(0));
  Result.Top := Result.Top + Round(Style.Padding.Top.Resolve(0));
  Result.Right := Result.Right - Round(Style.Padding.Right.Resolve(0));
  Result.Bottom := Result.Bottom - Round(Style.Padding.Bottom.Resolve(0));
end;

function TXuiNode.ContentRect: TRect;
var
  r: TRect;
begin
  r := PaddingRect;
  // M1 无独立内容偏移，padding box 即内容盒
  Result := r;
end;

{ TXuiDocument }

destructor TXuiDocument.Destroy;
begin
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
