unit xui_appspec;

{$mode objfpc}{$H+}

{ 应用清单与应用根（M12，ADR 48/49）。

  lui 的工程从"一堆文件约定"升级为"清单描述的应用"：应用根下放一个 lui.json，
  运行时的入口页、窗口、主题、组件库目录、构建输出全部由它描述——命令行只给
  应用根（或 exe 自己带着根，见 xui_bundle），不再需要 .cmd 里硬编码路径。

  为什么要独立一个单元：在这之前"根"是隐式的，代码里有三套互不相干的基准
  （<include>/<script src> 相对入口文档目录、ui.include/templateFile 相对脚本目录、
  <svg src> 相对当前工作目录），结果是打包产物必须 `cd pages` 才能跑。清单把
  "应用根"变成一个显式概念，所有相对引用都能锚定到同一个点。

  兼容：没有 lui.json 时回落到旧的 lui-project.json（M11 脚手架产物），字段一一映射；
  两者都没有时用目录约定推导默认值，所以"给个目录就能跑"仍然成立。

  注释里出现的 ADR 编号指 docs/M12-Electron式运行时重设计方案.md。 }

interface

uses
  Classes, SysUtils;

const
  XuiManifestName = 'lui.json';           // 新清单（首选）
  XuiManifestLegacy = 'lui-project.json'; // M11 旧清单（只读兼容）

type
  { 应用清单。字段都有默认值：清单缺项 / 缺文件都能装配出一个可运行的应用。 }
  TXuiAppSpec = class
  private
    FMap: TStringList;        // 扁平键值：Key -> 类型字符 + 原文
    FKind: string;            // 'lui.json' / 'lui-project.json' / '默认'
    function Val(const AKey: string): string;              // 类型字符
    function Raw(const AKey: string): string;              // 原文（无类型字符）
    function GetStr(const AKey, ADef: string): string;
    function GetInt(const AKey: string; ADef: Integer): Integer;
    function GetFlag(const AKey: string; ADef: Boolean): Boolean;
    procedure GetArr(const AKey: string; AInto: TStringList);
    procedure ApplyDefaults;
    procedure NoteDefaults;
  public
    Root: string;             // 应用根（绝对路径，清单所在目录）
    ManifestFile: string;     // 实际使用的清单文件（绝对路径；不存在时为拟用路径）
    Name: string;
    DisplayName: string;
    Version: string;
    Main: string;             // 入口页面（应用根相对路径）
    UiDir: string;            // 组件库目录（应用根相对路径）
    WindowWidth: Integer;
    WindowHeight: Integer;
    WindowTitle: string;
    Theme: string;            // 默认主题 light / dark
    Resizable: Boolean;
    Center: Boolean;
    Frameless: Boolean;
    Watch: Boolean;           // dev 模式是否默认监听
    BuildOut: string;         // build/pack 输出目录（应用根相对路径）
    Styles: TStringList;      // 清单声明的附加样式（应用根相对路径，与主题无关）
    Exclude: TStringList;     // 构建排除的目录/文件（应用根相对路径）
    Assets: TStringList;      // 构建强制包含的额外资源（应用根相对路径）
    Warnings: TStringList;    // 装配期间的提示（清单缺项/路径不存在）

    constructor Create;
    destructor Destroy; override;

    { 从应用根加载清单；文件缺失也返回 True（用默认值），只有清单语法错误才 False。 }
    function Load(const ARootDir: string): Boolean;
    function Kind: string;

    { 应用根相对的路径 → 绝对路径（已是绝对路径则原样返回）。 }
    function PathOf(const ARel: string): string;
    function Entry: string;                       // 入口页面的绝对路径
    function UiIndex: string;                     // <UiDir>/index.ts
    function UiTheme(const ATheme: string): string;  // <UiDir>/theme/lui-<theme>.css
    function Title: string;                       // 窗口标题：displayName > name > 目录名
    function DefaultTheme: string;                // light / dark
    { 入口页 + src/ 下的其它页面（供 check / build 逐页处理） }
    function Pages: TStringList;
  end;

{ 显式的应用根（自包含 exe 挂载根 / CLI --app-root）。非空时优先于一切磁盘查找。 }
var
  XuiAppRootOverride: string = '';

{ 从 APath（文件或目录）向上找含清单的目录；未找到返回 ''。 }
function XuiAppRootOf(const APath: string): string;

{ 自动装配：显式覆盖根 > 从 APath 向上找清单 > APath 自身作为默认根。 }
function XuiAppSpecAuto(const APath: string; out ASpec: TXuiAppSpec): Boolean;

{ 应用内资源路径解析（M12，ADR 49）：相对路径优先按应用根解析，未命中时原样返回，
  由调用方按旧语义（当前工作目录）处理——所以显式指定 --app-root 时才改变行为，
  不给"单独渲染一个 xml"的老用法添乱。 }
function XuiAppResourcePath(const ARel: string): string;

{ 应用内文件路径解析（M13）：与上面相反，这里必须给出**确定**的落点——写操作没有
  "没找到就回退"的余地。规则：绝对路径原样；相对路径在有应用根时锚定应用根，没有
  应用根时原样返回（按进程当前目录）。ui.fs 的全部操作都走这里。 }
function XuiAppPathResolve(const APath: string): string;

{ 只读清单里的一个标量（供 CLI 诊断用，失败返回 ADef）。 }
function XuiManifestScalar(const ARootDir, AKey, ADef: string): string;

implementation

const
  TypeStr = 's';
  TypeNum = 'n';
  TypeBool = 'b';
  TypeNull = 'x';

{ ---------- 极小 JSON 读取器（扁平化） ----------
  清单是扁平的键值集合，没必要建树：解析时把嵌套路径拍平成 'window.width'，
  数组拍成 'styles.0'、长度存 'styles.__len'。这样取值的代码是 O(n) 字符串查找，
  而不用为一堆嵌套 record 写样板。 }

type
  TFlatJson = class
  private
    FText: string;
    FPos: Integer;
    FMap: TStringList;
    function ChildPath(const APath, AKey: string): string;
    procedure SkipWs;
    function ParseString: string;
    procedure Put(const APath, AType, AValue: string);
    procedure ParseValue(const APath: string);
    procedure ParseObject(const APath: string);
    procedure ParseArray(const APath: string);
  public
    constructor Create(const AText: string; AMap: TStringList);
    function Parse: Boolean;   // 根必须是对象
  end;

function CodePointToUtf8(ACode: Integer): string; forward;

constructor TFlatJson.Create(const AText: string; AMap: TStringList);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
  FMap := AMap;
end;

function TFlatJson.ChildPath(const APath, AKey: string): string;
begin
  if APath = '' then
    Result := AKey
  else
    Result := APath + '.' + AKey;
end;

procedure TFlatJson.Put(const APath, AType, AValue: string);
begin
  if APath = '' then
    Exit;
  FMap.Values[APath] := AType + AValue;
end;

procedure TFlatJson.SkipWs;
begin
  while (FPos <= Length(FText)) and (FText[FPos] in [' ', #9, #10, #13]) do
    Inc(FPos);
end;

function TFlatJson.ParseString: string;
var
  code, i: Integer;

  function Hex4: Integer;
  var
    k, d: Integer;
    c: Char;
  begin
    Result := 0;
    for k := 1 to 4 do
    begin
      if FPos > Length(FText) then
        Exit;
      c := FText[FPos];
      case c of
        '0'..'9': d := Ord(c) - Ord('0');
        'a'..'f': d := Ord(c) - Ord('a') + 10;
        'A'..'F': d := Ord(c) - Ord('A') + 10;
      else
        Exit;
      end;
      Result := Result * 16 + d;
      Inc(FPos);
    end;
  end;

begin
  Result := '';
  if (FPos > Length(FText)) or (FText[FPos] <> '"') then
    Exit;
  Inc(FPos);
  while FPos <= Length(FText) do
  begin
    case FText[FPos] of
      '"':
        begin
          Inc(FPos);
          Exit;
        end;
      '\':
        begin
          Inc(FPos);
          if FPos > Length(FText) then
            Exit;
          case FText[FPos] of
            '"': Result := Result + '"';
            '\': Result := Result + '\';
            '/': Result := Result + '/';
            'b': Result := Result + #8;
            'f': Result := Result + #12;
            'n': Result := Result + #10;
            'r': Result := Result + #13;
            't': Result := Result + #9;
            'u':
              begin
                Inc(FPos);
                code := Hex4;
                if (code >= $D800) and (code <= $DBFF) then
                begin
                  // 代理对：合并成一个码点（清单里的中文通常是 BMP，这一步是保险）
                  if (FPos + 1 <= Length(FText)) and (FText[FPos] = '\') and
                     (FPos + 1 <= Length(FText)) and (FText[FPos + 1] = 'u') then
                  begin
                    Inc(FPos, 2);
                    i := Hex4;
                    if (i >= $DC00) and (i <= $DFFF) then
                      code := $10000 + ((code - $D800) shl 10) + (i - $DC00);
                  end
                  else
                    code := $FFFD;
                end;
                if code > 0 then
                  Result := Result + CodePointToUtf8(code);
                Continue;   // Hex4 已把 FPos 推到位，不要再 Inc
              end;
          else
            Result := Result + FText[FPos];
          end;
          Inc(FPos);
        end;
    else
      Result := Result + FText[FPos];
      Inc(FPos);
    end;
  end;
end;

procedure TFlatJson.ParseValue(const APath: string);
var
  start: Integer;
  ch: Char;
begin
  SkipWs;
  if FPos > Length(FText) then
    Exit;
  ch := FText[FPos];
  case ch of
    '{': ParseObject(APath);
    '[': ParseArray(APath);
    '"': Put(APath, TypeStr, ParseString);
    't':
      begin
        Inc(FPos, 4);
        Put(APath, TypeBool, '1');
      end;
    'f':
      begin
        Inc(FPos, 5);
        Put(APath, TypeBool, '0');
      end;
    'n':
      begin
        Inc(FPos, 4);
        Put(APath, TypeNull, '');
      end;
  else
    start := FPos;
    while (FPos <= Length(FText)) and (FText[FPos] in ['0'..'9', '+', '-', '.', 'e', 'E']) do
      Inc(FPos);
    if FPos > start then
      Put(APath, TypeNum, Copy(FText, start, FPos - start));
  end;
end;

procedure TFlatJson.ParseObject(const APath: string);
var
  key, cpath: string;
begin
  Inc(FPos);   // '{'
  SkipWs;
  if (FPos <= Length(FText)) and (FText[FPos] = '}') then
  begin
    Inc(FPos);
    Exit;
  end;
  while FPos <= Length(FText) do
  begin
    SkipWs;
    key := ParseString;
    SkipWs;
    if (FPos <= Length(FText)) and (FText[FPos] = ':') then
      Inc(FPos);
    cpath := ChildPath(APath, key);
    ParseValue(cpath);
    SkipWs;
    if (FPos <= Length(FText)) and (FText[FPos] = ',') then
    begin
      Inc(FPos);
      Continue;
    end;
    if (FPos <= Length(FText)) and (FText[FPos] = '}') then
      Inc(FPos);
    Exit;
  end;
end;

procedure TFlatJson.ParseArray(const APath: string);
var
  idx: Integer;
begin
  Inc(FPos);   // '['
  idx := 0;
  SkipWs;
  if (FPos <= Length(FText)) and (FText[FPos] = ']') then
  begin
    Inc(FPos);
    Put(APath + '.__len', TypeNum, '0');
    Exit;
  end;
  while FPos <= Length(FText) do
  begin
    ParseValue(ChildPath(APath, IntToStr(idx)));
    Inc(idx);
    SkipWs;
    if (FPos <= Length(FText)) and (FText[FPos] = ',') then
    begin
      Inc(FPos);
      Continue;
    end;
    if (FPos <= Length(FText)) and (FText[FPos] = ']') then
      Inc(FPos);
    Put(APath + '.__len', TypeNum, IntToStr(idx));
    Exit;
  end;
  Put(APath + '.__len', TypeNum, IntToStr(idx));
end;

function TFlatJson.Parse: Boolean;
begin
  Result := False;
  FMap.Clear;
  SkipWs;
  if (FPos > Length(FText)) or (FText[FPos] <> '{') then
    Exit;
  ParseObject('');
  Result := FMap.Count > 0;
end;

{ ---------- 读写工具 ---------- }

function ReadTextFile(const APath: string; out AText: string): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
begin
  Result := False;
  AText := '';
  if not FileExists(APath) then
    Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(buf, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(buf[0], fs.Size);
    finally
      fs.Free;
    end;
  except
    Exit;
  end;
  SetLength(AText, Length(buf));
  if Length(buf) > 0 then
    Move(buf[0], AText[1], Length(buf));
  // 容忍 BOM（用户手写清单时编辑器可能加）
  if (Length(AText) >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and (AText[3] = #$BF) then
    Delete(AText, 1, 3);
  Result := True;
end;

{ 码点 → UTF-8 字节串。本单元不依赖 LCL（引擎内核零 LCL 的分层约束），
  所以不使用 LazUTF8 的转换函数。 }
function CodePointToUtf8(ACode: Integer): string;
begin
  if ACode < $80 then
    Result := Chr(ACode)
  else if ACode < $800 then
    Result := Chr($C0 or (ACode shr 6)) + Chr($80 or (ACode and $3F))
  else if ACode < $10000 then
    Result := Chr($E0 or (ACode shr 12)) + Chr($80 or ((ACode shr 6) and $3F)) +
      Chr($80 or (ACode and $3F))
  else
    Result := Chr($F0 or (ACode shr 18)) + Chr($80 or ((ACode shr 12) and $3F)) +
      Chr($80 or ((ACode shr 6) and $3F)) + Chr($80 or (ACode and $3F));
end;

function ToSlash(const S: string): string;
begin
  Result := StringReplace(S, '\', '/', [rfReplaceAll]);
end;

function IsAbsolutePath(const S: string): Boolean;
begin
  Result := (Length(S) >= 2) and (S[2] = ':');
  if Result then
    Exit;
  Result := (Length(S) >= 1) and ((S[1] = '\') or (S[1] = '/'));
end;

{ ---------- TXuiAppSpec ---------- }

constructor TXuiAppSpec.Create;
begin
  inherited Create;
  FMap := TStringList.Create;
  FKind := '默认';
  Styles := TStringList.Create;
  Exclude := TStringList.Create;
  Assets := TStringList.Create;
  Warnings := TStringList.Create;
end;

destructor TXuiAppSpec.Destroy;
begin
  FMap.Free;
  Styles.Free;
  Exclude.Free;
  Assets.Free;
  Warnings.Free;
  inherited Destroy;
end;

function TXuiAppSpec.Val(const AKey: string): string;
var
  v: string;
begin
  v := FMap.Values[AKey];
  if v = '' then
    Result := TypeNull
  else
    Result := v[1];
end;

function TXuiAppSpec.Raw(const AKey: string): string;
var
  v: string;
begin
  v := FMap.Values[AKey];
  if Length(v) <= 1 then
    Result := ''
  else
    Result := Copy(v, 2, MaxInt);
end;

function TXuiAppSpec.GetStr(const AKey, ADef: string): string;
begin
  if (Val(AKey) = TypeStr) or (Val(AKey) = TypeNum) then
    Result := Raw(AKey)
  else
    Result := ADef;
end;

function TXuiAppSpec.GetInt(const AKey: string; ADef: Integer): Integer;
begin
  if Val(AKey) = TypeNum then
    Result := StrToIntDef(Raw(AKey), ADef)
  else if Val(AKey) = TypeStr then
    Result := StrToIntDef(Trim(Raw(AKey)), ADef)
  else
    Result := ADef;
end;

function TXuiAppSpec.GetFlag(const AKey: string; ADef: Boolean): Boolean;
var
  s: string;
begin
  case Val(AKey) of
    TypeBool: Result := Raw(AKey) = '1';
    TypeNum: Result := StrToIntDef(Raw(AKey), Ord(ADef)) <> 0;
    TypeStr:
      begin
        s := LowerCase(Trim(Raw(AKey)));
        Result := (s = 'true') or (s = '1') or (s = 'yes');
      end;
  else
    Result := ADef;
  end;
end;

procedure TXuiAppSpec.GetArr(const AKey: string; AInto: TStringList);
var
  n, i: Integer;
begin
  n := GetInt(AKey + '.__len', 0);
  for i := 0 to n - 1 do
  begin
    if Val(AKey + '.' + IntToStr(i)) = TypeStr then
      AInto.Add(Raw(AKey + '.' + IntToStr(i)));
  end;
end;

function TXuiAppSpec.Kind: string;
begin
  Result := FKind;
end;

function TXuiAppSpec.PathOf(const ARel: string): string;
var
  rel: string;
begin
  rel := Trim(ARel);
  if rel = '' then
    Exit('');
  if IsAbsolutePath(rel) then
    Exit(ExpandFileName(rel));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(Root) +
    StringReplace(rel, '/', PathDelim, [rfReplaceAll]));
end;

function TXuiAppSpec.Entry: string;
begin
  Result := PathOf(Main);
end;

function TXuiAppSpec.UiIndex: string;
begin
  Result := PathOf(UiDir + '/index.ts');
end;

function TXuiAppSpec.UiTheme(const ATheme: string): string;
begin
  Result := PathOf(UiDir + '/theme/lui-' + LowerCase(ATheme) + '.css');
end;

function TXuiAppSpec.Title: string;
begin
  if WindowTitle <> '' then
    Exit(WindowTitle);
  if DisplayName <> '' then
    Exit(DisplayName);
  if Name <> '' then
    Exit(Name);
  Result := ExtractFileName(ExcludeTrailingPathDelimiter(Root));
end;

function TXuiAppSpec.DefaultTheme: string;
begin
  if LowerCase(Theme) = 'dark' then
    Result := 'dark'
  else
    Result := 'light';
end;

function TXuiAppSpec.Pages: TStringList;
var
  sr: TSearchRec;
  dir: string;
begin
  Result := TStringList.Create;
  if FileExists(Entry) then
    Result.Add(Entry);
  dir := IncludeTrailingPathDelimiter(Root) + 'src';
  if FindFirst(dir + PathDelim + '*.xml', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then
        begin
          if Result.IndexOf(ExpandFileName(dir + PathDelim + sr.Name)) < 0 then
            Result.Add(ExpandFileName(dir + PathDelim + sr.Name));
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  if Result.Count = 0 then
    Result.Add(Entry);   // 不存在的入口也返回，让调用方给出"文件不存在"的诊断
end;

procedure TXuiAppSpec.ApplyDefaults;
begin
  if Name = '' then
    Name := ExtractFileName(ExcludeTrailingPathDelimiter(Root));
  if Version = '' then
    Version := '0.1.0';
  if UiDir = '' then
    UiDir := 'ui';
  if Main = '' then
  begin
    if FileExists(PathOf('src/main.xml')) then
      Main := 'src/main.xml'
    else
      Main := 'main.xml';
  end;
  if WindowWidth <= 0 then
    WindowWidth := 480;
  if WindowHeight <= 0 then
    WindowHeight := 560;
  if LowerCase(Theme) <> 'dark' then
    Theme := 'light'
  else
    Theme := 'dark';
  if BuildOut = '' then
    BuildOut := 'dist';
  if Exclude.IndexOf('out') < 0 then
    Exclude.Add('out');
  if Exclude.IndexOf('dist') < 0 then
    Exclude.Add('dist');
  if Exclude.IndexOf('.git') < 0 then
    Exclude.Add('.git');
  if Exclude.IndexOf('node_modules') < 0 then
    Exclude.Add('node_modules');
end;

procedure TXuiAppSpec.NoteDefaults;
begin
  Warnings.Clear;
  if not FileExists(ManifestFile) then
    Warnings.Add('未找到应用清单 ' + FKind + '，按目录约定推导（entry=' + Main + '）')
  else if FKind = XuiManifestLegacy then
    Warnings.Add('使用旧清单 lui-project.json；建议迁移到 lui.json（见 docs/M12）');
  if not FileExists(Entry) then
    Warnings.Add('入口页面不存在: ' + Main);
  if not FileExists(UiIndex) then
    Warnings.Add('组件库入口不存在: ' + ToSlash(UiDir) + '/index.ts');
end;

function TXuiAppSpec.Load(const ARootDir: string): Boolean;
var
  text, manifest: string;
  flat: TFlatJson;

  procedure LoadLegacy;
  begin
    // M11 清单：entry / viewport{width,height} / theme / styles / name / version
    Name := GetStr('name', '');
    Version := GetStr('version', '');
    Main := GetStr('entry', '');
    WindowWidth := GetInt('viewport.width', 0);
    WindowHeight := GetInt('viewport.height', 0);
    Theme := GetStr('theme', '');
    GetArr('styles', Styles);
  end;

begin
  Result := False;
  Root := ExpandFileName(ARootDir);
  FMap.Clear;
  Styles.Clear;
  Exclude.Clear;
  Assets.Clear;

  Name := '';
  DisplayName := '';
  Version := '';
  Main := '';
  UiDir := '';
  WindowWidth := 0;
  WindowHeight := 0;
  WindowTitle := '';
  Theme := '';
  Resizable := True;
  Center := True;
  Frameless := False;
  Watch := True;
  BuildOut := '';

  manifest := IncludeTrailingPathDelimiter(Root) + XuiManifestName;
  if FileExists(manifest) then
  begin
    FKind := XuiManifestName;
    if not ReadTextFile(manifest, text) then
      Exit;
    flat := TFlatJson.Create(text, FMap);
    try
      if not flat.Parse then
        Exit;   // 清单存在但语法不对：宁可报错，也不要静默用默认值
    finally
      flat.Free;
    end;
    Name := GetStr('name', '');
    DisplayName := GetStr('displayName', '');
    Version := GetStr('version', '');
    Main := GetStr('main', '');
    if Main = '' then
      Main := GetStr('entry', '');   // 兼容把 entry 写在新清单里的手改稿
    UiDir := GetStr('ui', '');
    WindowWidth := GetInt('window.width', 0);
    WindowHeight := GetInt('window.height', 0);
    WindowTitle := GetStr('window.title', '');
    Theme := GetStr('window.theme', '');
    if Theme = '' then
      Theme := GetStr('theme', '');
    Resizable := GetFlag('window.resizable', True);
    Center := GetFlag('window.center', True);
    Frameless := GetFlag('window.frameless', False);
    Watch := GetFlag('dev.watch', True);
    BuildOut := GetStr('build.out', '');
    GetArr('styles', Styles);
    GetArr('build.exclude', Exclude);
    GetArr('build.assets', Assets);
  end
  else
  begin
    manifest := IncludeTrailingPathDelimiter(Root) + XuiManifestLegacy;
    if FileExists(manifest) then
    begin
      FKind := XuiManifestLegacy;
      if not ReadTextFile(manifest, text) then
        Exit;
      flat := TFlatJson.Create(text, FMap);
      try
        if not flat.Parse then
          Exit;
      finally
        flat.Free;
      end;
      LoadLegacy;
    end
    else
      FKind := '默认';
  end;

  ManifestFile := manifest;
  ApplyDefaults;
  NoteDefaults;
  Result := True;
end;

{ ---------- 定位 ---------- }

function DirHasManifest(const ADir: string): Boolean;
begin
  Result := FileExists(IncludeTrailingPathDelimiter(ADir) + XuiManifestName) or
    FileExists(IncludeTrailingPathDelimiter(ADir) + XuiManifestLegacy);
end;

function XuiAppRootOf(const APath: string): string;
var
  dir: string;
begin
  Result := '';
  if APath = '' then
    Exit;
  if FileExists(APath) then
    dir := ExtractFileDir(ExpandFileName(APath))
  else
    dir := ExpandFileName(APath);
  if not DirectoryExists(dir) then
  begin
    // 给的是还不存在的产出路径：退到它的父目录再往上找
    dir := ExtractFileDir(dir);
  end;
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if DirHasManifest(dir) then
      Exit(dir);
    dir := ExtractFileDir(dir);
  end;
end;

function XuiAppSpecAuto(const APath: string; out ASpec: TXuiAppSpec): Boolean;
var
  root: string;
begin
  Result := False;
  ASpec := nil;
  root := XuiAppRootOverride;
  if root = '' then
    root := XuiAppRootOf(APath);
  if root = '' then
  begin
    // 没有任何清单：把 APath 自身（或其所在目录）当作默认根，仍可运行
    if (APath <> '') and DirectoryExists(APath) then
      root := ExpandFileName(APath)
    else if APath <> '' then
      root := ExtractFileDir(ExpandFileName(APath));
    if root = '' then
      root := GetCurrentDir;
  end;
  ASpec := TXuiAppSpec.Create;
  if not ASpec.Load(root) then
  begin
    ASpec.Free;
    ASpec := nil;
    Exit;
  end;
  Result := True;
end;

function XuiAppResourcePath(const ARel: string): string;
var
  cand: string;
begin
  Result := ARel;
  if Trim(ARel) = '' then
    Exit;
  if IsAbsolutePath(ARel) then
    Exit;
  if XuiAppRootOverride = '' then
    Exit;
  cand := IncludeTrailingPathDelimiter(XuiAppRootOverride) +
    StringReplace(ARel, '/', PathDelim, [rfReplaceAll]);
  if FileExists(cand) then
    Result := cand;
end;

function XuiAppPathResolve(const APath: string): string;
begin
  Result := APath;
  if Trim(APath) = '' then
    Exit;
  if IsAbsolutePath(APath) then
    Exit;
  if XuiAppRootOverride = '' then
    Exit;
  Result := IncludeTrailingPathDelimiter(XuiAppRootOverride) +
    StringReplace(APath, '/', PathDelim, [rfReplaceAll]);
end;

function XuiManifestScalar(const ARootDir, AKey, ADef: string): string;
var
  text: string;
  map: TStringList;
  flat: TFlatJson;
begin
  Result := ADef;
  if not ReadTextFile(IncludeTrailingPathDelimiter(ARootDir) + XuiManifestName, text) then
    Exit;
  map := TStringList.Create;
  flat := TFlatJson.Create(text, map);
  try
    if flat.Parse then
    begin
      if map.Values[AKey] <> '' then
        Result := Copy(map.Values[AKey], 2, MaxInt);
    end;
  finally
    flat.Free;
    map.Free;
  end;
end;

end.
