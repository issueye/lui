unit xui_script_bind;

{$mode objfpc}{$H+}

{ 声明式绑定引擎（M7，参照 Vue 3 模板能力子集）：
    x-text="expr"          文本绑定（支持双花括号插值，如 "共 N 条" 中嵌入表达式；冒号别名 :text 同样生效）
    x-class="expr"         追加类名（保留节点静态 class）
    x-disabled="expr"      可用性绑定
    x-show="expr"          显隐（切换内置 .xui-hidden 类 → display:none）
    x-if="expr"            条件渲染：假摘除子树（保活），真时原位恢复
    x-for="item in expr"   列表渲染：容器按数组重建克隆子树，作用域注入 item/index
    x-model="state.path"   input 双向绑定（路径形式，输入事件回写）

  响应式模型（ADR 19）：绑定集合静态登记，reactive 写入置脏，安全点批量重求值（flush），
  不做依赖追踪。表达式由同一 TS 子集解释器求值，AST 按源文缓存（ADR 20）。

  分层：本单元为 leaf（uses 引擎 + 脚本门面 + 运行时），由 DOM 桥装配。 }

interface

uses
  Classes, SysUtils, Contnrs,
  xui_types, xui_dom, xui_engine, xui_script,
  xui_js_token, xui_js_parser, xui_js_runtime;

type
  TXuiBindKind = (bkText, bkClass, bkDisabled, bkShow, bkIf, bkModel, bkFor);

  TXuiBindProg = class       // 表达式 AST 缓存项
  public
    Prog: TXuiJsProgram;
    Ast: TXuiJsNode;
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
    ItemName: string;        // x-for：迭代变量名
    Owner: TXuiBinding;      // 克隆绑定的归属（x-for 主绑定），重建时一并摘除
    Scope: TXuiJsEnv;        // 作用域（v-for 克隆；nil = 全局）
    Parts: TStringList;      // x-text 插值：偶数=字面量（Objects=nil），奇数=表达式（Objects=1）
    destructor Destroy; override;
  end;

  TXuiBindingEngine = class
  private
    FEngine: TXuiEngine;
    FScript: TXuiScript;
    FBindings: TObjectList;   // TXuiBinding（自有）
    FCache: TObjectList;      // TXuiBindProg（自有，按表达式源缓存）
    FScanned: Boolean;
    function CompileExpr(const ASrc: string): TXuiJsNode;
    function EvalOn(const ASrc: string; AScope: TXuiJsEnv): TXuiJsValue;
    function EvalBool(const ASrc: string; AScope: TXuiJsEnv): Boolean;
    function ScopeOf(AScope: TXuiJsEnv): TXuiJsEnv;
    procedure ScanNode(ANode: TXuiNode; AScope: TXuiJsEnv; AOwner: TXuiBinding);
    procedure ApplyBinding(ABinding: TXuiBinding);
    procedure ApplyFor(ABinding: TXuiBinding);
    procedure MarkScopes;     // GC 根：v-for 作用域环境
    procedure PruneOwner(AOwner: TXuiBinding);
  public
    constructor Create(AEngine: TXuiEngine; AScript: TXuiScript);
    destructor Destroy; override;
    procedure FlushIfDirty;   // 安全点调用：脏或未扫描 → 扫描/刷新
    procedure Flush;
    procedure ResetScan;      // 文档重建（热重载等）后重扫
    function HandleModelInput(ANode: TXuiNode): Boolean;   // xevInput 回写
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

destructor TXuiBinding.Destroy;
begin
  Parts.Free;
  TemplateRef.Free;
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
  FScanned := False;
  FScript.Interp.AddOnCollectRoots(@MarkScopes);
end;

destructor TXuiBindingEngine.Destroy;
begin
  FCache.Free;
  FBindings.Free;
  inherited Destroy;
end;

procedure TXuiBindingEngine.ResetScan;
begin
  FScanned := False;
  FBindings.Clear;
end;

procedure TXuiBindingEngine.MarkScopes;
var
  i: Integer;
begin
  for i := 0 to FBindings.Count - 1 do
    if TXuiBinding(FBindings[i]).Scope <> nil then
      FScript.Interp.MarkRootEnv(TXuiBinding(FBindings[i]).Scope);
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
    if (FCache[i] is TXuiBindProg) and
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

procedure TXuiBindingEngine.PruneOwner(AOwner: TXuiBinding);
var
  i: Integer;
begin
  for i := FBindings.Count - 1 downto 0 do
    if TXuiBinding(FBindings[i]).Owner = AOwner then
      FBindings.Delete(i);
end;

procedure TXuiBindingEngine.ScanNode(ANode: TXuiNode; AScope: TXuiJsEnv;
  AOwner: TXuiBinding);
var
  i, ifIdx: Integer;
  attr, expr, itemName: string;
  kind: TXuiBindKind;
  b: TXuiBinding;
  hasIf, hasFor: Boolean;
  p: Integer;
begin
  if ANode = nil then
    Exit;

  // x-if 最先登记（同节点其他绑定应用时按序在其后）
  hasIf := False;
  for i := 0 to ANode.Attributes.Count - 1 do
    if BindAttrName(ANode.Attributes.Names[i], kind) and (kind = bkIf) then
    begin
      hasIf := True;
      ifIdx := ANode.Parent.IndexOfChild(ANode);
      b := TXuiBinding.Create;
      b.Node := ANode;
      b.Kind := bkIf;
      b.Expr := Trim(ANode.Attributes.ValueFromIndex[i]);
      b.ParentRef := ANode.Parent;
      b.Index := ifIdx;
      b.Scope := AScope;
      b.Owner := AOwner;
      FBindings.Add(b);
      Break;
    end;

  // x-for：容器级列表渲染（模板 = 第一个子节点）
  hasFor := False;
  for i := 0 to ANode.Attributes.Count - 1 do
    if BindAttrName(ANode.Attributes.Names[i], kind) and (kind = bkFor) then
    begin
      hasFor := True;
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
      if ANode.Count > 0 then
      begin
        b.TemplateRef := CloneSubtree(ANode[0]);   // 模板快照（自有）
        FEngine.ClearChildren(ANode);
      end;
      FBindings.Add(b);
      // 克隆在 ApplyFor 时登记（作用域 = 迭代环境）
      Exit;   // 容器子树由模板替代，不再扫描原子树
    end;

  // 其余绑定
  for i := 0 to ANode.Attributes.Count - 1 do
  begin
    attr := ANode.Attributes.Names[i];
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
    b := TXuiBinding.Create;
    b.Node := ANode;
    b.Kind := kind;
    b.Scope := AScope;
    b.Owner := AOwner;
    if kind = bkText then
    begin
      b.Expr := expr;
      if Pos('{{', expr) > 0 then
      begin
        b.Parts := TStringList.Create;
        SplitInterp(expr, b.Parts);
      end;
    end
    else
      b.Expr := expr;
    if (kind = bkClass) or (kind = bkShow) then
      b.Base := Trim(StringReplace(Trim(ANode.Attributes.Values['class']),
        LineEnding, ' ', [rfReplaceAll]));
    FBindings.Add(b);
  end;

  // 递归子树（x-for 容器除外）
  if not hasFor then
    for i := 0 to ANode.Count - 1 do
      ScanNode(ANode[i], AScope, AOwner);
end;

procedure TXuiBindingEngine.Flush;
var
  i: Integer;
begin
  if not FScanned then
  begin
    if (FEngine.Document = nil) or (FEngine.Document.Root = nil) then
      Exit;
    ScanNode(FEngine.Document.Root, nil, nil);
    FScanned := True;
  end;
  for i := 0 to FBindings.Count - 1 do
    try
      if TXuiBinding(FBindings[i]).Kind = bkFor then
        ApplyFor(TXuiBinding(FBindings[i]))
      else
        ApplyBinding(TXuiBinding(FBindings[i]));
    except
      on E: EXuiJsThrow do ;   // 绑定求值异常：本轮跳过（模板先于数据就绪是常态）
      on E: EXuiJsRuntime do ; 
    end;
  FScript.Interp.ClearReactiveDirty;
  FScript.Interp.RunWatchers;
  if FScript.Interp.MountHookCount > 0 then
    FScript.Interp.RunMountHooks;   // onMount：注册即在下次刷新后排空（各执行一次）
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
  if (ABinding.Node = nil) or (ABinding.Kind = bkFor) then
    Exit;
  if (ABinding.Kind <> bkIf) and (ABinding.Node.Parent = nil) then
    Exit;   // 已被 x-if 摘除的子树：跳过其余绑定

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
        cls := FScript.ToStringValue(EvalOn(ABinding.Expr, ABinding.Scope));
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

// x-for：数组长度变化 → 清空重建克隆子树；否则原地重求值克隆绑定
procedure TXuiBindingEngine.ApplyFor(ABinding: TXuiBinding);
var
  arrV: TXuiJsValue;
  arr: TXuiJsArray;
  i: Integer;
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
  if arr.Length = ABinding.Node.Count then
    Exit;   // 长度未变：克隆子树的原地绑定在本 flush 中已重求值

  PruneOwner(ABinding);
  FEngine.ClearChildren(ABinding.Node);
  for i := 0 to arr.Length - 1 do
  begin
    clone := CloneSubtree(ABinding.TemplateRef);
    env := FScript.Interp.NewChildEnv(FScript.Interp.GlobalEnv);
    env.Define(ABinding.ItemName, arr.Items[i]);
    env.Define('index', FScript.Num(i));
    FEngine.AttachElement(ABinding.Node, clone);
    ScanNode(clone, env, ABinding);
  end;
  // 新克隆的绑定需要立即求值一次（本轮 flush 内完成首渲染）
  for i := 0 to FBindings.Count - 1 do
    if (TXuiBinding(FBindings[i]).Owner = ABinding) and
       (TXuiBinding(FBindings[i]).Kind <> bkFor) then
      ApplyBinding(TXuiBinding(FBindings[i]));
end;

// x-model 输入回写：x-model="state.path" → 写状态（触发响应式刷新）
function TXuiBindingEngine.HandleModelInput(ANode: TXuiNode): Boolean;
var
  i, j: Integer;
  b: TXuiBinding;
  segs: TStringList;
  cur: TXuiJsValue;
begin
  Result := False;
  for i := 0 to FBindings.Count - 1 do
  begin
    b := TXuiBinding(FBindings[i]);
    if (b.Node = ANode) and (b.Kind = bkModel) then
    begin
      segs := TStringList.Create;
      try
        segs.Delimiter := '.';
        segs.StrictDelimiter := True;
        segs.DelimitedText := b.Expr;
        if segs.Count = 0 then
          Exit;
        cur := FScript.Interp.GetGlobal(segs[0]);
        for j := 1 to segs.Count - 2 do
          cur := FScript.Interp.PropValue(cur, segs[j]);
        if (cur.Kind = jvObject) and (segs.Count >= 2) then
        begin
          FScript.Interp.SetPropValue(cur, segs[segs.Count - 1],
            FScript.Str(ANode.Text));
          Result := True;
        end;
      finally
        segs.Free;
      end;
      Exit;
    end;
  end;
end;

end.
