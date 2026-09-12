unit xui_script_bind;

{$mode objfpc}{$H+}

{ 声明式绑定引擎（M7，参照 Vue 3 模板能力子集）：
    x-text="expr"          文本绑定（支持双花括号插值；冒号别名 :text 同样生效）
    x-class="expr"         追加类名：字符串 / 对象（真值键生效）/ 数组
    x-disabled="expr"      可用性绑定
    x-show="expr"          显隐（切换内置 .xui-hidden 类 → display:none）
    x-if="expr"            条件渲染：假摘除子树（保活），真时原位恢复
    x-for="item in expr"   列表渲染：容器按数组重建克隆子树，作用域注入 item/index；
                            模板子节点上的 x-key="expr" 启用键控 diff（按 key 复用/移除/重排；
                            同 key 沿用原迭代作用域，组件实例等子作用域随之看到新数据）
    x-model="state.path"   input 双向绑定（路径形式，输入事件回写）

    组件（M7-3/M7-4）：
    component('name', opts)   注册；opts 含 props 与 template；模板支持多根，
      宿主 id/class 落到首根
    props: ['a']（仅声明）或对象形式（每项为类型名，或含 type/required 的选项对象）
      类型校验在每次写入时执行（静态字符串属性先按声明强转 number/boolean）；
      不匹配则上报 ssRuntime 并保留旧值
    slot 标记 slot/（带 name 属性为具名槽）：宿主子节点按 slot="x" 归位，
      未匹配的内容（连同其绑定）丢弃

  响应式模型（ADR 19）：绑定集合静态登记，reactive 写入置脏，安全点批量重求值（flush），
  不做依赖追踪。表达式由同一 TS 子集解释器求值，AST 按源文缓存（ADR 20）。

  分层：本单元为 leaf（uses 引擎 + 脚本门面 + 运行时），由 DOM 桥装配。 }

interface

uses
  Classes, SysUtils, Contnrs,
  xui_types, xui_dom, xui_xml, xui_engine, xui_script,
  xui_js_token, xui_js_parser, xui_js_runtime;

type
  TXuiBindKind = (bkText, bkClass, bkDisabled, bkShow, bkIf, bkModel, bkFor,
    bkComponent, bkProp, bkEvent);

  // DOM 桥注入的节点监听注册/注销（AEventName 形如 'click'；ABind=False 表示注销）
  TXuiBindNodeEventProc = procedure(ANode: TXuiNode; const AEventName: string;
    const AHandler: TXuiJsValue; ABind: Boolean) of object;

  // prop 声明项（M7-4/M7-5）：props 数组形式 = 只声明名字；对象形式可带 type/required/default
  TXuiPropSpec = class
  public
    Name: string;
    TypeName: string;        // '' = 不校验；string/number/boolean/function/object/array/any
    Required: Boolean;
    HasDefault: Boolean;
    DefaultValue: TXuiJsValue;   // 缺省值；可调用则视为工厂（实例化时调用取值）
  end;

  // 组件定义（component('name', {props, template}) 注册；注册表自有）
  TXuiComponentDef = class
  public
    Name: string;
    TemplateStr: string;
    Specs: TObjectList;      // TXuiPropSpec（自有）
    constructor Create(const AName: string);
    destructor Destroy; override;
    function FindSpec(const APropName: string): TXuiPropSpec;
  end;

  // 组件模板内的槽位标记（<slot/> = 默认槽；<slot name="x"/> = 具名槽）
  TXuiSlotMark = class
  public
    Node: TXuiNode;
    Parent: TXuiNode;
    Index: Integer;
    Name: string;            // '' = 默认槽
  end;

  TXuiBindProg = class       // 表达式 AST 缓存项
  public
    Prog: TXuiJsProgram;
    Ast: TXuiJsNode;
  end;

  TXuiForItem = class        // x-for：已渲染条目
  public
    Key: string;
    Node: TXuiNode;          // 克隆首根（弱引用；由文档持有）
    Nodes: TList;            // 克隆的根集合（多根组件实例 = 多根；弱引用，按序）
    Env: TXuiJsEnv;          // 迭代作用域（弱引用；GC 经绑定标记）
    constructor Create;
    destructor Destroy; override;
  end;

  TXuiBinding = class
  public
    Node: TXuiNode;          // 弱引用
    Kind: TXuiBindKind;
    Expr: string;            // 表达式源（缓存键）
    Base: string;            // x-class/x-show：节点静态 class
    ParentRef: TXuiNode;     // x-if：原父节点（弱引用）
    Index: Integer;          // x-if：原位置
    Detached: Boolean;       // x-if：当前是否已摘除
    TemplateRef: TXuiNode;   // x-for：模板子树（自有克隆）
    KeyExpr: string;         // x-for：x-key 表达式（空 = 非键控，按长度重建）
    Items: TObjectList;      // x-for：TXuiForItem（自有；Key/Node/Env 与已渲染条目平行）
    ItemName: string;        // x-for：迭代变量名
    Owner: TXuiBinding;      // 克隆绑定的归属（x-for 主绑定）
    OwnerRoot: TXuiNode;     // 所属 v-for 克隆子树根（剪除/复用按此归属；不在克隆内为 nil）
    CompDef: TObject;        // bkComponent：TXuiComponentDef（弱引用；注册表自有）
    CompName: string;        // bkProp：组件名（校验错误信息）
    PropSpec: TXuiPropSpec;  // bkProp：声明项（弱引用；nil = 未声明，不校验）
    PropsObj: TXuiJsObject;  // bkProp：目标属性容器（reactive）
    PropName: string;        // bkProp：属性名
    EventName: string;       // bkEvent：事件名（'click'/'input'/…）
    EventEntry: TObject;     // bkEvent：TXuiBindEvent（弱引用；引擎注册表自有）
    ModelEntry: TObject;     // 组件 x-model：TXuiBindModel（弱引用；引擎注册表自有）
    Scope: TXuiJsEnv;        // 作用域（v-for 克隆；nil = 全局）
    Parts: TStringList;      // x-text 插值：偶数=字面量（Objects=nil），奇数=表达式（Objects=1）
    destructor Destroy; override;
  end;

  // 事件处理器（M8 ADR 22：@event="expr"）
  // Fn 是注册给 DOM 桥的宿主函数；事件触发时在绑定作用域内求值表达式，结果是函数则调用并传入事件对象
  TXuiBindEvent = class
  public
    Fn: TXuiJsFunction;      // 弱引用（对象由解释器持有；GC 经 MarkScopes 标记）
    FnValue: TXuiJsValue;
    Binding: TXuiBinding;    // 弱引用
    Node: TXuiNode;          // 弱引用
    EventName: string;
    Env: TXuiJsEnv;          // 求值环境（事件对象以 event 变量注入；按作用域变化重建）
    EnvScope: TXuiJsEnv;     // Env 对应的绑定作用域
  end;

  // x-model 组件双向绑定（M8 ADR 23）：组件经 props.onModelValue(v) 写回宿主路径
  TXuiBindModel = class
  public
    Fn: TXuiJsFunction;      // 弱引用（对象由解释器持有；GC 经 MarkScopes 标记）
    FnValue: TXuiJsValue;
    Path: string;            // 宿主给出的状态路径（'state.name'）
  end;

  TXuiBindingEngine = class
  private
    FEngine: TXuiEngine;
    FScript: TXuiScript;
    FBindings: TObjectList;   // TXuiBinding（自有）
    FCache: TObjectList;      // TXuiBindProg（自有，按表达式源缓存）
    FComponents: TObjectList; // TXuiComponentDef（自有）
    FEvents: TObjectList;     // TXuiBindEvent（自有；@event 的处理器注册表）
    FModels: TObjectList;     // TXuiBindModel（自有；组件 x-model 的写回函数注册表）
    FOnNodeEvent: TXuiBindNodeEventProc;
    FScanned: Boolean;
    function CompileExpr(const ASrc: string): TXuiJsNode;
    function EvalOn(const ASrc: string; AScope: TXuiJsEnv): TXuiJsValue;
    function EvalBool(const ASrc: string; AScope: TXuiJsEnv): Boolean;
    function ScopeOf(AScope: TXuiJsEnv): TXuiJsEnv;
    procedure ScanNode(ANode: TXuiNode; AScope: TXuiJsEnv; AOwner: TXuiBinding;
      AOwnerRoot: TXuiNode = nil);
    procedure ApplyBinding(ABinding: TXuiBinding);
    procedure ApplyFor(ABinding: TXuiBinding);
    procedure ApplyForKeyed(ABinding: TXuiBinding);
    procedure ApplyNewBindings(AFromIndex: Integer);
    procedure BindEvent(ABinding: TXuiBinding);
    procedure UnbindEvent(ABinding: TXuiBinding);
    procedure UnbindModel(ABinding: TXuiBinding);
    function BindComponentModel(ABinding: TXuiBinding; AProps: TXuiJsObject;
      const APath: string; const ACompName: string): Boolean;
    function NativeModelWrite(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function WritePath(const APath: string; const AValue: TXuiJsValue): Boolean;
    procedure DeleteBinding(AIndex: Integer);
    function NativeEventDispatch(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    procedure MarkScopes;     // GC 根：v-for 作用域环境 / 事件处理器函数
    procedure PruneOwner(AOwner: TXuiBinding);
    procedure PruneCloneSubtree(ACloneRoot: TXuiNode);
    procedure PruneNodeBindings(ANode: TXuiNode; AKeep: TXuiBinding);
    procedure ReplaceNodeRefs(AOld: TXuiNode; ARoots: TList);
    function IsUnder(ANode, ARoot: TXuiNode): Boolean;
    function ClassValueToString(const AValue: TXuiJsValue): string;
    procedure WriteProp(AProps: TXuiJsObject; const AName: string;
      ASpec: TXuiPropSpec; const AValue: TXuiJsValue; AStatic: Boolean;
      const ACompName: string);
    function MatchPropType(const AValue: TXuiJsValue;
      const ATypeName: string): Boolean;
    function CoerceStaticProp(const AValue: TXuiJsValue; const ATypeName: string;
      out AOut: TXuiJsValue): Boolean;
    procedure CollectSlotMarks(ANode: TXuiNode; AList: TList);
    function ForItemsUnchanged(ABinding: TXuiBinding;
      AArr: TXuiJsArray): Boolean;
    procedure InstantiateComponent(ABinding: TXuiBinding);
    function NativeComponent(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function FindComponentDef(const AName: string): TXuiComponentDef;
  public
    constructor Create(AEngine: TXuiEngine; AScript: TXuiScript);
    destructor Destroy; override;
    procedure FlushIfDirty;   // 安全点调用：脏或未扫描 → 扫描/刷新
    procedure Flush;
    procedure ResetScan;      // 文档重建（热重载等）后重扫
    function HandleModelInput(ANode: TXuiNode): Boolean;   // xevInput 回写
    // DOM 桥注入：注册/注销节点监听（AEventName 形如 'click'）
    property OnNodeEvent: TXuiBindNodeEventProc read FOnNodeEvent write FOnNodeEvent;
  end;

implementation

function CloneSubtree(ASrc: TXuiNode): TXuiNode;
var
  i: Integer;
begin
  Result := TXuiNode.Create(ASrc.Tag);
  Result.Id := ASrc.Id;
  Result.Text := ASrc.Text;
  Result.Attributes.Assign(ASrc.Attributes);
  Result.ClassList.Assign(ASrc.ClassList);
  for i := 0 to ASrc.Count - 1 do
    Result.AddChild(CloneSubtree(ASrc[i]));
end;

// 属性名 → 绑定种类（x- 前缀；冒号别名）
function BindAttrName(const AName: string; out AKind: TXuiBindKind): Boolean;
var
  n: string;
begin
  n := LowerCase(AName);
  if Pos('x-', n) = 1 then
    n := Copy(n, 3, MaxInt)
  else if (n <> '') and (n[1] = ':') then
    n := Copy(n, 2, MaxInt)
  else
    Exit(False);
  Result := True;
  if n = 'text' then AKind := bkText
  else if n = 'class' then AKind := bkClass
  else if n = 'disabled' then AKind := bkDisabled
  else if n = 'show' then AKind := bkShow
  else if n = 'if' then AKind := bkIf
  else if n = 'model' then AKind := bkModel
  else if n = 'for' then AKind := bkFor
  else
    Result := False;
end;

// 拆插值模板："共 {{a}} 条" → 字面量/表达式交替表（Objects=nil 字面量 / =1 表达式）
procedure SplitInterp(const ATemplate: string; AParts: TStringList);
var
  rest: string;
  p1, p2: Integer;
begin
  rest := ATemplate;
  while True do
  begin
    p1 := Pos('{{', rest);
    if p1 = 0 then
      Break;
    p2 := Pos('}}', rest);
    if (p2 = 0) or (p2 < p1) then
      Break;
    if p1 > 1 then
      AParts.AddObject(Copy(rest, 1, p1 - 1), nil);
    AParts.AddObject(Trim(Copy(rest, p1 + 2, p2 - p1 - 2)), TObject(1));
    rest := Copy(rest, p2 + 2, MaxInt);
  end;
  if rest <> '' then
    AParts.AddObject(rest, nil);
end;

// 属性读取（大小写不敏感）；无该属性返回 ''
function AttrValueOf(ANode: TXuiNode; const AName: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to ANode.Attributes.Count - 1 do
    if SameText(ANode.Attributes.Names[i], AName) then
      Exit(ANode.Attributes.ValueFromIndex[i]);
end;

// 节点的槽位归属（slot="x"；无 slot 属性 = 默认槽 ''）
function SlotAttrOf(ANode: TXuiNode): string;
begin
  Result := Trim(AttrValueOf(ANode, 'slot'));
end;

// 属性名 → prop 名：剥离冒号前缀，kebab-case 转 camelCase（:on-tap → onTap）
function PropNameOfAttr(const AAttrName: string): string;
var
  i: Integer;
  upper: Boolean;
begin
  Result := AAttrName;
  if (Result <> '') and (Result[1] = ':') then
    Delete(Result, 1, 1);
  upper := False;
  i := 1;
  while i <= Length(Result) do
    if Result[i] = '-' then
    begin
      Delete(Result, i, 1);
      upper := True;
    end
    else
    begin
      if upper and (Result[i] >= 'a') and (Result[i] <= 'z') then
        Result[i] := Chr(Ord(Result[i]) - 32);
      upper := False;
      Inc(i);
    end;
end;

// 事件表达式属性的识别（M8 ADR 22）：
//   x-onclick / x-on:click / x-oninput …   → 事件名（'click'/'input'…）
// XML 属性名不能以 '@' 开头（Vue 的 @click 在 XML 里非法），故用 x-on<事件属性名> 形式，
// 与既有 x-text/x-if/x-for 家族一致；组件宿主上它等价于回调 prop（onClick…）。
function OnAttrEventName(const AAttrName: string; out AEventName: string): Boolean;
var
  n: string;
begin
  AEventName := '';
  n := LowerCase(AAttrName);
  if Pos('x-on', n) <> 1 then
    Exit(False);
  n := Copy(n, 5, MaxInt);          // 去掉 'x-on'
  if (n <> '') and (n[1] = ':') then
    Delete(n, 1, 1);
  if n = '' then
    Exit(False);
  AEventName := n;
  Result := True;
end;

// 事件名 → 首字母大写驼峰（'click' → 'Click'；'model-value' → 'ModelValue'）
function CamelizeName(const AName: string): string;
var
  i: Integer;
  upper: Boolean;
begin
  Result := AName;
  upper := True;
  i := 1;
  while i <= Length(Result) do
    if Result[i] = '-' then
    begin
      Delete(Result, i, 1);
      upper := True;
    end
    else
    begin
      if upper and (Result[i] >= 'a') and (Result[i] <= 'z') then
        Result[i] := Chr(Ord(Result[i]) - 32);
      upper := False;
      Inc(i);
    end;
end;

procedure StripSlotAttr(ANode: TXuiNode);
var
  i: Integer;
begin
  for i := ANode.Attributes.Count - 1 downto 0 do
    if SameText(ANode.Attributes.Names[i], 'slot') then
      ANode.Attributes.Delete(i);
end;

// JS 值类型名（props 校验错误信息）
function JsTypeNameOf(const AValue: TXuiJsValue): string;
begin
  case AValue.Kind of
    jvUndefined: Result := 'undefined';
    jvNull: Result := 'null';
    jvBool: Result := 'boolean';
    jvNumber: Result := 'number';
    jvString: Result := 'string';
  else
    if AValue.Obj is TXuiJsArray then
      Result := 'array'
    else if AValue.Obj is TXuiJsFunction then
      Result := 'function'
    else
      Result := 'object';
  end;
end;

constructor TXuiForItem.Create;
begin
  inherited Create;
  Nodes := TList.Create;
end;

destructor TXuiForItem.Destroy;
begin
  Nodes.Free;
  inherited Destroy;
end;

destructor TXuiBinding.Destroy;
begin
  Parts.Free;
  TemplateRef.Free;
  Items.Free;
  inherited Destroy;
end;

{ TXuiBindingEngine }

constructor TXuiBindingEngine.Create(AEngine: TXuiEngine; AScript: TXuiScript);
begin
  inherited Create;
  FEngine := AEngine;
  FScript := AScript;
  FBindings := TObjectList.Create(True);
  FCache := TObjectList.Create(True);
  FComponents := TObjectList.Create(True);
  FEvents := TObjectList.Create(True);
  FModels := TObjectList.Create(True);
  FScanned := False;
  FScript.Interp.AddOnCollectRoots(@MarkScopes);
  FScript.Interp.GlobalObject.SetOwn('component',
    FScript.Interp.CreateHostFunction('component', @NativeComponent));
end;

destructor TXuiBindingEngine.Destroy;
begin
  FModels.Free;
  FEvents.Free;
  FComponents.Free;
  FCache.Free;
  FBindings.Free;
  inherited Destroy;
end;

{ 组件定义 }

constructor TXuiComponentDef.Create(const AName: string);
begin
  inherited Create;
  Name := LowerCase(AName);
  Specs := TObjectList.Create(True);
end;

destructor TXuiComponentDef.Destroy;
begin
  Specs.Free;
  inherited Destroy;
end;

function TXuiComponentDef.FindSpec(const APropName: string): TXuiPropSpec;
var
  i: Integer;
begin
  for i := 0 to Specs.Count - 1 do
    if TXuiPropSpec(Specs[i]).Name = APropName then
      Exit(TXuiPropSpec(Specs[i]));
  Result := nil;
end;

function TXuiBindingEngine.FindComponentDef(const AName: string): TXuiComponentDef;
var
  i: Integer;
begin
  for i := 0 to FComponents.Count - 1 do
    if TXuiComponentDef(FComponents[i]).Name = LowerCase(AName) then
      Exit(TXuiComponentDef(FComponents[i]));
  Result := nil;
end;

// 支持的 prop 类型名（'' 与 'any' = 不校验）
function PropTypeSupported(const ATypeName: string): Boolean;
begin
  Result := (ATypeName = '') or (ATypeName = 'any') or (ATypeName = 'string') or
    (ATypeName = 'number') or (ATypeName = 'boolean') or (ATypeName = 'function') or
    (ATypeName = 'object') or (ATypeName = 'array');
end;

// component(name, {props, template}) 注册组件
// props 形式：['a', 'b']（仅声明）或 { a: 'number', b: { type: 'string', required: true } }
function TXuiBindingEngine.NativeComponent(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  name: string;
  defn: TXuiJsObject;
  def: TXuiComponentDef;
  pv, iv: TXuiJsValue;
  arr: TXuiJsArray;
  spec: TXuiPropSpec;
  i: Integer;
begin
  name := LowerCase(FScript.ToStringValue(FScript.Interp.ArgAtPublic(AArgs, 0)));
  if (FScript.Interp.ArgAtPublic(AArgs, 1).Kind <> jvObject) or (FScript.Interp.ArgAtPublic(AArgs, 1).Obj = nil) then
    raise EXuiJsRuntime.Create('component 的第二个参数必须是 {props, template} 对象');
  defn := FScript.Interp.ArgAtPublic(AArgs, 1).Obj;
  def := FindComponentDef(name);
  if def = nil then
  begin
    def := TXuiComponentDef.Create(name);
    FComponents.Add(def);
  end;
  def.TemplateStr := FScript.ToStringValue(defn.GetOwn('template'));
  pv := defn.GetOwn('props');
  def.Specs.Clear;
  if (pv.Kind = jvObject) and (pv.Obj is TXuiJsArray) then
  begin
    arr := TXuiJsArray(pv.Obj);
    for i := 0 to arr.Length - 1 do
    begin
      spec := TXuiPropSpec.Create;
      spec.Name := FScript.ToStringValue(arr.Items[i]);
      def.Specs.Add(spec);
    end;
  end
  else if (pv.Kind = jvObject) and (pv.Obj <> nil) then
    for i := 0 to pv.Obj.Props.Count - 1 do
    begin
      spec := TXuiPropSpec.Create;
      spec.Name := TXuiJsProp(pv.Obj.Props[i]).Name;
      iv := TXuiJsProp(pv.Obj.Props[i]).Value;
      if iv.Kind = jvString then
        spec.TypeName := LowerCase(Trim(iv.Str))
      else if (iv.Kind = jvObject) and (iv.Obj <> nil) then
      begin
        spec.TypeName := LowerCase(Trim(FScript.ToStringValue(iv.Obj.GetOwn('type'))));
        spec.Required := FScript.Interp.ToBoolValue(iv.Obj.GetOwn('required'));
        if iv.Obj.FindOwn('default') >= 0 then
        begin
          spec.HasDefault := True;
          spec.DefaultValue := iv.Obj.GetOwn('default');
        end;
      end;
      if not PropTypeSupported(spec.TypeName) then
        FScript.ReportError('', 'component("' + name + '") 的 prop "' + spec.Name +
          '" 类型不支持：' + spec.TypeName, ssCompile);
      def.Specs.Add(spec);
    end;
  Result := FScript.Undefined;
end;

// props 类型校验：不匹配即上报（静态字符串属性先按声明强转，与 Vue 的静态属性处理一致）
procedure TXuiBindingEngine.WriteProp(AProps: TXuiJsObject; const AName: string;
  ASpec: TXuiPropSpec; const AValue: TXuiJsValue; AStatic: Boolean;
  const ACompName: string);
var
  v, coerced: TXuiJsValue;
begin
  v := AValue;
  if (ASpec <> nil) and (not MatchPropType(v, ASpec.TypeName)) then
  begin
    if AStatic and CoerceStaticProp(v, ASpec.TypeName, coerced) then
      v := coerced   // 静态属性按声明强转（字符串 "7" → 数字 7）
    else
    begin
      FScript.ReportError('', '组件 ' + ACompName + ' 的 prop "' + AName +
        '" 期望 ' + ASpec.TypeName + '，实得 ' + JsTypeNameOf(v), ssRuntime);
      Exit;   // 不写入：保留旧值
    end;
  end;
  FScript.Interp.SetPropValue(FScript.Interp.ObjectValue(AProps), AName, v);
end;

function TXuiBindingEngine.MatchPropType(const AValue: TXuiJsValue;
  const ATypeName: string): Boolean;
begin
  if (ATypeName = '') or (ATypeName = 'any') then
    Exit(True);
  if (AValue.Kind in [jvUndefined, jvNull]) then
    Exit(True);   // 缺省不校验（required 另行检查）
  case AValue.Kind of
    jvString: Exit(ATypeName = 'string');
    jvNumber: Exit(ATypeName = 'number');
    jvBool: Exit(ATypeName = 'boolean');
  end;
  if AValue.Obj = nil then
    Exit(False);
  if ATypeName = 'function' then
    Exit(AValue.Obj is TXuiJsFunction);
  if ATypeName = 'array' then
    Exit(AValue.Obj is TXuiJsArray);
  if ATypeName = 'object' then
    Exit((not (AValue.Obj is TXuiJsArray)) and (not (AValue.Obj is TXuiJsFunction)));
  Result := True;
end;

function TXuiBindingEngine.CoerceStaticProp(const AValue: TXuiJsValue;
  const ATypeName: string; out AOut: TXuiJsValue): Boolean;
var
  n: Double;
  code: Integer;
  s: string;
begin
  AOut := AValue;
  Result := False;
  if AValue.Kind <> jvString then
    Exit;
  s := Trim(AValue.Str);
  if ATypeName = 'number' then
  begin
    Val(s, n, code);
    if code <> 0 then
      Exit;
    AOut := FScript.Num(n);
    Exit(True);
  end;
  if ATypeName = 'boolean' then
  begin
    if (s = '') or SameText(s, 'true') then
      AOut := FScript.Bool(True)
    else if SameText(s, 'false') then
      AOut := FScript.Bool(False)
    else
      Exit;
    Exit(True);
  end;
end;

procedure TXuiBindingEngine.ResetScan;
var
  i: Integer;
begin
  FScanned := False;
  for i := 0 to FBindings.Count - 1 do
  begin
    UnbindEvent(TXuiBinding(FBindings[i]));   // @event：注销监听并释放处理器
    UnbindModel(TXuiBinding(FBindings[i]));   // x-model：释放写回函数
  end;
  FBindings.Clear;
end;

// 绑定删除的唯一出口：@event / x-model 的运行时资源在此释放
procedure TXuiBindingEngine.DeleteBinding(AIndex: Integer);
begin
  UnbindEvent(TXuiBinding(FBindings[AIndex]));
  UnbindModel(TXuiBinding(FBindings[AIndex]));
  FBindings.Delete(AIndex);
end;

// x-model（组件宿主，M8 ADR 23）：登记 props.modelValue ← 宿主路径 的绑定，
// 并注入写回函数 props.onModelValue，组件内部调用它即可回写状态（双向绑定）
function TXuiBindingEngine.BindComponentModel(ABinding: TXuiBinding;
  AProps: TXuiJsObject; const APath: string; const ACompName: string): Boolean;
var
  pb: TXuiBinding;
  entry: TXuiBindModel;
begin
  Result := False;
  if (AProps = nil) or (APath = '') then
    Exit;
  // 1) 读：props.modelValue 随宿主状态刷新（复用动态 prop 通路，含类型校验）
  pb := TXuiBinding.Create;
  pb.Kind := bkProp;
  pb.PropsObj := AProps;
  pb.PropName := 'modelValue';
  pb.PropSpec := TXuiComponentDef(ABinding.CompDef).FindSpec('modelValue');
  pb.CompName := ACompName;
  pb.Expr := APath;
  pb.Scope := ABinding.Scope;
  pb.Owner := ABinding;
  pb.OwnerRoot := ABinding.OwnerRoot;
  FBindings.Add(pb);
  try
    WriteProp(AProps, 'modelValue', pb.PropSpec, EvalOn(APath, ABinding.Scope),
      False, ACompName);
  except
    on E: EXuiJsThrow do ;
    on E: EXuiJsRuntime do ;
  end;

  // 2) 写：props.onModelValue(v) → 写回宿主路径
  entry := TXuiBindModel.Create;
  entry.Path := APath;
  entry.FnValue := FScript.Interp.CreateHostFunction('onModelValue', @NativeModelWrite);
  entry.Fn := TXuiJsFunction(entry.FnValue.Obj);
  FModels.Add(entry);
  pb.ModelEntry := entry;
  WriteProp(AProps, 'onModelValue',
    TXuiComponentDef(ABinding.CompDef).FindSpec('onModelValue'), entry.FnValue,
    False, ACompName);
  Result := True;
end;


function TXuiBindingEngine.WritePath(const APath: string;
  const AValue: TXuiJsValue): Boolean;
var
  segs: TStringList;
  cur: TXuiJsValue;
  j: Integer;
begin
  Result := False;
  segs := TStringList.Create;
  try
    segs.Delimiter := '.';
    segs.StrictDelimiter := True;
    segs.DelimitedText := APath;
    if segs.Count < 2 then
      Exit;
    cur := FScript.Interp.GetGlobal(segs[0]);
    for j := 1 to segs.Count - 2 do
      cur := FScript.Interp.PropValue(cur, segs[j]);
    if cur.Kind <> jvObject then
      Exit;
    FScript.Interp.SetPropValue(cur, segs[segs.Count - 1], AValue);
    Result := True;
  finally
    segs.Free;
  end;
end;

// x-model（组件）：props.onModelValue(v) → 写回宿主给出的路径
// 组件若直接把事件对象传进来（x-oninput="props.onModelValue"），取 event.value / event.text
function TXuiBindingEngine.NativeModelWrite(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  i: Integer;
  entry: TXuiBindModel;
  v: TXuiJsValue;
  ev: TXuiJsObject;
begin
  Result := FScript.Undefined;
  for i := 0 to FModels.Count - 1 do
    if TXuiBindModel(FModels[i]).Fn = AFn then
    begin
      entry := TXuiBindModel(FModels[i]);
      if (entry.Path = '') or (System.Length(AArgs) = 0) then
        Exit;
      v := AArgs[0];
      if (v.Kind = jvObject) and (v.Obj <> nil) and (v.Obj.FindOwn('type') >= 0) then
      begin
        // 事件对象：优先 value，其次 text；两者都空则回读事件节点的当前文本
        ev := v.Obj;
        if ev.FindOwn('value') >= 0 then
          v := ev.GetOwn('value')
        else if ev.FindOwn('text') >= 0 then
          v := ev.GetOwn('text');
        if ((v.Kind = jvUndefined) or ((v.Kind = jvString) and (v.Str = ''))) and
           (ev.FindOwn('node') >= 0) then
          v := FScript.Interp.PropValue(ev.GetOwn('node'), 'text');
      end;
      WritePath(entry.Path, v);
      Exit;
    end;
end;

// @event="expr"：把宿主函数注册到节点事件上（只注册一次；表达式的求值在触发时进行，
// 走绑定作用域，因此组件模板/迭代克隆内都能用）
procedure TXuiBindingEngine.BindEvent(ABinding: TXuiBinding);
var
  entry: TXuiBindEvent;
begin
  if (ABinding.EventEntry <> nil) or (ABinding.Node = nil) or (ABinding.EventName = '') then
    Exit;
  entry := TXuiBindEvent.Create;
  entry.Binding := ABinding;
  entry.Node := ABinding.Node;
  entry.EventName := ABinding.EventName;
  entry.FnValue := FScript.Interp.CreateHostFunction('@' + entry.EventName,
    @NativeEventDispatch);
  entry.Fn := TXuiJsFunction(entry.FnValue.Obj);
  ABinding.EventEntry := entry;
  FEvents.Add(entry);
  if Assigned(FOnNodeEvent) then
    FOnNodeEvent(entry.Node, entry.EventName, entry.FnValue, True);
end;

procedure TXuiBindingEngine.UnbindEvent(ABinding: TXuiBinding);
var
  i: Integer;
  entry: TXuiBindEvent;
begin
  if ABinding.EventEntry = nil then
    Exit;
  entry := TXuiBindEvent(ABinding.EventEntry);
  ABinding.EventEntry := nil;
  if Assigned(FOnNodeEvent) then
    FOnNodeEvent(entry.Node, entry.EventName, entry.FnValue, False);
  for i := 0 to FEvents.Count - 1 do
    if FEvents[i] = entry then
    begin
      FEvents.Delete(i);
      Break;
    end;
end;

procedure TXuiBindingEngine.UnbindModel(ABinding: TXuiBinding);
var
  i: Integer;
  entry: TXuiBindModel;
begin
  if ABinding.ModelEntry = nil then
    Exit;
  entry := TXuiBindModel(ABinding.ModelEntry);
  ABinding.ModelEntry := nil;
  for i := 0 to FModels.Count - 1 do
    if FModels[i] = entry then
    begin
      FModels.Delete(i);
      Break;
    end;
end;

// 事件触发：在该绑定的作用域内求值；结果是函数则调用（传事件对象），否则视为语句表达式；
// 表达式形式可用 event 读取事件载荷（对应 Vue 的 $event）
function TXuiBindingEngine.NativeEventDispatch(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  i: Integer;
  b: TXuiBinding;
  entry: TXuiBindEvent;
  v: TXuiJsValue;
begin
  Result := FScript.Undefined;
  for i := 0 to FEvents.Count - 1 do
    if TXuiBindEvent(FEvents[i]).Fn = AFn then
    begin
      entry := TXuiBindEvent(FEvents[i]);
      b := entry.Binding;
      if (b = nil) or (b.Expr = '') then
        Exit;
      try
        if (entry.Env = nil) or (entry.EnvScope <> b.Scope) then
        begin
          entry.Env := FScript.Interp.NewChildEnv(ScopeOf(b.Scope));
          entry.EnvScope := b.Scope;
        end;
        if System.Length(AArgs) > 0 then
          entry.Env.Define('event', AArgs[0]);
        v := EvalOn(b.Expr, entry.Env);
        if FScript.Interp.IsCallable(v) then
          Result := FScript.Interp.Call(v, AArgs);
      except
        // 组件/页面脚本写错不该崩应用：按脚本错误上报（与绑定求值一致）
        on E: EXuiJsThrow do
          FScript.ReportError('', '事件表达式错误（' + b.Expr + '）：' +
            FScript.Interp.ToStringValue(E.Value), ssRuntime);
        on E: Exception do
          FScript.ReportError('', '事件表达式错误（' + b.Expr + '）：' + E.Message,
            ssRuntime);
      end;
      Exit;
    end;
end;

procedure TXuiBindingEngine.MarkScopes;
var
  i, j, k: Integer;
  def: TXuiComponentDef;
begin
  // 组件定义的 default 值（可为工厂函数/数组）由注册表持有，需保活
  for k := 0 to FComponents.Count - 1 do
  begin
    def := TXuiComponentDef(FComponents[k]);
    for j := 0 to def.Specs.Count - 1 do
      if TXuiPropSpec(def.Specs[j]).HasDefault and
         (TXuiPropSpec(def.Specs[j]).DefaultValue.Kind = jvObject) then
        FScript.Interp.MarkRootValue(TXuiPropSpec(def.Specs[j]).DefaultValue);
  end;
  for i := 0 to FBindings.Count - 1 do
  begin
    if TXuiBinding(FBindings[i]).Scope <> nil then
      FScript.Interp.MarkRootEnv(TXuiBinding(FBindings[i]).Scope);
    if TXuiBinding(FBindings[i]).PropsObj <> nil then
      FScript.Interp.MarkRootValue(
        FScript.Interp.ObjectValue(TXuiBinding(FBindings[i]).PropsObj));
    if TXuiBinding(FBindings[i]).Items <> nil then
      for j := 0 to TXuiBinding(FBindings[i]).Items.Count - 1 do
        FScript.Interp.MarkRootEnv(TXuiForItem(TXuiBinding(FBindings[i]).Items[j]).Env);
  end;
  // @event 处理器函数与 x-model 写回函数保活（注册表由绑定引擎持有，不经 DOM 桥的宿主根）
  for k := 0 to FEvents.Count - 1 do
    FScript.Interp.MarkRootValue(TXuiBindEvent(FEvents[k]).FnValue);
  for k := 0 to FModels.Count - 1 do
    FScript.Interp.MarkRootValue(TXuiBindModel(FModels[k]).FnValue);
end;

// 表达式 → AST（按源文缓存；解析失败上报 ssCompile 并返回 nil）
function TXuiBindingEngine.CompileExpr(const ASrc: string): TXuiJsNode;
var
  key: string;
  i: Integer;
  item: TXuiBindProg;
  prog: TXuiJsProgram;
begin
  key := Trim(ASrc);
  for i := 0 to FCache.Count - 1 do
    if (TXuiBindProg(FCache[i]).Prog <> nil) and
       (TXuiBindProg(FCache[i]).Prog.FileName = '#' + key) then
      Exit(TXuiBindProg(FCache[i]).Ast);
  item := TXuiBindProg.Create;
  Result := nil;
  try
    prog := XuiJsParse('(' + key + ')', '#bind#' + key);
    item.Prog := prog;
    if (prog.Root <> nil) and (prog.Root.ItemCount > 0) then
      Result := prog.Root.Items[0].A;
    item.Ast := Result;
    FCache.Add(item);
  except
    on E: EXuiJsSyntaxError do
    begin
      item.Free;
      FScript.ReportError('', '绑定表达式错误：' + E.Message, ssCompile);
    end;
    on E: Exception do
    begin
      item.Free;
      FScript.ReportError('', '绑定表达式错误：' + E.Message, ssCompile);
    end;
  end;
end;

function TXuiBindingEngine.ScopeOf(AScope: TXuiJsEnv): TXuiJsEnv;
begin
  if AScope = nil then
    Result := FScript.Interp.GlobalEnv
  else
    Result := AScope;
end;

function TXuiBindingEngine.EvalOn(const ASrc: string; AScope: TXuiJsEnv): TXuiJsValue;
var
  ast: TXuiJsNode;
begin
  ast := CompileExpr(ASrc);
  if ast = nil then
    Exit(FScript.Undefined);
  Result := FScript.Interp.EvalAst(ast, ScopeOf(AScope));
end;

function TXuiBindingEngine.EvalBool(const ASrc: string; AScope: TXuiJsEnv): Boolean;
begin
  Result := FScript.Interp.ToBoolValue(EvalOn(ASrc, AScope));
end;

// :class 值 → 类串：字符串原样；对象取真值键；数组逐元素展开
function TXuiBindingEngine.ClassValueToString(const AValue: TXuiJsValue): string;
var
  i: Integer;
  o: TXuiJsObject;
  s: string;
begin
  Result := '';
  if AValue.Kind <> jvObject then
    Exit(FScript.ToStringValue(AValue));
  if AValue.Obj = nil then
    Exit;
  if AValue.Obj is TXuiJsArray then
  begin
    for i := 0 to TXuiJsArray(AValue.Obj).Length - 1 do
    begin
      s := ClassValueToString(TXuiJsArray(AValue.Obj).Items[i]);
      if s <> '' then
        Result := Trim(Result + ' ' + s);
    end;
    Exit;
  end;
  o := AValue.Obj;
  for i := 0 to o.Props.Count - 1 do
    if FScript.Interp.ToBoolValue(TXuiJsProp(o.Props[i]).Value) then
      Result := Trim(Result + ' ' + TXuiJsProp(o.Props[i]).Name);
end;

procedure TXuiBindingEngine.ScanNode(ANode: TXuiNode; AScope: TXuiJsEnv;
  AOwner: TXuiBinding; AOwnerRoot: TXuiNode);
var
  i, ifIdx: Integer;
  attr, expr, itemName, keyExpr, evName: string;
  kind: TXuiBindKind;
  b: TXuiBinding;
  tpl: TXuiNode;
  hasIf, hasFor: Boolean;
  p: Integer;

  function RegBinding(AKind: TXuiBindKind; const ASrc: string): TXuiBinding;
  begin
    b := TXuiBinding.Create;
    b.Node := ANode;
    b.Kind := AKind;
    b.Scope := AScope;
    b.Owner := AOwner;
    b.OwnerRoot := AOwnerRoot;
    b.Expr := ASrc;
    FBindings.Add(b);
    Result := b;
  end;

begin
  if ANode = nil then
    Exit;

  // x-if 最先登记（同节点其他绑定应用时按序在其后）
  hasIf := False;
  for i := 0 to ANode.Attributes.Count - 1 do
    if BindAttrName(ANode.Attributes.Names[i], kind) and (kind = bkIf) then
    begin
      hasIf := True;
      b := TXuiBinding.Create;
      b.Node := ANode;
      b.Kind := bkIf;
      b.Expr := Trim(ANode.Attributes.ValueFromIndex[i]);
      b.ParentRef := ANode.Parent;
      b.Index := ANode.Parent.IndexOfChild(ANode);
      b.Scope := AScope;
      b.Owner := AOwner;
      b.OwnerRoot := AOwnerRoot;
      FBindings.Add(b);
      Break;
    end;

  // 组件：标签命中已注册组件 → 登记 bkComponent 并实例化
  //（slot 内容按父作用域登记——Vue 语义；实例化时移入模板槽位）
  if FindComponentDef(ANode.Tag) <> nil then
  begin
    b := TXuiBinding.Create;
    b.Node := ANode;
    b.Kind := bkComponent;
    b.CompDef := FindComponentDef(ANode.Tag);
    b.Scope := AScope;
    b.Owner := AOwner;
    b.OwnerRoot := AOwnerRoot;
    FBindings.Add(b);
    // 宿主子内容（slot 内容）：按父作用域登记，归属组件绑定——
    // 分发入槽后继续生效；未被槽位接收时随宿主内容一并剪除
    for i := 0 to ANode.Count - 1 do
      ScanNode(ANode[i], AScope, b, AOwnerRoot);
    InstantiateComponent(b);
    Exit;   // 宿主标签已被实例子树替换
  end;

  // x-for：容器级列表渲染（模板 = 第一个子节点；其 x-key 启用键控 diff）
  hasFor := False;
  for i := 0 to ANode.Attributes.Count - 1 do
    if BindAttrName(ANode.Attributes.Names[i], kind) and (kind = bkFor) then
    begin
      hasFor := True;
      if ANode.Count = 0 then
      begin
        FScript.ReportError('', 'x-for 容器缺少模板子节点', ssCompile);
        Exit;   // 不登记绑定：无模板可克隆
      end;
      expr := Trim(ANode.Attributes.ValueFromIndex[i]);
      p := Pos(' in ', expr);
      itemName := Trim(Copy(expr, 1, p - 1));
      if itemName = '' then
        itemName := 'item';
      b := TXuiBinding.Create;
      b.Node := ANode;
      b.Kind := bkFor;
      b.Expr := Trim(Copy(expr, p + 4, MaxInt));
      b.ItemName := itemName;
      b.Scope := AScope;
      b.Owner := AOwner;
      b.OwnerRoot := AOwnerRoot;
      b.Items := TObjectList.Create(True);
      if ANode.Count > 0 then
      begin
        tpl := ANode[0];
        b.TemplateRef := CloneSubtree(tpl);
        keyExpr := '';
        for p := 0 to tpl.Attributes.Count - 1 do
          if (LowerCase(tpl.Attributes.Names[p]) = 'x-key') or
             (LowerCase(tpl.Attributes.Names[p]) = ':key') then
            keyExpr := Trim(tpl.Attributes.Values[tpl.Attributes.Names[p]]);
        b.KeyExpr := keyExpr;
        FEngine.ClearChildren(ANode);
      end;
      FBindings.Add(b);
      Exit;   // 容器子树由模板替代，不再扫描原子树
    end;

  // 其余绑定
  for i := 0 to ANode.Attributes.Count - 1 do
  begin
    attr := ANode.Attributes.Names[i];
    if OnAttrEventName(attr, evName) then
    begin
      // x-onclick="expr"（M8 ADR 22）：事件触发时在绑定作用域求值；结果是函数则调用
      b := RegBinding(bkEvent, Trim(ANode.Attributes.ValueFromIndex[i]));
      b.EventName := evName;
      Continue;
    end;
    if not BindAttrName(attr, kind) then
    begin
      // 普通 text 属性含双花括号插值 → 也登记为文本绑定
      if (LowerCase(attr) = 'text') and (Pos('{{', ANode.Attributes.ValueFromIndex[i]) > 0) then
      begin
        b := TXuiBinding.Create;
        b.Node := ANode;
        b.Kind := bkText;
        b.Scope := AScope;
        b.Owner := AOwner;
        b.OwnerRoot := AOwnerRoot;
        b.Expr := Trim(ANode.Attributes.ValueFromIndex[i]);
        b.Parts := TStringList.Create;
        SplitInterp(b.Expr, b.Parts);
        FBindings.Add(b);
      end;
      Continue;
    end;
    if kind = bkIf then
      Continue;   // 已在循环前登记
    expr := Trim(ANode.Attributes.ValueFromIndex[i]);
    RegBinding(kind, expr);
    if kind = bkText then
    begin
      b.Expr := expr;
      if Pos('{{', expr) > 0 then
      begin
        b.Parts := TStringList.Create;
        SplitInterp(expr, b.Parts);
      end;
    end;
    if (kind = bkClass) or (kind = bkShow) then
      b.Base := Trim(StringReplace(Trim(ANode.Attributes.Values['class']),
        LineEnding, ' ', [rfReplaceAll]));
  end;

  // 递归子树（x-for 容器除外）
  if not hasFor then
    for i := 0 to ANode.Count - 1 do
      ScanNode(ANode[i], AScope, AOwner, AOwnerRoot);
end;

procedure TXuiBindingEngine.Flush;
var
  i: Integer;
  b: TXuiBinding;
begin
  if not FScanned then
  begin
    if (FEngine.Document = nil) or (FEngine.Document.Root = nil) then
      Exit;
    ScanNode(FEngine.Document.Root, nil, nil, nil);
    FScanned := True;
  end;
  if FBindings.Count > 0 then
    FScript.Interp.BumpReactiveVersion;
  i := 0;
  while i < FBindings.Count do
  begin
    try
      b := TXuiBinding(FBindings[i]);
      if b.Kind = bkFor then
      begin
        if b.KeyExpr <> '' then
          ApplyForKeyed(b)   // x-key：键控复用/移除/重排
        else
          ApplyFor(b);       // 无 x-key：长度重建
      end
      else
        ApplyBinding(b);
    except
      // 绑定求值异常：本轮跳过（模板先于数据就绪是常态，如脚本尚未定义状态）
      on E: EXuiJsThrow do ;
      on E: EXuiJsRuntime do ;
    end;
    // ApplyFor 可能增删绑定（x-for 重建），不可假定索引稳定
    if i >= FBindings.Count then
      Break;
    Inc(i);
  end;
  FScript.Interp.ClearReactiveDirty;
  FScript.Interp.RunWatchers;
  if FScript.Interp.MountHookCount > 0 then
    FScript.Interp.RunMountHooks;   // onMount：注册后的首次刷新执行（各一次）
end;

procedure TXuiBindingEngine.FlushIfDirty;
begin
  if (not FScanned) or FScript.Interp.ReactiveDirty then
    Flush;
end;

procedure TXuiBindingEngine.ApplyBinding(ABinding: TXuiBinding);
var
  i: Integer;
  s, cls: string;
  show: Boolean;
  parts: TStringList;
begin
  if ABinding.Kind = bkProp then
  begin
    // 组件属性更新：写 props 容器（reactive，按声明校验），模板绑定随后自动重求值
    WriteProp(ABinding.PropsObj, ABinding.PropName, ABinding.PropSpec,
      EvalOn(ABinding.Expr, ABinding.Scope), False, ABinding.CompName);
    Exit;
  end;
  if ABinding.Kind = bkEvent then
  begin
    BindEvent(ABinding);   // 注册一次；后续触发在 NativeEventDispatch 内求值
    Exit;
  end;
  if (ABinding.Node = nil) or (ABinding.Kind in [bkFor, bkComponent]) then
    Exit;
  if (ABinding.Kind <> bkIf) and (ABinding.Node.Parent = nil) then
    Exit;   // 已被 x-if 摘除的子树：跳过其余绑定（bkIf 自身需恢复）

  case ABinding.Kind of
    bkText:
      begin
        if ABinding.Parts <> nil then
        begin
          parts := ABinding.Parts;
          s := '';
          for i := 0 to parts.Count - 1 do
          begin
            if parts.Objects[i] = nil then
              s := s + parts[i]
            else
              s := s + FScript.ToStringValue(EvalOn(parts[i], ABinding.Scope));
          end;
          FEngine.SetText(ABinding.Node, s);
        end
        else
          FEngine.SetText(ABinding.Node,
            FScript.ToStringValue(EvalOn(ABinding.Expr, ABinding.Scope)));
      end;
    bkClass:
      begin
        cls := ClassValueToString(EvalOn(ABinding.Expr, ABinding.Scope));
        if ABinding.Base <> '' then
          cls := ABinding.Base + ' ' + cls;
        FEngine.SetClass(ABinding.Node, Trim(cls));
      end;
    bkDisabled:
      FEngine.SetDisabled(ABinding.Node, EvalBool(ABinding.Expr, ABinding.Scope));
    bkShow:
      begin
        show := EvalBool(ABinding.Expr, ABinding.Scope);
        cls := ABinding.Base;
        if not show then
        begin
          if cls <> '' then
            cls := cls + ' ';
          cls := cls + 'xui-hidden';
        end;
        FEngine.SetClass(ABinding.Node, Trim(cls));
      end;
    bkModel:
      FEngine.SetText(ABinding.Node,
        FScript.ToStringValue(EvalOn(ABinding.Expr, ABinding.Scope)));
    bkIf:
      begin
        show := EvalBool(ABinding.Expr, ABinding.Scope);
        if show and ABinding.Detached then
        begin
          if (ABinding.ParentRef <> nil) and
             (ABinding.Index >= 0) and (ABinding.Index <= ABinding.ParentRef.Count) then
            ABinding.ParentRef.InsertChild(ABinding.Index, ABinding.Node)
          else if ABinding.ParentRef <> nil then
            ABinding.ParentRef.AddChild(ABinding.Node);
          ABinding.Detached := False;
          FEngine.InvalidateStyles;
        end
        else if (not show) and (not ABinding.Detached) then
        begin
          if ABinding.Node.Parent <> nil then
          begin
            ABinding.Index := ABinding.Node.Parent.IndexOfChild(ABinding.Node);
            ABinding.ParentRef := ABinding.Node.Parent;
            ABinding.Node.Parent.RemoveChild(ABinding.Node);
            ABinding.Detached := True;
            FEngine.InvalidateStyles;
          end;
        end;
      end;
  end;
end;

// 组件实例化：解析模板（可多根）→ 建 props 容器（reactive，含声明校验）→
// 具名/默认 slot 分发宿主子内容 → 替换宿主标签 → 装配行为 → 以组件作用域登记实例绑定。
// 动态属性经 bkProp 随刷新更新。
procedure TXuiBindingEngine.InstantiateComponent(ABinding: TXuiBinding);
var
  def: TXuiComponentDef;
  compNode, host, firstRoot: TXuiNode;
  roots: TList;
  marks: TList;
  mark: TXuiSlotMark;
  child: TXuiNode;
  slotParent: TXuiNode;
  slotIdx, idx, i, j, scanFrom: Integer;
  env: TXuiJsEnv;
  props: TXuiJsObject;
  doc: TXuiDocument;
  attrName, attrValue, propName, slotName, evName, pn: string;
  pb: TXuiBinding;
  spec: TXuiPropSpec;
  dv: TXuiJsValue;
  placed, isEventAttr, explicit: Boolean;
begin
  def := TXuiComponentDef(ABinding.CompDef);
  compNode := ABinding.Node;
  if compNode = nil then
    Exit;

  // 属性容器（reactive）：静态属性立即赋值，:prop 动态属性登记 bkProp 绑定
  props := FScript.Interp.CreateHostObject('Props');
  props.Reactive := True;
  FScript.Interp.MarkReactiveDeep(props, 4);
  for i := 0 to compNode.Attributes.Count - 1 do
  begin
    attrName := compNode.Attributes.Names[i];
    attrValue := compNode.Attributes.ValueFromIndex[i];
    // 组件宿主上的 x-onclick="Expr" = 回调 prop（onClick/onChange…，ADR 22 父级侧写法）
    isEventAttr := OnAttrEventName(attrName, evName);
    if isEventAttr then
      propName := 'on' + CamelizeName(evName)
    else
      propName := PropNameOfAttr(attrName);   // :on-tap → onTap（kebab 转 camel）
    if (propName = '') or SameText(attrName, 'id') or SameText(attrName, 'class') or
       SameText(attrName, 'x-key') or SameText(attrName, 'slot') or
       SameText(attrName, 'x-model') then
      Continue;   // id/class 由宿主转移到实例根；x-key/slot/x-model 与 props 无关
    spec := def.FindSpec(propName);
    if isEventAttr or ((attrName <> '') and (attrName[1] = ':')) then
    begin
      // 动态属性：登记 bkProp（父作用域求值 → 写 props，类型校验随每次刷新）
      pb := TXuiBinding.Create;
      pb.Kind := bkProp;
      pb.PropsObj := props;
      pb.PropName := propName;
      pb.PropSpec := spec;
      pb.CompName := def.Name;
      pb.Expr := Trim(attrValue);
      pb.Scope := ABinding.Scope;
      pb.Owner := ABinding;
      pb.OwnerRoot := ABinding.OwnerRoot;
      FBindings.Add(pb);
      try
        WriteProp(props, propName, spec, EvalOn(Trim(attrValue), ABinding.Scope),
          False, def.Name);
      except
        // 脚本尚未就绪（状态/函数未定义）：保留 undefined，下轮刷新再写
        on E: EXuiJsThrow do ;
        on E: EXuiJsRuntime do ;
      end;
    end
    else
      WriteProp(props, propName, spec, FScript.Str(attrValue), True, def.Name);
  end;

  // 缺省值（实例化时套用；可调用则视为工厂，每次实例调用一次——对象/数组缺省不会跨实例共享）
  for i := 0 to def.Specs.Count - 1 do
  begin
    spec := TXuiPropSpec(def.Specs[i]);
    if (not spec.HasDefault) or (props.GetOwn(spec.Name).Kind <> jvUndefined) then
      Continue;
    dv := spec.DefaultValue;
    if FScript.Interp.IsCallable(dv) then
      try
        dv := FScript.Interp.Call(dv, []);
      except
        on E: EXuiJsThrow do ;
        on E: EXuiJsRuntime do ;
      end;
    WriteProp(props, spec.Name, spec, dv, False, def.Name);
  end;

  // x-model（M8 ADR 23）：组件宿主上的双向绑定（显式 :model-value / :on-model-value 优先）
  for i := 0 to compNode.Attributes.Count - 1 do
  begin
    if not SameText(compNode.Attributes.Names[i], 'x-model') then
      Continue;
    explicit := False;
    for j := 0 to compNode.Attributes.Count - 1 do
    begin
      pn := PropNameOfAttr(compNode.Attributes.Names[j]);
      if SameText(pn, 'modelValue') or SameText(pn, 'onModelValue') then
        explicit := True;
    end;
    if not explicit then
      BindComponentModel(ABinding, props, Trim(compNode.Attributes.ValueFromIndex[i]),
        def.Name);
    Break;
  end;

  // 必填校验（实例化时一次性检查）
  for i := 0 to def.Specs.Count - 1 do
  begin
    spec := TXuiPropSpec(def.Specs[i]);
    if spec.Required and (props.GetOwn(spec.Name).Kind = jvUndefined) then
      FScript.ReportError('', '组件 ' + def.Name + ' 缺少必填 prop "' + spec.Name + '"',
        ssRuntime);
  end;

  // 解析模板（支持多根：每个根节点按序插入宿主位置）
  doc := nil;
  roots := TList.Create;
  try
    try
      doc := LoadDocumentFromXML('<xui-root>' + def.TemplateStr + '</xui-root>', '');
      if (doc.Root = nil) or (doc.Root.Count = 0) then
        raise EXuiJsRuntime.Create('组件模板缺少根节点');
      while doc.Root.Count > 0 do
      begin
        firstRoot := doc.Root[0];
        doc.Root.RemoveChild(firstRoot);   // 摘出实例根，避免随临时文档释放
        roots.Add(firstRoot);
      end;
    except
      on E: Exception do
      begin
        doc.Free;
        for i := 0 to roots.Count - 1 do
          TXuiNode(roots[i]).Free;
        roots.Free;
        FScript.ReportError('', '组件 ' + def.Name + ' 模板错误：' + E.Message, ssCompile);
        Exit;
      end;
    end;
    doc.Free;
    doc := nil;

    firstRoot := TXuiNode(roots[0]);

    // 宿主 id/class 转移到首个实例根（多根时其余根不继承宿主标识）
    if compNode.Id <> '' then
      firstRoot.Id := compNode.Id;
    for i := 0 to compNode.ClassList.Count - 1 do
      if firstRoot.ClassList.IndexOf(compNode.ClassList[i]) < 0 then
        firstRoot.ClassList.Add(compNode.ClassList[i]);

    // slot 分发：宿主直接子节点按 slot="x" 归入具名槽（无该属性 = 默认槽）；
    // 逆文档序处理，插入内容不影响尚未处理的槽位下标
    marks := TObjectList.Create(True);
    try
      for i := 0 to roots.Count - 1 do
        CollectSlotMarks(TXuiNode(roots[i]), marks);
      for i := marks.Count - 1 downto 0 do
      begin
        mark := TXuiSlotMark(marks[i]);
        slotName := mark.Name;
        slotParent := mark.Parent;
        slotIdx := mark.Index;
        idx := 0;
        while idx < compNode.Count do
        begin
          child := compNode[idx];
          if SlotAttrOf(child) = slotName then
          begin
            compNode.RemoveChild(child);
            StripSlotAttr(child);
            slotParent.InsertChild(slotIdx, child);
            Inc(slotIdx);
          end
          else
            Inc(idx);
        end;
        slotParent.RemoveChild(mark.Node);
        mark.Node.Free;
      end;
    finally
      marks.Free;
    end;

    // 未被任何槽位接收的宿主子内容：丢弃（连带其绑定）
    if compNode.Count > 0 then
    begin
      PruneNodeBindings(compNode, ABinding);
      FEngine.ClearChildren(compNode);
    end;

    // 替换宿主标签（多根按序插入原位）
    host := compNode.Parent;
    placed := False;
    if host <> nil then
    begin
      idx := host.IndexOfChild(compNode);
      host.RemoveChild(compNode);
      for i := 0 to roots.Count - 1 do
        host.InsertChild(idx + i, TXuiNode(roots[i]));
      placed := True;
    end
    else
      for i := 0 to roots.Count - 1 do
        TXuiNode(roots[i]).Free;   // 宿主已脱离文档：实例无处置入
  except
    on E: Exception do
    begin
      for i := 0 to roots.Count - 1 do
        TXuiNode(roots[i]).Free;
      roots.Free;
      FScript.ReportError('', '组件 ' + def.Name + ' 实例化失败：' + E.Message, ssRuntime);
      Exit;
    end;
  end;

  if not placed then
  begin
    PruneNodeBindings(compNode, ABinding);
    compNode.Free;
    ABinding.Node := nil;
    roots.Free;
    Exit;
  end;

  // 宿主上的 x-if：单根实例改指实例根（假值摘除/真值原位恢复即作用于实例）；
  // 多根实例无法作为整体摘除，明确报不支持
  for i := 0 to FBindings.Count - 1 do
    if (TXuiBinding(FBindings[i]).Kind = bkIf) and
       (TXuiBinding(FBindings[i]).Node = compNode) then
    begin
      if roots.Count = 1 then
      begin
        TXuiBinding(FBindings[i]).Node := firstRoot;
        TXuiBinding(FBindings[i]).ParentRef := host;
        TXuiBinding(FBindings[i]).Index := host.IndexOfChild(firstRoot);
        TXuiBinding(FBindings[i]).Detached := False;
      end
      else
        FScript.ReportError('', '多根组件不支持 x-if：' + def.Name, ssCompile);
    end;

  // 其余落在宿主子树内的绑定（已随内容丢弃/替换）剪除
  PruneNodeBindings(compNode, ABinding);
  ReplaceNodeRefs(compNode, roots);
  compNode.Free;
  ABinding.Node := nil;

  // 装配行为与静态绑定（slot 内容的既有行为有防重复入守卫）
  for i := 0 to roots.Count - 1 do
    FEngine.ApplyNodeData(TXuiNode(roots[i]));
  FEngine.InvalidateStyles;

  // 以组件作用域登记实例绑定（props 经 env 暴露）；OwnerRoot 继承克隆归属
  env := FScript.Interp.NewChildEnv(FScript.Interp.GlobalEnv);
  env.Define('props', FScript.Interp.ObjectValue(props));
  scanFrom := FBindings.Count;
  if host <> nil then
    for i := 0 to roots.Count - 1 do
      ScanNode(TXuiNode(roots[i]), env, ABinding, ABinding.OwnerRoot);
  ApplyNewBindings(scanFrom);
  roots.Free;
end;

// 迭代条目与已渲染条目是否一一相同（同长度时判断能否免重建/就地更新）
function TXuiBindingEngine.ForItemsUnchanged(ABinding: TXuiBinding;
  AArr: TXuiJsArray): Boolean;
var
  i: Integer;
  v: TXuiJsValue;
begin
  for i := 0 to AArr.Length - 1 do
  begin
    if not TXuiForItem(ABinding.Items[i]).Env.Lookup(ABinding.ItemName, v) then
      Exit(False);
    if not FScript.Interp.StrictEquals(v, AArr.Items[i]) then
      Exit(False);
  end;
  Result := True;
end;

// x-for 非键控：长度或元素变化 → 重建；同长度元素替换 → 就地更新迭代作用域
procedure TXuiBindingEngine.ApplyFor(ABinding: TXuiBinding);
var
  arrV: TXuiJsValue;
  arr: TXuiJsArray;
  i, scanFrom: Integer;
  clone: TXuiNode;
  env: TXuiJsEnv;
begin
  arrV := EvalOn(ABinding.Expr, ABinding.Scope);
  if not ((arrV.Kind = jvObject) and (arrV.Obj is TXuiJsArray)) then
  begin
    FScript.ReportError('', 'x-for 的表达式必须是数组', ssRuntime);
    Exit;
  end;
  arr := TXuiJsArray(arrV.Obj);
  if arr.Length = ABinding.Items.Count then
  begin
    if ForItemsUnchanged(ABinding, arr) then
      Exit;   // 完全未变：克隆子树的原地绑定在本 flush 中已重求值
    // 同长度元素替换：沿用克隆，只改迭代作用域（内部绑定本轮重求值即生效）
    for i := 0 to arr.Length - 1 do
    begin
      TXuiForItem(ABinding.Items[i]).Env.Define(ABinding.ItemName, arr.Items[i]);
      TXuiForItem(ABinding.Items[i]).Env.Define('index', FScript.Num(i));
    end;
    Exit;
  end;

  PruneOwner(ABinding);
  FEngine.ClearChildren(ABinding.Node);
  ABinding.Items.Clear;
  scanFrom := FBindings.Count;
  for i := 0 to arr.Length - 1 do
  begin
    clone := CloneSubtree(ABinding.TemplateRef);
    env := FScript.Interp.NewChildEnv(FScript.Interp.GlobalEnv);
    env.Define(ABinding.ItemName, arr.Items[i]);
    env.Define('index', FScript.Num(i));
    FEngine.AttachElement(ABinding.Node, clone);
    // 条目簿记：作用域需登记为 GC 根，同长度替换时亦按此原地更新
    ABinding.Items.Add(TXuiForItem.Create);
    TXuiForItem(ABinding.Items.Last).Node := clone;
    TXuiForItem(ABinding.Items.Last).Nodes.Add(clone);
    TXuiForItem(ABinding.Items.Last).Env := env;
    ScanNode(clone, env, ABinding, clone);
  end;
  ApplyNewBindings(scanFrom);
end;

// 新登记的绑定立即求值一次（本轮 flush 内完成首渲染；嵌套 x-for 一并处理）
procedure TXuiBindingEngine.ApplyNewBindings(AFromIndex: Integer);
begin
  while AFromIndex < FBindings.Count do
  begin
    try
      if TXuiBinding(FBindings[AFromIndex]).Kind = bkFor then
      begin
        if TXuiBinding(FBindings[AFromIndex]).KeyExpr <> '' then
          ApplyForKeyed(TXuiBinding(FBindings[AFromIndex]))
        else
          ApplyFor(TXuiBinding(FBindings[AFromIndex]));
      end
      else
        ApplyBinding(TXuiBinding(FBindings[AFromIndex]));
    except
      on E: EXuiJsThrow do ;
      on E: EXuiJsRuntime do ;
    end;
    if AFromIndex >= FBindings.Count then
      Break;
    Inc(AFromIndex);
  end;
end;

// 剪除某绑定的全部下属绑定（组件实例、克隆等按 Owner 链归属；递归）
procedure TXuiBindingEngine.PruneOwner(AOwner: TXuiBinding);
var
  i: Integer;
begin
  for i := FBindings.Count - 1 downto 0 do
    if TXuiBinding(FBindings[i]).Owner = AOwner then
    begin
      PruneOwner(TXuiBinding(FBindings[i]));
      DeleteBinding(i);
    end;
end;

function TXuiBindingEngine.IsUnder(ANode, ARoot: TXuiNode): Boolean;
begin
  Result := False;
  while ANode <> nil do
  begin
    if ANode = ARoot then
      Exit(True);
    ANode := ANode.Parent;
  end;
end;

// 剪除整个克隆子树的绑定：按克隆根归属 + 子树内节点双条件（覆盖嵌套 x-for 的克隆）
procedure TXuiBindingEngine.PruneCloneSubtree(ACloneRoot: TXuiNode);
var
  i: Integer;
begin
  for i := FBindings.Count - 1 downto 0 do
    if (TXuiBinding(FBindings[i]).OwnerRoot = ACloneRoot) or
       ((TXuiBinding(FBindings[i]).Node <> nil) and
        IsUnder(TXuiBinding(FBindings[i]).Node, ACloneRoot)) then
    begin
      PruneOwner(TXuiBinding(FBindings[i]));
      DeleteBinding(i);
    end;
end;

// 剪除落在某节点子树内的绑定（宿主标签替换/丢弃 slot 内容时用）；AKeep 为需保留的绑定
procedure TXuiBindingEngine.PruneNodeBindings(ANode: TXuiNode; AKeep: TXuiBinding);
var
  i: Integer;
begin
  for i := FBindings.Count - 1 downto 0 do
    if (TXuiBinding(FBindings[i]) <> AKeep) and
       (TXuiBinding(FBindings[i]).Node <> nil) and
       IsUnder(TXuiBinding(FBindings[i]).Node, ANode) then
    begin
      PruneOwner(TXuiBinding(FBindings[i]));
      DeleteBinding(i);
    end;
end;

// 组件实例化替换宿主节点后，把各处对宿主节点的引用改指实例根集合
// （键控 x-for 的条目簿记、克隆归属都记录着宿主节点；多根实例整组记录）
procedure TXuiBindingEngine.ReplaceNodeRefs(AOld: TXuiNode; ARoots: TList);
var
  i, j, k: Integer;
  b: TXuiBinding;
  item: TXuiForItem;
begin
  if (ARoots = nil) or (ARoots.Count = 0) then
    Exit;
  for i := 0 to FBindings.Count - 1 do
  begin
    b := TXuiBinding(FBindings[i]);
    if b.OwnerRoot = AOld then
      b.OwnerRoot := TXuiNode(ARoots[0]);
    if b.Items = nil then
      Continue;
    for j := 0 to b.Items.Count - 1 do
    begin
      item := TXuiForItem(b.Items[j]);
      if item.Nodes.IndexOf(AOld) < 0 then
        Continue;
      item.Nodes.Clear;
      for k := 0 to ARoots.Count - 1 do
        item.Nodes.Add(ARoots[k]);
      item.Node := TXuiNode(ARoots[0]);
    end;
  end;
end;

// 组件模板中的槽位标记（文档序）
procedure TXuiBindingEngine.CollectSlotMarks(ANode: TXuiNode; AList: TList);
var
  i: Integer;
  mark: TXuiSlotMark;
begin
  for i := 0 to ANode.Count - 1 do
    if SameText(ANode[i].Tag, 'slot') then
    begin
      mark := TXuiSlotMark.Create;
      mark.Node := ANode[i];
      mark.Parent := ANode;
      mark.Index := i;
      mark.Name := Trim(AttrValueOf(ANode[i], 'name'));
      AList.Add(mark);
    end
    else
      CollectSlotMarks(ANode[i], AList);
end;

// x-for 键控 diff：按 x-key 复用/移除/重排克隆；无 x-key 时退化为长度重建
procedure TXuiBindingEngine.ApplyForKeyed(ABinding: TXuiBinding);
var
  arrV: TXuiJsValue;
  arr: TXuiJsArray;
  i, j2, k, oldIdx, cursor, scanFrom: Integer;
  clone: TXuiNode;
  env, scratch: TXuiJsEnv;
  newKeys: TStringList;
  newClones: array of TXuiNode;
  newEnvs: array of TXuiJsEnv;
  newEntries: array of TXuiForItem;
  used: array of Boolean;
  removed: TXuiNode;
  grp: TList;
begin
  arrV := EvalOn(ABinding.Expr, ABinding.Scope);
  if not ((arrV.Kind = jvObject) and (arrV.Obj is TXuiJsArray)) then
  begin
    FScript.ReportError('', 'x-for 的表达式必须是数组', ssRuntime);
    Exit;
  end;
  arr := TXuiJsArray(arrV.Obj);

  newKeys := TStringList.Create;
  try
    SetLength(newClones, arr.Length);
    SetLength(newEnvs, arr.Length);
    SetLength(newEntries, arr.Length);
    SetLength(used, ABinding.Items.Count);
    for i := 0 to High(used) do
      used[i] := False;

    // 逐条目：求 key、按 key 复用旧克隆与其迭代作用域
    // （求 key 共用一个临时作用域：解释器不回收环境对象，避免每次刷新新建 N 个）
    scratch := FScript.Interp.NewChildEnv(FScript.Interp.GlobalEnv);
    for i := 0 to arr.Length - 1 do
    begin
      scratch.Define(ABinding.ItemName, arr.Items[i]);
      scratch.Define('index', FScript.Num(i));
      newKeys.Add(FScript.ToStringValue(EvalOn(ABinding.KeyExpr, scratch)));
      oldIdx := -1;
      for j2 := 0 to ABinding.Items.Count - 1 do
        if (not used[j2]) and (TXuiForItem(ABinding.Items[j2]).Key = newKeys[i]) then
        begin
          oldIdx := j2;
          Break;
        end;
      if oldIdx >= 0 then
      begin
        used[oldIdx] := True;
        newEntries[i] := TXuiForItem(ABinding.Items[oldIdx]);
        newClones[i] := newEntries[i].Node;
        // 复用：沿用旧迭代作用域（组件实例等子作用域随之看到新数据），只更新条目与下标
        newEnvs[i] := newEntries[i].Env;
        newEnvs[i].Define(ABinding.ItemName, arr.Items[i]);
        newEnvs[i].Define('index', FScript.Num(i));
      end
      else
      begin
        // 新条目：新建迭代作用域
        env := FScript.Interp.NewChildEnv(FScript.Interp.GlobalEnv);
        env.Define(ABinding.ItemName, arr.Items[i]);
        env.Define('index', FScript.Num(i));
        newEnvs[i] := env;
      end;
    end;

    // 移除：未被复用的旧条目（整组节点连带其绑定）
    for i := ABinding.Items.Count - 1 downto 0 do
      if not used[i] then
      begin
        for k := TXuiForItem(ABinding.Items[i]).Nodes.Count - 1 downto 0 do
        begin
          removed := TXuiNode(TXuiForItem(ABinding.Items[i]).Nodes[k]);
          PruneCloneSubtree(removed);
          if removed.Parent <> nil then
            removed.Parent.RemoveChild(removed);
          removed.Free;
        end;
        ABinding.Items.Delete(i);
      end;

    // 新建：无对应旧 key 的条目
    scanFrom := FBindings.Count;
    for i := 0 to arr.Length - 1 do
      if newClones[i] = nil then
      begin
        clone := CloneSubtree(ABinding.TemplateRef);
        FEngine.AttachElement(ABinding.Node, clone);
        // 先登记簿记再扫描：模板根若是组件，实例化会替换宿主节点，
        // ReplaceNodeRefs 依簿记把条目改指实例根（多根则整组），扫描后据此读回
        ABinding.Items.Add(TXuiForItem.Create);
        newEntries[i] := TXuiForItem(ABinding.Items.Last);
        newEntries[i].Key := newKeys[i];
        newEntries[i].Node := clone;
        newEntries[i].Nodes.Add(clone);
        newEntries[i].Env := newEnvs[i];
        ScanNode(clone, newEnvs[i], ABinding, clone);
        newClones[i] := newEntries[i].Node;
      end;

    // 更新簿记：按 newKeys 顺序重排条目对象（保留各自的作用域与根集合）
    ABinding.Items.OwnsObjects := False;
    ABinding.Items.Clear;   // 仅解除引用；移除的条目已在上一步释放
    for i := 0 to arr.Length - 1 do
      ABinding.Items.Add(newEntries[i]);
    ABinding.Items.OwnsObjects := True;

    // 重排：使容器子节点顺序与 newKeys 一致；条目若是多根实例则整组搬移保持连续
    cursor := 0;
    for i := 0 to arr.Length - 1 do
    begin
      grp := TXuiForItem(ABinding.Items[i]).Nodes;
      if grp.Count = 0 then
        Continue;
      if ABinding.Node.IndexOfChild(TXuiNode(grp[0])) <> cursor then
      begin
        for k := 0 to grp.Count - 1 do
          if TXuiNode(grp[k]).Parent <> nil then
            TXuiNode(grp[k]).Parent.RemoveChild(TXuiNode(grp[k]));
        for k := 0 to grp.Count - 1 do
          ABinding.Node.InsertChild(cursor + k, TXuiNode(grp[k]));
      end;
      Inc(cursor, grp.Count);
    end;
  finally
    newKeys.Free;
  end;

  // 新建克隆的绑定立即求值一次（本轮 flush 内完成首渲染）
  ApplyNewBindings(scanFrom);
end;

// x-model 输入回写：x-model="state.path" → 写状态（触发响应式刷新）
function TXuiBindingEngine.HandleModelInput(ANode: TXuiNode): Boolean;
var
  i: Integer;
  b: TXuiBinding;
begin
  Result := False;
  for i := 0 to FBindings.Count - 1 do
  begin
    b := TXuiBinding(FBindings[i]);
    if (b.Node = ANode) and (b.Kind = bkModel) then
    begin
      Result := WritePath(b.Expr, FScript.Str(ANode.Text));
      Exit;
    end;
  end;
end;

end.
