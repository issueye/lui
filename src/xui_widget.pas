unit xui_widget;

{$mode objfpc}{$H+}

{ 元素行为与工厂。
  设计：绘制由引擎按计算样式统一完成；行为类只负责解释业务属性与承载交互（M4 扩展）。
  XML 未知标签回退为 panel 容器并继续渲染。 }

interface

uses
  Classes, SysUtils, Contnrs,
  xui_dom;

type
  TXuiBehavior = class
  protected
    FNode: TXuiNode;
  public
    destructor Destroy; override;
    procedure Attach(ANode: TXuiNode); virtual;
    // XML 属性逐个通知（text/id/class 之外的业务属性）
    procedure HandleAttribute(const AName, AValue: string); virtual;
    property Node: TXuiNode read FNode;
  end;

  // label：文本来自 text 属性（优先）或文本子节点
  TXuiLabelBehavior = class(TXuiBehavior)
  public
    procedure HandleAttribute(const AName, AValue: string); override;
  end;

  // button：M4 补充点击；M1 仅作为文本承载
  TXuiButtonBehavior = class(TXuiLabelBehavior)
  end;

  TXuiBehaviorClass = class of TXuiBehavior;

// 注册/创建；返回的 Behavior 已 Attach(ANode)，由节点通过 Behavior 字段弱引用持有
procedure RegisterBehavior(const ATag: string; AClass: TXuiBehaviorClass);
function CreateBehavior(const ATag: string; ANode: TXuiNode): TXuiBehavior;

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

{ TXuiLabelBehavior }

procedure TXuiLabelBehavior.HandleAttribute(const AName, AValue: string);
begin
  inherited HandleAttribute(AName, AValue);
  if CompareText(AName, 'text') = 0 then
    FNode.Text := AValue;
end;

procedure RegisterBehavior(const ATag: string; AClass: TXuiBehaviorClass);
begin
  Tags.Add(LowerCase(ATag));
  BehaviorClasses.Add(TObject(Pointer(AClass)));
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
