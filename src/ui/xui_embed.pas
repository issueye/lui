unit xui_embed;

{$mode objfpc}{$H+}

{ 资源内嵌运行时（M9-P4，ADR 34）：把页面资源（xml/css/ts/svg）与 ui/ 运行时资源
  在构建期编码进可执行文件，运行时按需解包到临时目录，再走既有文件访问路径。

  设计取舍：不做内存虚拟文件系统。引擎的文件访问点有十余处（XML 解析、CSS、
  <include>、脚本 src、组件模板、SVG、依赖热重载的 FileAge），逐一改造成 VFS 调用面
  大，且会让 FileAge 依赖跟踪与 ui.fs 真实 I/O 语义变模糊。改为"解包到磁盘 + 外部
  同名文件优先"，可复用全部既有能力（相对引用、include、热重载），代价仅一次约
  200KB 的解包（带就绪标记，后续运行只做一次存在性校验）。

  单程序 exe 仍是超集：命令行给出的文件若在磁盘上存在则直接用磁盘文件，
  内嵌资源只在磁盘上找不到时才参与解析。

  M12 追加：资源来源有两档——构建期编进 exe 的 Base64 常量（单程序版），以及挂在
  exe 尾部的应用载荷（`lui build` 产物，见 xui_bundle）。后者按偏移从文件流读取，
  不把整个载荷读进内存。两档共用同一套"解包到临时目录 + 指纹就绪标记"的挂载实现
  （MountIsReady/DoMount），所以缓存复用与失败原子性只有一份实现、一处修复。 }

interface

uses
  Classes, SysUtils;

{ 由生成的 xui_embed_assets 单元在 initialization 中调用。
  AChunks  全部资源按清单顺序拼接后的数据块（Base64，分块以减少超长字面量）
  ANames   每项的相对路径（'/' 分隔）
  ASizes   每项的字节数
  ACacheKey 内容指纹：用于临时目录命名与解包复用判定 }
procedure XuiEmbedInstall(const AChunks: array of string; const ANames: array of string;
  const ASizes: array of Integer; const ACacheKey: string);

{ M12：资源来自某个文件的载荷段（自包含应用 exe 的尾部载荷）。
  AFile 容器文件；ABaseOffset 载荷在文件中的绝对起始偏移；AOffsets 每项相对
  ABaseOffset 的偏移；其余语义同 XuiEmbedInstall。
  后调用者覆盖先调用者，所以同一个 exe 既能是单程序版（内嵌常量）又能是某个应用
  （尾部载荷），二者不互相干扰。 }
procedure XuiEmbedInstallFromFile(const AFile: string; ABaseOffset: Int64;
  const ANames: array of string; const AOffsets: array of Int64;
  const ASizes: array of Integer; const ACacheKey: string);

function XuiEmbedAvailable: Boolean;
{ 内嵌资源的相对路径清单（调用方负责释放） }
function XuiEmbedNames: TStringList;
{ 解包根目录（按需解包、幂等、带缓存）；无内嵌资源或解包失败时为 '' }
function XuiEmbedRoot: string;
{ 把输入名解析为磁盘路径：依次尝试 <根>/<名>、<根>/pages/<名>；未命中返回 '' }
function XuiEmbedResolve(const AName: string): string;

implementation

type
  TEmbedAsset = record
    Name: string;      // 相对路径，统一 '/' 分隔
    Offset: Int64;     // 在数据块/载荷中的偏移（字节）
    Size: Integer;
  end;

  { 资源来源：内存块（Base64 常量）或容器文件的载荷段 }
  TEmbedKind = (ekNone, ekMemory, ekFile);

var
  GInstalled: Boolean = False;
  GKind: TEmbedKind = ekNone;
  GAssets: array of TEmbedAsset;
  GBlob: TBytes;
  GFile: string = '';
  GFileBase: Int64 = 0;
  GCacheKey: string = '';
  GRoot: string = '';
  GMountTried: Boolean = False;

{ 按资源序号取字节：内存块直接切片，文件档按需 seek+read }
function ReadAsset(AIndex: Integer; out AData: TBytes): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  SetLength(AData, 0);
  if (AIndex < 0) or (AIndex > High(GAssets)) then
    Exit;
  SetLength(AData, GAssets[AIndex].Size);
  if GAssets[AIndex].Size = 0 then
    Exit(True);
  if GKind = ekMemory then
  begin
    if GAssets[AIndex].Offset + GAssets[AIndex].Size > Length(GBlob) then
      Exit;
    Move(GBlob[GAssets[AIndex].Offset], AData[0], GAssets[AIndex].Size);
    Exit(True);
  end;
  if GKind <> ekFile then
    Exit;
  try
    fs := TFileStream.Create(GFile, fmOpenRead or fmShareDenyNone);
    try
      fs.Seek(GFileBase + GAssets[AIndex].Offset, soBeginning);
      fs.ReadBuffer(AData[0], GAssets[AIndex].Size);
    finally
      fs.Free;
    end;
  except
    Exit;
  end;
  Result := True;
end;

function B64Value(AChar: Char): Integer;
begin
  case AChar of
    'A'..'Z': Result := Ord(AChar) - Ord('A');
    'a'..'z': Result := Ord(AChar) - Ord('a') + 26;
    '0'..'9': Result := Ord(AChar) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function DecodeBase64(const S: string; out AData: TBytes): Boolean;
var
  i, v, bits, buf, n: Integer;
begin
  Result := False;
  SetLength(AData, 0);
  if S = '' then
    Exit;
  SetLength(AData, (Length(S) div 4) * 3 + 3);
  n := 0;
  buf := 0;
  bits := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '=' then
      Break;
    v := B64Value(S[i]);
    if v < 0 then
      Continue;                 // 忽略换行/空白
    buf := (buf shl 6) or v;
    Inc(bits, 6);
    if bits >= 8 then
    begin
      Dec(bits, 8);
      AData[n] := Byte((buf shr bits) and $FF);
      Inc(n);
    end;
  end;
  SetLength(AData, n);
  Result := n > 0;
end;

function JoinChunks(const AChunks: array of string): string;
var
  i, len: Integer;
begin
  len := 0;
  for i := Low(AChunks) to High(AChunks) do
    Inc(len, Length(AChunks[i]));
  SetLength(Result, len);
  len := 0;
  for i := Low(AChunks) to High(AChunks) do
  begin
    if AChunks[i] <> '' then
      Move(AChunks[i][1], Result[len + 1], Length(AChunks[i]));
    Inc(len, Length(AChunks[i]));
  end;
end;

function NormalizeName(const AName: string): string;
var
  i: Integer;
begin
  Result := Trim(AName);
  for i := 1 to Length(Result) do
    if Result[i] = '\' then
      Result[i] := '/';
  while (Length(Result) > 1) and (Result[1] = '/') do
    Delete(Result, 1, 1);
  while Copy(Result, 1, 2) = './' do
    Delete(Result, 1, 2);
end;

procedure XuiEmbedInstall(const AChunks: array of string; const ANames: array of string;
  const ASizes: array of Integer; const ACacheKey: string);
var
  blob: TBytes;
  i, offset: Integer;
begin
  if (Length(ANames) = 0) or (Length(ANames) <> Length(ASizes)) then
    Exit;
  if (Length(AChunks) = 0) or not DecodeBase64(JoinChunks(AChunks), blob) then
    Exit;

  SetLength(GAssets, Length(ANames));
  offset := 0;
  for i := 0 to High(ANames) do
  begin
    if (ASizes[i] < 0) or (offset + ASizes[i] > Length(blob)) then
    begin
      SetLength(GAssets, 0);
      Exit;
    end;
    GAssets[i].Name := NormalizeName(ANames[i]);
    GAssets[i].Offset := offset;
    GAssets[i].Size := ASizes[i];
    Inc(offset, ASizes[i]);
  end;
  if offset <> Length(blob) then
  begin
    SetLength(GAssets, 0);
    Exit;
  end;
  GBlob := blob;
  GFile := '';
  GFileBase := 0;
  GKind := ekMemory;
  GCacheKey := ACacheKey;
  GInstalled := True;
  GMountTried := False;
  GRoot := '';
end;

procedure XuiEmbedInstallFromFile(const AFile: string; ABaseOffset: Int64;
  const ANames: array of string; const AOffsets: array of Int64;
  const ASizes: array of Integer; const ACacheKey: string);
var
  i: Integer;
begin
  if (Length(ANames) = 0) or (Length(ANames) <> Length(ASizes)) or
     (Length(ANames) <> Length(AOffsets)) then
    Exit;
  if (ABaseOffset < 0) or (not FileExists(AFile)) then
    Exit;

  SetLength(GAssets, Length(ANames));
  for i := 0 to High(ANames) do
  begin
    if (ASizes[i] < 0) or (AOffsets[i] < 0) then
    begin
      SetLength(GAssets, 0);
      Exit;
    end;
    GAssets[i].Name := NormalizeName(ANames[i]);
    GAssets[i].Offset := AOffsets[i];
    GAssets[i].Size := ASizes[i];
  end;
  SetLength(GBlob, 0);
  GFile := ExpandFileName(AFile);
  GFileBase := ABaseOffset;
  GKind := ekFile;
  GCacheKey := ACacheKey;
  GInstalled := True;
  GMountTried := False;
  GRoot := '';
end;

function XuiEmbedAvailable: Boolean;
begin
  Result := GInstalled;
end;

function XuiEmbedNames: TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  for i := 0 to High(GAssets) do
    Result.Add(GAssets[i].Name);
end;

function ReadTextFileRaw(const AFile: string): string;
var
  fs: TFileStream;
  buf: TBytes;
begin
  Result := '';
  if not FileExists(AFile) then
    Exit;
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(buf, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(buf[0], fs.Size);
  finally
    fs.Free;
  end;
  SetLength(Result, Length(buf));
  if Length(buf) > 0 then
    Move(buf[0], Result[1], Length(buf));
end;

function WriteBlobFile(const AFile: string; AIndex: Integer): Boolean;
var
  fs: TFileStream;
  data: TBytes;
begin
  Result := False;
  if not ReadAsset(AIndex, data) then
    Exit;
  try
    fs := TFileStream.Create(AFile, fmCreate);
    try
      if Length(data) > 0 then
        fs.WriteBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
      Result := False;
  end;
end;

{ 就绪判定：标记文件内容等于当前指纹，且清单内每个文件都已在磁盘上
  （防止上次解包中途失败后留下"半包"被误用） }
function MountIsReady(const ADir: string): Boolean;
var
  i, dlen: Integer;
  base: string;
begin
  Result := False;
  if ReadTextFileRaw(ADir + PathDelim + '.lui-embed-ready') <> GCacheKey then
    Exit;
  base := IncludeTrailingPathDelimiter(ADir);
  dlen := Length(base);
  for i := 0 to High(GAssets) do
  begin
    base := Copy(base, 1, dlen) +
      StringReplace(GAssets[i].Name, '/', PathDelim, [rfReplaceAll]);
    if not FileExists(base) then
      Exit;
  end;
  Result := True;
end;

function DoMount: string;
var
  dir, dest: string;
  i: Integer;
  fs: TFileStream;
begin
  Result := '';
  { 解包目标目录：LUI_EMBED_DIR 优先（测试与调试用），否则 %TEMP%\lui-embed-<指纹>。
    单程序版与自包含应用共用同一命名空间，指纹不同即互不干扰。 }
  dir := Trim(GetEnvironmentVariable('LUI_EMBED_DIR'));
  if dir = '' then
    dir := IncludeTrailingPathDelimiter(GetTempDir) + 'lui-embed-' + GCacheKey;
  dir := ExcludeTrailingPathDelimiter(dir);

  if MountIsReady(dir) then
    Exit(dir);

  if not ForceDirectories(dir) then
    Exit;
  for i := 0 to High(GAssets) do
  begin
    dest := dir + PathDelim + StringReplace(GAssets[i].Name, '/', PathDelim, [rfReplaceAll]);
    if not ForceDirectories(ExtractFileDir(dest)) then
      Exit('');
    if not WriteBlobFile(dest, i) then
      Exit('');
  end;

  // 全部成功后才落标记；失败时下次运行会整包重解
  try
    fs := TFileStream.Create(dir + PathDelim + '.lui-embed-ready', fmCreate);
    try
      if GCacheKey <> '' then
        fs.WriteBuffer(GCacheKey[1], Length(GCacheKey));
    finally
      fs.Free;
    end;
  except
    on E: Exception do
      Exit('');
  end;
  Result := dir;
end;

function XuiEmbedRoot: string;
begin
  if not GInstalled then
    Exit('');
  if not GMountTried then
  begin
    GMountTried := True;
    GRoot := DoMount;
  end;
  Result := GRoot;
end;

function XuiEmbedResolve(const AName: string): string;
var
  root, name, cand: string;
begin
  Result := '';
  root := XuiEmbedRoot;
  if root = '' then
    Exit;
  name := NormalizeName(AName);
  if name = '' then
    Exit;
  cand := IncludeTrailingPathDelimiter(root) + StringReplace(name, '/', PathDelim, [rfReplaceAll]);
  if FileExists(cand) then
    Exit(cand);
  cand := IncludeTrailingPathDelimiter(root) + 'pages' + PathDelim +
    StringReplace(name, '/', PathDelim, [rfReplaceAll]);
  if FileExists(cand) then
    Exit(cand);
end;

end.
