unit xui_css_token;

{$mode objfpc}{$H+}

{ CSS 词法分析器（v1 子集）。
  覆盖：标识符、字符串、数字/百分比/带单位数值、#名、括号与结构符号。
  注释 /* */ 与空白被跳过。数值类 token 的 Text 保留原始写法（如 "4px"、"50%"）。 }

interface

uses
  SysUtils, Classes;

type
  TCssTokenKind = (
    ctkEOF,
    ctkWhitespace, // 连续空白（后代组合器依据）
    ctkIdent,      // 标识符（属性名/关键字/选择器名）
    ctkString,     // 引号字符串（Text 不含引号）
    ctkNumber,     // 纯数字（Text 为原始写法）
    ctkPercent,    // 数字%
    ctkDimension,  // 数字+单位（4px / 1.5em），Number+UnitName 有效
    ctkHash,       // #名（颜色或 id 选择器）
    ctkColon,      // :
    ctkSemicolon,  // ;
    ctkLBrace,     // {
    ctkRBrace,     // }
    ctkComma,      // ,
    ctkGreater,    // >
    ctkDot,        // .
    ctkStar,       // *
    ctkLParen,     // (
    ctkRParen,     // )
    ctkAt,         // @
    ctkOther       // 其它单字符（Text 承载）
  );

  TCssToken = record
    Kind: TCssTokenKind;
    Text: string;     // 原始文本（string 类型已去引号）
    Number: Double;   // Number/Percent/Dimension 的数值
    UnitStr: string; // Dimension 的单位（小写）
  end;

  TCssLexer = class
  private
    FText: string;
    FPos: Integer; // 1-based；FPos > Length 表示结束
    function PeekChar: Char; inline;
    function ReadChar: Char; inline;
    function IsIdentStart(c: Char): Boolean; inline;
    function IsIdentChar(c: Char): Boolean; inline;
    function ReadIdentName: string;
  public
    constructor Create(const AText: string);
    function Next: TCssToken;
    function Offset: Integer; inline; // 当前读取位置（从 1 起）
  end;

implementation

function IsSpace(c: Char): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13);
end;

{ TCssLexer }

constructor TCssLexer.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
end;

function TCssLexer.PeekChar: Char;
begin
  if FPos <= Length(FText) then
    Result := FText[FPos]
  else
    Result := #0;
end;

function TCssLexer.ReadChar: Char;
begin
  if FPos <= Length(FText) then
  begin
    Result := FText[FPos];
    Inc(FPos);
  end
  else
    Result := #0;
end;

function TCssLexer.IsIdentStart(c: Char): Boolean;
begin
  Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
    (c = '_') or (c = '-') or (Ord(c) > 127);
end;

function TCssLexer.IsIdentChar(c: Char): Boolean;
begin
  Result := IsIdentStart(c) or ((c >= '0') and (c <= '9'));
end;

function TCssLexer.ReadIdentName: string;
var
  start: Integer;
begin
  start := FPos;
  while (FPos <= Length(FText)) and IsIdentChar(FText[FPos]) do
    Inc(FPos);
  Result := Copy(FText, start, FPos - start);
end;

function TCssLexer.Next: TCssToken;
var
  c: Char;
  start: Integer;
  numStr, unitStr: string;
  code: Integer;
  numVal: Double;
begin
  // 空白折叠为一个 token；注释静默跳过
  while True do
  begin
    c := PeekChar;
    if IsSpace(c) then
    begin
      while IsSpace(PeekChar) do
        ReadChar;
      Result.Kind := ctkWhitespace;
      Result.Text := ' ';
      Result.Number := 0;
      Result.UnitStr := '';
      Exit;
    end;
    if (c = '/') and (FPos < Length(FText)) and (FText[FPos + 1] = '*') then
    begin
      ReadChar; ReadChar;
      while FPos <= Length(FText) do
      begin
        if (FText[FPos] = '*') and (FPos < Length(FText)) and (FText[FPos + 1] = '/') then
        begin
          ReadChar; ReadChar;
          Break;
        end;
        ReadChar;
      end;
      Continue;
    end;
    Break;
  end;

  Result.Kind := ctkEOF;
  Result.Text := '';
  Result.Number := 0;
  Result.UnitStr := '';

  c := PeekChar;
  if c = #0 then
    Exit;

  start := FPos;

  // 结构符号
  case c of
    '{': begin ReadChar; Result.Kind := ctkLBrace; Result.Text := '{'; Exit; end;
    '}': begin ReadChar; Result.Kind := ctkRBrace; Result.Text := '}'; Exit; end;
    ':': begin ReadChar; Result.Kind := ctkColon; Result.Text := ':'; Exit; end;
    ';': begin ReadChar; Result.Kind := ctkSemicolon; Result.Text := ';'; Exit; end;
    ',': begin ReadChar; Result.Kind := ctkComma; Result.Text := ','; Exit; end;
    '>': begin ReadChar; Result.Kind := ctkGreater; Result.Text := '>'; Exit; end;
    '.': begin ReadChar; Result.Kind := ctkDot; Result.Text := '.'; Exit; end;
    '*': begin ReadChar; Result.Kind := ctkStar; Result.Text := '*'; Exit; end;
    '(': begin ReadChar; Result.Kind := ctkLParen; Result.Text := '('; Exit; end;
    ')': begin ReadChar; Result.Kind := ctkRParen; Result.Text := ')'; Exit; end;
    '@': begin ReadChar; Result.Kind := ctkAt; Result.Text := '@'; Exit; end;
  end;

  // 字符串
  if (c = '"') or (c = '''') then
  begin
    ReadChar;
    while True do
    begin
      c := ReadChar;
      if c = #0 then Break;
      if c = '\' then
      begin
        ReadChar; // 跳过转义字符（简化处理）
        Continue;
      end;
      if c = '''' then
      begin
        if PeekChar = '''' then begin ReadChar; Continue; end; // '' 转义
        Break;
      end;
      if c = '"' then
      begin
        if PeekChar = '"' then begin ReadChar; Continue; end;
        Break;
      end;
    end;
    Result.Kind := ctkString;
    Result.Text := Copy(FText, start + 1, FPos - start - 2);
    Exit;
  end;

  // 数字 / 百分比 / 带单位
  if ((c >= '0') and (c <= '9')) or
     (((c = '-') or (c = '+') or (c = '.')) and
      (FPos < Length(FText)) and (FText[FPos + 1] >= '0') and (FText[FPos + 1] <= '9')) then
  begin
    if c = '-' then ReadChar; // 负号并入（FPC StrToFloat 处理 '-x'）
    if c = '+' then ReadChar;
    while (PeekChar >= '0') and (PeekChar <= '9') do
      ReadChar;
    if PeekChar = '.' then
    begin
      ReadChar;
      while (PeekChar >= '0') and (PeekChar <= '9') do
        ReadChar;
    end;
    numStr := Copy(FText, start, FPos - start);
    Val(numStr, numVal, code);

    if PeekChar = '%' then
    begin
      ReadChar;
      Result.Kind := ctkPercent;
      Result.Text := Copy(FText, start, FPos - start);
      Result.Number := numVal;
      Exit;
    end;
    if IsIdentStart(PeekChar) then
    begin
      unitStr := LowerCase(ReadIdentName);
      Result.Kind := ctkDimension;
      Result.Text := Copy(FText, start, FPos - start);
      Result.Number := numVal;
      Result.UnitStr := unitStr;
      Exit;
    end;
    Result.Kind := ctkNumber;
    Result.Text := numStr;
    Result.Number := numVal;
    Exit;
  end;

  // # 名（颜色 / id）
  if c = '#' then
  begin
    ReadChar;
    Result.Kind := ctkHash;
    Result.Text := ReadIdentName;
    Exit;
  end;

  // 标识符
  if IsIdentStart(c) then
  begin
    Result.Kind := ctkIdent;
    Result.Text := ReadIdentName;
    Exit;
  end;

  // 其它单字符
  ReadChar;
  Result.Kind := ctkOther;
  Result.Text := c;
end;

function TCssLexer.Offset: Integer;
begin
  Result := FPos;
end;

end.
