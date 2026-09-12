unit xui_script;

{$mode objfpc}{$H+}

{ 脚本门面（M6 P0）。职责：
  - 编译缓存：源码 → AST（同一路径重复加载时复用）
  - 求值：脚本文件按序求值，注册到全局环境
  - 执行切片（Slice）：统一预算重置、异常捕获与错误路由（见 M6-异步设计 §3）
  - 原生注册：路径式 API（'ui.now' / 'document.find'），后续功能的统一挂点
  - GC 根管理：宿主长期持有的脚本值登记

  本单元不依赖 LCL 与引擎：DOM 桥在 xui_script_dom（leaf 单元），
  引擎只依赖本单元的类型与门面（分层规则见 M6 设计文档 §2）。 }

interface

uses
  Classes, SysUtils, Contnrs,
  xui_js_token, xui_js_parser, xui_js_runtime,
  xui_script_io;

type
  // 错误阶段（决定 UI 呈现方式）
  TXuiScriptStage = (
    ssCompile,           // 词法/语法/位置校验
    ssRuntime,           // 同步抛出
    ssUnhandledRejection,// Promise 未处理拒绝（P1 起使用）
    ssIO,                // I/O 失败（P4 起使用）
    ssBudget             // 超出指令预算
  );

  TXuiScriptErrorEvent = procedure(const AFile, AMessage: string;
    ALine, ACol: Integer; AStage: TXuiScriptStage) of object;

  // 编译单元（源码 → AST）
  TXuiScriptUnit = class
  public
    FileName: string;        // 源文件（来自字符串时为空）
    Source: string;
    Program_: TXuiJsProgram; // 拥有 AST
    destructor Destroy; override;
  end;

  TXuiScript = class
  private
    FInterp: TXuiJsInterp;
    FUnits: TObjectList;     // TXuiScriptUnit（编译缓存，自有）
    FOnError: TXuiScriptErrorEvent;
    FErrorCount: Integer;
    FLastErrorFile: string;
    FCurrentFile: string;   // 正在求值的脚本文件（组件模板相对路径以它为基准）
    FLastErrorMessage: string;
    FLastErrorLine: Integer;
    FLastErrorCol: Integer;
    FLastErrorStage: TXuiScriptStage;
    FIO: TXuiScriptIO;       // 真实 I/O（懒创建；ui.http/ui.fs 首次调用即装）
    FOnFlushReactive: TXuiGcRootsProc;   // M7：安全点响应式刷新（绑定引擎装配）
    FOnResetBindings: TXuiGcRootsProc;   // M7：文档重建作废绑定登记
    FSliceDepth: Integer;    // 切片嵌套深度（最外层才重置预算）
    function FindUnit(const AFileName: string): TXuiScriptUnit;
    procedure Report(const AFile, AMessage: string; ALine, ACol: Integer;
      AStage: TXuiScriptStage);
    // 从异常对象提取错误位置（EXuiJsSyntaxError 带行列）
    procedure ReportException(const AFile: string; E: Exception);
    // 未处理 Promise 拒绝（Interp 排水末回调）：预算超限归类为 budget
    procedure HandleUnhandledRejection(const AMessage: string);
    // 定时器宏任务回调内未捕获异常（Interp 泵回调）：预算超限归类为 budget
    procedure HandleCallbackError(const AMessage: string);
    // I/O 失败上报（TXuiScriptIO 完成回调）：stage=io
    procedure HandleIoError(const AMessage: string);
  public
    constructor Create;
    destructor Destroy; override;

    // 编译并缓存（同名文件重复调用复用已有 AST）
    function Compile(const ASource, AFileName: string): TXuiScriptUnit;
    function CompileFile(const AFileName: string): TXuiScriptUnit;

    // 求值：整个编译单元（顶层声明进入全局环境）
    function RunUnit(AUnit: TXuiScriptUnit): Boolean;
    function Run(const ASource, AFileName: string): Boolean;
    function RunFile(const AFileName: string): Boolean;

    // 执行切片：预算重置 + 错误路由 + 返回值
    // 事件处理器、定时器回调、Promise 恢复等都应经由这里进入脚本
    function InvokeSlice(const AFn: TXuiJsValue; const AArgs: TXuiJsValueArray): TXuiJsValue;
    function InvokeMethodSlice(const AFn, AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;

    // 排空微任务队列（安全点调用：切片退出 / Tick / 文档加载后；
    // 末尾对未处理拒绝上报一次，见 M6-异步设计 §4）
    procedure DrainMicrotasks;

    // M7 响应式：安全点回调（绑定引擎在安全点批量刷新声明式绑定）
    procedure FlushReactive;
    procedure MarkReactiveDirty;   // 脚本求值完成后请求一次首渲染
    procedure ResetBindings;       // 文档重建：作废旧节点上的绑定登记
    property OnFlushReactive: TXuiGcRootsProc read FOnFlushReactive write FOnFlushReactive;
    property OnResetBindings: TXuiGcRootsProc read FOnResetBindings write FOnResetBindings;

    // P4 真实 I/O（引擎 Tick 驱动完成泵；首次访问自动创建并注册 ui.http/ui.fs/ui.storage）
    function IO: TXuiScriptIO;
    procedure PumpIO;                // 排空 I/O 完成队列 → settle 对应 Promise
    function IoInFlight: Integer;    // 在途请求数（引擎 NeedsTick 计入）

    // P2 定时器宿主接口（引擎 Tick 驱动；时钟相对应用零点）
    procedure SetClockMs(ANowMs: Int64);   // 注入当前脚本时钟
    function PumpTimers: Integer;          // 执行到期定时器（每个宏任务切片后排微任务）
    function TimersPending: Integer;       // 未取消定时器数（引擎 NeedsTick 计入）

    // 全局作用域查询/调用（事件绑定的"脚本第二来源"）
    function HasGlobalFunction(const AName: string): Boolean;
    function CallGlobal(const AName: string; const AArgs: TXuiJsValueArray): TXuiJsValue;

    // 原生注册（后续功能挂载点）
    procedure RegisterNative(const APath: string; AFn: TXuiJsNativeFunc);
    procedure RegisterValue(const APath: string; const AValue: TXuiJsValue);
    procedure AddRoot(const AValue: TXuiJsValue);
    procedure ClearRoots;

    // 值工具（转发，减少桥接层对互操作单元的依赖）
    function Str(const S: string): TXuiJsValue;
    function Num(const N: Double): TXuiJsValue;
    function Bool(const B: Boolean): TXuiJsValue;
    function Undefined: TXuiJsValue;
    function ToStringValue(const V: TXuiJsValue): string;
    function ToNumberValue(const V: TXuiJsValue): Double;
    function ToBoolValue(const V: TXuiJsValue): Boolean;

    // 供宿主/引擎上报非脚本内部的错误（如脚本文件缺失）
    procedure ReportError(const AFile, AMessage: string;
      AStage: TXuiScriptStage);

    property Interp: TXuiJsInterp read FInterp;
    property OnError: TXuiScriptErrorEvent read FOnError write FOnError;
    property ErrorCount: Integer read FErrorCount;
    // 最近一次错误（宿主用于在界面上显示 / 写日志）
    property LastErrorFile: string read FLastErrorFile;
    property LastErrorMessage: string read FLastErrorMessage;
    property LastErrorLine: Integer read FLastErrorLine;
    property LastErrorCol: Integer read FLastErrorCol;
    property LastErrorStage: TXuiScriptStage read FLastErrorStage;
    // 正在求值的脚本文件（脚本内注册组件时按它的目录解析模板等相对路径）
    property CurrentFile: string read FCurrentFile;
  end;

implementation

{ TXuiScriptUnit }

destructor TXuiScriptUnit.Destroy;
begin
  Program_.Free;
  inherited Destroy;
end;

{ TXuiScript }

constructor TXuiScript.Create;
begin
  inherited Create;
  FInterp := TXuiJsInterp.Create;
  FUnits := TObjectList.Create(True);
  FSliceDepth := 0;
  FInterp.OnUnhandledRejection := @HandleUnhandledRejection;
  FInterp.OnCallbackError := @HandleCallbackError;
end;

destructor TXuiScript.Destroy;
begin
  FIO.Free;
  FUnits.Free;
  FInterp.Free;
  inherited Destroy;
end;

procedure TXuiScript.ReportError(const AFile, AMessage: string;
  AStage: TXuiScriptStage);
begin
  Report(AFile, AMessage, 0, 0, AStage);
end;

procedure TXuiScript.Report(const AFile, AMessage: string; ALine, ACol: Integer;
  AStage: TXuiScriptStage);
begin
  Inc(FErrorCount);
  FLastErrorFile := AFile;
  FLastErrorMessage := AMessage;
  FLastErrorLine := ALine;
  FLastErrorCol := ACol;
  FLastErrorStage := AStage;
  if Assigned(FOnError) then
    FOnError(AFile, AMessage, ALine, ACol, AStage);
end;

procedure TXuiScript.ReportException(const AFile: string; E: Exception);
var
  stage: TXuiScriptStage;
begin
  stage := ssRuntime;
  if E is EXuiJsSyntaxError then
    stage := ssCompile;
  if E is EXuiJsRuntime then
    stage := ssRuntime;
  if Pos('步数超出预算', E.Message) > 0 then
    stage := ssBudget;
  if E is EXuiJsSyntaxError then
    Report(AFile, E.Message, EXuiJsSyntaxError(E).Line, EXuiJsSyntaxError(E).Col, stage)
  else
    Report(AFile, E.ClassName + ': ' + E.Message, 0, 0, stage);
end;

// 未处理拒绝上报：预算超限冒泡成拒绝时保持 budget 分类
procedure TXuiScript.HandleUnhandledRejection(const AMessage: string);
var
  stage: TXuiScriptStage;
begin
  stage := ssUnhandledRejection;
  if Pos('步数超出预算', AMessage) > 0 then
    stage := ssBudget;
  Report('', AMessage, 0, 0, stage);
end;

// 定时器宏任务回调内未捕获异常（不中断后续定时器与应用）
procedure TXuiScript.HandleCallbackError(const AMessage: string);
var
  stage: TXuiScriptStage;
begin
  stage := ssRuntime;
  if Pos('步数超出预算', AMessage) > 0 then
    stage := ssBudget;
  Report('', AMessage, 0, 0, stage);
end;

function TXuiScript.FindUnit(const AFileName: string): TXuiScriptUnit;
var
  i: Integer;
begin
  if AFileName = '' then
    Exit(nil);
  for i := 0 to FUnits.Count - 1 do
    if SameFileName(TXuiScriptUnit(FUnits[i]).FileName, AFileName) then
      Exit(TXuiScriptUnit(FUnits[i]));
  Result := nil;
end;

function TXuiScript.Compile(const ASource, AFileName: string): TXuiScriptUnit;
begin
  Result := FindUnit(AFileName);
  if Result <> nil then
    Exit;
  Result := TXuiScriptUnit.Create;
  try
    Result.FileName := AFileName;
    Result.Source := ASource;
    Result.Program_ := XuiJsParse(ASource, AFileName);
  except
    on E: Exception do
    begin
      ReportException(AFileName, E);
      Result.Free;
      raise;
    end;
  end;
  FUnits.Add(Result);
end;

function TXuiScript.CompileFile(const AFileName: string): TXuiScriptUnit;
var
  list: TStringList;
begin
  list := TStringList.Create;
  try
    list.LoadFromFile(AFileName);
    Result := Compile(list.Text, AFileName);
  finally
    list.Free;
  end;
end;

// 求值整个编译单元：进入切片（预算重置 + 错误路由）
function TXuiScript.RunUnit(AUnit: TXuiScriptUnit): Boolean;
var
  prevFile: string;
begin
  Result := False;
  if AUnit = nil then
    Exit;
  Inc(FSliceDepth);
  prevFile := FCurrentFile;
  FCurrentFile := AUnit.FileName;   // 供 component(templateFile) 等按脚本目录解析相对路径
  try
    // 求值也是切片：预算从零计数（多文件顺序求值不互相累计）
    FInterp.ResetSteps;
    FInterp.Run(AUnit.Program_.Root);
    FInterp.MarkReactiveDirty;   // M7：脚本定义状态后请求绑定首渲染
    FInterp.DrainMicrotasks;     // 求值结束即安全点：排空微任务
    Result := True;
  except
    on E: Exception do
      ReportException(AUnit.FileName, E);
  end;
  FCurrentFile := prevFile;
  Dec(FSliceDepth);
end;

function TXuiScript.Run(const ASource, AFileName: string): Boolean;
var
  unit_: TXuiScriptUnit;
begin
  Result := False;
  try
    unit_ := Compile(ASource, AFileName);
  except
    Exit; // 编译错误已上报
  end;
  Result := RunUnit(unit_);
end;

function TXuiScript.RunFile(const AFileName: string): Boolean;
var
  unit_: TXuiScriptUnit;
begin
  Result := False;
  try
    unit_ := CompileFile(AFileName);
  except
    Exit; // 读取/编译错误已上报
  end;
  Result := RunUnit(unit_);
end;

function TXuiScript.InvokeSlice(const AFn: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  Result := InvokeMethodSlice(AFn, FInterp.Undefined, AArgs);
end;

function TXuiScript.InvokeMethodSlice(const AFn, AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  Result := FInterp.Undefined;
  if not FInterp.IsCallable(AFn) then
    Exit;
  Inc(FSliceDepth);
  try
    // 切片入口重置预算（修掉"跨调用累积"缺陷：每次切片都从现在开始计数）
    FInterp.ResetSteps;
    Result := FInterp.CallWithThis(AFn, AThis, AArgs);
    // 切片退出即安全点：排空微任务（Promise 回调在此获得执行机会）
    FInterp.DrainMicrotasks;
  except
    on E: Exception do
      ReportException('', E);
  end;
  Dec(FSliceDepth);
end;

procedure TXuiScript.DrainMicrotasks;
begin
  FInterp.DrainMicrotasks;
end;

{ ---- P4 真实 I/O ---- }

function TXuiScript.IO: TXuiScriptIO;
begin
  if FIO = nil then
  begin
    FIO := TXuiScriptIO.Create(FInterp);
    FIO.OnIoError := @HandleIoError;
    FIO.Install;
  end;
  Result := FIO;
end;

procedure TXuiScript.PumpIO;
begin
  if FIO <> nil then
    FIO.PumpCompletions;
end;

function TXuiScript.IoInFlight: Integer;
begin
  if FIO <> nil then
    Result := FIO.InFlight
  else
    Result := 0;
end;

// I/O 失败上报（不中断应用）
procedure TXuiScript.HandleIoError(const AMessage: string);
begin
  Report('', AMessage, 0, 0, ssIO);
end;

// M7：安全点响应式刷新（绑定引擎挂的回调；无人装配则零开销）
procedure TXuiScript.FlushReactive;
begin
  if Assigned(FOnFlushReactive) then
    FOnFlushReactive;
end;

procedure TXuiScript.MarkReactiveDirty;
begin
  FInterp.MarkReactiveDirty;
end;

procedure TXuiScript.ResetBindings;
begin
  if Assigned(FOnResetBindings) then
    FOnResetBindings;
end;

{ ---- P2 定时器宿主接口 ---- }

procedure TXuiScript.SetClockMs(ANowMs: Int64);
begin
  FInterp.SetClockMs(ANowMs);
end;

function TXuiScript.PumpTimers: Integer;
begin
  Result := FInterp.PumpTimers;
end;

function TXuiScript.TimersPending: Integer;
begin
  Result := FInterp.TimersPending;
end;

function TXuiScript.HasGlobalFunction(const AName: string): Boolean;
var
  v: TXuiJsValue;
begin
  v := FInterp.GetGlobal(AName);
  Result := FInterp.IsCallable(v);
end;

function TXuiScript.CallGlobal(const AName: string; const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  Result := InvokeSlice(FInterp.GetGlobal(AName), AArgs);
end;

procedure TXuiScript.RegisterNative(const APath: string; AFn: TXuiJsNativeFunc);
begin
  FInterp.RegisterNative(APath, AFn);
end;

procedure TXuiScript.RegisterValue(const APath: string; const AValue: TXuiJsValue);
begin
  FInterp.RegisterValue(APath, AValue);
end;

procedure TXuiScript.AddRoot(const AValue: TXuiJsValue);
begin
  FInterp.AddRoot(AValue);
end;

procedure TXuiScript.ClearRoots;
begin
  FInterp.ClearRoots;
end;

function TXuiScript.Str(const S: string): TXuiJsValue;
begin
  Result := FInterp.Str(S);
end;

function TXuiScript.Num(const N: Double): TXuiJsValue;
begin
  Result := FInterp.Num(N);
end;

function TXuiScript.Bool(const B: Boolean): TXuiJsValue;
begin
  Result := FInterp.Bool(B);
end;

function TXuiScript.Undefined: TXuiJsValue;
begin
  Result := FInterp.Undefined;
end;

function TXuiScript.ToStringValue(const V: TXuiJsValue): string;
begin
  Result := FInterp.ToStringValue(V);
end;

function TXuiScript.ToNumberValue(const V: TXuiJsValue): Double;
begin
  Result := FInterp.ToNumberValue(V);
end;

function TXuiScript.ToBoolValue(const V: TXuiJsValue): Boolean;
begin
  Result := FInterp.ToBoolValue(V);
end;

end.
