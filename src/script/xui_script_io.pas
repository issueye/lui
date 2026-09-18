unit xui_script_io;

{$mode objfpc}{$H+}

{ 真实 I/O（M6 P4，ADR 18）：ui.http / ui.fs / ui.storage。

  铁律（线程安全）：工作线程只做系统调用，不持有、不创建、不触碰任何 JS 值；
  跨线程只传"原始数据 + 状态码 + 请求 Id"；所有 JS 值转换与 Promise settle 都在主线程
  （PumpCompletions 由引擎 Tick 驱动）完成。

  - HTTP：WinHTTP 直声明（winhttp.dll，与既有 gdiplus/imm32 同做法，零第三方依赖）
  - 文件：TFileStream 读写，与 HTTP 共用同一个 I/O 工作线程串行执行
  - 进程（M13）：TProcess（FPC RTL 自带）执行外部命令，stdout/stderr 分流 + 超时终止；
    与 HTTP/文件共用同一工作线程，所以跑命令不会卡住界面
  - 路径：相对路径锚定应用根（M12 ADR 49 的同一基准），无应用根时退回进程 CWD
  - 完成回传：工作线程写入完成队列（临界区保护的单向队列），主线程 Tick 轮询排空；
    完成回调最多延迟到下一个 Tick（宿主 Timer 16ms）
  - 可注入 fake：SyncMode = True 时不开工作线程，Submit 在调用线程内经 Executor 同步
    产生结果（单元测试用，不依赖真实网络）
  - storage：同步（内存字典）；StorageFile 为空 = 仅内存，否则按 name=value 行持久化 }

interface

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, SyncObjs, Contnrs,
  xui_js_runtime;

type
  TXuiIoKind = (iokHttpGet, iokHttpPost, iokFsRead, iokFsWrite,
    // M13：文件系统补全（目录遍历、追加、原子替换）——写真实应用时，只靠
    // "整文件读 + 整文件写"没法落 JSONL、没法建目录、没法做安全的替换写
    iokFsAppend, iokFsExists, iokFsStat, iokFsList, iokFsMkdir, iokFsRemove,
    iokFsRename,
    // M13：进程执行——ui.exec.run()。与 Electron 的 child_process 同性质：
    // 引擎提供能力，是否允许由应用自己的策略与审批决定
    iokExec);

  // I/O 失败上报（stage=io；门面接线；主线程 PumpCompletions 内回调）
  TXuiIoErrorProc = procedure(const AMessage: string) of object;

  // 请求（主线程创建、入队后不再改动；工作线程只读）
  TXuiIoRequest = class
  public
    Id: Integer;
    Kind: TXuiIoKind;
    Url: string;          // http（UTF-8）
    Body: string;         // http post（UTF-8 原始字节）
    Headers: string;      // 附加请求头（CRLF 分隔）
    TimeoutMs: Integer;   // 0 = 默认（http/exec 30s）
    Path: string;         // fs
    Text: string;         // fs write / append
    Path2: string;        // fs rename 的目标路径
    Cmd: string;          // exec：命令行（交给系统 shell 解释，引擎不做词法解析）
    Cwd: string;          // exec：工作目录（空 = 进程当前目录）
    MaxBytes: Integer;    // exec：stdout / stderr 各自的上限（0 = 64KiB）
  end;

  // 结果（工作线程填充，主线程消费后释放）
  TXuiIoResult = class
  public
    Id: Integer;
    Ok: Boolean;
    Status: Integer;      // http 状态码；fs/exec 为 0
    Headers: string;      // http 响应头（原始 CRLF 块）
    Data: string;         // 响应体 / 文件内容（原始字节）
    ErrMsg: string;
    // ---- M13 ----
    ExitCode: Integer;    // exec：退出码（超时终止时为 -1）
    StdOut, StdErr: string;
    TimedOut: Boolean;    // exec：超时被终止
    Truncated: Boolean;   // exec：输出被上限截断
    DurationMs: Int64;    // exec：实际耗时
    Flag: Boolean;        // fs exists / remove：布尔结果
    Value: Int64;         // fs stat：字节数；MTime：毫秒时间戳
    MTime: Int64;
    IsDir: Boolean;       // fs stat
    Items: TStringList;   // fs list：每行 "名称<TAB>d|f<TAB>字节数"
    constructor Create;
    destructor Destroy; override;
  end;

  // 主线程挂起的请求 → Promise 控制函数（仅主线程访问；经 OnCollectRoots 保活）
  TXuiIoPending = class
  public
    Id: Integer;
    Kind: TXuiIoKind;
    Promise: TXuiJsPromise;
    Resolve: TXuiJsFunction;
    Reject: TXuiJsFunction;
  end;

  // 工作线程执行器（可注入 fake；默认 RealExecute）。在工作线程上下文调用。
  TXuiIoExecutor = procedure(AReq: TXuiIoRequest; ARes: TXuiIoResult);

  TXuiIoWorker = class(TThread)
  private
    FOwner: TObject;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TObject);
  end;

  TXuiScriptIO = class
  private
    FInterp: TXuiJsInterp;
    FOnIoError: TXuiIoErrorProc;
    // 请求队列（主线程写 / 工作线程读）
    FQueueLock: TRTLCriticalSection;
    FQueueEvent: TEvent;
    FQueue: TObjectList;         // TXuiIoRequest（所有权转移给工作线程）
    // 完成队列（工作线程写 / 主线程读）
    FDoneLock: TRTLCriticalSection;
    FDone: TObjectList;          // TXuiIoResult（PumpCompletions 释放）
    FWorker: TXuiIoWorker;
    FSyncMode: Boolean;          // True = 不开工作线程（测试注入用）
    FExecutor: TXuiIoExecutor;   // 可注入执行器（默认 RealExecute）
    FNextId: Integer;
    FInFlight: Integer;
    FPending: TObjectList;       // TXuiIoPending（仅主线程）
    FStorage: TStringList;       // name=value
    FStorageFile: string;        // 空 = 仅内存
    FStorageDirty: Boolean;
    procedure WorkerLoop;
    procedure RealExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
    procedure ExecExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
    procedure FsExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
    {$IFDEF WINDOWS}procedure HttpExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);{$ENDIF}
    procedure ExecFileSync(AReq: TXuiIoRequest);   // SyncMode：调用线程内完成
    procedure MarkPendingRoots;   // GC 根：挂起请求的 Promise 控制函数
    function NativeHttp(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeFs(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeExec(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function MakeExecResult(ARes: TXuiIoResult): TXuiJsValue;
    function MakeStatResult(ARes: TXuiIoResult): TXuiJsValue;
    function MakeListResult(ARes: TXuiIoResult): TXuiJsValue;
    function NativeStorage(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeRespText(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeRespJson(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NewPending(AKind: TXuiIoKind; out AId: Integer): TXuiIoPending;
    function MakeResponse(ARes: TXuiIoResult): TXuiJsValue;
    function OptTimeout(const AOpts: TXuiJsValue): Integer;
    function OptHeaders(const AOpts: TXuiJsValue): string;
    procedure CheckSignal(const AOpts: TXuiJsValue);
    procedure LoadStorage;
    procedure SaveStorage;
  public
    constructor Create(AInterp: TXuiJsInterp);
    destructor Destroy; override;
    procedure Install;              // 注册 ui.http / ui.fs / ui.storage
    procedure Submit(AReq: TXuiIoRequest);
    procedure PumpCompletions;      // 主线程：排空完成队列 → settle Promise
    function InFlight: Integer;
    property SyncMode: Boolean read FSyncMode write FSyncMode;
    property Executor: TXuiIoExecutor read FExecutor write FExecutor;
    property StorageFile: string read FStorageFile write FStorageFile;
    property OnIoError: TXuiIoErrorProc read FOnIoError write FOnIoError;
  end;

implementation

uses
  Process, Pipes, StrUtils, xui_appspec;

{ ---- WinHTTP 直声明（winhttp.dll，仅 Windows）---- }

{$IFDEF WINDOWS}
const
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_RAW_HEADERS_CRLF = 22;

function WinHttpOpen(const AAgent: PWideChar; AAccessType: DWORD;
  const AProxy: PWideChar; const AProxyBypass: PWideChar; AFlags: DWORD): THandle; stdcall;
  external 'winhttp.dll' name 'WinHttpOpen';
function WinHttpConnect(HSession: THandle; const AServer: PWideChar;
  APort: Word; AReserved: DWORD): THandle; stdcall;
  external 'winhttp.dll' name 'WinHttpConnect';
function WinHttpOpenRequest(HConnect: THandle; const AVerb: PWideChar;
  const AObject: PWideChar; const AVersion: PWideChar; const AReferrer: PWideChar;
  const AAcceptTypes: PPWideChar; AFlags: DWORD): THandle; stdcall;
  external 'winhttp.dll' name 'WinHttpOpenRequest';
function WinHttpCloseHandle(HInternet: THandle): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpCloseHandle';
function WinHttpAddRequestHeaders(HRequest: THandle; const AHeaders: PWideChar;
  ALength: DWORD; AModifiers: DWORD): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpAddRequestHeaders';
function WinHttpSendRequest(HRequest: THandle; const AHeaders: PWideChar;
  AHeadersLength: DWORD; AOptional: Pointer; AOptionalLength: DWORD;
  ATotalLength: DWORD; AContext: DWORD_PTR): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpSendRequest';
function WinHttpReceiveResponse(HRequest: THandle; AReserved: Pointer): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpReceiveResponse';
function WinHttpQueryDataAvailable(HRequest: THandle; out AAvailable: DWORD): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpQueryDataAvailable';
function WinHttpReadData(HRequest: THandle; ABuffer: Pointer;
  AToRead: DWORD; out ARead: DWORD): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpReadData';
function WinHttpQueryHeaders(HRequest: THandle; AInfoLevel: DWORD;
  AName: PWideChar; ABuffer: Pointer; var ABufferLength: DWORD;
  AIndex: PDWORD): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpQueryHeaders';
function WinHttpSetTimeouts(HInternet: THandle; AResolve, AConnect, ASend,
  AReceive: Integer): Boolean; stdcall;
  external 'winhttp.dll' name 'WinHttpSetTimeouts';
{$ENDIF}

constructor TXuiIoResult.Create;
begin
  inherited Create;
  Items := TStringList.Create;
  ExitCode := 0;
end;

destructor TXuiIoResult.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

{ TXuiIoWorker }

constructor TXuiIoWorker.Create(AOwner: TObject);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TXuiIoWorker.Execute;
begin
  TXuiScriptIO(FOwner).WorkerLoop;
end;

{ TXuiScriptIO }

constructor TXuiScriptIO.Create(AInterp: TXuiJsInterp);
begin
  inherited Create;
  FInterp := AInterp;
  InitCriticalSection(FQueueLock);
  InitCriticalSection(FDoneLock);
  FQueue := TObjectList.Create(True);
  FDone := TObjectList.Create(True);
  FPending := TObjectList.Create(True);
  FStorage := TStringList.Create;
  FQueueEvent := TEvent.Create(nil, False, False, '');
  FSyncMode := False;
  FNextId := 1;
  if Assigned(FInterp) then
    FInterp.OnCollectRoots := @MarkPendingRoots;
end;

destructor TXuiScriptIO.Destroy;
begin
  if Assigned(FInterp) then
    FInterp.OnCollectRoots := nil;
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FQueueEvent.SetEvent;
    FWorker.WaitFor;
    FWorker.Free;
  end;
  FQueue.Free;               // 未执行的请求随队列释放（仅 Destroy 路径）
  FDone.Free;
  FPending.Free;
  FStorage.Free;
  FQueueEvent.Free;
  DoneCriticalSection(FQueueLock);
  DoneCriticalSection(FDoneLock);
  inherited Destroy;
end;

// 注册 ui.http / ui.fs / ui.storage（并入既有 ui 对象）
procedure TXuiScriptIO.Install;
var
  uiv: TXuiJsValue;
  ui, httpObj, fsObj, storageObj, execObj: TXuiJsObject;
begin
  uiv := FInterp.GlobalObject.GetOwn('ui');
  if (uiv.Kind = jvObject) and (uiv.Obj <> nil) then
    ui := uiv.Obj
  else
    ui := FInterp.CreateHostObject('Object');
  httpObj := FInterp.CreateHostObject('Object');
  httpObj.SetOwn('get', FInterp.CreateHostFunction('get', @NativeHttp));
  httpObj.SetOwn('post', FInterp.CreateHostFunction('post', @NativeHttp));
  ui.SetOwn('http', FInterp.ObjectValue(httpObj));
  fsObj := FInterp.CreateHostObject('Object');
  fsObj.SetOwn('readText', FInterp.CreateHostFunction('readText', @NativeFs));
  fsObj.SetOwn('writeText', FInterp.CreateHostFunction('writeText', @NativeFs));
  // M13：文件名一律小写注册，NativeFs 内按 LowerCase 分派——避免大小写两套名字
  fsObj.SetOwn('appendText', FInterp.CreateHostFunction('appendText', @NativeFs));
  fsObj.SetOwn('exists', FInterp.CreateHostFunction('exists', @NativeFs));
  fsObj.SetOwn('stat', FInterp.CreateHostFunction('stat', @NativeFs));
  fsObj.SetOwn('listDir', FInterp.CreateHostFunction('listDir', @NativeFs));
  fsObj.SetOwn('mkdir', FInterp.CreateHostFunction('mkdir', @NativeFs));
  fsObj.SetOwn('remove', FInterp.CreateHostFunction('remove', @NativeFs));
  fsObj.SetOwn('rename', FInterp.CreateHostFunction('rename', @NativeFs));
  ui.SetOwn('fs', FInterp.ObjectValue(fsObj));
  execObj := FInterp.CreateHostObject('Object');
  execObj.SetOwn('run', FInterp.CreateHostFunction('run', @NativeExec));
  ui.SetOwn('exec', FInterp.ObjectValue(execObj));
  storageObj := FInterp.CreateHostObject('Object');
  storageObj.SetOwn('get', FInterp.CreateHostFunction('get', @NativeStorage));
  storageObj.SetOwn('set', FInterp.CreateHostFunction('set', @NativeStorage));
  ui.SetOwn('storage', FInterp.ObjectValue(storageObj));
  FInterp.GlobalObject.SetOwn('ui', FInterp.ObjectValue(ui));
end;

function TXuiScriptIO.InFlight: Integer;
begin
  Result := FInFlight;
end;

procedure TXuiScriptIO.Submit(AReq: TXuiIoRequest);
begin
  Inc(FInFlight);
  if FSyncMode then
    ExecFileSync(AReq)
  else
  begin
    if FWorker = nil then
      FWorker := TXuiIoWorker.Create(Self);
    EnterCriticalSection(FQueueLock);
    try
      FQueue.Add(AReq);
    finally
      LeaveCriticalSection(FQueueLock);
    end;
    FQueueEvent.SetEvent;
  end;
end;

// SyncMode：调用线程内同步执行并入完成队列（结果仍经 PumpCompletions 派发）
procedure TXuiScriptIO.ExecFileSync(AReq: TXuiIoRequest);
var
  res: TXuiIoResult;
begin
  res := TXuiIoResult.Create;
  res.Id := AReq.Id;
  try
    if Assigned(FExecutor) then
      FExecutor(AReq, res)
    else
      RealExecute(AReq, res);
  except
    on E: Exception do
    begin
      res.Ok := False;
      res.ErrMsg := E.Message;
    end;
  end;
  AReq.Free;
  EnterCriticalSection(FDoneLock);
  try
    FDone.Add(res);
  finally
    LeaveCriticalSection(FDoneLock);
  end;
end;

procedure TXuiScriptIO.WorkerLoop;
var
  req: TXuiIoRequest;
  res: TXuiIoResult;
begin
  while not TThread.CheckTerminated do
  begin
    FQueueEvent.WaitFor(100);
    req := nil;
    EnterCriticalSection(FQueueLock);
    try
      if FQueue.Count > 0 then
      begin
        req := TXuiIoRequest(FQueue[0]);
        FQueue.Extract(req);
      end;
    finally
      LeaveCriticalSection(FQueueLock);
    end;
    if req = nil then
      Continue;
    res := TXuiIoResult.Create;
    res.Id := req.Id;
    try
      if Assigned(FExecutor) then
        FExecutor(req, res)
      else
        RealExecute(req, res);
    except
      on E: Exception do
      begin
        res.Ok := False;
        res.ErrMsg := E.Message;
      end;
    end;
    req.Free;
    EnterCriticalSection(FDoneLock);
    try
      FDone.Add(res);
    finally
      LeaveCriticalSection(FDoneLock);
    end;
  end;
end;

// 默认执行器（工作线程上下文）：只做系统调用，不触碰 JS 值
procedure TXuiScriptIO.RealExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
var
  fs: TFileStream;
  n: Integer;
  buf: RawByteString;
begin
  try
    case AReq.Kind of
      iokFsRead:
        begin
          fs := TFileStream.Create(AReq.Path, fmOpenRead or fmShareDenyWrite);
          try
            n := fs.Size;
            SetLength(ARes.Data, n);
            if n > 0 then
              fs.ReadBuffer(ARes.Data[1], n);
          finally
            fs.Free;
          end;
          ARes.Ok := True;
        end;
      iokFsWrite:
        begin
          buf := AReq.Text;
          n := System.Length(buf);
          fs := TFileStream.Create(AReq.Path, fmCreate);
          try
            if n > 0 then
              fs.WriteBuffer(buf[1], n);
          finally
            fs.Free;
          end;
          ARes.Ok := True;
        end;
      iokFsAppend,
      iokFsExists, iokFsStat, iokFsList, iokFsMkdir, iokFsRemove, iokFsRename:
        FsExecute(AReq, ARes);
      iokExec:
        ExecExecute(AReq, ARes);
      {$IFDEF WINDOWS}
      iokHttpGet, iokHttpPost: HttpExecute(AReq, ARes);
      {$ENDIF}
    end;
  except
    on E: Exception do
    begin
      ARes.Ok := False;
      ARes.ErrMsg := E.Message;
    end;
  end;
end;

{ 文件系统补充操作（工作线程上下文）。路径已在 NativeFs 侧解析为绝对路径，
  这里只做系统调用；各分支自行决定失败是"抛异常 → reject"还是"结果里带状态"。 }
procedure TXuiScriptIO.FsExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
var
  fs: TFileStream;
  n: Integer;
  buf: RawByteString;
  sr: TSearchRec;
  rec: TStringList;

  procedure FillStat(const APath: string);
  var
    age: LongInt;
  begin
    if DirectoryExists(APath) then
    begin
      ARes.IsDir := True;
      ARes.Value := 0;
    end
    else if FileExists(APath) then
    begin
      ARes.IsDir := False;
      fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
      try
        ARes.Value := fs.Size;
      finally
        fs.Free;
      end;
    end
    else
      Exit;   // Flag 保持 False：调用方据此知道"不存在"
    age := FileAge(APath);
    if age <> -1 then
      ARes.MTime := Int64(age) * 1000;
    ARes.Flag := True;
  end;

begin
  case AReq.Kind of
    iokFsAppend:
      begin
        buf := AReq.Text;
        n := System.Length(buf);
        if FileExists(AReq.Path) then
          fs := TFileStream.Create(AReq.Path, fmOpenReadWrite or fmShareDenyNone)
        else
          fs := TFileStream.Create(AReq.Path, fmCreate);
        try
          fs.Seek(0, soEnd);
          if n > 0 then
            fs.WriteBuffer(buf[1], n);
        finally
          fs.Free;
        end;
        ARes.Ok := True;
      end;
    iokFsExists:
      begin
        ARes.Flag := FileExists(AReq.Path) or DirectoryExists(AReq.Path);
        ARes.Ok := True;
      end;
    iokFsStat:
      begin
        FillStat(AReq.Path);
        ARes.Ok := True;
      end;
    iokFsList:
      begin
        if not DirectoryExists(AReq.Path) then
          raise Exception.Create('目录不存在: ' + AReq.Path);
        // 排序后回传：让调用方的递归遍历顺序稳定，搜索结果可复现
        rec := TStringList.Create;
        try
          if FindFirst(IncludeTrailingPathDelimiter(AReq.Path) + '*', faAnyFile, sr) = 0 then
          begin
            try
              repeat
                if (sr.Name = '.') or (sr.Name = '..') then
                  Continue;
                if (sr.Attr and faDirectory) <> 0 then
                  rec.Add(sr.Name + #9 + 'd' + #9 + '0')
                else
                  rec.Add(sr.Name + #9 + 'f' + #9 + IntToStr(sr.Size));
              until FindNext(sr) <> 0;
            finally
              FindClose(sr);
            end;
          end;
          rec.Sort;
          ARes.Items.Assign(rec);
        finally
          rec.Free;
        end;
        ARes.Ok := True;
      end;
    iokFsMkdir:
      begin
        if not ForceDirectories(AReq.Path) then
          raise Exception.Create('无法创建目录: ' + AReq.Path);
        ARes.Flag := True;
        ARes.Ok := True;
      end;
    iokFsRemove:
      begin
        if DirectoryExists(AReq.Path) then
        begin
          if not RemoveDir(AReq.Path) then
            raise Exception.Create('目录非空或无法删除: ' + AReq.Path);
          ARes.Flag := True;
        end
        else if FileExists(AReq.Path) then
        begin
          if not DeleteFile(AReq.Path) then
            raise Exception.Create('无法删除文件: ' + AReq.Path);
          ARes.Flag := True;
        end
        else
          ARes.Flag := False;   // 不存在不算失败：调用方拿 Flag 决定要不要报错
        ARes.Ok := True;
      end;
    iokFsRename:
      begin
        // 目标已存在时先删再改名（Windows 的 RenameFile 不覆盖目标）。这正是"替换写"
        // 需要的语义：先写 <目标>.tmp，再 rename 覆盖，中途失败不会留下半个目标文件。
        if FileExists(AReq.Path2) then
          DeleteFile(AReq.Path2)
        else if DirectoryExists(AReq.Path2) then
          RemoveDir(AReq.Path2);
        if not RenameFile(AReq.Path, AReq.Path2) then
          raise Exception.Create('无法重命名: ' + AReq.Path + ' -> ' + AReq.Path2);
        ARes.Ok := True;
      end;
  end;
end;

{$IFDEF WINDOWS}
function IsValidUtf8Bytes(const S: string): Boolean;
var
  i, n, b: Integer;
begin
  Result := True;
  n := Length(S);
  i := 1;
  while i <= n do
  begin
    b := Byte(S[i]);
    if b <= $7F then
      Inc(i)
    else if (b >= $C2) and (b <= $DF) then
    begin
      if (i + 1 > n) or ((Byte(S[i + 1]) and $C0) <> $80) then
        Exit(False);
      Inc(i, 2);
    end
    else if (b >= $E0) and (b <= $EF) then
    begin
      if (i + 2 > n) or
         ((Byte(S[i + 1]) and $C0) <> $80) or
         ((Byte(S[i + 2]) and $C0) <> $80) then
        Exit(False);
      if (b = $E0) and (Byte(S[i + 1]) < $A0) then Exit(False);
      if (b = $ED) and (Byte(S[i + 1]) > $9F) then Exit(False);
      Inc(i, 3);
    end
    else if (b >= $F0) and (b <= $F4) then
    begin
      if (i + 3 > n) or
         ((Byte(S[i + 1]) and $C0) <> $80) or
         ((Byte(S[i + 2]) and $C0) <> $80) or
         ((Byte(S[i + 3]) and $C0) <> $80) then
        Exit(False);
      if (b = $F0) and (Byte(S[i + 1]) < $90) then Exit(False);
      if (b = $F4) and (Byte(S[i + 1]) > $8F) then Exit(False);
      Inc(i, 4);
    end
    else
      Exit(False);
  end;
end;

function NormalizeToUtf8(const S: string): string;
var
  cp: UINT;
  wideLen: Integer;
  wideBuf: UnicodeString;
begin
  if S = '' then
    Exit('');
  if IsValidUtf8Bytes(S) then
    Exit(S);

  cp := GetConsoleOutputCP;
  if (cp = 0) or (cp = 65001) then
    cp := GetOEMCP;
  if cp = 0 then
    cp := CP_ACP;

  wideLen := MultiByteToWideChar(cp, 0, PAnsiChar(S), Length(S), nil, 0);
  if wideLen > 0 then
  begin
    SetLength(wideBuf, wideLen);
    MultiByteToWideChar(cp, 0, PAnsiChar(S), Length(S), PWideChar(wideBuf), wideLen);
    Exit(UTF8Encode(wideBuf));
  end;
  Result := S;
end;
{$ELSE}
function NormalizeToUtf8(const S: string): string;
begin
  Result := S;
end;
{$ENDIF}

{ 外部命令执行（工作线程上下文）。

  与 shell 的分工：不做命令行词法解析（引号/管道/重定向交给系统 shell），不做命令
  白名单——"哪些命令允许跑"是应用层的策略与审批，引擎只提供这个能力（与 Electron
  的 child_process 同性质）。

  输出必须边跑边排空：stdout/stderr 两个管道各有缓冲，若等进程结束再读，子进程写满
  管道就会永远阻塞，双方死锁。所以循环里同时读两个流；超时则终止进程再排空剩余。 }
procedure TXuiScriptIO.ExecExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
var
  proc: TProcess;
  opts: TProcessOptions;
  started: QWord;
  timeoutMs, cap: Integer;
  outAcc, errAcc: string;
  truncOut, truncErr: Boolean;

  procedure Drain(AStream: TInputPipeStream; var AAcc: string;
    AStreamCap: Integer; var ATruncated: Boolean; AFinal: Boolean);
  var
    avail, want, got: Integer;
    buf: array[0..8191] of Byte;
  begin
    while True do
    begin
      avail := AStream.NumBytesAvailable;
      if avail <= 0 then
        Break;
      if avail > SizeOf(buf) then
        want := SizeOf(buf)
      else
        want := avail;
      got := AStream.Read(buf[0], want);
      if got <= 0 then
        Break;
      if System.Length(AAcc) < AStreamCap then
      begin
        if System.Length(AAcc) + got > AStreamCap then
        begin
          AAcc := AAcc + Copy(string(PAnsiChar(@buf[0])), 1,
            AStreamCap - System.Length(AAcc));
          ATruncated := True;
        end
        else
          AAcc := AAcc + Copy(string(PAnsiChar(@buf[0])), 1, got);
      end
      else
        ATruncated := True;   // 超限部分继续读掉丢弃，避免子进程写管道时阻塞
      if not AFinal then
        Break;
    end;
  end;

begin
  if Trim(AReq.Cmd) = '' then
    raise Exception.Create('命令不能为空');
  cap := AReq.MaxBytes;
  if cap <= 0 then
    cap := 64 * 1024;
  timeoutMs := AReq.TimeoutMs;
  if timeoutMs <= 0 then
    timeoutMs := 30000;

  outAcc := '';
  errAcc := '';
  truncOut := False;
  truncErr := False;
  started := GetTickCount64;

  proc := TProcess.Create(nil);
  try
    {$IFDEF WINDOWS}
    proc.Executable := GetEnvironmentVariable('COMSPEC');
    if proc.Executable = '' then
      proc.Executable := 'cmd.exe';
    proc.Parameters.Add('/c');
    {$ELSE}
    proc.Executable := '/bin/sh';
    proc.Parameters.Add('-c');
    {$ENDIF}
    proc.Parameters.Add(AReq.Cmd);
    if AReq.Cwd <> '' then
      proc.CurrentDirectory := AReq.Cwd;
    opts := [poUsePipes];
    {$IFDEF WINDOWS}
    opts := opts + [poNoConsole];
    {$ENDIF}
    proc.Options := opts;

    proc.Execute;
    while True do
    begin
      Drain(proc.Output, outAcc, cap, truncOut, False);
      Drain(proc.Stderr, errAcc, cap, truncErr, False);
      if not proc.Running then
      begin
        Drain(proc.Output, outAcc, cap, truncOut, True);   // 退出后把剩余字节读净
        Drain(proc.Stderr, errAcc, cap, truncErr, True);
        Break;
      end;
      if GetTickCount64 - started > QWord(timeoutMs) then
      begin
        ARes.TimedOut := True;
        proc.Terminate(1);
        Drain(proc.Output, outAcc, cap, truncOut, True);
        Drain(proc.Stderr, errAcc, cap, truncErr, True);
        Break;
      end;
      Sleep(10);
    end;

    if ARes.TimedOut then
      ARes.ExitCode := -1
    else
      ARes.ExitCode := proc.ExitStatus;
  finally
    proc.Free;
  end;

  ARes.StdOut := NormalizeToUtf8(outAcc);
  ARes.StdErr := NormalizeToUtf8(errAcc);
  ARes.Truncated := truncOut or truncErr;
  ARes.DurationMs := Int64(GetTickCount64 - started);
  ARes.Ok := True;   // 跑起来即成功：退出码非 0 / 超时都通过字段回报，由调用方判定
end;

{$IFDEF WINDOWS}
// WinHTTP 请求（工作线程上下文；成功填 Status/Headers/Data，失败抛异常）
procedure TXuiScriptIO.HttpExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
var
  url, host, path, wUrl, wHost, wPath, wHeaders, ws: WideString;
  rest, port: Integer;
  secure, isPost: Boolean;
  verb: PWideChar;
  flags: DWORD;
  hs, hc, hr: THandle;
  bodyBytes: RawByteString;
  bodyLen: DWORD;
  sc: array[0..31] of WideChar;
  scLen: DWORD;
  hLen: DWORD;
  avail, readn: DWORD;
  chunk: RawByteString;
  timeoutMs: Integer;
begin
  url := Utf8Decode(AReq.Url);
  if Pos('https://', url) = 1 then
  begin
    secure := True;
    rest := 9;
    port := 443;
  end
  else if Pos('http://', url) = 1 then
  begin
    secure := False;
    rest := 8;
    port := 80;
  end
  else
    raise Exception.Create('URL 仅支持 http/https');
  wUrl := Copy(url, rest, MaxInt);
  host := wUrl;
  path := '/';
  rest := Pos('/', wUrl);
  if rest > 0 then
  begin
    host := Copy(wUrl, 1, rest - 1);
    path := Copy(wUrl, rest, MaxInt);
  end;
  rest := Pos(':', host);
  if rest > 0 then
  begin
    port := StrToIntDef(Copy(host, rest + 1, MaxInt), port);
    host := Copy(host, 1, rest - 1);
  end;
  wHost := host;
  wPath := path;

  hs := WinHttpOpen('lui-io', 0, nil, nil, 0);
  if hs = 0 then
    raise Exception.Create('WinHttpOpen 失败');
  try
    timeoutMs := AReq.TimeoutMs;
    if timeoutMs <= 0 then
      timeoutMs := 30000;
    WinHttpSetTimeouts(hs, timeoutMs, timeoutMs, timeoutMs, timeoutMs);
    hc := WinHttpConnect(hs, PWideChar(wHost), Word(port), 0);
    if hc = 0 then
      raise Exception.Create('无法连接 ' + Utf8Encode(wHost));
    try
      isPost := (AReq.Kind = iokHttpPost);
      // 动词由请求种类决定，TLS 只决定端口与 WINHTTP_FLAG_SECURE：
      // 此前用 secure 选动词，导致 https GET 发成 POST、http POST 发成 GET
      if isPost then
        verb := 'POST'
      else
        verb := 'GET';
      if secure then
        flags := WINHTTP_FLAG_SECURE
      else
        flags := 0;
      hr := WinHttpOpenRequest(hc, PWideChar(verb), PWideChar(wPath), nil, nil,
        nil, flags);
      if hr = 0 then
        raise Exception.Create('WinHttpOpenRequest 失败');
      try
        if AReq.Headers <> '' then
        begin
          wHeaders := Utf8Decode(AReq.Headers);
          WinHttpAddRequestHeaders(hr, PWideChar(wHeaders), DWORD(-1),
            $20000000);  // WINHTTP_ADDREQ_FLAG_ADD
        end;
        bodyBytes := '';
        bodyLen := 0;
        if isPost then
        begin
          bodyBytes := AReq.Body;
          bodyLen := System.Length(bodyBytes);
        end;
        if not WinHttpSendRequest(hr, nil, 0, Pointer(bodyBytes), bodyLen,
          bodyLen, 0) then
          raise Exception.Create('请求发送失败（网络/超时）');
        if not WinHttpReceiveResponse(hr, nil) then
          raise Exception.Create('响应接收失败（网络/超时）');
        // 状态码
        scLen := SizeOf(sc);
        if WinHttpQueryHeaders(hr, WINHTTP_QUERY_STATUS_CODE, nil, @sc, scLen, nil) then
          ARes.Status := StrToIntDef(WideCharToString(sc), 0);
        // 响应头（原始块）
        hLen := 0;
        WinHttpQueryHeaders(hr, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil, nil, hLen, nil);
        if hLen > 0 then
        begin
          SetLength(ws, (hLen + 1) div 2);
          if WinHttpQueryHeaders(hr, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil,
            @ws[1], hLen, nil) then
            ARes.Headers := Utf8Encode(ws);
        end;
        // 响应体
        repeat
          if not WinHttpQueryDataAvailable(hr, avail) then
            break;
          if avail = 0 then
            break;
          SetLength(chunk, avail);
          if not WinHttpReadData(hr, @chunk[1], avail, readn) then
            break;
          SetLength(chunk, readn);
          ARes.Data := ARes.Data + chunk;
        until False;
        ARes.Ok := True;
      finally
        WinHttpCloseHandle(hr);
      end;
    finally
      WinHttpCloseHandle(hc);
    end;
  finally
    WinHttpCloseHandle(hs);
  end;
end;
{$ENDIF}

// 主线程：排空完成队列 → 查挂起表 → settle Promise（唯一的 JS 值触碰点）
procedure TXuiScriptIO.PumpCompletions;
var
  res: TXuiIoResult;
  pend: TXuiIoPending;
  args: TXuiJsValueArray;

  function FindPending(AId: Integer): TXuiIoPending;
  var
    k: Integer;
  begin
    Result := nil;
    for k := 0 to FPending.Count - 1 do
      if TXuiIoPending(FPending[k]).Id = AId then
        Exit(TXuiIoPending(FPending[k]));
  end;

  procedure TakeResult;
  begin
    res := nil;
    EnterCriticalSection(FDoneLock);
    try
      if FDone.Count > 0 then
      begin
        res := TXuiIoResult(FDone[0]);
        FDone.Extract(res);
      end;
    finally
      LeaveCriticalSection(FDoneLock);
    end;
  end;

begin
  while True do
  begin
    TakeResult;
    if res = nil then
      Exit;
    try
      Dec(FInFlight);
      pend := FindPending(res.Id);
      if pend = nil then
        Continue;   // 挂起表已清理（应用关闭等）：丢弃结果
      SetLength(args, 1);
      if res.Ok then
      begin
        case pend.Kind of
          iokHttpGet, iokHttpPost: args[0] := MakeResponse(res);
          iokFsRead: args[0] := FInterp.Str(res.Data);
          iokFsWrite, iokFsAppend, iokFsMkdir, iokFsRename: args[0] := FInterp.Undefined;
          iokFsExists, iokFsRemove: args[0] := FInterp.Bool(res.Flag);
          iokFsStat: args[0] := MakeStatResult(res);
          iokFsList: args[0] := MakeListResult(res);
          iokExec: args[0] := MakeExecResult(res);
        else
          args[0] := FInterp.Undefined;
        end;
        FInterp.CallWithThis(FInterp.FunctionValue(pend.Resolve),
          FInterp.Undefined, args);
      end
      else
      begin
        args[0] := FInterp.Str('Error: ' + res.ErrMsg);
        FInterp.CallWithThis(FInterp.FunctionValue(pend.Reject),
          FInterp.Undefined, args);
        if Assigned(FOnIoError) then
          FOnIoError(res.ErrMsg);   // stage=io 记录，不中断应用
      end;
      FPending.Remove(pend);
    finally
      res.Free;
    end;
  end;
end;

// GC 根：挂起请求的 Promise 控制函数（连同其 Tag 的 promise）在等待期间保活
procedure TXuiScriptIO.MarkPendingRoots;
var
  i: Integer;
  pend: TXuiIoPending;
begin
  for i := 0 to FPending.Count - 1 do
  begin
    pend := TXuiIoPending(FPending[i]);
    FInterp.MarkRootValue(FInterp.FunctionValue(pend.Resolve));
    FInterp.MarkRootValue(FInterp.FunctionValue(pend.Reject));
  end;
end;

function TXuiScriptIO.NewPending(AKind: TXuiIoKind; out AId: Integer): TXuiIoPending;
var
  p: TXuiJsPromise;
begin
  p := FInterp.NewPromise;
  Result := TXuiIoPending.Create;
  Result.Kind := AKind;
  Result.Promise := p;
  Result.Resolve := FInterp.NewControlFunction('resolve', p);
  Result.Reject := FInterp.NewControlFunction('reject', p);
  Inc(FNextId);
  Result.Id := FNextId;
  AId := FNextId;
  FPending.Add(Result);
end;

function TXuiScriptIO.MakeResponse(ARes: TXuiIoResult): TXuiJsValue;
var
  obj: TXuiJsObject;
begin
  obj := FInterp.CreateHostObject('Response');
  obj.SetOwn('status', FInterp.Num(ARes.Status));
  obj.SetOwn('headers', FInterp.Str(ARes.Headers));
  obj.SetOwn('data', FInterp.Str(ARes.Data));
  obj.SetOwn('text', FInterp.CreateHostFunction('text', @NativeRespText));
  obj.SetOwn('json', FInterp.CreateHostFunction('json', @NativeRespJson));
  Result := FInterp.ObjectValue(obj);
end;

function TXuiScriptIO.NativeRespText(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  if (AThis.Kind = jvObject) and (AThis.Obj <> nil) then
    Exit(AThis.Obj.GetOwn('data'));
  Result := FInterp.Undefined;
end;

function TXuiScriptIO.NativeRespJson(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  text, parse: TXuiJsValue;
begin
  if (AThis.Kind = jvObject) and (AThis.Obj <> nil) then
    text := AThis.Obj.GetOwn('data')
  else
    text := FInterp.Undefined;
  parse := FInterp.PropValue(FInterp.GetGlobal('JSON'), 'parse');
  Result := FInterp.Call(parse, [text]);
end;

function TXuiScriptIO.OptTimeout(const AOpts: TXuiJsValue): Integer;
begin
  Result := 0;
  if (AOpts.Kind = jvObject) and (AOpts.Obj <> nil) then
    Result := FInterp.ArgInt([FInterp.PropValue(AOpts, 'timeout')], 0);
end;

// opts.headers（对象）→ "Name: value" 行。文档契约为 {timeout?, headers?}：
// 此前直接把 opts 的顶层属性当请求头发，导致 opts.headers 整对象被 toString 成一行
// 垃圾头（"headers: [object Object]"），而 Content-Type / Authorization 根本没发出。
// 现优先取嵌套 headers；无嵌套时兼容旧的平铺写法，但跳过 timeout / signal 选项键。
function TXuiScriptIO.OptHeaders(const AOpts: TXuiJsValue): string;
var
  o, hdrObj: TXuiJsObject;
  hdrVal: TXuiJsValue;
  i: Integer;

  procedure AddProp(AObj: TXuiJsObject; AIndex: Integer);
  var
    nm: string;
  begin
    nm := TXuiJsProp(AObj.Props[AIndex]).Name;
    if (nm = 'timeout') or (nm = 'signal') then
      Exit;
    Result := Result + nm + ': ' +
      FInterp.ToStringValue(TXuiJsProp(AObj.Props[AIndex]).Value) + #13#10;
  end;

begin
  Result := '';
  if (AOpts.Kind <> jvObject) or (AOpts.Obj = nil) then
    Exit;
  o := AOpts.Obj;
  hdrVal := o.GetOwn('headers');
  if (hdrVal.Kind = jvObject) and (hdrVal.Obj <> nil) then
  begin
    hdrObj := hdrVal.Obj;
    for i := 0 to hdrObj.Props.Count - 1 do
      AddProp(hdrObj, i);
    Exit;
  end;
  for i := 0 to o.Props.Count - 1 do
    AddProp(o, i);
end;

procedure TXuiScriptIO.CheckSignal(const AOpts: TXuiJsValue);
var
  sig: TXuiJsValue;
begin
  if (AOpts.Kind = jvObject) and (AOpts.Obj <> nil) then
  begin
    sig := AOpts.Obj.GetOwn('signal');
    if (sig.Kind <> jvUndefined) and (sig.Kind <> jvNull) then
      raise EXuiJsRuntime.Create('暂不支持 AbortSignal 取消');
  end;
end;

// ui.http.get(url, opts?) / ui.http.post(url, body, opts?)
function TXuiScriptIO.NativeHttp(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  pend: TXuiIoPending;
  req: TXuiIoRequest;
  id: Integer;
  opts: TXuiJsValue;
begin
  opts := FInterp.Undefined;
  req := TXuiIoRequest.Create;
  if AFn.Name = 'get' then
  begin
    req.Kind := iokHttpGet;
    req.Url := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0));
    opts := FInterp.ArgAtPublic(AArgs, 1);
  end
  else
  begin
    req.Kind := iokHttpPost;
    req.Url := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0));
    req.Body := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1));
    opts := FInterp.ArgAtPublic(AArgs, 2);
  end;
  CheckSignal(opts);
  req.TimeoutMs := OptTimeout(opts);
  req.Headers := OptHeaders(opts);
  pend := NewPending(req.Kind, id);
  req.Id := id;
  Submit(req);
  Result := FInterp.PendingPromiseValue(pend.Promise);
end;

// ui.fs.readText(path) / ui.fs.writeText(path, text) 及 M13 的文件系统补充操作。
// 路径统一在进队列前解析：相对路径锚定应用根（ADR 49 的同一基准），绝对路径原样。
function TXuiScriptIO.NativeFs(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  pend: TXuiIoPending;
  req: TXuiIoRequest;
  id: Integer;
  kind: TXuiIoKind;
  nm: string;
begin
  nm := LowerCase(AFn.Name);
  if nm = 'readtext' then
    kind := iokFsRead
  else if nm = 'writetext' then
    kind := iokFsWrite
  else if nm = 'appendtext' then
    kind := iokFsAppend
  else if nm = 'exists' then
    kind := iokFsExists
  else if nm = 'stat' then
    kind := iokFsStat
  else if nm = 'listdir' then
    kind := iokFsList
  else if nm = 'mkdir' then
    kind := iokFsMkdir
  else if nm = 'remove' then
    kind := iokFsRemove
  else
    kind := iokFsRename;

  pend := NewPending(kind, id);
  req := TXuiIoRequest.Create;
  req.Id := id;
  req.Kind := kind;
  req.Path := XuiAppPathResolve(FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0)));
  case kind of
    iokFsWrite, iokFsAppend:
      req.Text := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1));
    iokFsRename:
      req.Path2 := XuiAppPathResolve(FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1)));
  end;
  Submit(req);
  Result := FInterp.PendingPromiseValue(pend.Promise);
end;

// ui.exec.run(cmd, opts?)：opts = { cwd?, timeout?, maxBytes? }
// 解析为 { ok, exitCode, stdout, stderr, timedOut, truncated, durationMs }。
// 退出码非 0 与超时都不算 Promise 失败——那是命令的正常结果，由调用方判定；
// 只有"根本跑不起来"（可执行文件不存在、权限等）才 reject。
function TXuiScriptIO.NativeExec(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  pend: TXuiIoPending;
  req: TXuiIoRequest;
  id: Integer;
  opts, v: TXuiJsValue;
begin
  opts := FInterp.ArgAtPublic(AArgs, 1);
  CheckSignal(opts);
  pend := NewPending(iokExec, id);
  req := TXuiIoRequest.Create;
  req.Id := id;
  req.Kind := iokExec;
  req.Cmd := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0));
  // 空命令不在这里抛：那会让错误不可被 JS catch（EXuiJsRuntime 是引擎级错误）。
  // 走正常队列，由执行器判为失败 → Promise reject，调用方能 catch/finally 处理。
  req.TimeoutMs := OptTimeout(opts);
  if (opts.Kind = jvObject) and (opts.Obj <> nil) then
  begin
    // 必须先判类型取值：ToStringValue(undefined) 会给字面量 "undefined"，把它当 cwd
    // 传下去就成了一个不存在的目录，CreateProcess 会以 ERROR_DIRECTORY(267) 失败
    v := FInterp.PropValue(opts, 'cwd');
    if (v.Kind = jvString) or (v.Kind = jvNumber) then
      req.Cwd := XuiAppPathResolve(FInterp.ToStringValue(v));
    req.MaxBytes := FInterp.ArgInt([FInterp.PropValue(opts, 'maxBytes')], 0);
  end;
  Submit(req);
  Result := FInterp.PendingPromiseValue(pend.Promise);
end;

function TXuiScriptIO.MakeExecResult(ARes: TXuiIoResult): TXuiJsValue;
var
  obj: TXuiJsObject;
begin
  obj := FInterp.CreateHostObject('ExecResult');
  obj.SetOwn('ok', FInterp.Bool(True));
  obj.SetOwn('exitCode', FInterp.Num(ARes.ExitCode));
  obj.SetOwn('stdout', FInterp.Str(ARes.StdOut));
  obj.SetOwn('stderr', FInterp.Str(ARes.StdErr));
  obj.SetOwn('timedOut', FInterp.Bool(ARes.TimedOut));
  obj.SetOwn('truncated', FInterp.Bool(ARes.Truncated));
  obj.SetOwn('durationMs', FInterp.Num(ARes.DurationMs));
  Result := FInterp.ObjectValue(obj);
end;

function TXuiScriptIO.MakeStatResult(ARes: TXuiIoResult): TXuiJsValue;
var
  obj: TXuiJsObject;
begin
  obj := FInterp.CreateHostObject('StatResult');
  obj.SetOwn('exists', FInterp.Bool(ARes.Flag));
  obj.SetOwn('isDir', FInterp.Bool(ARes.IsDir));
  obj.SetOwn('size', FInterp.Num(ARes.Value));
  obj.SetOwn('mtimeMs', FInterp.Num(ARes.MTime));
  Result := FInterp.ObjectValue(obj);
end;

// 每行 "名称<TAB>d|f<TAB>字节数" → [{ name, isDir, size }]
function TXuiScriptIO.MakeListResult(ARes: TXuiIoResult): TXuiJsValue;
var
  items: TXuiJsValueArray;
  i, p, q, n: Integer;
  line: string;
  entry: TXuiJsObject;
begin
  n := 0;
  SetLength(items, ARes.Items.Count);
  for i := 0 to ARes.Items.Count - 1 do
  begin
    line := ARes.Items[i];
    p := Pos(#9, line);
    if p <= 0 then
      Continue;
    q := PosEx(#9, line, p + 1);
    if q <= 0 then
      Continue;
    entry := FInterp.CreateHostObject('DirEntry');
    entry.SetOwn('name', FInterp.Str(Copy(line, 1, p - 1)));
    entry.SetOwn('isDir', FInterp.Bool(Copy(line, p + 1, q - p - 1) = 'd'));
    entry.SetOwn('size', FInterp.Num(StrToInt64Def(Copy(line, q + 1, MaxInt), 0)));
    items[n] := FInterp.ObjectValue(entry);
    Inc(n);
  end;
  SetLength(items, n);
  Result := FInterp.MakeArray(items);
end;

procedure TXuiScriptIO.LoadStorage;
begin
  if (FStorage.Count = 0) and (FStorageFile <> '') and FileExists(FStorageFile) then
    FStorage.LoadFromFile(FStorageFile);
end;

procedure TXuiScriptIO.SaveStorage;
begin
  if (FStorageFile <> '') and FStorageDirty then
  begin
    // 目标目录可能还不存在（首次运行）：不建目录会静默丢掉整份配置
    if not DirectoryExists(ExtractFileDir(FStorageFile)) then
      ForceDirectories(ExtractFileDir(FStorageFile));
    FStorage.SaveToFile(FStorageFile);
    FStorageDirty := False;
  end;
end;

// ui.storage.get(key): string | null（同步）/ ui.storage.set(key, value)
function TXuiScriptIO.NativeStorage(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  key: string;
  idx: Integer;
begin
  LoadStorage;
  key := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0));
  idx := FStorage.IndexOfName(key);
  if AFn.Name = 'get' then
  begin
    if idx >= 0 then
      Exit(FInterp.Str(FStorage.ValueFromIndex[idx]));
    Exit(FInterp.NullValue);
  end;
  if idx >= 0 then
    FStorage[idx] := key + '=' + FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1))
  else
    FStorage.Add(key + '=' + FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1)));
  FStorageDirty := True;
  SaveStorage;
  Result := FInterp.Undefined;
end;

end.
