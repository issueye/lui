unit xui_js_token;

{$mode objfpc}{$H+}

{ TS/JS 词法分析（M6 脚本引擎第一层）。纯逻辑、不依赖 LCL，便于单元测试。

  覆盖：
  - 数字：十进制（含小数/指数）、0x / 0b / 0o、下划线分隔符
  - 字符串：单/双引号 + 常用转义（\n \t \r \b \f \v \0 \xHH \uHHHH \u 花括号形式、续行）
  - 模板串：反引号包围，美元花括号插值；词法层切成 头/中/尾 片段（表达式由解析器递归处理）
  - 标识符：ASCII 字母/下划线/美元符 + 任意非 ASCII 字节（支持中文标识符）
  - 注释：行注释与块注释
  - 运算符/标点：最长匹配

  刻意不支持：正则字面量（斜杠一律按除号处理）；BigInt 后缀（报错） }

interface

uses
  SysUtils, Math;

type
  TXuiJsTokenKind = (
    tkEOF,
    tkNumber,         // Num
    tkString,         // Str（已解转义）
    tkIdent,          // Text
    tkKeyword,        // Text（原文；判定用 XuiJsIsKeyword）
    tkPunct,          // Text
    tkTemplateNoSub,  // Str：无插值的整段模板
    tkTemplateHead,   // Str：模板头（后面跟一个表达式）
    tkTemplateMiddle, // Str：模板中段（后面跟一个表达式）
    tkTemplateTail    // Str：模板尾（模板结束）
  );

  TXuiJsToken = record
    Kind: TXuiJsTokenKind;
    Text: string;            // 标识符/关键字/标点原文
    Str: string;             // 字符串或模板片段的值
    Num: Double;             // 数字
    Line, Col: Integer;      // 1 基
    NewlineBefore: Boolean;  // 之前有换行（ASI 判定）
    Adjacent: Boolean;       // 与前一 token 之间无空白/注释（TS 非空断言判定）
  end;

  TXuiJsTokens = array of TXuiJsToken;

  EXuiJsSyntaxError = class(Exception)
  public
    Line, Col: Integer;
    constructor Create(const AMsg: string; ALine, ACol: Integer);
  end;

// 关键字判定（大小写敏感；含 TS 与 ES6 保留字，供解析器给"不支持"的明确报错）
function XuiJsIsKeyword(const AWord: string): Boolean;

type
  TXuiJsLexer = class
  private
    FSrc: string;
    FPos: Integer;           // 1 基
    FLine, FCol: Integer;
    FTokens: TXuiJsTokens;
    FCount: Integer;
    FTemplateStack: array of Integer;  // 模板表达式内的 `{` 深度栈
    FResumeTemplate: Boolean;          // 上一个 `}` 是模板闭合，需继续扫描模板片段
    function Cur: Char; inline;
    function At(AOffset: Integer): Char; inline;
    function Eof: Boolean; inline;
    procedure Advance; inline;
    procedure Emit(AKind: TXuiJsTokenKind; ALine, ACol: Integer);
    procedure LexError(const AMsg: string; ALine, ACol: Integer);
    procedure SkipTrivia(out ANewline, AAny: Boolean);
    procedure ScanNumber;
    procedure ScanString(AQuote: Char);
    procedure ScanTemplateChunk;   // 扫描一段模板字面量（从 ` 后 或 } 后开始）
    procedure ScanIdent;
    procedure ScanPunct;
    procedure Tokenize;
  public
    constructor Create(const ASource: string);
    property Tokens: TXuiJsTokens read FTokens;
    property Count: Integer read FCount;
  end;

implementation

constructor EXuiJsSyntaxError.Create(const AMsg: string; ALine, ACol: Integer);
begin
  inherited CreateFmt('%s（第 %d 行 第 %d 列）', [AMsg, ALine, ACol]);
  Line := ALine;
  Col := ACol;
end;

const
  Keywords: array[0..57] of string = (
    // ES 关键字
    'var', 'let', 'const', 'function', 'return', 'if', 'else', 'while', 'do', 'for',
    'in', 'of', 'break', 'continue', 'new', 'delete', 'typeof', 'instanceof', 'void',
    'this', 'super', 'class', 'extends', 'static', 'get', 'set', 'constructor',
    'null', 'true', 'false', 'throw', 'try', 'catch', 'finally', 'switch', 'case',
    'default', 'export', 'import', 'yield', 'async', 'await', 'debugger', 'with',
    // TS 关键字（多数用于类型擦除或明确报"不支持"；刻意不含 is/out/infer 等可作标识符的词）
    'interface', 'type', 'enum', 'as', 'public', 'private', 'protected', 'readonly',
    'declare', 'module', 'namespace', 'abstract', 'implements', 'keyof');

function XuiJsIsKeyword(const AWord: string): Boolean;
var
  i: Integer;
begin
  for i := Low(Keywords) to High(Keywords) do
    if Keywords[i] = AWord then
      Exit(True);
  Result := False;
end;

function IsIdentStartChar(C: Char): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    (C = '_') or (C = '$') or (Byte(C) >= $80);
end;

function IsIdentPartChar(C: Char): Boolean; inline;
begin
  Result := IsIdentStartChar(C) or ((C >= '0') and (C <= '9'));
end;

function IsDigitChar(C: Char): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

function IsHexChar(C: Char): Boolean; inline;
begin
  Result := IsDigitChar(C) or ((C >= 'a') and (C <= 'f')) or ((C >= 'A') and (C <= 'F'));
end;

function HexValue(C: Char): Integer; inline;
begin
  if IsDigitChar(C) then
    Result := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    Result := Ord(C) - Ord('a') + 10
  else
    Result := Ord(C) - Ord('A') + 10;
end;

{ TXuiJsLexer }

constructor TXuiJsLexer.Create(const ASource: string);
begin
  inherited Create;
  FSrc := ASource;
  FPos := 1;
  FLine := 1;
  FCol := 1;
  FCount := 0;
  SetLength(FTokens, 0);
  SetLength(FTemplateStack, 0);
  FResumeTemplate := False;
  Tokenize;
end;

function TXuiJsLexer.Cur: Char;
begin
  if FPos <= Length(FSrc) then
    Result := FSrc[FPos]
  else
    Result := #0;
end;

function TXuiJsLexer.At(AOffset: Integer): Char;
var
  p: Integer;
begin
  p := FPos + AOffset;
  if (p >= 1) and (p <= Length(FSrc)) then
    Result := FSrc[p]
  else
    Result := #0;
end;

function TXuiJsLexer.Eof: Boolean;
begin
  Result := FPos > Length(FSrc);
end;

procedure TXuiJsLexer.Advance;
begin
  if FPos > Length(FSrc) then
    Exit;
  if FSrc[FPos] = #10 then
  begin
    Inc(FLine);
    FCol := 1;
  end
  else if (FSrc[FPos] = #13) and (At(1) <> #10) then
  begin
    Inc(FLine);
    FCol := 1;
  end
  else
    Inc(FCol);
  Inc(FPos);
end;

procedure TXuiJsLexer.Emit(AKind: TXuiJsTokenKind; ALine, ACol: Integer);
begin
  if FCount >= Length(FTokens) then
    SetLength(FTokens, FCount * 2 + 64);
  FTokens[FCount].Kind := AKind;
  FTokens[FCount].Text := '';
  FTokens[FCount].Str := '';
  FTokens[FCount].Num := 0;
  FTokens[FCount].Line := ALine;
  FTokens[FCount].Col := ACol;
  FTokens[FCount].NewlineBefore := False;
  FTokens[FCount].Adjacent := False;
  Inc(FCount);
end;

procedure TXuiJsLexer.LexError(const AMsg: string; ALine, ACol: Integer);
begin
  raise EXuiJsSyntaxError.Create(AMsg, ALine, ACol);
end;

procedure TXuiJsLexer.SkipTrivia(out ANewline, AAny: Boolean);
begin
  ANewline := False;
  AAny := False;
  while not Eof do
  begin
    if (Cur = ' ') or (Cur = #9) or (Cur = #11) or (Cur = #12) then
    begin
      AAny := True;
      Advance;
    end
    else if (Cur = #10) or (Cur = #13) then
    begin
      AAny := True;
      ANewline := True;
      Advance;
    end
    else if (Cur = '/') and (At(1) = '/') then
    begin
      AAny := True;
      while (not Eof) and (Cur <> #10) and (Cur <> #13) do
        Advance;
    end
    else if (Cur = '/') and (At(1) = '*') then
    begin
      AAny := True;
      Advance;
      Advance;
      while (not Eof) and not ((Cur = '*') and (At(1) = '/')) do
        Advance;
      if not Eof then
      begin
        Advance;
        Advance;
      end;
    end
    else
      Break;
  end;
end;

procedure TXuiJsLexer.ScanNumber;
var
  s: string;
  line0, col0, base: Integer;
  isFloat: Boolean;
  d: Double;
begin
  line0 := FLine;
  col0 := FCol;
  s := '';
  base := 10;
  isFloat := False;

  if (Cur = '0') and ((At(1) = 'x') or (At(1) = 'X')) then
  begin
    base := 16;
    Advance;
    Advance;
  end
  else if (Cur = '0') and ((At(1) = 'b') or (At(1) = 'B')) then
  begin
    base := 2;
    Advance;
    Advance;
  end
  else if (Cur = '0') and ((At(1) = 'o') or (At(1) = 'O')) then
  begin
    base := 8;
    Advance;
    Advance;
  end;

  while not Eof do
  begin
    if Cur = '_' then
      Advance
    else if IsDigitChar(Cur) then
    begin
      s := s + Cur;
      Advance;
    end
    else if (base = 16) and IsHexChar(Cur) then
    begin
      s := s + Cur;
      Advance;
    end
    else if (base = 10) and (Cur = '.') and IsDigitChar(At(1)) then
    begin
      isFloat := True;
      s := s + '.';
      Advance;
    end
    else if (base = 10) and ((Cur = 'e') or (Cur = 'E')) and
            (IsDigitChar(At(1)) or ((At(1) = '+') or (At(1) = '-')) and IsDigitChar(At(2))) then
    begin
      isFloat := True;
      s := s + 'e';
      Advance;
      if (Cur = '+') or (Cur = '-') then
      begin
        s := s + Cur;
        Advance;
      end;
    end
    else
      Break;
  end;

  if Cur = '.' then
  begin
    // 尾随小数点：1. 视为浮点
    isFloat := True;
    s := s + '.';
    Advance;
    while (not Eof) and (IsDigitChar(Cur) or (Cur = '_')) do
    begin
      if Cur <> '_' then
        s := s + Cur;
      Advance;
    end;
  end;

  if Cur = 'n' then
    LexError('不支持 BigInt 字面量', FLine, FCol);

  if s = '' then
    LexError('数字字面量不完整', line0, col0);

  if base = 10 then
    d := StrToFloatDef(s, 0)
  else
    d := StrToInt64Def('$' + s, 0);
  if base = 2 then
    d := StrToInt64Def(s, 0);
  if base = 8 then
    d := StrToInt64Def(s, 0);

  Emit(tkNumber, line0, col0);
  FTokens[FCount - 1].Num := d;
end;

procedure TXuiJsLexer.ScanString(AQuote: Char);
var
  line0, col0: Integer;
  s: string;
  c: Char;
  code, n, i: Integer;
begin
  line0 := FLine;
  col0 := FCol;
  Advance; // 开引号
  s := '';
  while True do
  begin
    if Eof then
      LexError('字符串未闭合', line0, col0);
    c := Cur;
    if c = AQuote then
    begin
      Advance;
      Break;
    end;
    if c = #10 then
      LexError('字符串中不能直接换行', FLine, FCol);
    if c = '\' then
    begin
      Advance;
      if Eof then
        LexError('字符串未闭合', line0, col0);
      c := Cur;
      case c of
        'n': begin s := s + #10; Advance; end;
        'r': begin s := s + #13; Advance; end;
        't': begin s := s + #9; Advance; end;
        'b': begin s := s + #8; Advance; end;
        'f': begin s := s + #12; Advance; end;
        'v': begin s := s + #11; Advance; end;
        '0': begin s := s + #0; Advance; end;
        'x':
          begin
            Advance;
            code := 0;
            n := 0;
            while (n < 2) and (not Eof) and IsHexChar(Cur) do
            begin
              code := code * 16 + HexValue(Cur);
              Advance;
              Inc(n);
            end;
            s := s + Char(code);
          end;
        'u':
          begin
            Advance;
            if Cur = '{' then
            begin
              Advance;
              code := 0;
              while (not Eof) and (Cur <> '}') and IsHexChar(Cur) do
              begin
                code := code * 16 + HexValue(Cur);
                Advance;
              end;
              if Cur = '}' then
                Advance;
            end
            else
            begin
              code := 0;
              for i := 1 to 4 do
                if (not Eof) and IsHexChar(Cur) then
                begin
                  code := code * 16 + HexValue(Cur);
                  Advance;
                end;
            end;
            s := s + UTF8Encode(UnicodeString(WideChar(code)));
          end;
        #10: Advance;  // 续行
        #13: Advance;
      else
        s := s + c;
        Advance;
      end;
    end
    else
    begin
      s := s + c;
      Advance;
    end;
  end;
  Emit(tkString, line0, col0);
  FTokens[FCount - 1].Str := s;
end;

// 从当前位置（` 之后 或 模板表达式 } 之后）扫描一段模板字面量
procedure TXuiJsLexer.ScanTemplateChunk;
var
  line0, col0: Integer;
  s: string;
  c: Char;
begin
  line0 := FLine;
  col0 := FCol;
  s := '';
  while True do
  begin
    if Eof then
      LexError('模板串未闭合', line0, col0);
    c := Cur;
    if c = '`' then
    begin
      Advance;
      if Length(FTemplateStack) = 0 then
      begin
        Emit(tkTemplateNoSub, line0, col0);
        FTokens[FCount - 1].Str := s;
      end
      else
      begin
        Emit(tkTemplateTail, line0, col0);
        FTokens[FCount - 1].Str := s;
        SetLength(FTemplateStack, Length(FTemplateStack) - 1);
      end;
      Exit;
    end;
    if (c = '$') and (At(1) = '{') then
    begin
      Advance;
      Advance;
      if Length(FTemplateStack) = 0 then
      begin
        Emit(tkTemplateHead, line0, col0);
        FTokens[FCount - 1].Str := s;
      end
      else
      begin
        Emit(tkTemplateMiddle, line0, col0);
        FTokens[FCount - 1].Str := s;
      end;
      SetLength(FTemplateStack, Length(FTemplateStack) + 1);
      FTemplateStack[Length(FTemplateStack) - 1] := 0;
      Exit;
    end;
    if c = '\' then
    begin
      // 模板内的转义：复用字符串转义规则（简化为常用几种）
      Advance;
      if Eof then
        LexError('模板串未闭合', line0, col0);
      case Cur of
        'n': s := s + #10;
        'r': s := s + #13;
        't': s := s + #9;
        '`': s := s + '`';
        '$': s := s + '$';
        '\': s := s + '\';
      else
        s := s + '\' + Cur;
      end;
      Advance;
    end
    else
    begin
      s := s + c;
      Advance;
    end;
  end;
end;

procedure TXuiJsLexer.ScanIdent;
var
  line0, col0: Integer;
  s: string;
  isKw: Boolean;
begin
  line0 := FLine;
  col0 := FCol;
  s := '';
  while (not Eof) and IsIdentPartChar(Cur) do
  begin
    s := s + Cur;
    Advance;
  end;
  isKw := XuiJsIsKeyword(s);
  if isKw then
    Emit(tkKeyword, line0, col0)
  else
    Emit(tkIdent, line0, col0);
  FTokens[FCount - 1].Text := s;
end;

procedure TXuiJsLexer.ScanPunct;
const
  Puncts: array[0..47] of string = (
    '>>>=', '...', '===', '!==', '**=', '<<=', '>>=', '>>>', '&&=', '||=', '??=',
    '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--',
    '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '**', '<<', '>>',
    '+', '-', '*', '/', '%', '=', '<', '>', '!', '~', '&', '|', '^', '?', ':');
var
  line0, col0: Integer;
  i: Integer;
  p: string;
begin
  line0 := FLine;
  col0 := FCol;
  for i := Low(Puncts) to High(Puncts) do
  begin
    p := Puncts[i];
    if (FPos + Length(p) - 1 <= Length(FSrc)) and
       (Copy(FSrc, FPos, Length(p)) = p) then
    begin
      // `?.` 后跟数字时是 `?` + `.5`（避免把三元与小数混淆）
      if (p = '?.') and IsDigitChar(At(2)) then
        Continue;
      FPos := FPos + Length(p);
      FCol := FCol + Length(p);
      Emit(tkPunct, line0, col0);
      FTokens[FCount - 1].Text := p;
      Exit;
    end;
  end;
  // 单字符标点
  Emit(tkPunct, line0, col0);
  FTokens[FCount - 1].Text := Cur;
  Advance;
end;

procedure TXuiJsLexer.Tokenize;
var
  newline, any: Boolean;
  line0, col0: Integer;
  depth: Integer;
begin
  while True do
  begin
    SkipTrivia(newline, any);

    if FResumeTemplate then
    begin
      FResumeTemplate := False;
      ScanTemplateChunk;
      if FCount > 0 then
        FTokens[FCount - 1].NewlineBefore := newline;
      if FCount > 0 then
        FTokens[FCount - 1].Adjacent := not any;
      Continue;
    end;

    if Eof then
      Break;

    line0 := FLine;
    col0 := FCol;

    if Cur = '`' then
    begin
      Advance;
      ScanTemplateChunk;
    end
    else if (Cur = '"') or (Cur = '''') then
      ScanString(Cur)
    else if IsDigitChar(Cur) then
      ScanNumber
    else if (Cur = '.') and IsDigitChar(At(1)) then
      ScanNumber
    else if IsIdentStartChar(Cur) then
      ScanIdent
    else if Cur = '{' then
    begin
      if Length(FTemplateStack) > 0 then
        FTemplateStack[Length(FTemplateStack) - 1] :=
          FTemplateStack[Length(FTemplateStack) - 1] + 1;
      Emit(tkPunct, line0, col0);
      FTokens[FCount - 1].Text := '{';
      Advance;
    end
    else if Cur = '}' then
    begin
      if Length(FTemplateStack) > 0 then
      begin
        depth := FTemplateStack[Length(FTemplateStack) - 1];
        if depth = 0 then
        begin
          // 模板表达式的闭合：继续扫描模板片段
          Advance;
          FResumeTemplate := True;
          Continue;
        end;
        FTemplateStack[Length(FTemplateStack) - 1] := depth - 1;
      end;
      Emit(tkPunct, line0, col0);
      FTokens[FCount - 1].Text := '}';
      Advance;
    end
    else
      ScanPunct;

    if FCount > 0 then
    begin
      FTokens[FCount - 1].NewlineBefore := newline;
      FTokens[FCount - 1].Adjacent := not any;
    end;
  end;

  if Length(FTemplateStack) > 0 then
    LexError('模板串未闭合', FLine, FCol);
  Emit(tkEOF, FLine, FCol);
  SetLength(FTokens, FCount);
end;

end.
