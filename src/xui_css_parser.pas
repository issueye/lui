unit xui_css_parser;

{$mode objfpc}{$H+}

{ CSS 解析器（v1 子集）：
  规则集 = 选择器组 { 声明* }；@规则整体跳过；解析容错（坏声明/残片跳过继续）。
  选择器：类型 / * / #id / .class / :伪类，组合器 空格(后代) 与 >(子代)。
  特异性三元组 (SpecA=ID, SpecB=类+伪类, SpecC=类型) 在解析期计算。
  选择器组 (a, b {…}) 展开为多条规则（声明复制），便于匹配阶段逐条处理。 }

interface

uses
  Classes, SysUtils, Contnrs,
  xui_css_token;

type
  TCssCombinator = (ccDescendant, ccChild);

  TCssSelectorPart = class
  public
    Tag: string;      // '' 或 '*' 表示任意
    Id: string;
    Classes: TStringList;
    Pseudos: TStringList;
    Combinator: TCssCombinator; // 与前一个 part 的关系（首个 part 无意义）
    constructor Create;
    destructor Destroy; override;
  end;

  TCssSelector = class
  public
    Parts: TObjectList; // TCssSelectorPart，从左到右
    constructor Create;
    destructor Destroy; override;
  end;

  TCssDeclaration = record
    Prop: string;
    Value: string;
    Important: Boolean;
  end;

  TCssDeclArray = array of TCssDeclaration;

  TCssRule = class
  public
    Selector: TCssSelector;
    Declarations: array of TCssDeclaration;
    Order: Integer;       // 全局递增序（同特异性时后者胜）
    SpecA, SpecB, SpecC: Integer;
    destructor Destroy; override;
  end;

  TCssStyleSheet = class
  private
    FRules: TObjectList;
    function GetRuleCount: Integer; inline;
    function GetRule(AIndex: Integer): TCssRule; inline;
  public
    SourceFile: string;   // 来源文件（热重载监测用；来自字符串时为空）
    SourceMTime: Integer; // 加载时的文件时间戳（FileAge）
    constructor Create;
    destructor Destroy; override;
    procedure AddRule(ARule: TCssRule); // 获得所有权
    // 清空全部规则（热重载就地重解析前调用）
    procedure ClearRules;
    // 追加解析一段 CSS 文本（可多次调用合并多张表）
    procedure ParseStyleSheet(const AText: string);
    // 解析内联声明（style="" 属性）
    function ParseDeclarations(const AText: string): TCssDeclArray;
    property RuleCount: Integer read GetRuleCount;
    property Rules[AIndex: Integer]: TCssRule read GetRule; default;
  end;

implementation

type
  // 内部递归下降解析器（带一个 token 回看）
  TCssParser = class
  private
    FLexer: TCssLexer;
    FPeeked: Boolean;
    FPeek: TCssToken;
    FNextOrder: Integer;
    function NextToken: TCssToken;
    function PeekToken: TCssToken;
    procedure ParseCompound(APart: TCssSelectorPart);
    function ParseSelector: TCssSelector;   // 单条选择器链（不含逗号）
    procedure ComputeSpecificity(ARule: TCssRule);
    function ParseDeclarationList: TCssDeclArray;
  public
    constructor Create(const ASource: string);
    procedure ParseStyleSheet(AInto: TCssStyleSheet);
    function ParseInlineDeclarations: TCssDeclArray;
  end;

{ TCssSelectorPart }

constructor TCssSelectorPart.Create;
begin
  inherited Create;
  Classes := TStringList.Create;
  Classes.CaseSensitive := False;
  Pseudos := TStringList.Create;
  Pseudos.CaseSensitive := False;
end;

destructor TCssSelectorPart.Destroy;
begin
  Pseudos.Free;
  Classes.Free;
  inherited Destroy;
end;

{ TCssSelector }

constructor TCssSelector.Create;
begin
  inherited Create;
  Parts := TObjectList.Create(True);
end;

destructor TCssSelector.Destroy;
begin
  Parts.Free;
  inherited Destroy;
end;

{ TCssRule }

destructor TCssRule.Destroy;
begin
  Selector.Free;
  inherited Destroy;
end;

{ TCssStyleSheet }

constructor TCssStyleSheet.Create;
begin
  inherited Create;
  FRules := TObjectList.Create(True);
end;

destructor TCssStyleSheet.Destroy;
begin
  FRules.Free;
  inherited Destroy;
end;

function TCssStyleSheet.GetRuleCount: Integer;
begin
  Result := FRules.Count;
end;

function TCssStyleSheet.GetRule(AIndex: Integer): TCssRule;
begin
  Result := TCssRule(FRules[AIndex]);
end;

procedure TCssStyleSheet.AddRule(ARule: TCssRule);
begin
  FRules.Add(ARule);
end;

procedure TCssStyleSheet.ClearRules;
begin
  FRules.Clear;
end;

procedure TCssStyleSheet.ParseStyleSheet(const AText: string);
var
  parser: TCssParser;
begin
  parser := TCssParser.Create(AText);
  try
    parser.ParseStyleSheet(Self);
  finally
    parser.Free;
  end;
end;

function TCssStyleSheet.ParseDeclarations(const AText: string): TCssDeclArray;
var
  parser: TCssParser;
begin
  parser := TCssParser.Create(AText);
  try
    Result := parser.ParseInlineDeclarations;
  finally
    parser.Free;
  end;
end;

{ TCssParser }

constructor TCssParser.Create(const ASource: string);
begin
  inherited Create;
  FLexer := TCssLexer.Create(ASource);
  FPeeked := False;
  FNextOrder := 0;
end;

function TCssParser.NextToken: TCssToken;
begin
  if FPeeked then
  begin
    FPeeked := False;
    Result := FPeek;
  end
  else
    Result := FLexer.Next;
end;

function TCssParser.PeekToken: TCssToken;
begin
  if not FPeeked then
  begin
    FPeek := FLexer.Next;
    FPeeked := True;
  end;
  Result := FPeek;
end;

procedure TCssParser.ParseCompound(APart: TCssSelectorPart);
var
  t: TCssToken;
begin
  // 跳过前导空白（如 ",  .x" 或 "> .x" 之后）
  while PeekToken.Kind = ctkWhitespace do
    NextToken;

  // 前导类型 / *
  t := PeekToken;
  if t.Kind = ctkStar then
  begin
    NextToken;
    APart.Tag := '*';
  end
  else if t.Kind = ctkIdent then
  begin
    NextToken;
    APart.Tag := LowerCase(t.Text);
  end;

  // 修饰串 #id .class :pseudo
  while True do
  begin
    t := PeekToken;
    if t.Kind = ctkHash then
    begin
      NextToken;
      if t.Text <> '' then
        APart.Id := LowerCase(t.Text);
      Continue;
    end;
    if t.Kind = ctkDot then
    begin
      NextToken;
      t := NextToken;
      if t.Kind = ctkIdent then
        APart.Classes.Add(LowerCase(t.Text));
      Continue;
    end;
    if t.Kind = ctkColon then
    begin
      NextToken;
      t := NextToken;
      if t.Kind = ctkIdent then
        APart.Pseudos.Add(LowerCase(t.Text));
      Continue;
    end;
    Break;
  end;
end;

function TCssParser.ParseSelector: TCssSelector;
var
  part: TCssSelectorPart;
  t: TCssToken;
begin
  Result := TCssSelector.Create;

  part := TCssSelectorPart.Create;
  Result.Parts.Add(part);
  ParseCompound(part);

  // 组合器链（空白 token 是后代组合器的依据）
  while True do
  begin
    t := PeekToken;
    if t.Kind = ctkWhitespace then
    begin
      NextToken;
      t := PeekToken;
    end;
    case t.Kind of
      ctkGreater:
      begin
        NextToken;
        part := TCssSelectorPart.Create;
        part.Combinator := ccChild;
        Result.Parts.Add(part);
        ParseCompound(part);
      end;
      ctkIdent, ctkStar, ctkDot, ctkHash, ctkColon:
      begin
        // 空白后跟新的 compound → 后代组合器
        part := TCssSelectorPart.Create;
        part.Combinator := ccDescendant;
        Result.Parts.Add(part);
        ParseCompound(part);
      end;
    else
      Exit;
    end;
  end;
end;

procedure TCssParser.ComputeSpecificity(ARule: TCssRule);
var
  i: Integer;
  part: TCssSelectorPart;
begin
  ARule.SpecA := 0; ARule.SpecB := 0; ARule.SpecC := 0;
  for i := 0 to ARule.Selector.Parts.Count - 1 do
  begin
    part := TCssSelectorPart(ARule.Selector.Parts[i]);
    if part.Id <> '' then
      Inc(ARule.SpecA);
    Inc(ARule.SpecB, part.Classes.Count);
    Inc(ARule.SpecB, part.Pseudos.Count);
    if (part.Tag <> '') and (part.Tag <> '*') then
      Inc(ARule.SpecC);
  end;
end;

function TCssParser.ParseDeclarationList: TCssDeclArray;
var
  decls: TCssDeclArray;
  count: Integer;
  t: TCssToken;
  prop, value: string;
  words: TStringList;
  i, parenDepth: Integer;
  impl: Boolean;
begin
  count := 0;
  SetLength(decls, 0);
  words := TStringList.Create;
  try
    while True do
    begin
      t := NextToken;
      case t.Kind of
        ctkEOF:
          Break;
        ctkRBrace:
          Break; // 块结束（调用方已消费该 token）
        ctkSemicolon:
          Continue; // 空声明
        ctkWhitespace:
          Continue; // 声明间空白（token 已消费，不能再吃下一个）
        ctkColon:
          Continue; // 游离冒号：跳过
        ctkIdent:
        begin
          prop := LowerCase(t.Text);
          t := NextToken;
          if t.Kind <> ctkColon then
          begin
            // 坏声明：跳到 ';'（消费）或 '}' / EOF（不消费）
            while True do
            begin
              t := PeekToken;
              if t.Kind = ctkSemicolon then
              begin
                NextToken;
                Break;
              end;
              if (t.Kind = ctkRBrace) or (t.Kind = ctkEOF) then
                Break;
              NextToken;
            end;
            Continue;
          end;

          // 收集值 token 直到 ';' / '}' / EOF，括号配平（rgba(...)）
          words.Clear;
          parenDepth := 0;
          impl := False;
          while True do
          begin
            t := PeekToken;
            if t.Kind = ctkLParen then Inc(parenDepth);
            if t.Kind = ctkRParen then Dec(parenDepth);
            if (((t.Kind = ctkSemicolon) or (t.Kind = ctkRBrace)) and (parenDepth <= 0)) or
               (t.Kind = ctkEOF) then
              Break;
            if (t.Kind = ctkOther) and (t.Text = '!') then
            begin
              NextToken;
              t := PeekToken;
              if (t.Kind = ctkIdent) and SameText(t.Text, 'important') then
              begin
                NextToken;
                impl := True;
              end;
              Continue;
            end;
            NextToken;
            if t.Kind = ctkWhitespace then
              Continue; // 值内空白在拼接时统一补一个空格
            if t.Kind = ctkHash then
              words.Add('#' + t.Text) // 颜色值保留 #
            else
              words.Add(t.Text);
          end;

          value := '';
          for i := 0 to words.Count - 1 do
          begin
            if i > 0 then
              value := value + ' ';
            value := value + words[i];
          end;

          if count >= Length(decls) then
            SetLength(decls, count * 2 + 8);
          decls[count].Prop := prop;
          decls[count].Value := value;
          decls[count].Important := impl;
          Inc(count);
        end;
      else
        NextToken; // 非法内容：丢弃，继续
      end;
    end;
    SetLength(Result, count);
    for i := 0 to count - 1 do
      Result[i] := decls[i];
  finally
    words.Free;
  end;
end;

procedure TCssParser.ParseStyleSheet(AInto: TCssStyleSheet);
var
  t: TCssToken;
  rule: TCssRule;
  decls: TCssDeclArray;
  selectors: TObjectList; // TCssSelector 临时组（不拥有）
  i, j: Integer;
  inBrace: Boolean;
begin
  while True do
  begin
    t := PeekToken;
    if t.Kind = ctkEOF then
      Exit;
    if t.Kind = ctkWhitespace then
    begin
      NextToken;
      Continue;
    end;

    if t.Kind = ctkAt then
    begin
      // @规则：跳到 ';' 或配平的 {...} 块
      NextToken;
      inBrace := False;
      while True do
      begin
        t := NextToken;
        if t.Kind = ctkEOF then Break;
        if t.Kind = ctkLBrace then begin inBrace := True; Continue; end;
        if t.Kind = ctkRBrace then begin if inBrace then Break else Continue; end;
        if (t.Kind = ctkSemicolon) and (not inBrace) then Break;
      end;
      Continue;
    end;

    if t.Kind = ctkRBrace then
    begin
      NextToken; // 多余的 '}' 丢弃
      Continue;
    end;

    // 选择器组：sel1, sel2, ... （逗号展开为多条规则）
    selectors := TObjectList.Create(False);
    try
      while True do
      begin
        selectors.Add(ParseSelector);
        t := PeekToken;
        if t.Kind = ctkWhitespace then
        begin
          NextToken;
          t := PeekToken;
        end;
        if t.Kind = ctkComma then
        begin
          NextToken;
          Continue;
        end;
        Break;
      end;

      t := NextToken;
      if (t.Kind <> ctkLBrace) or (selectors.Count = 0) then
        Continue; // 残片：游离选择器由 finally 统一释放

      decls := ParseDeclarationList;
      for i := 0 to selectors.Count - 1 do
      begin
        rule := TCssRule.Create;
        rule.Selector := TCssSelector(selectors[i]);
        selectors[i] := nil; // 所有权转移给 rule
        SetLength(rule.Declarations, Length(decls));
        for j := 0 to High(decls) do
          rule.Declarations[j] := decls[j];
        rule.Order := FNextOrder;
        Inc(FNextOrder);
        ComputeSpecificity(rule);
        AInto.AddRule(rule);
      end;
    finally
      // 已转移的选择器为 nil，剩余（异常路径）在此释放
      for i := 0 to selectors.Count - 1 do
        if selectors[i] <> nil then
          TCssSelector(selectors[i]).Free;
      selectors.Free;
    end;
  end;
end;

function TCssParser.ParseInlineDeclarations: TCssDeclArray;
begin
  Result := ParseDeclarationList;
end;

end.
