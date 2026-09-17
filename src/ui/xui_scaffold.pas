unit xui_scaffold;

{$mode objfpc}{$H+}

{ 项目脚手架（M11）：`lui-render --init <目录>` 生成一个可直接开发 / 测试 / 打包 / 交付的
  lui 工程骨架。

  模板来源是仓库里的 scaffold/ 目录（真文件，不是 Pascal 字面量）——模板可读、可 diff、
  可被测试直接渲染。定位顺序（ADR 44）：
    1) 当前目录向上查找 scaffold/lui-project.json（仓库内开发）
    2) 可执行文件所在目录向上查找（打包分发目录 dist/lui/）
    3) 内嵌资源解包根（单程序版 lui-render-single.exe）
  组件库运行时取 scaffold/ 的同级 ui/ 目录，整树复制进新工程：生成即自带运行时，
  不依赖外部仓库（ADR 42）。

  占位符：模板中的 @@KEY@@ 在写入时替换。@@RUNTIME@@ 是运行时 exe 的原生路径
  （供 .cmd），@@RUNTIME_POSIX@@ 是正斜杠形式（供 .sh / .md）。

  M12 起模板以 lui.json 为标记文件（ADR 49）：清单不只是"这是不是 lui 工程"的记号，
  运行时真的会读它——入口页、窗口尺寸、主题、组件库目录、构建输出全在里面，所以
  .cmd 脚本不再需要记 <%ENTRY%>/<%THEME%>/<%WIDTH%> 这些要与模板同步的常量。

  写入策略：只写不改不删。目标目录已存在同名文件时默认跳过并保留；仅当显式 Force 才
  覆盖；任何情况下都不删除目标目录中的任何东西（ADR 43）。目标目录非空但不是 lui 工程
  时（没有 lui-project.json）默认拒绝写入，需 --force —— 避免误往任意目录里铺文件。
  换行：.cmd 写成 CRLF（cmd.exe 对 LF-only 的标签解析不可靠），其余统一 LF；
  一律按原始字节读写，不引入 BOM 与平台换行翻译。 }

interface

uses
  Classes, SysUtils;

type
  TXuiScaffoldOptions = record
    TargetDir: string;     // 目标目录（必需）
    Name: string;          // 工程名；空 = 取目标目录名
    Width: Integer;        // 视口宽；<=0 = 480
    Height: Integer;       // 视口高；<=0 = 560（起步页刚好放下，不留大片空白）
    Theme: string;         // light / dark / both；空 = light
    LuiVersion: string;    // 渲染器版本（写进清单与 README）
    RuntimePath: string;   // 写进脚本的运行时路径；空 = ParamStr(0)
    Force: Boolean;        // 覆盖已存在文件（默认跳过并保留）
    Verbose: Boolean;
  end;

  TXuiScaffoldResult = record
    Name: string;          // 最终采用的工程名（默认取目标目录名）
    Files: TStringList;    // 已写入（相对目标目录，'/' 分隔；调用方释放）
    Skipped: TStringList;  // 因已存在而保留（调用方释放）
    UiFiles: Integer;      // 复制的组件库运行时文件数
    TemplateRoot: string;  // 模板来源目录（诊断用）
    Error: string;         // 失败原因（中文；成功为空）
  end;

{ 生成工程。返回 False 时 AResult.Error 给出中文原因。 }
function XuiScaffoldCreate(const AOpts: TXuiScaffoldOptions;
  out AResult: TXuiScaffoldResult): Boolean;

{ 定位模板目录 scaffold/；未找到返回 '' }
function XuiScaffoldDir: string;

const
  XuiScaffoldProjectVersion = '0.1.0';

implementation

uses
  xui_embed;

const
  MarkerFile = 'lui.json';   // 模板目录与应用目录的识别标记（M12，ADR 49）

type
  TToken = record
    Key: string;
    Value: string;
  end;

function ToSlash(const S: string): string;
begin
  Result := StringReplace(S, '\', '/', [rfReplaceAll]);
end;

function ToNative(const S: string): string;
begin
  Result := StringReplace(S, '/', PathDelim, [rfReplaceAll]);
end;

function DirHasMarker(const ADir: string): Boolean;
begin
  Result := FileExists(IncludeTrailingPathDelimiter(ADir) + MarkerFile);
end;

{ 从 AStart 起逐级向上查找包含 scaffold/ 的目录，返回 scaffold 目录本身 }
function WalkUpForScaffold(const AStart: string): string;
var
  dir: string;
begin
  Result := '';
  dir := ExcludeTrailingPathDelimiter(AStart);
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if DirHasMarker(dir + PathDelim + 'scaffold') then
      Exit(dir + PathDelim + 'scaffold');
    dir := ExtractFileDir(dir);
  end;
end;

function XuiScaffoldDir: string;
var
  dir: string;
begin
  Result := WalkUpForScaffold(GetCurrentDir);
  if Result <> '' then
    Exit;
  Result := WalkUpForScaffold(ExtractFilePath(ExpandFileName(ParamStr(0))));
  if Result <> '' then
    Exit;
  dir := XuiEmbedRoot;
  if (dir <> '') and DirHasMarker(dir + PathDelim + 'scaffold') then
    Result := dir + PathDelim + 'scaffold';
end;

{ 递归收集目录下的文件（相对路径，'/' 分隔），结果排序保证可复现 }
procedure CollectFiles(const ARoot, ARel: string; AList: TStringList);
var
  sr: TSearchRec;
  dir, rel: string;
begin
  dir := IncludeTrailingPathDelimiter(ARoot);
  if ARel <> '' then
    dir := dir + ToNative(ARel) + PathDelim;
  if FindFirst(dir + '*', faAnyFile, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Name = '') or (sr.Name[1] = '.') then
        Continue;
      rel := sr.Name;
      if ARel <> '' then
        rel := ARel + '/' + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        CollectFiles(ARoot, rel, AList)
      else
        AList.Add(rel);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

{ 顶层条目数（"目录非空"判定） }
function TopLevelCount(const ADir: string): Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Name = '') or (sr.Name[1] = '.') then
        Continue;
      Inc(Result);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

{ 模板文件 → 输出名：末段 gitignore 还原为 .gitignore。
  模板自身不能叫 .gitignore，否则会被仓库 git 当成忽略规则作用到 scaffold/ 子树。 }
function OutputRelName(const ARel: string): string;
var
  p: Integer;
  base: string;
begin
  p := LastDelimiter('/', ARel);
  base := Copy(ARel, p + 1, MaxInt);
  if base = 'gitignore' then
    Result := Copy(ARel, 1, p) + '.gitignore'
  else
    Result := ARel;
end;

function IsTextFile(const AName: string): Boolean;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(AName));
  Result := (ext = '.xml') or (ext = '.css') or (ext = '.ts') or (ext = '.json') or
    (ext = '.md') or (ext = '.txt') or (ext = '.cmd') or (ext = '.sh');
end;

function Substitute(const AText: string; const ATokens: array of TToken): string;
var
  i: Integer;
begin
  Result := AText;
  for i := Low(ATokens) to High(ATokens) do
    Result := StringReplace(Result, '@@' + ATokens[i].Key + '@@', ATokens[i].Value,
      [rfReplaceAll]);
end;

function ReadRaw(const APath: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(Result[1], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure WriteRaw(const APath, AContent: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then
      fs.WriteBuffer(AContent[1], Length(AContent));
  finally
    fs.Free;
  end;
end;

procedure CopyRaw(const ASrc, ADest: string);
var
  src, dst: TFileStream;
  buf: array[0..65535] of Byte;
  n: LongInt;
begin
  src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    dst := TFileStream.Create(ADest, fmCreate);
    try
      repeat
        n := src.Read(buf, SizeOf(buf));
        if n > 0 then
          dst.WriteBuffer(buf, n);
      until n <= 0;
    finally
      dst.Free;
    end;
  finally
    src.Free;
  end;
end;

{ 目标目录准备。

  规则（ADR 43）：
    - 不存在 → 创建
    - 存在且是文件 → 报错
    - 存在且为空 → 直接生成
    - 存在且非空 → 只有当它看起来已经是本工具生成的工程（有 lui-project.json）时才继续，
      此时按"跳过已存在文件"写入（便于日后重跑以补齐新增文件）；否则要求 --force。
  这样既不往任意目录里乱写，也不会因为工程已经存在就挡住"补文件"这种正常诉求。 }
function PrepareTarget(const AOpts: TXuiScaffoldOptions; out AErr: string): Boolean;
var
  n: Integer;
  marker: string;
begin
  Result := False;
  AErr := '';
  if DirectoryExists(AOpts.TargetDir) then
  begin
    n := TopLevelCount(AOpts.TargetDir);
    marker := IncludeTrailingPathDelimiter(AOpts.TargetDir) + MarkerFile;
    if (n > 0) and (not AOpts.Force) and (not FileExists(marker)) then
    begin
      AErr := Format('目标目录已存在 %d 个条目，且不是 lui 工程: %s（用 --force 允许写入）',
        [n, AOpts.TargetDir]);
      Exit;
    end;
    Result := True;
    Exit;
  end;
  if FileExists(AOpts.TargetDir) then
  begin
    AErr := '目标路径是一个文件: ' + AOpts.TargetDir;
    Exit;
  end;
  if not ForceDirectories(AOpts.TargetDir) then
  begin
    AErr := '无法创建目标目录: ' + AOpts.TargetDir;
    Exit;
  end;
  Result := True;
end;

{ 写入一个文件：自动建父目录、文本模板做占位符替换与换行归一。
  返回 False 且 AErr = '' 表示"已存在且未允许覆盖"（调用方按保留处理）。 }
function WriteOne(const ATargetDir, ASrcFile, AOutName: string;
  const ATokens: array of TToken; AOverwrite: Boolean; out AErr: string): Boolean;
var
  dest, content: string;
begin
  Result := False;
  AErr := '';
  dest := IncludeTrailingPathDelimiter(ATargetDir) + ToNative(AOutName);
  if FileExists(dest) and (not AOverwrite) then
    Exit;
  try
    if not ForceDirectories(ExtractFilePath(dest)) then
    begin
      AErr := '无法创建目录: ' + ExtractFilePath(dest);
      Exit;
    end;
    if IsTextFile(ASrcFile) then
    begin
      content := Substitute(ReadRaw(ASrcFile), ATokens);
      if LowerCase(ExtractFileExt(AOutName)) = '.cmd' then
        content := AdjustLineBreaks(content, tlbsCRLF)
      else
        content := AdjustLineBreaks(content, tlbsLF);
      WriteRaw(dest, content);
    end
    else
      CopyRaw(ASrcFile, dest);
  except
    on E: Exception do
    begin
      AErr := Format('写入失败 %s: %s', [dest, E.Message]);
      Exit;
    end;
  end;
  Result := True;
end;

function XuiScaffoldCreate(const AOpts: TXuiScaffoldOptions;
  out AResult: TXuiScaffoldResult): Boolean;
var
  tplRoot, uiSrc, name, theme, devTheme, renderer, err, srcFile, rel, outRel: string;
  tokens: array[0..9] of TToken;
  tplFiles, uiFiles: TStringList;
  i, width, height: Integer;
begin
  Result := False;
  AResult.Name := '';
  AResult.Files := TStringList.Create;
  AResult.Skipped := TStringList.Create;
  AResult.UiFiles := 0;
  AResult.TemplateRoot := '';
  AResult.Error := '';

  tplRoot := XuiScaffoldDir;
  if tplRoot = '' then
  begin
    AResult.Error := '未找到项目模板（scaffold/）。请使用单程序版运行时（自带模板），' +
      '或在 lui 仓库目录内运行 init。';
    Exit;
  end;
  AResult.TemplateRoot := tplRoot;

  uiSrc := ExtractFileDir(ExcludeTrailingPathDelimiter(tplRoot)) + PathDelim + 'ui';
  if not FileExists(uiSrc + PathDelim + 'index.ts') then
  begin
    AResult.Error := '未找到组件库运行时（' + uiSrc + '）；模板目录需与 ui/ 同级。';
    Exit;
  end;

  if not PrepareTarget(AOpts, err) then
  begin
    AResult.Error := err;
    Exit;
  end;

  name := Trim(AOpts.Name);
  if name = '' then
    name := ExtractFileName(ExcludeTrailingPathDelimiter(ExpandFileName(AOpts.TargetDir)));
  if name = '' then
    name := 'lui-app';

  AResult.Name := name;

  width := AOpts.Width;
  if width <= 0 then
    width := 480;
  height := AOpts.Height;
  if height <= 0 then
    height := 560;
  theme := LowerCase(Trim(AOpts.Theme));
  if (theme <> 'light') and (theme <> 'dark') and (theme <> 'both') then
    theme := 'light';
  devTheme := theme;
  if devTheme = 'both' then
    devTheme := 'light';   // 预览窗一次只显示一个主题，T 键切换

  renderer := Trim(AOpts.RuntimePath);
  if renderer = '' then
    renderer := ExpandFileName(ParamStr(0));
  renderer := ExcludeTrailingPathDelimiter(renderer);

  tokens[0].Key := 'PROJECT_NAME';    tokens[0].Value := name;
  tokens[1].Key := 'PROJECT_VERSION'; tokens[1].Value := XuiScaffoldProjectVersion;
  tokens[2].Key := 'LUI_VERSION';     tokens[2].Value := AOpts.LuiVersion;
  tokens[3].Key := 'DATE';            tokens[3].Value := FormatDateTime('yyyy-mm-dd', Now);
  tokens[4].Key := 'RUNTIME';         tokens[4].Value := renderer;
  tokens[5].Key := 'RUNTIME_POSIX';   tokens[5].Value := ToSlash(renderer);
  tokens[6].Key := 'WIDTH';           tokens[6].Value := IntToStr(width);
  tokens[7].Key := 'HEIGHT';          tokens[7].Value := IntToStr(height);
  tokens[8].Key := 'THEME';           tokens[8].Value := theme;
  tokens[9].Key := 'DEV_THEME';       tokens[9].Value := devTheme;
  // 模板里没有 @@EXE_NAME@@：产物名一律写成 @@PROJECT_NAME@@.exe，少一个可漂移的变量

  tplFiles := TStringList.Create;
  uiFiles := TStringList.Create;
  try
    // 1) 工程文件（scaffold/ 整树）
    CollectFiles(tplRoot, '', tplFiles);
    tplFiles.Sort;
    for i := 0 to tplFiles.Count - 1 do
    begin
      rel := tplFiles[i];
      srcFile := IncludeTrailingPathDelimiter(tplRoot) + ToNative(rel);
      outRel := OutputRelName(rel);
      if WriteOne(AOpts.TargetDir, srcFile, outRel, tokens, AOpts.Force, err) then
        AResult.Files.Add(outRel)
      else if err <> '' then
      begin
        AResult.Error := err;
        Exit;
      end
      else
        AResult.Skipped.Add(outRel);
    end;

    // 2) 组件库运行时（scaffold/ 的同级 ui/）——整树复制，工程自带运行时
    CollectFiles(uiSrc, '', uiFiles);
    uiFiles.Sort;
    for i := 0 to uiFiles.Count - 1 do
    begin
      rel := uiFiles[i];
      srcFile := IncludeTrailingPathDelimiter(uiSrc) + ToNative(rel);
      outRel := 'ui/' + rel;
      if WriteOne(AOpts.TargetDir, srcFile, outRel, tokens, AOpts.Force, err) then
      begin
        AResult.Files.Add(outRel);
        Inc(AResult.UiFiles);
      end
      else if err <> '' then
      begin
        AResult.Error := err;
        Exit;
      end
      else
        AResult.Skipped.Add(outRel);
    end;

    // 3) 输出目录（渲染产物 / 打包产物；.gitignore 已忽略）
    ForceDirectories(IncludeTrailingPathDelimiter(AOpts.TargetDir) + 'out');
  finally
    uiFiles.Free;
    tplFiles.Free;
  end;

  if AOpts.Verbose then
    WriteLn(Format('[信息] 模板来源: %s；工程名: %s；视口: %dx%d；主题: %s',
      [tplRoot, name, width, height, theme]));

  Result := True;
end;

end.
