unit xui_bundle;

{$mode objfpc}{$H+}

{ 自包含应用容器（M12，ADR 50/51）：把一个 lui 应用连同组件库运行时挂到运行时 exe 的
  尾部，产出"双击即运行、拷走即交付"的单文件应用。这是 Electron 式打包在"没有 Node、
  没有编译期资源内嵌"约束下的等价物——关键在于**构建应用不需要 Pascal 编译器**：
  打包器就是运行时自己，它把自己复制一份、把应用目录按原样追加到文件末尾、再写一个
  48 字节的尾部目录，完事。

  为什么是"追加"而不是重编译内嵌（M9 的 Base64 方案）：M9 的内嵌把资源编成 Pascal
  常量再链接，只有 lui 自己的构建能那么干；用户工程要出单文件就得装 FPC，这与"应用
  开发者不写 Pascal、不装 Pascal"直接冲突。追加式载荷对 PE 文件是安全的（镜像之外的
  尾部数据不参与加载），且解包复用 xui_embed 已有的"指纹缓存 + 就绪标记"机制。

  文件布局（全部小端）：
    [运行时 exe 原始字节]
    [载荷]   各文件原始字节，按 TOC 顺序紧密排列
    [TOC]    每项 = nameLen:UInt32 | name(UTF-8) | size:UInt32 | crc32:UInt32
    [尾部]   48 字节，见 XuiBundleTrailer
  读侧只信任尾部：magic 与长度自洽才认，损坏的 exe 会被当成"没有载荷"。

  注释里的 ADR 编号指 docs/M12-Electron式运行时重设计方案.md。 }

interface

uses
  Classes, SysUtils;

const
  XuiBundleMagic = 'LUIBNDL1';
  XuiBundleTrailerSize = 48;
  XuiBundleFormatVersion = 1;

type
  TXuiBundleInfo = record
    Valid: Boolean;
    PayloadOffset: Int64;    // 载荷起始（绝对文件偏移）
    PayloadSize: Int64;
    FileCount: Integer;
    TocSize: Integer;
    Fingerprint: Cardinal;   // TOC 的 CRC32：缓存目录名与"内容变了"的判据
    ExeSize: Int64;
    Error: string;           // Valid=False 时的原因（诊断用）
  end;

  TXuiBundleEntry = record
    Name: string;            // '/' 分隔的相对路径
    Size: Integer;
    Crc: Cardinal;
    Offset: Int64;           // 相对载荷起点
  end;

  TXuiBundleEntries = array of TXuiBundleEntry;

{ 探测 AExeFile 尾部是否挂着应用载荷。 }
function XuiBundleProbe(const AExeFile: string; out AInfo: TXuiBundleInfo): Boolean;

{ 载荷内的文件清单（'/' 分隔，调用方释放）。非容器返回空表。 }
function XuiBundleList(const AExeFile: string): TStringList;

{ 读取载荷目录项（调用方释放；非容器返回空表）。 }
function XuiBundleEntries(const AExeFile: string): TXuiBundleEntries;

{ 把 AExeFile 的载荷挂载到缓存目录（复用 xui_embed 的解包机制），
  返回应用根。无载荷 / 解包失败返回 False。 }
function XuiBundleMount(const AExeFile: string; out AMountRoot: string): Boolean;

{ 挂载"我自己"（ParamStr(0)）的载荷——自包含应用 exe 的启动入口。 }
function XuiBundleMountSelf(out AMountRoot: string): Boolean;

{ 组装自包含应用：ATemplateExe 复制为 AOutputExe，再把 ARootDir 下由 ARelNames
  列出的文件（'/' 分隔的相对路径，顺序即载荷顺序）追加进去。
  输出文件已存在时会被替换；不允许 AOutputExe 与 ATemplateExe 是同一个文件。 }
function XuiBundleBuild(const ATemplateExe, AOutputExe, ARootDir: string;
  const ARelNames: TStrings; out AFileCount: Integer; out AErr: string): Boolean;

var
  { 构建过程的行日志（nil = 静默）。由 CLI 注入，便于 --json 时把日志导向 stderr。 }
  XuiBundleLog: procedure(const AText: string) = nil;

implementation

uses
  xui_embed;

type
  TXuiBundleTrailer = record
    PayloadOffset: Int64;
    PayloadSize: Int64;
    FileCount: Cardinal;
    TocSize: Cardinal;
    FormatVersion: Cardinal;
    Flags: Cardinal;
    Fingerprint: Cardinal;
    Reserved: Cardinal;
    Magic: array[0..7] of Char;
  end;

var
  GCrcTable: array[0..255] of Cardinal;
  GCrcReady: Boolean = False;

procedure Log(const AText: string);
begin
  if Assigned(XuiBundleLog) then
    XuiBundleLog(AText);
end;

{ ---------- CRC32（载荷完整性；也用作缓存指纹） ---------- }

procedure InitCrc;
var
  i, j: Integer;
  c: Cardinal;
begin
  for i := 0 to 255 do
  begin
    c := Cardinal(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then
        c := $EDB88320 xor (c shr 1)
      else
        c := c shr 1;
    GCrcTable[i] := c;
  end;
  GCrcReady := True;
end;

function Crc32Update(ACrc: Cardinal; const ABuf; ASize: Integer): Cardinal;
var
  p: PByte;
  i: Integer;
begin
  if not GCrcReady then
    InitCrc;
  Result := ACrc;
  p := @ABuf;
  for i := 0 to ASize - 1 do
  begin
    Result := GCrcTable[(Result xor p^) and $FF] xor (Result shr 8);
    Inc(p);
  end;
end;

function Crc32OfStream(AStream: TStream; ASize: Int64): Cardinal;
const
  BufSize = 65536;
var
  buf: TBytes;
  remain: Int64;
  want: Integer;
begin
  Result := $FFFFFFFF;
  SetLength(buf, BufSize);
  remain := ASize;
  while remain > 0 do
  begin
    if remain > BufSize then
      want := BufSize
    else
      want := Integer(remain);
    AStream.ReadBuffer(buf[0], want);
    Result := Crc32Update(Result, buf[0], want);
    Dec(remain, want);
  end;
  Result := Result xor $FFFFFFFF;
end;

function Crc32OfBytes(const ABuf; ASize: Integer): Cardinal;
begin
  Result := Crc32Update($FFFFFFFF, ABuf, ASize) xor $FFFFFFFF;
end;

function Crc32OfFile(const APath: string; out ACrc: Cardinal; out ASize: Int64): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  ACrc := 0;
  ASize := 0;
  if not FileExists(APath) then
    Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      ASize := fs.Size;
      ACrc := Crc32OfStream(fs, fs.Size);
    finally
      fs.Free;
    end;
  except
    Exit;
  end;
  Result := True;
end;

{ ---------- 读侧 ---------- }

function ReadTrailer(AStream: TStream; out AT: TXuiBundleTrailer): Boolean;
begin
  Result := False;
  FillChar(AT, SizeOf(AT), 0);
  if AStream.Size < XuiBundleTrailerSize then
    Exit;
  AStream.Seek(AStream.Size - XuiBundleTrailerSize, soBeginning);
  AStream.ReadBuffer(AT, SizeOf(AT));
  if CompareMem(@AT.Magic[0], PChar(XuiBundleMagic), 8) then
    Result := True;
end;

function XuiBundleProbe(const AExeFile: string; out AInfo: TXuiBundleInfo): Boolean;
var
  fs: TFileStream;
  t: TXuiBundleTrailer;
begin
  Result := False;
  FillChar(AInfo, SizeOf(AInfo), 0);
  if not FileExists(AExeFile) then
  begin
    AInfo.Error := '文件不存在';
    Exit;
  end;
  try
    fs := TFileStream.Create(AExeFile, fmOpenRead or fmShareDenyNone);
    try
      AInfo.ExeSize := fs.Size;
      if not ReadTrailer(fs, t) then
      begin
        AInfo.Error := '没有载荷（尾部标记不匹配）';
        Exit;
      end;
      if t.FormatVersion <> XuiBundleFormatVersion then
      begin
        AInfo.Error := Format('载荷格式版本不支持: %d', [t.FormatVersion]);
        Exit;
      end;
      if (t.PayloadOffset < 0) or (t.PayloadSize < 0) or (t.FileCount > 1000000) then
      begin
        AInfo.Error := '载荷头部字段非法';
        Exit;
      end;
      // 三段必须刚好凑满文件：exe + 载荷 + TOC + 尾部
      if t.PayloadOffset + t.PayloadSize + Int64(t.TocSize) + XuiBundleTrailerSize <> fs.Size then
      begin
        AInfo.Error := '载荷长度与文件大小不自洽';
        Exit;
      end;
      AInfo.Valid := True;
      AInfo.PayloadOffset := t.PayloadOffset;
      AInfo.PayloadSize := t.PayloadSize;
      AInfo.FileCount := t.FileCount;
      AInfo.TocSize := t.TocSize;
      AInfo.Fingerprint := t.Fingerprint;
    finally
      fs.Free;
    end;
  except
    on E: Exception do
    begin
      AInfo.Valid := False;
      AInfo.Error := E.Message;
      Exit;
    end;
  end;
  Result := AInfo.Valid;
end;

function XuiBundleEntries(const AExeFile: string): TXuiBundleEntries;
var
  info: TXuiBundleInfo;
  fs: TFileStream;
  toc: TBytes;
  p, i, nameLen, size: Integer;
  crc: Cardinal;
  offset: Int64;

  function TakeInt: Cardinal;
  begin
    Result := Cardinal(toc[p]) or (Cardinal(toc[p + 1]) shl 8) or
      (Cardinal(toc[p + 2]) shl 16) or (Cardinal(toc[p + 3]) shl 24);
    Inc(p, 4);
  end;

begin
  Result := nil;
  if not XuiBundleProbe(AExeFile, info) then
    Exit;
  SetLength(Result, info.FileCount);
  SetLength(toc, info.TocSize);
  fs := TFileStream.Create(AExeFile, fmOpenRead or fmShareDenyNone);
  try
    fs.Seek(info.PayloadOffset + info.PayloadSize, soBeginning);
    if info.TocSize > 0 then
      fs.ReadBuffer(toc[0], info.TocSize);
  finally
    fs.Free;
  end;

  p := 0;
  offset := 0;
  for i := 0 to info.FileCount - 1 do
  begin
    if p + 4 > Length(toc) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    nameLen := Integer(TakeInt);
    if (nameLen <= 0) or (p + nameLen > Length(toc)) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    SetLength(Result[i].Name, nameLen);
    Move(toc[p], Result[i].Name[1], nameLen);
    Inc(p, nameLen);
    if p + 8 > Length(toc) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    size := Integer(TakeInt);
    crc := TakeInt;
    Result[i].Size := size;
    Result[i].Crc := crc;
    Result[i].Offset := offset;
    Inc(offset, size);
  end;
end;

function XuiBundleList(const AExeFile: string): TStringList;
var
  entries: TXuiBundleEntries;
  i: Integer;
begin
  Result := TStringList.Create;
  entries := XuiBundleEntries(AExeFile);
  for i := 0 to High(entries) do
    Result.Add(entries[i].Name);
end;

function XuiBundleMount(const AExeFile: string; out AMountRoot: string): Boolean;
var
  info: TXuiBundleInfo;
  entries: TXuiBundleEntries;
  names: array of string;
  offsets: array of Int64;
  sizes: array of Integer;
  key: string;
  i: Integer;
begin
  Result := False;
  AMountRoot := '';
  if not XuiBundleProbe(AExeFile, info) then
    Exit;
  entries := XuiBundleEntries(AExeFile);
  if Length(entries) <> info.FileCount then
    Exit;
  SetLength(names, Length(entries));
  SetLength(offsets, Length(entries));
  SetLength(sizes, Length(entries));
  for i := 0 to High(entries) do
  begin
    names[i] := entries[i].Name;
    offsets[i] := entries[i].Offset;
    sizes[i] := entries[i].Size;
  end;
  // 缓存键带 'app' 前缀：与单程序版的内嵌资源不共用目录，便于排查
  key := 'app' + IntToHex(info.Fingerprint, 8);
  XuiEmbedInstallFromFile(ExpandFileName(AExeFile), info.PayloadOffset, names, offsets,
    sizes, key);
  AMountRoot := XuiEmbedRoot;
  Result := AMountRoot <> '';
end;

function XuiBundleMountSelf(out AMountRoot: string): Boolean;
begin
  Result := XuiBundleMount(ParamStr(0), AMountRoot);
end;

{ ---------- 写侧 ---------- }

function XuiBundleBuild(const ATemplateExe, AOutputExe, ARootDir: string;
  const ARelNames: TStrings; out AFileCount: Integer; out AErr: string): Boolean;
var
  tpl, dst, part: TFileStream;
  toc: TBytes;
  t: TXuiBundleTrailer;
  names: TStringList;
  entries: array of TXuiBundleEntry;
  i, j, tocLen, p: Integer;
  payloadBase, payloadSize, fsize: Int64;
  crc: Cardinal;
  root, outPath, tmpPath, full: string;

  procedure PutInt(AValue: Cardinal);
  begin
    toc[p] := Byte(AValue and $FF);
    toc[p + 1] := Byte((AValue shr 8) and $FF);
    toc[p + 2] := Byte((AValue shr 16) and $FF);
    toc[p + 3] := Byte((AValue shr 24) and $FF);
    Inc(p, 4);
  end;

begin
  Result := False;
  AFileCount := 0;
  AErr := '';
  payloadSize := 0;
  try
  root := IncludeTrailingPathDelimiter(ExpandFileName(ARootDir));
  outPath := ExpandFileName(AOutputExe);
  if not FileExists(ATemplateExe) then
  begin
    AErr := '运行时文件不存在: ' + ATemplateExe;
    Exit;
  end;
  if SameFileName(outPath, ExpandFileName(ATemplateExe)) then
  begin
    AErr := '输出文件不能覆盖运行时自身: ' + outPath;
    Exit;
  end;

  // 收集有效文件（跳过缺失项、去重、保持调用方顺序 —— 顺序稳定才有可复现的构建）
  names := TStringList.Create;
  try
    for i := 0 to ARelNames.Count - 1 do
    begin
      if Trim(ARelNames[i]) = '' then
        Continue;
      full := root + StringReplace(Trim(ARelNames[i]), '/', PathDelim, [rfReplaceAll]);
      if not FileExists(full) then
      begin
        Log('  跳过（文件不存在）: ' + ARelNames[i]);
        Continue;
      end;
      if names.IndexOf(ARelNames[i]) >= 0 then
        Continue;
      names.Add(ARelNames[i]);
    end;
    if names.Count = 0 then
    begin
      AErr := '没有可打包的文件（应用目录为空？）';
      Exit;
    end;

    SetLength(entries, names.Count);
    for i := 0 to names.Count - 1 do
    begin
      full := root + StringReplace(names[i], '/', PathDelim, [rfReplaceAll]);
      entries[i].Name := names[i];
      if not Crc32OfFile(full, crc, fsize) then
      begin
        AErr := '读取失败: ' + names[i];
        Exit;
      end;
      entries[i].Crc := crc;
      entries[i].Size := Integer(fsize);
      payloadSize := payloadSize + fsize;
    end;

    // TOC 尺寸：每项 4 + len(name) + 4 + 4
    tocLen := 0;
    for i := 0 to names.Count - 1 do
      Inc(tocLen, 4 + Length(entries[i].Name) + 8);
    SetLength(toc, tocLen);

    // 先写到临时文件，成功后再替换目标：半成品不该留在 dist/ 里被双击。
    // 输出目录由本函数负责创建——调用方（CLI 与测试）都不该被迫先建一次目录。
    if not ForceDirectories(ExtractFileDir(outPath)) then
    begin
      AErr := '无法创建输出目录: ' + ExtractFileDir(outPath);
      Exit;
    end;
    tmpPath := outPath + '.lui-tmp';
    if FileExists(tmpPath) then
      DeleteFile(tmpPath);
    tpl := TFileStream.Create(ExpandFileName(ATemplateExe), fmOpenRead or fmShareDenyNone);
    try
      dst := TFileStream.Create(tmpPath, fmCreate);
      try
        // 1) 运行时本体
        dst.CopyFrom(tpl, tpl.Size);
        payloadBase := dst.Size;

        // 2) 载荷：逐文件原样追加（每个文件独立打开，单个失败不会留下半开的流）
        for i := 0 to names.Count - 1 do
        begin
          full := root + StringReplace(names[i], '/', PathDelim, [rfReplaceAll]);
          part := TFileStream.Create(full, fmOpenRead or fmShareDenyNone);
          try
            dst.CopyFrom(part, part.Size);
          finally
            part.Free;
          end;
        end;
        payloadSize := dst.Size - payloadBase;

        // 3) TOC
        p := 0;
        for i := 0 to names.Count - 1 do
        begin
          PutInt(Cardinal(Length(entries[i].Name)));
          for j := 1 to Length(entries[i].Name) do
            toc[p + j - 1] := Byte(entries[i].Name[j]);
          Inc(p, Length(entries[i].Name));
          PutInt(Cardinal(entries[i].Size));
          PutInt(entries[i].Crc);
        end;
        if Length(toc) > 0 then
          dst.WriteBuffer(toc[0], Length(toc));

        // 4) 尾部
        FillChar(t, SizeOf(t), 0);
        t.PayloadOffset := payloadBase;
        t.PayloadSize := payloadSize;
        t.FileCount := Cardinal(names.Count);
        t.TocSize := Cardinal(tocLen);
        t.FormatVersion := XuiBundleFormatVersion;
        t.Flags := 0;
        t.Fingerprint := Crc32OfBytes(toc[0], Length(toc));
        t.Reserved := 0;
        Move(XuiBundleMagic[1], t.Magic[0], 8);
        dst.WriteBuffer(t, SizeOf(t));
      finally
        dst.Free;
      end;
    finally
      tpl.Free;
    end;

    AFileCount := names.Count;

    if FileExists(outPath) then
      if not DeleteFile(outPath) then
      begin
        AErr := '无法替换已存在的输出文件（正在运行？）: ' + outPath;
        DeleteFile(tmpPath);
        Exit;
      end;
    if not RenameFile(tmpPath, outPath) then
    begin
      AErr := '无法写出输出文件: ' + outPath;
      DeleteFile(tmpPath);
      Exit;
    end;
    Log(Format('  载荷 %d 个文件，%.1f KB，尾部指纹 %s',
      [names.Count, payloadSize / 1024, IntToHex(t.Fingerprint, 8)]));
    Result := True;
  finally
    names.Free;
  end;
  except
    on E: Exception do
    begin
      AErr := '打包过程中出错: ' + E.Message;
      Result := False;
      if (tmpPath <> '') and FileExists(tmpPath) then
        DeleteFile(tmpPath);
    end;
  end;
end;

end.
