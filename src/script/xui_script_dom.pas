unit xui_script_dom;

{$mode objfpc}{$H+}

{ DOM 桥（M6 P0）：把节点与引擎能力暴露为脚本对象。
  分层规则：本单元是 leaf（uses 引擎 + 脚本门面 + 互操作单元），由宿主装配；
  引擎只依赖 xui_script 的抽象与一个事件钩子，不反向依赖本单元。

  暴露面（见 M6 设计文档 §4）：
    document.find(id) / document.add(xml)
    node.id / tag / text / class / disabled / scrollTop / count / parent
    node.find(id) / hasClass(name) / on(type, fn) / off(type, fn)
    node.add(xml) / remove() / clear() / eachChild(fn)
  事件对象（处理器首参）：{ type, node, x, y, delta, key, text, shift:{shift,ctrl,alt} }

  实现要点：
  - 属性读写走 NativeGet/NativeSet 动态路由，写入一律经引擎 API（样式/布局正确失效）
  - 桥对象对 TXuiNode 弱引用（Obj.Tag），DOM 变更前 ResetBridges 作废缓存
  - 方法按需挂到节点对象自身（名字分派），首次访问时创建
  - 事件回调经门面 InvokeSlice 进入（切片预算重置 + 错误路由） }

interface

uses
  Classes, SysUtils, Contnrs, Types,
  xui_types, xui_dom, xui_events, xui_engine, xui_script,
  xui_js_token, xui_js_parser, xui_js_runtime;

type
  // 节点桥：一个 TXuiNode 对应一个脚本对象（按需创建、缓存于桥）
  TXuiNodeBridge = class
  public
    Obj: TXuiJsObject;       // 脚本侧对象
    Node: TXuiNode;          // 被桥接的节点（弱引用）
  end;

  // 动态事件监听（node.on）：脚本侧注册的函数句柄
  TXuiJsListener = class
  public
    Node: TXuiNode;          // 弱引用
    Kind: TXuiEventKind;
    Handler: TXuiJsValue;
  end;

  TXuiDomBridge = class
  private
    FEngine: TXuiEngine;
    FScript: TXuiScript;
    FBridges: TObjectList;   // TXuiNodeBridge（自有）
    FListeners: TObjectList; // TXuiJsListener（自有）
    FDocumentObj: TXuiJsObject;
    function FindBridge(ANode: TXuiNode): TXuiNodeBridge;
    function EnsureBridge(ANode: TXuiNode): TXuiJsObject;
    function FindListener(ANode: TXuiNode; AKind: TXuiEventKind;
      out AIndex: Integer): Boolean;
    // 动态属性
    function NodePropGet(AObj: TXuiJsObject; const AName: string;
      out AValue: TXuiJsValue): Boolean;
    function NodePropSet(AObj: TXuiJsObject; const AName: string;
      const AValue: TXuiJsValue): Boolean;
    // 方法（按名字分派）
    function NodeMethod(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function DocumentMethod(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NodeOf(const AValue: TXuiJsValue): TXuiNode;
    // 事件对象：节点不在 TXuiEvent 载荷里，由分发目标显式传入
    function MakeEventValue(ANode: TXuiNode; const AEvent: TXuiEvent): TXuiJsValue;
    // 引擎事件钩子：动态监听（node.on）
    function HandleEngineEvent(ANode: TXuiNode; const AEvent: TXuiEvent): Boolean;
    // 确保节点对象上存在某方法（惰性创建）
    procedure EnsureNodeMethod(AObj: TXuiJsObject; const AName: string);
  public
    constructor Create(AEngine: TXuiEngine; AScript: TXuiScript);
    destructor Destroy; override;
    // 装配：注册 document / ui.version，并挂上引擎事件钩子
    procedure Install;
    // DOM 变更前调用：作废全部桥与监听（节点可能被释放）
    procedure ResetBridges;
    function NodeValue(ANode: TXuiNode): TXuiJsValue;
    property DocumentObject: TXuiJsObject read FDocumentObj;
  end;

implementation

// 事件方法名 → 事件种类（动态绑定用它把 'click' 这类名字转成枚举）
function KindFromName(const AName: string): TXuiEventKind;
var
  k: TXuiEventKind;
begin
  for k := Low(TXuiEventKind) to High(TXuiEventKind) do
  begin
    if TXuiEventAttrs[k] = '' then
      Continue;
    // 支持 'click' 与 'onclick' 两种写法
    if (TXuiEventAttrs[k] = AName) or (TXuiEventAttrs[k] = 'on' + AName) then
      Exit(k);
  end;
  Result := xevClick;
end;

{ TXuiDomBridge }

constructor TXuiDomBridge.Create(AEngine: TXuiEngine; AScript: TXuiScript);
begin
  inherited Create;
  FEngine := AEngine;
  FScript := AScript;
  FBridges := TObjectList.Create(True);
  FListeners := TObjectList.Create(True);
end;

destructor TXuiDomBridge.Destroy;
begin
  FListeners.Free;
  FBridges.Free;
  inherited Destroy;
end;

procedure TXuiDomBridge.ResetBridges;
begin
  FBridges.Clear;
  FListeners.Clear;
end;

function TXuiDomBridge.FindBridge(ANode: TXuiNode): TXuiNodeBridge;
var
  i: Integer;
begin
  for i := 0 to FBridges.Count - 1 do
    if TXuiNodeBridge(FBridges[i]).Node = ANode then
      Exit(TXuiNodeBridge(FBridges[i]));
  Result := nil;
end;

function TXuiDomBridge.FindListener(ANode: TXuiNode; AKind: TXuiEventKind;
  out AIndex: Integer): Boolean;
var
  i: Integer;
begin
  AIndex := -1;
  for i := 0 to FListeners.Count - 1 do
    if (TXuiJsListener(FListeners[i]).Node = ANode) and
       (TXuiJsListener(FListeners[i]).Kind = AKind) then
    begin
      AIndex := i;
      Exit(True);
    end;
  Result := False;
end;

// 节点 → 脚本对象（带缓存；方法惰性挂到对象自身）
function TXuiDomBridge.EnsureBridge(ANode: TXuiNode): TXuiJsObject;
var
  bridge: TXuiNodeBridge;
  v: TXuiJsValue;
begin
  Result := nil;
  if ANode = nil then
    Exit;
  bridge := FindBridge(ANode);
  if bridge <> nil then
    Exit(bridge.Obj);

  v := FScript.Interp.ObjectValue(FScript.Interp.CreateHostObject('Node'));
  Result := v.Obj;
  Result.Tag := ANode;                    // 弱引用（节点可能先释放）
  Result.NativeGet := @NodePropGet;
  Result.NativeSet := @NodePropSet;

  bridge := TXuiNodeBridge.Create;
  bridge.Obj := Result;
  bridge.Node := ANode;
  FBridges.Add(bridge);
end;

procedure TXuiDomBridge.EnsureNodeMethod(AObj: TXuiJsObject; const AName: string);
begin
  if AObj.GetOwn(AName).Kind = jvObject then
    Exit;
  AObj.SetOwn(AName, FScript.Interp.CreateHostFunction(AName, @NodeMethod));
end;

function TXuiDomBridge.NodeOf(const AValue: TXuiJsValue): TXuiNode;
var
  obj: TXuiJsObject;
  bridge: TXuiNodeBridge;
begin
  Result := nil;
  if (AValue.Kind <> jvObject) or (AValue.Obj = nil) then
    Exit;
  obj := AValue.Obj;
  if (obj.Tag = nil) or not (obj.Tag is TXuiNode) then
    Exit;
  // 校验桥仍有效（节点可能已释放 / 缓存已作废）
  bridge := FindBridge(TXuiNode(obj.Tag));
  if (bridge = nil) or (bridge.Obj <> obj) then
    Exit;
  Result := TXuiNode(obj.Tag);
end;

function TXuiDomBridge.NodeValue(ANode: TXuiNode): TXuiJsValue;
begin
  if ANode = nil then
    Exit(FScript.Undefined);
  Result := FScript.Interp.ObjectValue(EnsureBridge(ANode));
end;

{ 动态属性 }

function TXuiDomBridge.NodePropGet(AObj: TXuiJsObject; const AName: string;
  out AValue: TXuiJsValue): Boolean;
var
  node: TXuiNode;
begin
  AValue := FScript.Undefined;
  Result := False;
  if (AObj.Tag = nil) or not (AObj.Tag is TXuiNode) then
    Exit;
  node := TXuiNode(AObj.Tag);
  if AName = 'id' then
    AValue := FScript.Str(node.Id)
  else if AName = 'tag' then
    AValue := FScript.Str(node.Tag)
  else if AName = 'text' then
    AValue := FScript.Str(node.Text)
  else if AName = 'class' then
    AValue := FScript.Str(StringReplace(Trim(node.ClassList.Text), LineEnding, ' ', [rfReplaceAll]))
  else if AName = 'disabled' then
    AValue := FScript.Bool(XuiIsDisabled(node))
  else if AName = 'scrollTop' then
    AValue := FScript.Num(node.ScrollTop)
  else if AName = 'count' then
    AValue := FScript.Num(node.Count)
  else if AName = 'parent' then
    AValue := NodeValue(node.Parent)
  else
  begin
    // 方法名（find/hasClass/on/off/add/remove/clear/eachChild/at）
    if (AName = 'find') or (AName = 'hasClass') or (AName = 'on') or (AName = 'off') or
       (AName = 'add') or (AName = 'remove') or (AName = 'clear') or
       (AName = 'eachChild') or (AName = 'at') then
    begin
      EnsureNodeMethod(AObj, AName);
      AValue := AObj.GetOwn(AName);
      Exit(True);
    end;
    Exit(False); // 未知属性：交给普通属性查找
  end;
  Result := True;
end;

function TXuiDomBridge.NodePropSet(AObj: TXuiJsObject; const AName: string;
  const AValue: TXuiJsValue): Boolean;
var
  node: TXuiNode;
  s: string;
begin
  Result := False;
  if (AObj.Tag = nil) or not (AObj.Tag is TXuiNode) then
    Exit;
  node := TXuiNode(AObj.Tag);
  if AName = 'text' then
  begin
    FEngine.SetText(node, FScript.ToStringValue(AValue));
    Result := True;
  end
  else if AName = 'class' then
  begin
    FEngine.SetClass(node, FScript.ToStringValue(AValue));
    Result := True;
  end
  else if AName = 'disabled' then
  begin
    FEngine.SetDisabled(node, FScript.ToBoolValue(AValue));
    Result := True;
  end
  else if AName = 'scrollTop' then
  begin
    node.ScrollTop := FScript.ToNumberValue(AValue);
    FEngine.InvalidateLayout;
    Result := True;
  end
  else if AName = 'id' then
  begin
    s := FScript.ToStringValue(AValue);
    node.Id := s;
    node.Attributes.Values['id'] := s;
    Result := True;
  end;
end;

{ 方法分派（按名字） }

function TXuiDomBridge.NodeMethod(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  node: TXuiNode;
  name: string;
  i, idx: Integer;
  listener: TXuiJsListener;
begin
  Result := FScript.Undefined;
  node := NodeOf(AThis);
  if node = nil then
    Exit;
  name := AFn.Name;

  if name = 'find' then
  begin
    if System.Length(AArgs) < 1 then
      Exit;
    Exit(NodeValue(node.FindById(FScript.ToStringValue(AArgs[0]))));
  end;
  if name = 'hasClass' then
  begin
    if System.Length(AArgs) < 1 then
      Exit(FScript.Bool(False));
    Exit(FScript.Bool(node.HasClass(FScript.ToStringValue(AArgs[0]))));
  end;
  if name = 'add' then
  begin
    if System.Length(AArgs) < 1 then
      Exit;
    Exit(NodeValue(FEngine.AddElement(node, FScript.ToStringValue(AArgs[0]))));
  end;
  if name = 'remove' then
  begin
    FEngine.RemoveElement(node);
    Exit;
  end;
  if name = 'clear' then
  begin
    FEngine.ClearChildren(node);
    Exit;
  end;
  if name = 'at' then
  begin
    idx := 0;
    if System.Length(AArgs) >= 1 then
      idx := Round(FScript.ToNumberValue(AArgs[0]));
    if (idx < 0) or (idx >= node.Count) then
      Exit;
    Exit(NodeValue(node[idx]));
  end;
  if name = 'eachChild' then
  begin
    if (System.Length(AArgs) >= 1) and FScript.Interp.IsCallable(AArgs[0]) then
      for i := 0 to node.Count - 1 do
        FScript.InvokeSlice(AArgs[0], [NodeValue(node[i]), FScript.Num(i)]);
    Exit;
  end;
  if (name = 'on') or (name = 'off') then
  begin
    if System.Length(AArgs) < 2 then
      Exit;
    if name = 'on' then
    begin
      // 一个节点同类事件只保留最后一个监听（v1 简化）
      if FindListener(node, KindFromName(FScript.ToStringValue(AArgs[0])), idx) then
        FListeners.Delete(idx);
      listener := TXuiJsListener.Create;
      listener.Node := node;
      listener.Kind := KindFromName(FScript.ToStringValue(AArgs[0]));
      listener.Handler := AArgs[1];
      FScript.AddRoot(AArgs[1]);   // 监听期间保持存活
      FListeners.Add(listener);
    end
    else
    begin
      if FindListener(node, KindFromName(FScript.ToStringValue(AArgs[0])), idx) then
        FListeners.Delete(idx);
    end;
    Exit(FScript.Bool(True));
  end;
end;

function TXuiDomBridge.DocumentMethod(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  name: string;
begin
  Result := FScript.Undefined;
  name := AFn.Name;
  if name = 'find' then
  begin
    if (System.Length(AArgs) < 1) or (FEngine.Document = nil) then
      Exit;
    Exit(NodeValue(FEngine.Document.FindElementById(FScript.ToStringValue(AArgs[0]))));
  end;
  if name = 'add' then
  begin
    if (System.Length(AArgs) < 1) or (FEngine.Document = nil) or
       (FEngine.Document.Root = nil) then
      Exit;
    Exit(NodeValue(FEngine.AddElement(FEngine.Document.Root,
      FScript.ToStringValue(AArgs[0]))));
  end;
  if name = 'body' then
  begin
    if FEngine.Document = nil then
      Exit;
    Exit(NodeValue(FEngine.Document.Root));
  end;
end;

function TXuiDomBridge.MakeEventValue(ANode: TXuiNode;
  const AEvent: TXuiEvent): TXuiJsValue;
var
  obj, shift: TXuiJsObject;
begin
  obj := FScript.Interp.CreateHostObject('Event');
  obj.SetOwn('type', FScript.Str(XuiEventAttrOf(AEvent.Kind)));
  obj.SetOwn('node', NodeValue(ANode));
  obj.SetOwn('x', FScript.Num(AEvent.X));
  obj.SetOwn('y', FScript.Num(AEvent.Y));
  obj.SetOwn('delta', FScript.Num(AEvent.Delta));
  obj.SetOwn('key', FScript.Num(AEvent.Key));
  obj.SetOwn('text', FScript.Str(AEvent.Text));
  shift := FScript.Interp.CreateHostObject('Object');
  shift.SetOwn('shift', FScript.Bool(xssShift in AEvent.Shift));
  shift.SetOwn('ctrl', FScript.Bool(xssCtrl in AEvent.Shift));
  shift.SetOwn('alt', FScript.Bool(xssAlt in AEvent.Shift));
  obj.SetOwn('shift', FScript.Interp.ObjectValue(shift));
  Result := FScript.Interp.ObjectValue(obj);
  FScript.AddRoot(Result);   // 事件对象在脚本执行期间需存活
end;

// 引擎事件钩子：动态监听（node.on 注册的函数）
function TXuiDomBridge.HandleEngineEvent(ANode: TXuiNode;
  const AEvent: TXuiEvent): Boolean;
var
  idx: Integer;
  args: TXuiJsValueArray;
begin
  Result := False;
  if not FindListener(ANode, AEvent.Kind, idx) then
    Exit;
  SetLength(args, 1);
  args[0] := MakeEventValue(ANode, AEvent);
  FScript.InvokeSlice(TXuiJsListener(FListeners[idx]).Handler, args);
  FScript.ClearRoots;
  Result := True;
end;

procedure TXuiDomBridge.Install;
var
  doc: TXuiJsObject;
begin
  // document：find / add / body
  doc := FScript.Interp.CreateHostObject('Document');
  doc.SetOwn('find', FScript.Interp.CreateHostFunction('find', @DocumentMethod));
  doc.SetOwn('add', FScript.Interp.CreateHostFunction('add', @DocumentMethod));
  doc.SetOwn('body', FScript.Interp.CreateHostFunction('body', @DocumentMethod));
  FDocumentObj := doc;
  FScript.RegisterValue('document', FScript.Interp.ObjectValue(doc));

  // ui.version（ui.now / 定时器在 P2 接入）
  FScript.RegisterValue('ui.version', FScript.Str('lui M6'));

  // 引擎事件钩子（动态绑定）
  FEngine.OnScriptEvent := @HandleEngineEvent;
end;

end.
