unit xui_js_parser;

{$mode objfpc}{$H+}

{ TS 子集语法分析（M6 脚本引擎第二层）：token 流 → AST。纯逻辑、不依赖 LCL。

  - 优先级爬升表达式 + 递归下降语句
  - TS 类型擦除：类型注解、泛型参数表、「as」、interface/type 声明整体丢弃；
    enum 降级为对象字面量（数字成员附带反向映射）
  - ES6：箭头函数（词法 this）、模板串、解构（默认值/重命名/剩余）、展开、
    可选链、「??」、for..of、类（constructor/方法/实例字段/单继承/super）
  - 简化 ASI：缺分号时遇右花括号、EOF 或换行自动结束
  - 明确不支持项给出中文报错（import/export、async/await、正则、装饰器、get/set 等）

  AST 槽位约定（详见各 Kind 注释）：
  - nkProgram/nkBlock/nkSeq: Items
  - nkVarDecl:   Name = 'var'/'let'/'const'；Items = nkDeclarator
  - nkDeclarator: A = 目标模式；B = 初始化表达式（可空）
  - nkFuncDecl:  Name；A = nkFunc
  - nkClassDecl: Name；A = nkClass
  - nkFunc:      Name；A = 参数表（nkSeq）；B = 函数体（nkBlock 或表达式）；Flags = nfArrow/nfExprBody/nfMethod
  - nkClass:     Name；A = 成员表（nkSeq）；B = 父类表达式
  - nkMethod:    Name；A = nkFunc；Flags = nfStatic/nfComputed
  - nkClassField: Name；B = 初始化表达式；Flags = nfStatic/nfComputed
  - nkIf:        A 条件 / B 真分支 / C 假分支
  - nkWhile:     A 条件 / B 体；nkDoWhile 同
  - nkFor:       A 初始化 / B 条件 / C 步进 / Items[0] = 体
  - nkForOf:     Name = 声明方式；A 绑定 / B 可迭代对象 / C 体
  - nkTry:       B try 块 / A catch 参数（可空）/ C catch 块 / Items[0] = finally 块（可空）
  - nkUnary/nkUpdate: Op / A；nkUpdate 的 nfPrefix
  - nkBinary/nkLogical: Op / A / B
  - nkAssign:    Op / A 目标 / B 值
  - nkCond:      A 条件 / B 真 / C 假
  - nkCall:      A 被调 / Items 实参 / nfOptional
  - nkNew:       A 构造器 / Items 实参
  - nkMember:    A 对象 / Name 属性名（或 B 计算键）/ nfComputed / nfOptional
  - nkTemplate:  Items（nkString 字面量 与 表达式交替）
  - nkArrayLit:  Items（nkSpread 展开 / nkEmpty 空洞）
  - nkObjectLit: Items（nkProperty / nkSpread）
  - nkProperty:  A 键（nkString/nkNumber）/ B 值 / Name 非计算键名 / nfComputed / nfShorthand / nfMethod
  - nkArrayPat:  Items（模式 / nkEmpty 空洞 / nkRestPat）
  - nkObjectPat: Items（Name+A 属性模式 / nkRestPat）
  - nkAssignPat: A 目标 / B 默认值；nkRestPat: A 目标 }

interface

uses
  SysUtils, Classes, Contnrs,
  xui_js_token;

type
  TXuiJsNodeKind = (
    // 表达式
    nkNumber, nkString, nkBool, nkNull, nkUndefined, nkIdent, nkThis, nkSuper,
    nkArrayLit, nkObjectLit, nkProperty, nkFunc, nkClass, nkMethod, nkClassField,
    nkUnary, nkUpdate, nkBinary, nkLogical, nkAssign, nkCond, nkCall, nkNew,
    nkMember, nkSeq, nkTemplate, nkSpread, nkDeclarator,
    // 语句
    nkProgram, nkBlock, nkVarDecl, nkFuncDecl, nkClassDecl, nkExprStmt, nkIf,
    nkWhile, nkDoWhile, nkFor, nkForOf, nkReturn, nkBreak, nkContinue, nkThrow,
    nkTry, nkEmpty,
    // 解构模式
    nkArrayPat, nkObjectPat, nkAssignPat, nkRestPat
  );

  TXuiJsNodeFlag = (
    nfPrefix,     // 前缀 ++/--
    nfComputed,   // 计算属性名 / 计算成员
    nfOptional,   // 可选链
    nfArrow,      // 箭头函数（词法 this）
    nfExprBody,   // 箭头函数单表达式体
    nfMethod,     // 方法定义
    nfStatic,     // 类静态成员
    nfShorthand,  // 对象字面量简写
    nfRest,       // 剩余元素
    nfSpread      // 展开元素
  );
  TXuiJsNodeFlags = set of TXuiJsNodeFlag;

  TXuiJsNode = class
  public
    Kind: TXuiJsNodeKind;
    Line, Col: Integer;
    Name: string;
    Str: string;
    Num: Double;
    Op: string;
    Flags: TXuiJsNodeFlags;
    A, B, C: TXuiJsNode;
    Items: array of TXuiJsNode;
    constructor Create(AKind: TXuiJsNodeKind; ALine, ACol: Integer);
    procedure AddItem(ANode: TXuiJsNode);
    function ItemCount: Integer; inline;
  end;

  TXuiJsProgram = class
  private
    FAll: TObjectList;
    FRoot: TXuiJsNode;
    FFileName: string;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    function NewNode(AKind: TXuiJsNodeKind; ALine, ACol: Integer): TXuiJsNode;
    property Root: TXuiJsNode read FRoot write FRoot;
    property FileName: string read FFileName;
  end;

  TXuiJsParser = class
  private
    FProg: TXuiJsProgram;
    FToks: TXuiJsTokens;
    FIndex: Integer;
    FDepth: Integer;
    // token 游标
    function Cur: TXuiJsToken;
    function CurKind: TXuiJsTokenKind;
    function TokAt(AIndex: Integer): TXuiJsToken;
    function PunctAt(AIndex: Integer; const S: string): Boolean;
    function KwAt(AIndex: Integer; const S: string): Boolean;
    procedure Advance;
    function IsPunct(const S: string): Boolean;
    function IsKw(const S: string): Boolean;
    function Accept(const S: string): Boolean;
    procedure Expect(const S: string);
    procedure ExpectKw(const S: string);
    procedure ParseError(const AMsg: string);
    function MkNode(AKind: TXuiJsNodeKind): TXuiJsNode;
    function IsIdentLike: Boolean;
    function TakeIdentLike: string;
    // 类型擦除
    procedure SkipBalancedAngle;
    procedure SkipTypeParamsIfAny;
    procedure SkipType(const AStops: array of string);
    procedure SkipBracedBlock;
    procedure SkipInterfaceDecl;
    procedure SkipTypeAliasDecl;
    function ParseEnumDecl: TXuiJsNode;
    // 前瞻
    function ScanMatching(APos: Integer): Integer;
    function ScanAngle(APos: Integer): Integer;
    function CheckArrowAfter(APos: Integer): Boolean;
    function IsArrowAhead: Boolean;
    // 语句
    function ParseBlock: TXuiJsNode;
    function ParseStatement: TXuiJsNode;
    function ParseVarDecl(AConsumeSemi: Boolean): TXuiJsNode;
    function ParseFunctionDecl: TXuiJsNode;
    function ParseClassDecl: TXuiJsNode;
    // 声明片段
    function ParseParams: TXuiJsNode;
    function ParseBindingTarget: TXuiJsNode;
    function ParseClassMembers(ACls: TXuiJsNode): TXuiJsNode;
    // 表达式
    function ParseExpression: TXuiJsNode;
    function ParseAssignment: TXuiJsNode;
    function ParseConditional: TXuiJsNode;
    function ParseBinary(AMinLevel: Integer): TXuiJsNode;
    function ParseUnary: TXuiJsNode;
    function ParsePostfix: TXuiJsNode;
    function ParseCallMember: TXuiJsNode;
    function ParseArguments: TXuiJsNode;
    function ParsePrimary: TXuiJsNode;
    function ParseArrowFromIdent: TXuiJsNode;
    function ParseArrowFromParams: TXuiJsNode;
    function ParseArrowOrGeneric: TXuiJsNode;
    function ParseParenExpr: TXuiJsNode;
    function ParseArrowBody: TXuiJsNode;
    function ParseArrayLiteral: TXuiJsNode;
    function ParseObjectLiteral: TXuiJsNode;
    function ParsePropertyName(out AComputed: Boolean): string;
    function ParseTemplate: TXuiJsNode;
    function ParseFuncExpr: TXuiJsNode;
    function ParseClassExpr: TXuiJsNode;
    // 辅助
    function IsAssignable(ANode: TXuiJsNode): Boolean;
    function ConvertToPattern(ANode: TXuiJsNode): TXuiJsNode;
  public
    constructor Create(AProgram: TXuiJsProgram; const ASource: string);
    function ParseProgram: TXuiJsNode;
  end;

// 解析入口：失败抛 EXuiJsSyntaxError
function XuiJsParse(const ASource: string; const AFileName: string = ''): TXuiJsProgram;

implementation

{ TXuiJsNode }

constructor TXuiJsNode.Create(AKind: TXuiJsNodeKind; ALine, ACol: Integer);
begin
  inherited Create;
  Kind := AKind;
  Line := ALine;
  Col := ACol;
  SetLength(Items, 0);
end;

procedure TXuiJsNode.AddItem(ANode: TXuiJsNode);
var
  n: Integer;
begin
  n := Length(Items);
  SetLength(Items, n + 1);
  Items[n] := ANode;
end;

function TXuiJsNode.ItemCount: Integer;
begin
  Result := Length(Items);
end;

{ TXuiJsProgram }

constructor TXuiJsProgram.Create(const AFileName: string);
begin
  inherited Create;
  FAll := TObjectList.Create(True);
  FFileName := AFileName;
end;

destructor TXuiJsProgram.Destroy;
begin
  FAll.Free;
  inherited Destroy;
end;

function TXuiJsProgram.NewNode(AKind: TXuiJsNodeKind; ALine, ACol: Integer): TXuiJsNode;
begin
  Result := TXuiJsNode.Create(AKind, ALine, ACol);
  FAll.Add(Result);
end;

{ TXuiJsParser — token 游标 }

constructor TXuiJsParser.Create(AProgram: TXuiJsProgram; const ASource: string);
var
  lex: TXuiJsLexer;
begin
  inherited Create;
  FProg := AProgram;
  lex := TXuiJsLexer.Create(ASource);
  try
    FToks := lex.Tokens;
  finally
    lex.Free;
  end;
  FIndex := 0;
  FDepth := 0;
end;

function TXuiJsParser.Cur: TXuiJsToken;
begin
  if FIndex <= High(FToks) then
    Result := FToks[FIndex]
  else
    Result := FToks[High(FToks)];
end;

function TXuiJsParser.CurKind: TXuiJsTokenKind;
begin
  Result := Cur.Kind;
end;

function TXuiJsParser.TokAt(AIndex: Integer): TXuiJsToken;
begin
  if (AIndex >= 0) and (AIndex <= High(FToks)) then
    Result := FToks[AIndex]
  else
  begin
    Result := FToks[High(FToks)];
  end;
end;

function TXuiJsParser.PunctAt(AIndex: Integer; const S: string): Boolean;
var
  t: TXuiJsToken;
begin
  t := TokAt(AIndex);
  Result := (t.Kind = tkPunct) and (t.Text = S);
end;

function TXuiJsParser.KwAt(AIndex: Integer; const S: string): Boolean;
var
  t: TXuiJsToken;
begin
  t := TokAt(AIndex);
  Result := (t.Kind = tkKeyword) and (t.Text = S);
end;

procedure TXuiJsParser.Advance;
begin
  if FIndex <= High(FToks) then
    Inc(FIndex);
end;

function TXuiJsParser.IsPunct(const S: string): Boolean;
begin
  Result := (Cur.Kind = tkPunct) and (Cur.Text = S);
end;

function TXuiJsParser.IsKw(const S: string): Boolean;
begin
  Result := (Cur.Kind = tkKeyword) and (Cur.Text = S);
end;

function TXuiJsParser.Accept(const S: string): Boolean;
begin
  if IsPunct(S) then
  begin
    Advance;
    Exit(True);
  end;
  Result := False;
end;

procedure TXuiJsParser.Expect(const S: string);
begin
  if not Accept(S) then
    ParseError('期望 "' + S + '"，实际是 "' + Cur.Text + '"');
end;

procedure TXuiJsParser.ExpectKw(const S: string);
begin
  if IsKw(S) then
    Advance
  else
    ParseError('期望关键字 "' + S + '"，实际是 "' + Cur.Text + '"');
end;

procedure TXuiJsParser.ParseError(const AMsg: string);
begin
  raise EXuiJsSyntaxError.Create(AMsg, Cur.Line, Cur.Col);
end;

function TXuiJsParser.MkNode(AKind: TXuiJsNodeKind): TXuiJsNode;
begin
  Result := FProg.NewNode(AKind, Cur.Line, Cur.Col);
end;

function TXuiJsParser.IsIdentLike: Boolean;
begin
  Result := (Cur.Kind = tkIdent) or (Cur.Kind = tkKeyword);
end;

function TXuiJsParser.TakeIdentLike: string;
begin
  if not IsIdentLike then
    ParseError('期望标识符，实际是 "' + Cur.Text + '"');
  Result := Cur.Text;
  Advance;
end;

{ ---- TS 类型擦除 ---- }

procedure TXuiJsParser.SkipBalancedAngle;
var
  depth: Integer;
  t: string;
begin
  if not IsPunct('<') then
    Exit;
  depth := 0;
  while CurKind <> tkEOF do
  begin
    if Cur.Kind = tkPunct then
    begin
      t := Cur.Text;
      if t = '<' then
        Inc(depth)
      else if t = '>' then
      begin
        Dec(depth);
        if depth <= 0 then
        begin
          Advance;
          Exit;
        end;
      end
      else if t = '>>' then
      begin
        Dec(depth, 2);
        if depth <= 0 then
        begin
          Advance;
          Exit;
        end;
      end
      else if t = '>>>' then
      begin
        Dec(depth, 3);
        if depth <= 0 then
        begin
          Advance;
          Exit;
        end;
      end;
    end;
    Advance;
  end;
end;

procedure TXuiJsParser.SkipTypeParamsIfAny;
begin
  if IsPunct('<') then
    SkipBalancedAngle;
end;

// 跳过一段类型；遇到顶层（深度 0）的停止标点即返回（不消费）
procedure TXuiJsParser.SkipType(const AStops: array of string);
var
  depth, i: Integer;
  isStop: Boolean;
begin
  depth := 0;
  while CurKind <> tkEOF do
  begin
    if Cur.Kind = tkPunct then
    begin
      if depth = 0 then
      begin
        isStop := False;
        for i := Low(AStops) to High(AStops) do
          if Cur.Text = AStops[i] then
            isStop := True;
        if isStop then
          Exit;
      end;
      if (Cur.Text = '(') or (Cur.Text = '[') or (Cur.Text = '{') or (Cur.Text = '<') then
        Inc(depth)
      else if (Cur.Text = ')') or (Cur.Text = ']') or (Cur.Text = '}') then
      begin
        if depth = 0 then
          Exit;  // 归外层结构
        Dec(depth);
      end
      else if Cur.Text = '>' then
      begin
        if depth = 0 then
          Exit;
        Dec(depth);
      end
      else if Cur.Text = '>>' then
      begin
        if depth < 2 then
          Exit;
        Dec(depth, 2);
      end
      else if Cur.Text = '>>>' then
      begin
        if depth < 3 then
          Exit;
        Dec(depth, 3);
      end;
    end;
    Advance;
  end;
end;

// 跳到配对的 '}' 之后（调用处应为 '{'）
procedure TXuiJsParser.SkipBracedBlock;
var
  depth: Integer;
begin
  if not IsPunct('{') then
    Exit;
  depth := 0;
  while CurKind <> tkEOF do
  begin
    if Cur.Kind = tkPunct then
    begin
      if Cur.Text = '{' then
        Inc(depth)
      else if Cur.Text = '}' then
      begin
        Dec(depth);
        Advance;
        if depth <= 0 then
          Exit;
        Continue;
      end;
    end;
    Advance;
  end;
end;

procedure TXuiJsParser.SkipInterfaceDecl;
begin
  Advance; // interface
  if IsIdentLike then
    Advance;
  SkipTypeParamsIfAny;
  if IsKw('extends') then
  begin
    Advance;
    SkipType(['{']);
  end;
  SkipBracedBlock;
  Accept(';');
end;

procedure TXuiJsParser.SkipTypeAliasDecl;
begin
  Advance; // type
  if IsIdentLike then
    Advance;
  SkipTypeParamsIfAny;
  Expect('=');
  SkipType([';']);
  Accept(';');
end;

// enum Color { A, B = 2, C } → const Color = { A:0, B:2, C:3, 0:'A', 1:'B', 2:'C' }
function TXuiJsParser.ParseEnumDecl: TXuiJsNode;
type
  TMember = record
    Name: string;
    HasValue: Boolean;
    IsStr: Boolean;
    NumVal: Double;
    StrVal: string;
  end;
var
  enumName: string;
  members: array of TMember;
  cnt, i: Integer;
  nextNum: Double;
  allNumeric: Boolean;
  obj, prop, keyNode, decl, declarator: TXuiJsNode;
  line, col: Integer;
begin
  line := Cur.Line;
  col := Cur.Col;
  Advance; // enum
  if not IsIdentLike then
    ParseError('enum 缺少名称');
  enumName := Cur.Text;
  Advance;
  Expect('{');
  cnt := 0;
  SetLength(members, 8);
  nextNum := 0;
  while not IsPunct('}') do
  begin
    if CurKind = tkEOF then
      ParseError('enum 未闭合');
    if cnt >= Length(members) then
      SetLength(members, cnt * 2);
    members[cnt].Name := TakeIdentLike;
    members[cnt].HasValue := False;
    members[cnt].IsStr := False;
    members[cnt].NumVal := 0;
    members[cnt].StrVal := '';
    if Accept('=') then
    begin
      members[cnt].HasValue := True;
      if CurKind = tkString then
      begin
        members[cnt].IsStr := True;
        members[cnt].StrVal := Cur.Str;
        Advance;
      end
      else if CurKind = tkNumber then
      begin
        members[cnt].NumVal := Cur.Num;
        Advance;
      end
      else if IsPunct('-') and (TokAt(FIndex + 1).Kind = tkNumber) then
      begin
        Advance;
        members[cnt].NumVal := -Cur.Num;
        Advance;
      end
      else
        ParseError('enum 成员值必须是数字或字符串');
    end;
    Inc(cnt);
    if not Accept(',') then
      Break;
  end;
  Expect('}');
  SetLength(members, cnt);

  allNumeric := True;
  for i := 0 to cnt - 1 do
    if members[i].IsStr then
      allNumeric := False;

  obj := FProg.NewNode(nkObjectLit, line, col);
  for i := 0 to cnt - 1 do
  begin
    prop := FProg.NewNode(nkProperty, line, col);
    prop.Name := members[i].Name;
    keyNode := FProg.NewNode(nkString, line, col);
    keyNode.Str := members[i].Name;
    prop.A := keyNode;
    if members[i].IsStr then
    begin
      keyNode := FProg.NewNode(nkString, line, col);
      keyNode.Str := members[i].StrVal;
      prop.B := keyNode;
    end
    else
    begin
      if members[i].HasValue then
        nextNum := members[i].NumVal;
      keyNode := FProg.NewNode(nkNumber, line, col);
      keyNode.Num := nextNum;
      nextNum := nextNum + 1;
      prop.B := keyNode;
      if allNumeric then
      begin
        // 反向映射
        prop := FProg.NewNode(nkProperty, line, col);
        keyNode := FProg.NewNode(nkNumber, line, col);
        keyNode.Num := members[i].NumVal;
        if not members[i].HasValue then
          keyNode.Num := i;
        prop.A := keyNode;
        keyNode := FProg.NewNode(nkString, line, col);
        keyNode.Str := members[i].Name;
        prop.B := keyNode;
        obj.AddItem(prop);
      end;
    end;
    obj.AddItem(prop);
  end;

  decl := FProg.NewNode(nkVarDecl, line, col);
  decl.Name := 'const';
  declarator := FProg.NewNode(nkDeclarator, line, col);
  declarator.A := FProg.NewNode(nkIdent, line, col);
  declarator.A.Name := enumName;
  declarator.B := obj;
  decl.AddItem(declarator);
  Result := decl;
end;

{ ---- 前瞻扫描（箭头函数判定） ---- }

// APos 处应为开括号；返回配对闭括号之后的下标
function TXuiJsParser.ScanMatching(APos: Integer): Integer;
var
  depth: Integer;
  i: Integer;
  t: TXuiJsToken;
begin
  depth := 0;
  i := APos;
  while i <= High(FToks) do
  begin
    t := FToks[i];
    if t.Kind = tkEOF then
      Exit(i);
    if t.Kind = tkPunct then
    begin
      if (t.Text = '(') or (t.Text = '[') or (t.Text = '{') then
        Inc(depth)
      else if (t.Text = ')') or (t.Text = ']') or (t.Text = '}') then
      begin
        Dec(depth);
        if depth <= 0 then
          Exit(i + 1);
      end;
    end;
    Inc(i);
  end;
  Result := i;
end;

// APos 处应为 '<'；返回配对 '>' 之后的下标
function TXuiJsParser.ScanAngle(APos: Integer): Integer;
var
  depth, i: Integer;
  t: TXuiJsToken;
begin
  depth := 0;
  i := APos;
  while i <= High(FToks) do
  begin
    t := FToks[i];
    if t.Kind = tkEOF then
      Exit(i);
    if t.Kind = tkPunct then
    begin
      if t.Text = '<' then
        Inc(depth)
      else if t.Text = '>' then
      begin
        Dec(depth);
        if depth <= 0 then
          Exit(i + 1);
      end
      else if t.Text = '>>' then
      begin
        Dec(depth, 2);
        if depth <= 0 then
          Exit(i + 1);
      end
      else if t.Text = '>>>' then
      begin
        Dec(depth, 3);
        if depth <= 0 then
          Exit(i + 1);
      end;
    end;
    Inc(i);
  end;
  Result := i;
end;

// 从 APos 起跳过可选的返回类型注解，判断是否出现顶层 '=>'
function TXuiJsParser.CheckArrowAfter(APos: Integer): Boolean;
var
  p, depth: Integer;
  t: TXuiJsToken;
begin
  p := APos;
  if PunctAt(p, ':') then
  begin
    Inc(p);
    depth := 0;
    while p <= High(FToks) do
    begin
      t := FToks[p];
      if t.Kind = tkEOF then
        Exit(False);
      if t.Kind = tkPunct then
      begin
        if (t.Text = '(') or (t.Text = '[') or (t.Text = '{') or (t.Text = '<') then
          Inc(depth)
        else if (t.Text = ')') or (t.Text = ']') or (t.Text = '}') or (t.Text = '>') then
        begin
          if depth > 0 then
            Dec(depth);
        end
        else if t.Text = '=>' then
        begin
          if depth = 0 then
            Exit(True);
        end
        else if (t.Text = ';') or (t.Text = ',') then
        begin
          if depth = 0 then
            Exit(False);
        end;
      end;
      Inc(p);
    end;
    Exit(False);
  end;
  Result := PunctAt(p, '=>');
end;

function TXuiJsParser.IsArrowAhead: Boolean;
var
  p, q: Integer;
begin
  if Cur.Kind = tkIdent then
  begin
    // x => ...  或  x: T => ...
    Exit(CheckArrowAfter(FIndex + 1));
  end;
  if CurKind <> tkPunct then
    Exit(False);
  if Cur.Text = '(' then
  begin
    p := ScanMatching(FIndex);
    Exit(CheckArrowAfter(p));
  end;
  if Cur.Text = '<' then
  begin
    p := ScanAngle(FIndex);
    if not PunctAt(p, '(') then
      Exit(False);
    q := ScanMatching(p);
    Exit(CheckArrowAfter(q));
  end;
  Result := False;
end;

{ ---- 语句 ---- }

function TXuiJsParser.ParseProgram: TXuiJsNode;
var
  stmt: TXuiJsNode;
begin
  Result := MkNode(nkProgram);
  while CurKind <> tkEOF do
  begin
    stmt := ParseStatement();
    if stmt <> nil then
      Result.AddItem(stmt);
  end;
end;

function TXuiJsParser.ParseBlock: TXuiJsNode;
var
  stmt: TXuiJsNode;
begin
  Result := MkNode(nkBlock);
  Expect('{');
  while not IsPunct('}') do
  begin
    if CurKind = tkEOF then
      ParseError('块未闭合');
    stmt := ParseStatement();
    if stmt <> nil then
      Result.AddItem(stmt);
  end;
  Expect('}');
end;

function TXuiJsParser.ParseVarDecl(AConsumeSemi: Boolean): TXuiJsNode;
var
  declName: string;
  target, init, declarator: TXuiJsNode;
begin
  Result := MkNode(nkVarDecl);
  declName := Cur.Text;
  Advance;
  Result.Name := declName;
  while True do
  begin
    declarator := MkNode(nkDeclarator);
    target := ParseBindingTarget();
    declarator.A := target;
    if Accept('=') then
      declarator.B := ParseAssignment
    else if declName = 'const' then
      ParseError('const 声明必须有初始值');
    Result.AddItem(declarator);
    if not Accept(',') then
      Break;
  end;
  if AConsumeSemi then
    Accept(';');
end;

function TXuiJsParser.ParseFunctionDecl: TXuiJsNode;
var
  fn: TXuiJsNode;
begin
  Result := MkNode(nkFuncDecl);
  Advance; // function
  if IsPunct('*') then
    ParseError('不支持生成器函数');
  Result.Name := TakeIdentLike;
  SkipTypeParamsIfAny;
  fn := MkNode(nkFunc);
  fn.Name := Result.Name;
  fn.A := ParseParams;
  if Accept(':') then
    SkipType(['{']);
  fn.B := ParseBlock;
  Result.A := fn;
end;

function TXuiJsParser.ParseClassDecl: TXuiJsNode;
begin
  Result := MkNode(nkClassDecl);
  Advance; // class
  Result.Name := TakeIdentLike;
  SkipTypeParamsIfAny;
  Result.A := FProg.NewNode(nkClass, Result.Line, Result.Col);
  Result.A.Name := Result.Name;
  Result.A.A := ParseClassMembers(Result.A);
  Accept(';');
end;

// 参数表：'(' 参数 {',' 参数} ')'（含解构/默认值/剩余/类型擦除/修饰符擦除）
function TXuiJsParser.ParseParams: TXuiJsNode;
var
  p, rest: TXuiJsNode;
  def: TXuiJsNode;
begin
  Result := MkNode(nkSeq);
  Expect('(');
  while not IsPunct(')') do
  begin
    if CurKind = tkEOF then
      ParseError('参数表未闭合');
    if Accept('...') then
    begin
      rest := MkNode(nkRestPat);
      if IsPunct('{') or IsPunct('[') then
        rest.A := ParseBindingTarget
      else
      begin
        rest.A := MkNode(nkIdent);
        rest.A.Name := TakeIdentLike;
        Accept('?');
        if Accept(':') then
          SkipType([',', ')']);
      end;
      Result.AddItem(rest);
      Break;
    end;
    // TS：`this: T` 伪参数与参数属性修饰符（擦除）
    if IsKw('this') and PunctAt(FIndex + 1, ':') then
    begin
      Advance;
      Advance;
      SkipType([',', ')']);
      if not Accept(',') then
        Break;
      Continue;
    end;
    while IsKw('public') or IsKw('private') or IsKw('protected') or IsKw('readonly') do
      Advance;
    if IsPunct('{') or IsPunct('[') then
      p := ParseBindingTarget
    else
    begin
      p := MkNode(nkIdent);
      p.Name := TakeIdentLike;
      Accept('?');
      if Accept(':') then
        SkipType(['=', ',', ')']);
    end;
    if Accept('=') then
    begin
      def := MkNode(nkAssignPat);
      def.A := p;
      def.B := ParseAssignment;
      p := def;
    end;
    Result.AddItem(p);
    if not Accept(',') then
      Break;
  end;
  Expect(')');
end;

// 绑定目标：标识符 / 对象模式 / 数组模式（含默认值与剩余）
function TXuiJsParser.ParseBindingTarget: TXuiJsNode;
var
  item, rest, target, def: TXuiJsNode;
  name: string;
  computed: Boolean;
begin
  if IsPunct('{') then
  begin
    Result := MkNode(nkObjectPat);
    Expect('{');
    while not IsPunct('}') do
    begin
      if CurKind = tkEOF then
        ParseError('对象模式未闭合');
      if Accept('...') then
      begin
        rest := MkNode(nkRestPat);
        rest.A := MkNode(nkIdent);
        rest.A.Name := TakeIdentLike;
        Result.AddItem(rest);
        Break;
      end;
      item := MkNode(nkProperty);
      computed := False;
      name := ParsePropertyName(computed);
      item.Name := name;
      if computed then
        Include(item.Flags, nfComputed);
      if Accept(':') then
      begin
        if IsPunct('{') or IsPunct('[') then
          item.A := ParseBindingTarget
        else
        begin
          target := MkNode(nkIdent);
          target.Name := TakeIdentLike;
          Accept('?');
          if Accept(':') then
            SkipType(['=', ',', '}']);
          item.A := target;
        end;
      end
      else
      begin
        target := MkNode(nkIdent);
        target.Name := name;
        item.A := target;
        Include(item.Flags, nfShorthand);
      end;
      if Accept('=') then
      begin
        def := MkNode(nkAssignPat);
        def.A := item.A;
        def.B := ParseAssignment;
        item.A := def;
      end;
      Result.AddItem(item);
      if not Accept(',') then
        Break;
    end;
    Expect('}');
    Exit;
  end;

  if IsPunct('[') then
  begin
    Result := MkNode(nkArrayPat);
    Expect('[');
    while not IsPunct(']') do
    begin
      if CurKind = tkEOF then
        ParseError('数组模式未闭合');
      if Accept(',') then
      begin
        Result.AddItem(MkNode(nkEmpty));
        Continue;
      end;
      if Accept('...') then
      begin
        rest := MkNode(nkRestPat);
        if IsPunct('{') or IsPunct('[') then
          rest.A := ParseBindingTarget
        else
        begin
          rest.A := MkNode(nkIdent);
          rest.A.Name := TakeIdentLike;
        end;
        Result.AddItem(rest);
        Break;
      end;
      if IsPunct('{') or IsPunct('[') then
        item := ParseBindingTarget
      else
      begin
        item := MkNode(nkIdent);
        item.Name := TakeIdentLike;
        Accept('?');
        if Accept(':') then
          SkipType(['=', ',', ']']);
      end;
      if Accept('=') then
      begin
        def := MkNode(nkAssignPat);
        def.A := item;
        def.B := ParseAssignment;
        item := def;
      end;
      Result.AddItem(item);
      if not Accept(',') then
        Break;
    end;
    Expect(']');
    Exit;
  end;

  Result := MkNode(nkIdent);
  Result.Name := TakeIdentLike;
  Accept('?');
  if Accept('!') then ;
  if Accept(':') then
    SkipType(['=', ',', ';', ')', ']', '}']);
end;

function TXuiJsParser.ParseClassMembers(ACls: TXuiJsNode): TXuiJsNode;
var
  members, m, fn: TXuiJsNode;
  isStatic, computed: Boolean;
  name: string;
begin
  members := MkNode(nkSeq);
  if IsKw('extends') then
  begin
    Advance;
    ACls.B := ParseCallMember;
  end;
  if IsKw('implements') then
  begin
    Advance;
    SkipType(['{']);
  end;
  Expect('{');
  while not IsPunct('}') do
  begin
    if CurKind = tkEOF then
      ParseError('类体未闭合');
    if Accept(';') then
      Continue;
    isStatic := False;
    if IsKw('static') then
    begin
      Advance;
      isStatic := True;
    end;
    while IsKw('public') or IsKw('private') or IsKw('protected') or IsKw('readonly') or
          IsKw('abstract') or IsKw('override') or IsKw('declare') do
      Advance;
    // get/set 仅在“后面跟属性名”时才是访问器；`get()` 是名为 get 的方法
    if (IsKw('get') or IsKw('set')) and (not PunctAt(FIndex + 1, '(')) and
       (not PunctAt(FIndex + 1, ':')) then
      ParseError('不支持 get/set 访问器');
    name := ParsePropertyName(computed);
    if IsPunct('(') or IsPunct('<') then
    begin
      SkipTypeParamsIfAny;
      fn := MkNode(nkFunc);
      fn.Name := name;
      Include(fn.Flags, nfMethod);
      fn.A := ParseParams;
      if Accept(':') then
        SkipType(['{']);
      fn.B := ParseBlock;
      m := MkNode(nkMethod);
      m.Name := name;
      if computed then
        Include(m.Flags, nfComputed);
      if isStatic then
        Include(m.Flags, nfStatic);
      m.A := fn;
      members.AddItem(m);
    end
    else
    begin
      m := MkNode(nkClassField);
      m.Name := name;
      if computed then
        Include(m.Flags, nfComputed);
      if isStatic then
        Include(m.Flags, nfStatic);
      Accept('?');
      if IsPunct('!') and Cur.Adjacent then
        Advance;
      if Accept(':') then
        SkipType(['=', ';', '}']);
      if Accept('=') then
        m.B := ParseAssignment;
      members.AddItem(m);
      Accept(';');
    end;
  end;
  Expect('}');
  Result := members;
end;

function TXuiJsParser.ParseStatement: TXuiJsNode;
var
  node, expr: TXuiJsNode;
  line, col: Integer;
begin
  line := Cur.Line;
  col := Cur.Col;

  if IsPunct('{') then
    Exit(ParseBlock);
  if IsPunct(';') then
  begin
    Advance;
    Exit(nil);
  end;

  if IsKw('var') or IsKw('let') or IsKw('const') then
    Exit(ParseVarDecl(True));
  if IsKw('function') then
    Exit(ParseFunctionDecl);
  if IsKw('class') then
    Exit(ParseClassDecl);

  if IsKw('interface') then
  begin
    SkipInterfaceDecl;
    Exit(nil);
  end;
  if IsKw('type') then
  begin
    SkipTypeAliasDecl;
    Exit(nil);
  end;
  if IsKw('enum') then
    Exit(ParseEnumDecl);
  if IsKw('declare') or IsKw('module') or IsKw('namespace') then
    ParseError('不支持 ' + Cur.Text + ' 声明');
  if IsKw('import') or IsKw('export') then
    ParseError('不支持模块系统（import/export）');
  if IsKw('async') then
    ParseError('不支持 async（异步）');
  if IsKw('await') then
    ParseError('不支持 await（异步）');
  if IsKw('switch') then
    ParseError('不支持 switch 语句');
  if IsKw('with') then
    ParseError('不支持 with 语句');
  if IsKw('debugger') then
  begin
    Advance;
    Accept(';');
    Exit(nil);
  end;

  if IsKw('if') then
  begin
    Result := MkNode(nkIf);
    Advance;
    Expect('(');
    Result.A := ParseExpression;
    Expect(')');
    Result.B := ParseStatement();
    if IsKw('else') then
    begin
      Advance;
      Result.C := ParseStatement();
    end;
    Exit;
  end;

  if IsKw('while') then
  begin
    Result := MkNode(nkWhile);
    Advance;
    Expect('(');
    Result.A := ParseExpression;
    Expect(')');
    Result.B := ParseStatement();
    Exit;
  end;

  if IsKw('do') then
  begin
    Result := MkNode(nkDoWhile);
    Advance;
    Result.B := ParseStatement();
    ExpectKw('while');
    Expect('(');
    Result.A := ParseExpression;
    Expect(')');
    Accept(';');
    Exit;
  end;

  if IsKw('for') then
  begin
    Advance;
    Expect('(');

    // for (const x of expr) / for (x of expr)
    if (IsKw('var') or IsKw('let') or IsKw('const')) and
       (TokAt(FIndex + 1).Kind = tkIdent) and KwAt(FIndex + 2, 'of') then
    begin
      Result := MkNode(nkForOf);
      Result.Name := Cur.Text;
      Advance;
      expr := MkNode(nkIdent);
      expr.Name := TakeIdentLike;
      Result.A := expr;
      ExpectKw('of');
      Result.B := ParseAssignment;
      Expect(')');
      Result.C := ParseStatement();
      Exit;
    end;
    if (IsKw('var') or IsKw('let') or IsKw('const')) and
       (PunctAt(FIndex + 1, '{') or PunctAt(FIndex + 1, '[')) then
    begin
      // for (const {a} of arr)
      Result := MkNode(nkForOf);
      Result.Name := Cur.Text;
      Advance;
      Result.A := ParseBindingTarget();
      if IsKw('of') then
      begin
        Advance;
        Result.B := ParseAssignment;
        Expect(')');
        Result.C := ParseStatement();
        Exit;
      end;
      ParseError('for 解构仅支持 for..of');
    end;
    if (Cur.Kind = tkIdent) and KwAt(FIndex + 1, 'of') then
    begin
      Result := MkNode(nkForOf);
      expr := MkNode(nkIdent);
      expr.Name := TakeIdentLike;
      Result.A := expr;
      ExpectKw('of');
      Result.B := ParseAssignment;
      Expect(')');
      Result.C := ParseStatement();
      Exit;
    end;

    Result := MkNode(nkFor);
    if IsKw('var') or IsKw('let') or IsKw('const') then
    begin
      // for (let k = 0; ...) —— 初始化是声明（分号由本处消费）
      Result.A := ParseVarDecl(False);
      Expect(';');
    end
    else
    begin
      if not IsPunct(';') then
        Result.A := ParseExpression;
      Expect(';');
    end;
    if not IsPunct(';') then
      Result.B := ParseExpression;
    Expect(';');
    if not IsPunct(')') then
      Result.C := ParseExpression;
    Expect(')');
    Result.AddItem(ParseStatement());  // Items[0] = 体
    Exit;
  end;

  if IsKw('return') then
  begin
    Result := MkNode(nkReturn);
    Advance;
    if (not Cur.NewlineBefore) and (not IsPunct(';')) and (not IsPunct('}')) and
       (CurKind <> tkEOF) then
      Result.A := ParseExpression;
    Accept(';');
    Exit;
  end;

  if IsKw('break') then
  begin
    Result := MkNode(nkBreak);
    Advance;
    if (Cur.Kind = tkIdent) and (not Cur.NewlineBefore) then
      ParseError('不支持标签');
    Accept(';');
    Exit;
  end;

  if IsKw('continue') then
  begin
    Result := MkNode(nkContinue);
    Advance;
    if (Cur.Kind = tkIdent) and (not Cur.NewlineBefore) then
      ParseError('不支持标签');
    Accept(';');
    Exit;
  end;

  if IsKw('throw') then
  begin
    Result := MkNode(nkThrow);
    Advance;
    Result.A := ParseExpression;
    Accept(';');
    Exit;
  end;

  if IsKw('try') then
  begin
    Result := MkNode(nkTry);
    Advance;
    Result.B := ParseBlock;
    if IsKw('catch') then
    begin
      Advance;
      if Accept('(') then
      begin
        if IsPunct('{') or IsPunct('[') then
          Result.A := ParseBindingTarget
        else
        begin
          Result.A := MkNode(nkIdent);
          Result.A.Name := TakeIdentLike;
          if Accept(':') then
            SkipType([')']);
        end;
        Expect(')');
      end;
      Result.C := ParseBlock;
    end;
    if IsKw('finally') then
    begin
      Advance;
      Result.AddItem(ParseBlock);
    end;
    if (Result.C = nil) and (Result.ItemCount = 0) then
      ParseError('try 需要 catch 或 finally');
    Exit;
  end;

  // 表达式语句
  expr := ParseExpression;
  Result := FProg.NewNode(nkExprStmt, line, col);
  Result.A := expr;
  if not Accept(';') then
  begin
    if (not IsPunct('}')) and (CurKind <> tkEOF) and (not Cur.NewlineBefore) then
      ParseError('缺少分号');
  end;
end;

{ ---- 表达式 ---- }

function TXuiJsParser.ParseExpression: TXuiJsNode;
var
  first, node: TXuiJsNode;
begin
  Inc(FDepth);
  if FDepth > 200 then
    ParseError('表达式嵌套过深');
  try
    first := ParseAssignment;
    if not IsPunct(',') then
      Exit(first);
    node := FProg.NewNode(nkSeq, first.Line, first.Col);
    node.AddItem(first);
    while Accept(',') do
      node.AddItem(ParseAssignment);
    Result := node;
  finally
    Dec(FDepth);
  end;
end;

function TXuiJsParser.ParseAssignment: TXuiJsNode;
var
  lhs, rhs, node: TXuiJsNode;
  op: string;
begin
  if IsArrowAhead then
  begin
    if Cur.Kind = tkIdent then
      Exit(ParseArrowFromIdent);
    if IsPunct('<') then
      Exit(ParseArrowOrGeneric);
    Exit(ParseArrowFromParams);
  end;

  lhs := ParseConditional;
  if Cur.Kind = tkPunct then
  begin
    op := Cur.Text;
    if (op = '=') or (op = '+=') or (op = '-=') or (op = '*=') or (op = '/=') or
       (op = '%=') or (op = '**=') or (op = '<<=') or (op = '>>=') or (op = '>>>=') or
       (op = '&=') or (op = '|=') or (op = '^=') or (op = '&&=') or (op = '||=') or
       (op = '??=') then
    begin
      if not IsAssignable(lhs) then
        ParseError('赋值目标无效');
      Advance;
      // 注意：FPC 下无参方法直接裸名自递归会解析到错误符号，必须写 ()（或 Self.）
      rhs := ParseAssignment();
      node := FProg.NewNode(nkAssign, lhs.Line, lhs.Col);
      node.Op := op;
      node.A := ConvertToPattern(lhs);
      node.B := rhs;
      Exit(node);
    end;
  end;
  Result := lhs;
end;

function TXuiJsParser.ParseConditional: TXuiJsNode;
var
  test, cons, alt, node: TXuiJsNode;
begin
  test := ParseBinary(1);
  if not IsPunct('?') then
    Exit(test);
  Advance;
  cons := ParseAssignment;
  Expect(':');
  alt := ParseAssignment;
  node := FProg.NewNode(nkCond, test.Line, test.Col);
  node.A := test;
  node.B := cons;
  node.C := alt;
  Result := node;
end;

function BinaryLevel(const AOp: string): Integer;
begin
  if AOp = '??' then Exit(1);
  if AOp = '||' then Exit(2);
  if AOp = '&&' then Exit(3);
  if AOp = '|' then Exit(4);
  if AOp = '^' then Exit(5);
  if AOp = '&' then Exit(6);
  if (AOp = '==') or (AOp = '!=') or (AOp = '===') or (AOp = '!==') then Exit(7);
  if (AOp = '<') or (AOp = '>') or (AOp = '<=') or (AOp = '>=') or
     (AOp = 'instanceof') or (AOp = 'in') then Exit(8);
  if (AOp = '<<') or (AOp = '>>') or (AOp = '>>>') then Exit(9);
  if (AOp = '+') or (AOp = '-') then Exit(10);
  if (AOp = '*') or (AOp = '/') or (AOp = '%') then Exit(11);
  if AOp = '**' then Exit(12);
  Result := 0;
end;

function TXuiJsParser.ParseBinary(AMinLevel: Integer): TXuiJsNode;
var
  left, right, node: TXuiJsNode;
  op: string;
  level: Integer;
begin
  left := ParseUnary;
  while True do
  begin
    op := '';
    if Cur.Kind = tkPunct then
      op := Cur.Text
    else if (Cur.Kind = tkKeyword) and ((Cur.Text = 'instanceof') or (Cur.Text = 'in')) then
      op := Cur.Text;
    if op = '' then
      Break;
    level := BinaryLevel(op);
    if (level = 0) or (level < AMinLevel) then
      Break;
    Advance;
    if op = '**' then
      right := ParseBinary(level)   // 右结合
    else
      right := ParseBinary(level + 1);
    if (op = '&&') or (op = '||') or (op = '??') then
      node := FProg.NewNode(nkLogical, left.Line, left.Col)
    else
      node := FProg.NewNode(nkBinary, left.Line, left.Col);
    node.Op := op;
    node.A := left;
    node.B := right;
    left := node;
  end;
  Result := left;
end;

function TXuiJsParser.ParseUnary: TXuiJsNode;
var
  node, operand: TXuiJsNode;
  op: string;
begin
  if Cur.Kind = tkPunct then
  begin
    op := Cur.Text;
    if (op = '!') or (op = '~') or (op = '+') or (op = '-') or (op = '++') or (op = '--') then
    begin
      Advance;
      operand := ParseUnary();
      if (op = '++') or (op = '--') then
      begin
        if not IsAssignable(operand) then
          ParseError('自增/自减目标无效');
        node := FProg.NewNode(nkUpdate, operand.Line, operand.Col);
        node.Op := op;
        node.A := operand;
        Include(node.Flags, nfPrefix);
        Exit(node);
      end;
      node := FProg.NewNode(nkUnary, operand.Line, operand.Col);
      node.Op := op;
      node.A := operand;
      Exit(node);
    end;
  end;
  if IsKw('typeof') or IsKw('void') or IsKw('delete') then
  begin
    op := Cur.Text;
    Advance;
    operand := ParseUnary();
    node := FProg.NewNode(nkUnary, operand.Line, operand.Col);
    node.Op := op;
    node.A := operand;
    Exit(node);
  end;
  if IsKw('await') or IsKw('yield') then
    ParseError('不支持 ' + Cur.Text + '（异步/生成器）');
  Result := ParsePostfix;
end;

function TXuiJsParser.ParsePostfix: TXuiJsNode;
var
  expr, node: TXuiJsNode;
  op: string;
begin
  expr := ParseCallMember;
  if (Cur.Kind = tkPunct) and ((Cur.Text = '++') or (Cur.Text = '--')) and
     (not Cur.NewlineBefore) then
  begin
    op := Cur.Text;
    if not IsAssignable(expr) then
      ParseError('自增/自减目标无效');
    Advance;
    node := FProg.NewNode(nkUpdate, expr.Line, expr.Col);
    node.Op := op;
    node.A := expr;
    Exit(node);
  end;
  // TS 非空断言（`expr!`，与表达式紧邻）
  while IsPunct('!') and Cur.Adjacent do
    Advance;
  // TS `as T`（擦除）
  while IsKw('as') do
  begin
    Advance;
    if IsKw('const') then
      Advance
    else
      SkipType([';', ',', ')', ']', '}', ':', '=', '&&', '||', '??', '?', '+', '-', '*', '/']);
  end;
  Result := expr;
end;

function TXuiJsParser.ParseCallMember: TXuiJsNode;
var
  expr, node, args: TXuiJsNode;
  prop: string;
begin
  expr := ParsePrimary;
  while True do
  begin
    if IsPunct('.') then
    begin
      Advance;
      if not IsIdentLike then
        ParseError('属性名缺失');
      prop := Cur.Text;
      Advance;
      node := FProg.NewNode(nkMember, expr.Line, expr.Col);
      node.A := expr;
      node.Name := prop;
      expr := node;
    end
    else if IsPunct('?.') then
    begin
      Advance;
      if IsPunct('(') then
      begin
        args := ParseArguments;
        node := FProg.NewNode(nkCall, expr.Line, expr.Col);
        node.A := expr;
        node.Items := args.Items;
        Include(node.Flags, nfOptional);
        expr := node;
      end
      else if IsPunct('[') then
      begin
        Advance;
        node := FProg.NewNode(nkMember, expr.Line, expr.Col);
        node.A := expr;
        node.B := ParseExpression;
        Include(node.Flags, nfComputed);
        Include(node.Flags, nfOptional);
        Expect(']');
        expr := node;
      end
      else
      begin
        if not IsIdentLike then
          ParseError('属性名缺失');
        prop := Cur.Text;
        Advance;
        node := FProg.NewNode(nkMember, expr.Line, expr.Col);
        node.A := expr;
        node.Name := prop;
        Include(node.Flags, nfOptional);
        expr := node;
      end;
    end
    else if IsPunct('[') then
    begin
      Advance;
      node := FProg.NewNode(nkMember, expr.Line, expr.Col);
      node.A := expr;
      node.B := ParseExpression;
      Include(node.Flags, nfComputed);
      Expect(']');
      expr := node;
    end
    else if IsPunct('(') then
    begin
      args := ParseArguments;
      node := FProg.NewNode(nkCall, expr.Line, expr.Col);
      node.A := expr;
      node.Items := args.Items;
      expr := node;
    end
    else if (CurKind = tkTemplateNoSub) or (CurKind = tkTemplateHead) then
      ParseError('不支持标签模板')
    else
      Break;
  end;
  Result := expr;
end;

function TXuiJsParser.ParseArguments: TXuiJsNode;
var
  arg: TXuiJsNode;
begin
  Result := MkNode(nkSeq);
  Expect('(');
  while not IsPunct(')') do
  begin
    if CurKind = tkEOF then
      ParseError('实参表未闭合');
    if Accept('...') then
    begin
      arg := MkNode(nkSpread);
      arg.A := ParseAssignment;
      Result.AddItem(arg);
    end
    else
      Result.AddItem(ParseAssignment);
    if not Accept(',') then
      Break;
  end;
  Expect(')');
end;

function TXuiJsParser.ParseParenExpr: TXuiJsNode;
var
  expr: TXuiJsNode;
begin
  Expect('(');
  if IsPunct(')') then
    ParseError('空括号不是合法表达式');
  expr := ParseExpression;
  Expect(')');
  Result := expr;
end;

function TXuiJsParser.ParsePrimary: TXuiJsNode;
var
  node, callee, args: TXuiJsNode;
begin
  case CurKind of
    tkNumber:
      begin
        node := MkNode(nkNumber);
        node.Num := Cur.Num;
        Advance;
        Exit(node);
      end;
    tkString:
      begin
        node := MkNode(nkString);
        node.Str := Cur.Str;
        Advance;
        Exit(node);
      end;
    tkTemplateNoSub, tkTemplateHead, tkTemplateMiddle:
      Exit(ParseTemplate);
  end;

  if Cur.Kind = tkPunct then
  begin
    if Cur.Text = '(' then
    begin
      if IsArrowAhead then
        Exit(ParseArrowFromParams);
      Exit(ParseParenExpr);
    end;
    if Cur.Text = '[' then
      Exit(ParseArrayLiteral);
    if Cur.Text = '{' then
      Exit(ParseObjectLiteral);
    if Cur.Text = '<' then
      Exit(ParseArrowOrGeneric);
  end;

  if Cur.Kind = tkIdent then
  begin
    if IsArrowAhead then
      Exit(ParseArrowFromIdent);
    node := MkNode(nkIdent);
    node.Name := Cur.Text;
    Advance;
    Exit(node);
  end;

  if Cur.Kind = tkKeyword then
  begin
    if Cur.Text = 'function' then
      Exit(ParseFuncExpr);
    if Cur.Text = 'class' then
      Exit(ParseClassExpr);
    if Cur.Text = 'this' then
    begin
      Advance;
      Exit(MkNode(nkThis));
    end;
    if Cur.Text = 'super' then
    begin
      Advance;
      Exit(MkNode(nkSuper));
    end;
    if Cur.Text = 'new' then
    begin
      Advance;
      if IsPunct('.') then
        ParseError('不支持 new.target');
      // 注意：无参方法自递归必须写 ()（FPC 裸名自递归会解析到错误符号）
      callee := ParsePrimary();
      // 仅成员链（不吞调用），随后可选实参
      while IsPunct('.') or IsPunct('[') do
      begin
        if Accept('.') then
        begin
          if not IsIdentLike then
            ParseError('属性名缺失');
          node := FProg.NewNode(nkMember, callee.Line, callee.Col);
          node.A := callee;
          node.Name := Cur.Text;
          Advance;
          callee := node;
        end
        else
        begin
          Advance;
          node := FProg.NewNode(nkMember, callee.Line, callee.Col);
          node.A := callee;
          node.B := ParseExpression;
          Include(node.Flags, nfComputed);
          Expect(']');
          callee := node;
        end;
      end;
      node := FProg.NewNode(nkNew, callee.Line, callee.Col);
      node.A := callee;
      if IsPunct('(') then
      begin
        args := ParseArguments;
        node.Items := args.Items;
      end;
      Exit(node);
    end;
    if Cur.Text = 'true' then
    begin
      node := MkNode(nkBool);
      node.Num := 1;
      Advance;
      Exit(node);
    end;
    if Cur.Text = 'false' then
    begin
      node := MkNode(nkBool);
      node.Num := 0;
      Advance;
      Exit(node);
    end;
    if Cur.Text = 'null' then
    begin
      Advance;
      Exit(MkNode(nkNull));
    end;
  end;

  ParseError('意外的记号 "' + Cur.Text + '"');
end;

function TXuiJsParser.ParseArrayLiteral: TXuiJsNode;
var
  item: TXuiJsNode;
begin
  Result := MkNode(nkArrayLit);
  Expect('[');
  while not IsPunct(']') do
  begin
    if CurKind = tkEOF then
      ParseError('数组未闭合');
    if Accept(',') then
    begin
      Result.AddItem(MkNode(nkEmpty));
      Continue;
    end;
    if Accept('...') then
    begin
      item := MkNode(nkSpread);
      item.A := ParseAssignment;
      Result.AddItem(item);
    end
    else
      Result.AddItem(ParseAssignment);
    if not Accept(',') then
      Break;
  end;
  Expect(']');
end;

function TXuiJsParser.ParsePropertyName(out AComputed: Boolean): string;
var
  expr: TXuiJsNode;
begin
  AComputed := False;
  if IsPunct('[') then
  begin
    AComputed := True;
    Advance;
    expr := ParseAssignment;   // 计算键：解析后由调用者按需处理
    Result := '';
    Expect(']');
    Exit;
  end;
  if CurKind = tkString then
  begin
    Result := Cur.Str;
    Advance;
    Exit;
  end;
  if CurKind = tkNumber then
  begin
    Result := FloatToStr(Cur.Num);
    Advance;
    Exit;
  end;
  Result := TakeIdentLike;
end;

function TXuiJsParser.ParseObjectLiteral: TXuiJsNode;
var
  prop, keyNode, value: TXuiJsNode;
  computed: Boolean;
  name: string;
  line, col: Integer;
begin
  Result := MkNode(nkObjectLit);
  Expect('{');
  while not IsPunct('}') do
  begin
    if CurKind = tkEOF then
      ParseError('对象字面量未闭合');
    if Accept('...') then
    begin
      prop := MkNode(nkSpread);
      prop.A := ParseAssignment;
      Result.AddItem(prop);
      if not Accept(',') then
        Break;
      Continue;
    end;
    // get/set 仅在“后面跟属性名”时才是访问器；`get()` 是名为 get 的方法
    if (IsKw('get') or IsKw('set')) and (not PunctAt(FIndex + 1, '(')) and
       (not PunctAt(FIndex + 1, ':')) then
      ParseError('不支持 get/set 访问器');
    line := Cur.Line;
    col := Cur.Col;
    name := ParsePropertyName(computed);
    prop := FProg.NewNode(nkProperty, line, col);
    prop.Name := name;
    if computed then
      Include(prop.Flags, nfComputed);
    if IsPunct('(') or IsPunct('<') then
    begin
      SkipTypeParamsIfAny;
      value := FProg.NewNode(nkFunc, line, col);
      value.Name := name;
      Include(value.Flags, nfMethod);
      value.A := ParseParams;
      if Accept(':') then
        SkipType(['{']);
      value.B := ParseBlock;
      prop.B := value;
      Include(prop.Flags, nfMethod);
    end
    else if Accept(':') then
    begin
      keyNode := FProg.NewNode(nkString, line, col);
      keyNode.Str := name;
      prop.A := keyNode;
      prop.B := ParseAssignment;
    end
    else
    begin
      keyNode := FProg.NewNode(nkString, line, col);
      keyNode.Str := name;
      prop.A := keyNode;
      value := FProg.NewNode(nkIdent, line, col);
      value.Name := name;
      prop.B := value;
      Include(prop.Flags, nfShorthand);
    end;
    Result.AddItem(prop);
    if not Accept(',') then
      Break;
  end;
  Expect('}');
end;

function TXuiJsParser.ParseTemplate: TXuiJsNode;
var
  node, part: TXuiJsNode;
begin
  node := MkNode(nkTemplate);
  if CurKind = tkTemplateNoSub then
  begin
    part := FProg.NewNode(nkString, Cur.Line, Cur.Col);
    part.Str := Cur.Str;
    node.AddItem(part);
    Advance;
    Exit(node);
  end;
  while True do
  begin
    part := FProg.NewNode(nkString, Cur.Line, Cur.Col);
    part.Str := Cur.Str;
    node.AddItem(part);
    if CurKind = tkTemplateTail then
    begin
      Advance;
      Break;
    end;
    if CurKind <> tkTemplateHead then
      ParseError('模板串片段缺失');
    Advance;  // head
    node.AddItem(ParseExpression);
    if CurKind = tkTemplateTail then
    begin
      part := FProg.NewNode(nkString, Cur.Line, Cur.Col);
      part.Str := Cur.Str;
      node.AddItem(part);
      Advance;
      Break;
    end;
    if CurKind <> tkTemplateMiddle then
      ParseError('模板串片段缺失');
  end;
  Result := node;
end;

function TXuiJsParser.ParseFuncExpr: TXuiJsNode;
var
  fn: TXuiJsNode;
begin
  Advance; // function
  if IsPunct('*') then
    ParseError('不支持生成器函数');
  fn := MkNode(nkFunc);
  if IsIdentLike then
  begin
    fn.Name := Cur.Text;
    Advance;
  end;
  SkipTypeParamsIfAny;
  fn.A := ParseParams;
  if Accept(':') then
    SkipType(['{']);
  fn.B := ParseBlock;
  Result := fn;
end;

function TXuiJsParser.ParseClassExpr: TXuiJsNode;
var
  cls: TXuiJsNode;
begin
  Advance; // class
  cls := MkNode(nkClass);
  if IsIdentLike then
  begin
    cls.Name := Cur.Text;
    Advance;
  end;
  SkipTypeParamsIfAny;
  cls.A := ParseClassMembers(cls);
  Result := cls;
end;

function TXuiJsParser.ParseArrowFromIdent: TXuiJsNode;
var
  fn, param: TXuiJsNode;
begin
  fn := MkNode(nkFunc);
  Include(fn.Flags, nfArrow);
  param := MkNode(nkIdent);
  param.Name := Cur.Text;
  Advance;
  Accept('?');
  if Accept(':') then
    SkipType(['=>']);
  fn.A := MkNode(nkSeq);
  fn.A.AddItem(param);
  Expect('=>');
  fn.B := ParseArrowBody;
  Result := fn;
end;

function TXuiJsParser.ParseArrowFromParams: TXuiJsNode;
var
  fn: TXuiJsNode;
begin
  fn := MkNode(nkFunc);
  Include(fn.Flags, nfArrow);
  fn.A := ParseParams;
  if Accept(':') then
    SkipType(['=>']);
  Expect('=>');
  fn.B := ParseArrowBody;
  Result := fn;
end;

function TXuiJsParser.ParseArrowOrGeneric: TXuiJsNode;
begin
  SkipTypeParamsIfAny;
  Result := ParseArrowFromParams;
end;

function TXuiJsParser.ParseArrowBody: TXuiJsNode;
begin
  if IsPunct('{') then
    Result := ParseBlock
  else
  begin
    Result := ParseAssignment;
  end;
end;

{ ---- 辅助 ---- }

function TXuiJsParser.IsAssignable(ANode: TXuiJsNode): Boolean;
begin
  Result := (ANode <> nil) and
    ((ANode.Kind = nkIdent) or (ANode.Kind = nkMember) or
     (ANode.Kind = nkArrayLit) or (ANode.Kind = nkObjectLit) or
     (ANode.Kind = nkArrayPat) or (ANode.Kind = nkObjectPat));
end;

function TXuiJsParser.ConvertToPattern(ANode: TXuiJsNode): TXuiJsNode;
var
  i: Integer;
  item: TXuiJsNode;
begin
  Result := ANode;
  if ANode = nil then
    Exit;
  case ANode.Kind of
    nkArrayLit:
      begin
        ANode.Kind := nkArrayPat;
        for i := 0 to ANode.ItemCount - 1 do
        begin
          item := ANode.Items[i];
          if item = nil then
            Continue;
          if item.Kind = nkSpread then
          begin
            item.Kind := nkRestPat;
            item.A := ConvertToPattern(item.A);
          end
          else
            ANode.Items[i] := ConvertToPattern(item);
        end;
      end;
    nkObjectLit:
      begin
        ANode.Kind := nkObjectPat;
        for i := 0 to ANode.ItemCount - 1 do
        begin
          item := ANode.Items[i];
          if item = nil then
            Continue;
          if item.Kind = nkSpread then
          begin
            item.Kind := nkRestPat;
            item.A := ConvertToPattern(item.A);
          end
          else if item.Kind = nkProperty then
            item.B := ConvertToPattern(item.B);
        end;
      end;
  end;
end;

function XuiJsParse(const ASource: string; const AFileName: string): TXuiJsProgram;
var
  parser: TXuiJsParser;
begin
  Result := TXuiJsProgram.Create(AFileName);
  try
    parser := TXuiJsParser.Create(Result, ASource);
    try
      Result.Root := parser.ParseProgram;
    finally
      parser.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
