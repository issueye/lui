unit xui_script_io;

{$mode objfpc}{$H+}

{ 真实 I/O（M6 P4，ADR 18）：ui.http / ui.fs / ui.storage。

  铁律（线程安全）：工作线程只做系统调用，不持有、不创建、不触碰任何 JS 值；
  跨线程只传"原始数据 + 状态码 + 请求 Id"；所有 JS 值转换与 Promise settle 都在主线程
  （PumpCompletions 由引擎 Tick 驱动）完成。

  - HTTP：WinHTTP 直声明（winhttp.dll，与既有 gdiplus/imm32 同做法，零第三方依赖）
  - 文件：TFileStream 读写，与 HTTP 共用同一个 I/O 工作线程串行执行
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
  TXuiIoKind = (iokHttpGet, iokHttpPost, iokFsRead, iokFsWrite);

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
    TimeoutMs: Integer;   // 0 = 默认（30s）
    Path: string;         // fs
    Text: string;         // fs write
  end;

  // 结果（工作线程填充，主线程消费后释放）
  TXuiIoResult = class
  public
    Id: Integer;
    Ok: Boolean;
    Status: Integer;      // http 状态码；fs 为 0
    Headers: string;      // http 响应头（原始 CRLF 块）
    Data: string;         // 响应体 / 文件内容（原始字节）
    ErrMsg: string;
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
    {$IFDEF WINDOWS}procedure HttpExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);{$ENDIF}
    procedure ExecFileSync(AReq: TXuiIoRequest);   // SyncMode：调用线程内完成
    procedure MarkPendingRoots;   // GC 根：挂起请求的 Promise 控制函数
    function NativeHttp(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeFs(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
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
  ui, httpObj, fsObj, storageObj: TXuiJsObject;
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
  ui.SetOwn('fs', FInterp.ObjectValue(fsObj));
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

{$IFDEF WINDOWS}
// WinHTTP 请求（工作线程上下文；成功填 Status/Headers/Data，失败抛异常）
procedure TXuiScriptIO.HttpExecute(AReq: TXuiIoRequest; ARes: TXuiIoResult);
var
  url, host, path, wUrl, wHost, wPath, wHeaders, ws: WideString;
  rest, port: Integer;
  secure, isPost: Boolean;
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
      if secure then
        hr := WinHttpOpenRequest(hc, 'POST', PWideChar(wPath), nil, nil, nil,
          WINHTTP_FLAG_SECURE)
      else
        hr := WinHttpOpenRequest(hc, 'GET', PWideChar(wPath), nil, nil, nil, 0);
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
          iokFsWrite: args[0] := FInterp.Undefined;
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

function TXuiScriptIO.OptHeaders(const AOpts: TXuiJsValue): string;
var
  o: TXuiJsObject;
  i: Integer;
begin
  Result := '';
  if (AOpts.Kind <> jvObject) or (AOpts.Obj = nil) then
    Exit;
  o := AOpts.Obj;
  for i := 0 to o.Props.Count - 1 do
    Result := Result + TXuiJsProp(o.Props[i]).Name + ': ' +
      FInterp.ToStringValue(TXuiJsProp(o.Props[i]).Value) + #13#10;
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

// ui.fs.readText(path) / ui.fs.writeText(path, text)
function TXuiScriptIO.NativeFs(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  pend: TXuiIoPending;
  req: TXuiIoRequest;
  id: Integer;
  kind: TXuiIoKind;
begin
  if AFn.Name = 'readText' then
    kind := iokFsRead
  else
    kind := iokFsWrite;
  pend := NewPending(kind, id);
  req := TXuiIoRequest.Create;
  req.Id := id;
  req.Kind := kind;
  req.Path := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 0));
  if kind = iokFsWrite then
    req.Text := FInterp.ToStringValue(FInterp.ArgAtPublic(AArgs, 1));
  Submit(req);
  Result := FInterp.PendingPromiseValue(pend.Promise);
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
