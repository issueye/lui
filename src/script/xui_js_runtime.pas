unit xui_js_runtime;
{$mode objfpc}{$H+}
{ TS 子集解释器（M6 脚本引擎第三层）。纯逻辑、不依赖 LCL，便于单元测试。
  - 值模型：undefined / null / boolean / number(double) / string(UTF-8 码点语义) / object
  - 对象：属性表 + 原型链；函数（脚本 AST 闭包 / Pascal 原生回调）；数组（密集存储）
  - 环境：链式作用域，函数调用创建新环境（含 this）
  - 语句与表达式求值；throw/try/catch/finally；指令预算（防死循环，按切片重置）
  - Promise 与微任务队列（P1）：then/catch/finally、resolve/reject/all/allSettled/race、
    new Promise(executor)、thenable 采纳；每个微任务是独立预算切片
  - 定时器宏任务（P2）：ui.setTimeout/setInterval/clearTimeout/clearInterval/delay/now，
    表项 {Id, Callback, DueMs, Interval, Cancelled}；Tick 泵执行；宏任务也是独立预算切片
  - 完整 async/await（P3）：显式控制栈可挂起求值器（快慢双路径，帧栈按"节点种类 × 相位"
    推进）；async 函数同步执行到首个 await 即返回 promise；异常经帧栈展开进 try/catch/finally
  - 标记-清除 GC：根集 = 全局环境 + 宿主注册的根 + 微任务队列 + 未处理拒绝表 +
    定时器表 + 活跃 async 帧栈
  刻意语义偏差（见设计方案 §3）：
  - string.length 与索引按 UTF-8 码点计数（非 UTF-16 code unit）
  - 事件处理器内 this 不绑定（顶层函数调用 this 为 undefined）
  不支持：正则、Date、BigInt、Map/Set、Proxy/Reflect/Symbol、get/set 访问器、生成器；
  真实 I/O（P4） }
interface
uses
  SysUtils, Classes, Contnrs, Math,
  xui_js_token, xui_js_parser,
  xui_text;   // UTF-8 码点工具（Utf8Length/Utf8NextIndex/Utf8PrevIndex）
type
  TXuiJsValueKind = (jvUndefined, jvNull, jvBool, jvNumber, jvString, jvObject);
  TXuiJsObject = class;
  TXuiJsFunction = class;
  TXuiJsEnv = class;
  TXuiJsValue = record
    Kind: TXuiJsValueKind;
    Num: Double;
    Str: string;
    Obj: TXuiJsObject;
  end;
  TXuiJsValueArray = array of TXuiJsValue;
  EXuiJsThrow = class(Exception)
  public
    Value: TXuiJsValue;
  end;
  EXuiJsRuntime = class(Exception);
  // 原生函数：AFn 为函数对象本身（内建按名分派），AThis 为接收者，返回脚本值
  TXuiJsNativeFunc = function(AFn: TXuiJsFunction; AThis: TXuiJsValue;
    const AArgs: TXuiJsValueArray): TXuiJsValue of object;
  TXuiJsLogProc = procedure(const AText: string) of object;
  // 未处理 Promise 拒绝上报（门面接 OnScriptError；v1 每次排水结束检查一次）
  TXuiJsUnhandledProc = procedure(const AMessage: string) of object;
  // 宏任务回调内未捕获异常上报（门面接 OnScriptError；文本含"步数超出预算"时归类 budget）
  TXuiJsErrorProc = procedure(const AMessage: string) of object;
  // GC 根扩展回调（宿主 IO 等子系统在此标记自己保活的 JS 值）
  TXuiGcRootsProc = procedure of object;
  // watch(fn, cb) 的注册项（M7）
  TXuiJsWatcher = class
  public
    Fn: TXuiJsValue;
    Cb: TXuiJsValue;
    HasLast: Boolean;
    Last: TXuiJsValue;
    LastSnap: string;     // deep watch：上次快照（内容指纹）
    Immediate: Boolean;   // opts.immediate：注册即回调一次
    Deep: Boolean;        // opts.deep：新旧值按深度比较（对象/数组内容）
  end;
  // 宿主对象的动态属性（DOM 桥：node.text 等）
  TXuiJsNativePropGet = function(AObj: TXuiJsObject; const AName: string;
    out AValue: TXuiJsValue): Boolean of object;
  TXuiJsNativePropSet = function(AObj: TXuiJsObject; const AName: string;
    const AValue: TXuiJsValue): Boolean of object;
  TXuiJsProp = class
  public
    Name: string;
    Value: TXuiJsValue;
  end;
  TXuiJsObject = class
  public
    Props: TObjectList;        // TXuiJsProp（自有）
    Proto: TXuiJsObject;       // 弱引用（原型链）
    JsClass: string;         // 'Object' / 'Array' / 'Function' / 'Node' ...
    Marked: Boolean;           // GC 标记位
    Tag: TObject;              // 宿主数据（弱引用；DOM 桥存 TXuiNode 包装）
    NativeGet: TXuiJsNativePropGet;
    NativeSet: TXuiJsNativePropSet;
    Reactive: Boolean;        // M7：reactive() 标记（顶层属性写入触发响应式刷新）
    function FindOwn(const AName: string): Integer;
    function GetOwn(const AName: string): TXuiJsValue;
    procedure SetOwn(const AName: string; const AValue: TXuiJsValue);
    procedure DeleteOwn(const AName: string);
    constructor Create;
    destructor Destroy; override;
  end;
  TXuiJsArray = class(TXuiJsObject)
  public
    Items: TXuiJsValueArray;
    function Length: Integer;
    constructor Create;
  end;
  TXuiJsFunction = class(TXuiJsObject)
  public
    Name: string;
    Native: TXuiJsNativeFunc;      // 原生实现（与下面的 AST 字段二选一）
    // 脚本函数
    ParamItems: array of TXuiJsNode;
    Body: TXuiJsNode;
    Closure: TXuiJsEnv;
    IsArrow: Boolean;
    IsAsync: Boolean;              // async 函数（经机器求值，返回 promise）
    IsExprBody: Boolean;
    HomeObject: TXuiJsObject;      // 方法定义所在对象（super 解析）
    IsCtor: Boolean;               // 构造函数（class）
    FieldInits: TList;             // TXuiJsNode（类字段初始化表达式，按序）
    ParentCtor: TXuiJsFunction;    // 父类构造函数
    ProtoObject: TXuiJsObject;     // prototype
    constructor Create;
    destructor Destroy; override;
  end;
  TXuiJsEnv = class
  public
    Parent: TXuiJsEnv;
    Names: TStringList;
    Values: TXuiJsValueArray;
    HasThis: Boolean;
    ThisValue: TXuiJsValue;
    HomeObject: TXuiJsObject;      // 当前方法所属对象（super 用）
    IsFunctionScope: Boolean;      // 函数级作用域（var/函数声明的落点）
    Func: TXuiJsFunction;          // 正在执行的函数（构造/super 用）
    PendingFields: TList;          // 派生子类：super() 之后要执行的字段初始化
    Marked: Boolean;               // GC 标记位
    constructor Create(AParent: TXuiJsEnv);
    destructor Destroy; override;
    function Lookup(const AName: string; out AValue: TXuiJsValue): Boolean;
    function Define(const AName: string; const AValue: TXuiJsValue): Integer;
    procedure Assign(const AName: string; const AValue: TXuiJsValue);
    function FindHomeObject: TXuiJsObject;
    function FindFunctionEnv: TXuiJsEnv;
  end;
  { ---- Promise 与微任务（M6-异步设计 P1，见 §4）---- }
  TXuiJsPromiseState = (psPending, psFulfilled, psRejected);
  // 反应项种类：then（含 catch 透传）/ finally / all・allSettled 聚合 / race / async 恢复
  TXuiJsReactionKind = (rkThen, rkFinally, rkAll, rkAllSettled, rkRace, rkResume);
  // Promise.all / allSettled 的共享收集状态（解释器持有，任务跑完即回收）
  TXuiJsPromise = class(TXuiJsObject)
  public
    State: TXuiJsPromiseState;
    Value: TXuiJsValue;
    Reactions: TObjectList;      // TXuiJsReaction（pending 期间持有；settle 后即拷入微任务并清空）
    constructor Create;
    destructor Destroy; override;
  end;
  TXuiJsAggregate = class
  public
    Downstream: TXuiJsPromise;
    Results: TXuiJsArray;        // 按输入下标写回结果
    PendingJobs: Integer;        // 未执行的聚合任务数（归零即回收）
  end;
  // 反应项：then/catch/finally 挂接；settle 时拷贝为微任务（回调保证异步）
  TXuiJsReaction = class
  public
    Kind: TXuiJsReactionKind;
    OnFulfilled: TXuiJsValue;    // rkThen 成功回调 / rkFinally 的回调
    OnRejected: TXuiJsValue;     // rkThen 失败回调
    Downstream: TXuiJsPromise;   // then/catch/finally 的返回值
    Aggregate: TObject;          // rkAll/rkAllSettled：TXuiJsAggregate（非拥有）
    Index: Integer;              // rkAll/rkAllSettled：结果写回下标
  end;
  // 微任务 = settle 时由反应项拷贝出的作业（自持冻结数据，不再引用上游 promise）
  TXuiJsMicroTask = class
  public
    Kind: TXuiJsReactionKind;
    OnFulfilled: TXuiJsValue;
    OnRejected: TXuiJsValue;
    SrcFulfilled: Boolean;       // 上游 settle 结果（冻结）
    SrcValue: TXuiJsValue;
    Downstream: TXuiJsPromise;
    Aggregate: TObject;          // 非拥有（TXuiJsAggregate）
    Index: Integer;
  end;
  // 定时器表项（P2，ADR 17）：setInterval 的 Interval>0；Cancelled 待泵回收
  TXuiJsTimer = class
  public
    Id: Integer;
    Callback: TXuiJsValue;
    Args: TXuiJsValueArray;
    DueMs: Int64;
    Interval: Int64;             // 固定间隔重排（不做漂移补偿）
    Cancelled: Boolean;
  end;
  { ---- async/await 机器（P3，ADR 16：显式控制栈可挂起求值器）---- }
  TXuiJsFrameRole = (frExpr, frStmt);
  // 帧 = "节点 × 相位"的推进状态。离脊（无 await）操作数委托既有递归求值器同步算完。
  TXuiJsFrame = class
  public
    Machine: TObject;            // 所属机器（TXuiJsAsyncMachine）
    Node: TXuiJsNode;
    Role: TXuiJsFrameRole;
    Phase: Integer;
    Parent: TXuiJsFrame;         // 交付目标（nil = 机器栈底）
    Slot: Integer;               // 交付到父帧 Values[Slot]
    DeliverFlow: Boolean;        // 语句帧：同时把 Flow 交付到父帧 ChildFlow
    Env: TXuiJsEnv;              // 进入帧时的环境
    EnvNow: TXuiJsEnv;           // 当前执行环境（catch/for 等子作用域）
    Values: TXuiJsValueArray;    // 操作数槽
    Waiting: Boolean;            // 子帧挂起中（结果待交付）
    ChildFlow: Integer;          // 已完成语句子帧的控制流
    Done: Boolean;
    Value: TXuiJsValue;          // 本帧结果值
    Flow: Integer;               // 本帧结果控制流
    // 游标与辅助状态（各节点种类按需取用）
    Idx: Integer;
    Idx2: Integer;
    Sub: Integer;                // 子相位（成员链 / 展开标记等）
    Sub2: Integer;
    Flag: Boolean;               // baseIsSuper 等通用布尔
    Flag2: Boolean;              // lastWasMember 等通用布尔
    SavedFlow: Integer;          // try 帧：保护块/捕获块的结果流
    HasThrown: Boolean;          // try 帧：finally 后待重抛
    ThrownValue: TXuiJsValue;
    StrAcc: string;              // 模板串累积 / 字符串迭代游标
    Ref: TXuiJsNode;             // 当前子节点引用（VarDecl 声明器等）
    DeclEnv: TXuiJsEnv;          // var 声明的落点环境
    ArgsAcc: TXuiJsValueArray;   // 调用实参累积
    Links: TList;                // 成员链 links（AST 节点指针，非拥有）
    CursorObj: TObject;          // 迭代数组等（非拥有）
    TryMode: Integer;            // 0=try 块 1=catch 2=finally 3=finally 已抛过
    constructor Create;
    destructor Destroy; override;
  end;
  // 一次 async 调用的可挂起机器；活跃期由解释器持有（GC 根）
  TXuiJsAsyncMachine = class
  public
    Frames: TObjectList;         // TXuiJsFrame（自有；栈顶 = Count-1）
    Promise: TXuiJsPromise;
    Suspended: Boolean;
    Done: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  TXuiJsInterp = class
  private
    FAllObjects: TObjectList;   // 全部对象（GC 扫描用）
    FAllEnvs: TObjectList;      // 全部环境（GC 扫描用）
    FRoots: TList;              // 宿主注册的根（TXuiJsValue 指针）
    FGlobal: TXuiJsObject;
    FGlobalEnv: TXuiJsEnv;
    FObjectProto, FFunctionProto, FArrayProto, FStringProto, FNumberProto,
      FBoolProto: TXuiJsObject;
    FPromiseProto: TXuiJsObject;
    FSteps: Int64;
    FMaxSteps: Int64;
    FCollectThreshold: Integer;
    FLog: TXuiJsLogProc;
    FOnUnhandledRejection: TXuiJsUnhandledProc;
    FOnCallbackError: TXuiJsErrorProc;
    FOnCollectRoots: TXuiGcRootsProc;
    FOnReactiveWrite: TXuiGcRootsProc;
    FExtraRoots: array of TXuiGcRootsProc;   // 额外 GC 根回调（AddOnCollectRoots）
    // 响应式内核（M7）
    FReactiveDirty: Boolean;      // reactive 对象被写入 → 待刷新
    FReactiveVersion: Integer;    // 每次刷新递增（computed 失效用）
    FWatchers: TObjectList;       // TXuiJsWatcher（自有）
    FMountHooks: TObjectList;     // TXuiJsProp（Name 空，Value=onMount 函数）
    // JSON.parse 状态（方法组共享；解释器单线程）
    FJsonS: string;
    FJsonPos: Integer;
    FDepth: Integer;
    FCurrentEnv: TXuiJsEnv;
    // Promise / 微任务（P1）
    FMicroTasks: TObjectList;    // TXuiJsMicroTask（FIFO，自有）
    FAggregates: TObjectList;    // TXuiJsAggregate（自有，任务跑完即回收）
    FUnhandled: TObjectList;     // 已拒绝且无人处理的 Promise（非拥有，排水末上报一次）
    FDraining: Boolean;          // 排水重入防护
    // 定时器 / 宏任务（P2）
    FTimers: TObjectList;        // TXuiJsTimer（自有；Cancelled 的在泵内回收）
    FClockMs: Int64;             // 脚本时钟（宿主 Tick 注入；测试可人造推进）
    FTimerSeq: Integer;          // 定时器 Id 分配器
    FPumping: Boolean;           // 宏任务泵重入防护
    // async/await 机器（P3）
    FAsyncCalls: TObjectList;    // 活跃机器（自有；完成即摘除，GC 根）
    // 执行
    function EvalExpr(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
    function EvalMemberChain(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
    function ExecStmt(ANode: TXuiJsNode; AEnv: TXuiJsEnv; out AFlow: Integer): TXuiJsValue;
    function ExecBlock(ABlock: TXuiJsNode; AEnv: TXuiJsEnv; ANewScope: Boolean;
      out AFlow: Integer): TXuiJsValue;
    procedure BindPattern(APattern: TXuiJsNode; const AValue: TXuiJsValue;
      AEnv: TXuiJsEnv; ADeclare: Boolean);
    procedure HoistDeclarations(ABody: TXuiJsNode; AEnv: TXuiJsEnv);
    function CallFunction(const AFn: TXuiJsValue; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function Construct(const AFn: TXuiJsValue; const AArgs: TXuiJsValueArray): TXuiJsValue;
    procedure Step;
    // 求值辅助
    function ThisOf(AEnv: TXuiJsEnv): TXuiJsValue;
    function MakeClosure(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
    function EvalClass(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
    function EvalBinaryOp(const AOp: string; const A, B: TXuiJsValue): TXuiJsValue;
    function HasProp(const AValue: TXuiJsValue; const AName: string): Boolean;
    function PropNameOf(const AValue: TXuiJsValue): string;
    function JsInstanceOf(const A, B: TXuiJsValue): Boolean;
    function EvalArgs(ACallNode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValueArray;
    function SuperBaseValue(AEnv: TXuiJsEnv): TXuiJsValue;
    function SuperConstructCall(AEnv: TXuiJsEnv;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    procedure BindParams(AFn: TXuiJsFunction; AEnv: TXuiJsEnv;
      const AArgs: TXuiJsValueArray);
    procedure RunFieldInits(AFn: TXuiJsFunction; AEnv: TXuiJsEnv);
    // 派生类未声明构造函数：沿继承链共享 this 执行（体 + 字段初始化）
    procedure RunImplicitCtor(AFn: TXuiJsFunction; const AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray);
    procedure RunCtorBody(AFn: TXuiJsFunction; AEnv: TXuiJsEnv;
      const AArgs: TXuiJsValueArray);
    function ArgAt(const AArgs: TXuiJsValueArray; AIndex: Integer): TXuiJsValue;
    // 对象/值
    function NewObject(const AJsClass: string = 'Object'): TXuiJsObject;
    function NewArray: TXuiJsArray;
    function NewFunction: TXuiJsFunction;
    function NewEnv(AParent: TXuiJsEnv): TXuiJsEnv;
    function GetProp(const AValue: TXuiJsValue; const AName: string): TXuiJsValue;
    procedure SetProp(const AValue: TXuiJsValue; const AName: string;
      const ANewValue: TXuiJsValue);
    function OwnKeys(const AObj: TXuiJsObject): TXuiJsValueArray;
    // 内建
    procedure InitGlobals;
    procedure DefineNative(AObj: TXuiJsObject; const AName: string; AFn: TXuiJsNativeFunc);
    procedure DefineValue(AObj: TXuiJsObject; const AName: string; const AValue: TXuiJsValue);
    function Native(const AFn: TXuiJsNativeFunc): TXuiJsValue;
    procedure RegisterValueTo(const APath: string; const AValue: TXuiJsValue);
    // 内建实现（按函数名分派）
    function NativeConsole(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeMath(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeJson(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    procedure JsonSkipWs;
    function JsonParseString: string;
    function JsonParseValue: TXuiJsValue;
    function JsonParseText(const S: string): TXuiJsValue;
    // 响应式内核（M7）
    function NativeVue(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function ComputedGet(AObj: TXuiJsObject; const AName: string;
      out AValue: TXuiJsValue): Boolean;
    function EqualDeep(const A, B: TXuiJsValue): Boolean;
    function DeepSnapshot(const AValue: TXuiJsValue): string;
    procedure NotifyArrayWrite(AObj: TXuiJsObject);
    function NativeGlobalFn(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeObjectStatics(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeStringProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeArrayProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeNumberProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativeFunctionProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    // Promise（按函数名分派；控制函数 resolve/reject 经 Tag 携带目标 promise）
    function NativePromise(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativePromiseCtl(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativePromiseProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    function NativePromiseStatics(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    // ui.* 定时器（按函数名分派：setTimeout/setInterval/clearTimeout/clearInterval/delay/now）
    function NativeUiTimer(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    // Promise / 微任务
    function IsPromise(const AValue: TXuiJsValue): Boolean;
    procedure PromiseAddReaction(AP: TXuiJsPromise; AKind: TXuiJsReactionKind;
      const AOnOk, AOnErr: TXuiJsValue; ADownstream: TXuiJsPromise;
      AAggregate: TObject; AIndex: Integer);
    procedure PromiseSettle(AP: TXuiJsPromise; ARejected: Boolean;
      const AValue: TXuiJsValue);
    procedure PromiseResolve(AP: TXuiJsPromise; const AValue: TXuiJsValue);
    procedure PromiseReject(AP: TXuiJsPromise; const AReason: TXuiJsValue);
    procedure EnqueueReactionJob(AReaction: TXuiJsReaction;
      ASrcFulfilled: Boolean; const ASrcValue: TXuiJsValue);
    procedure RunJob(ATask: TXuiJsMicroTask);
    procedure RunMicroTaskSlice;   // 执行一个微任务（独立切片：预算重置）
    procedure CleanupAggregates;
    procedure ScanUnhandledRejections;
    procedure RunTimerSlice(ATimer: TXuiJsTimer);  // 执行一个到期定时器（宏任务切片）
    // async/await 机器（P3）
    procedure PushFrame(M: TObject; ANode: TXuiJsNode; ARole: TXuiJsFrameRole;
      AEnv: TXuiJsEnv; AParent: TXuiJsFrame; ASlot: Integer);
    procedure SetSlot(F: TXuiJsFrame; ASlot: Integer; const AValue: TXuiJsValue);
    procedure NeedChildValue(F: TXuiJsFrame; ASlot: Integer; AChild: TXuiJsNode);
    procedure NeedChildStmt(F: TXuiJsFrame; ASlot: Integer; AChild: TXuiJsNode);
    procedure FinishFrame(F: TXuiJsFrame; const AValue: TXuiJsValue; AFlow: Integer);
    procedure StepFrame(M: TObject; F: TXuiJsFrame);
    function RunMachine(M: TObject): Boolean;
    function UnwindMachine(M: TObject; const AThrown: TXuiJsValue): Boolean;
    procedure ResumeMachine(M: TObject; AOk: Boolean; const AValue: TXuiJsValue);
    procedure CompleteMachine(M: TObject; ARejected: Boolean; const AValue: TXuiJsValue);
    procedure MarkAsyncMachine(M: TObject);
    function CallAsyncFunction(AFn: TXuiJsFunction; AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    // 赋值目标读写（StepFrame 用；与 EvalExpr 内嵌逻辑一致）
    procedure WriteRefTo(ATarget: TXuiJsNode; const AValue: TXuiJsValue;
      AEnv: TXuiJsEnv);
    function ReadRefOf(ATarget: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
    // GC
    procedure MarkValue(const AValue: TXuiJsValue);
    procedure MarkObject(AObj: TXuiJsObject);
    procedure MarkEnv(AEnv: TXuiJsEnv);
    procedure CollectGarbage;
    procedure MaybeCollect;
  public
    constructor Create;
    destructor Destroy; override;
    // 执行一段编译好的程序（返回最后表达式语句的值或 undefined）
    function Run(AProgram: TXuiJsNode): TXuiJsValue;
    // 调用脚本函数/原生函数
    function Call(const AFn: TXuiJsValue; const AArgs: TXuiJsValueArray): TXuiJsValue;
    function CallWithThis(const AFn: TXuiJsValue; const AThis: TXuiJsValue;
      const AArgs: TXuiJsValueArray): TXuiJsValue;
    // 全局变量读写
    function GetGlobal(const AName: string): TXuiJsValue;
    procedure SetGlobal(const AName: string; const AValue: TXuiJsValue);
    // 宿主适配器用：创建对象/函数（宿主对象可挂 NativeGet/NativeSet 做动态属性）
    function CreateHostObject(const AJsClass: string = 'Object'): TXuiJsObject;
    function CreateHostFunction(const AName: string; AFn: TXuiJsNativeFunc): TXuiJsValue;
    // 预算：按执行切片重置（跨调用累积会让长跑应用误报死循环）
    procedure ResetSteps;
    // P1：排空微任务队列（安全点调用：切片退出 / Tick / 文档加载后）
    // 重入安全；结束时对"已拒绝且无人处理"的 Promise 上报一次 OnUnhandledRejection
    procedure DrainMicrotasks;
    function MicroTaskCount: Integer;
    // P4：宿主 IO/异步子系统桥接（xui_script_io 用）
    function NewPromise: TXuiJsPromise;
    function NewControlFunction(const AName: string;
      APromise: TXuiJsPromise): TXuiJsFunction;   // resolve/reject 控制函数（Tag 携带 promise）
    function PendingPromiseValue(APromise: TXuiJsPromise): TXuiJsValue;
    function ArgAtPublic(const AArgs: TXuiJsValueArray; AIndex: Integer): TXuiJsValue;
    procedure MarkRootValue(const AValue: TXuiJsValue);
    procedure MarkRootEnv(AEnv: TXuiJsEnv);
    procedure MarkReactiveDeep(AObj: TXuiJsObject; ADepth: Integer);   // 深度响应式标记（M7-2，绑定引擎用）
    procedure NotifyReactiveWrite(AObj: TXuiJsObject);    // 数组等方法型写入的变更通知               // 供绑定引擎标记作用域环境
    function GlobalEnv: TXuiJsEnv;                        // M7 绑定求值的根环境
    function NewChildEnv(AParent: TXuiJsEnv): TXuiJsEnv;  // v-for 作用域
    function EvalAst(AAst: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;  // 表达式 AST 求值
    // M7 响应式：flush 由绑定引擎在安全点驱动
    function ReactiveDirty: Boolean;
    procedure ClearReactiveDirty;
    procedure BumpReactiveVersion;
    function ReactiveVersion: Integer;
    procedure RunWatchers;        // 刷新后比对 watcher（新旧值不等才回调）
    procedure RunMountHooks;      // 文档就绪后调用一次（调用即清空）
    procedure ClearPageReactive;  // 文档替换：作废上一页注册的 watch / onMount
    procedure AddOnCollectRoots(AProc: TXuiGcRootsProc);
    function MountHookCount: Integer;
    procedure MarkReactiveDirty;   // 请求一次响应式刷新（脚本加载完成等）
    procedure AddOnCollectRootsImpl(AProc: TXuiGcRootsProc);   // 仅供 OnCollectRoots 回调内使用
    // P2：定时器与宏任务（ADR 17：引擎侧表 + Tick 泵；时钟可注入以便人造时间测试）
    procedure SetClockMs(ANowMs: Int64);   // 注入当前脚本时钟（宿主 Tick 驱动）
    function NowMs: Int64;
    function SetTimeout(const ACallback: TXuiJsValue; ADelayMs: Int64;
      const AArgs: TXuiJsValueArray): Integer;
    function SetInterval(const ACallback: TXuiJsValue; ADelayMs: Int64;
      const AArgs: TXuiJsValueArray): Integer;
    procedure ClearTimer(AId: Integer);    // clearTimeout / clearInterval 共用
    function PumpTimers: Integer;          // 执行到期定时器（宏任务切片；每回调后排微任务）
    function TimersPending: Integer;       // 未取消定时器数（NeedsTick 计入）
    function HasDueTimers: Boolean;
    // 测试 / 宿主诊断
    procedure ForceCollectGarbage;
    function ObjectCount: Integer;
    // 原生注册（后续功能挂载点）：'ui.now' / 'ui.foo.bar' 路径式
    procedure RegisterNative(const APath: string; AFn: TXuiJsNativeFunc);
    procedure RegisterValue(const APath: string; const AValue: TXuiJsValue);
    // 根集管理（宿主长期持有脚本值时登记）
    procedure AddRoot(const AValue: TXuiJsValue);
    procedure ClearRoots;
    // 值工具
    function Str(const S: string): TXuiJsValue;
    function Num(const N: Double): TXuiJsValue;
    function Bool(const B: Boolean): TXuiJsValue;
    function Undefined: TXuiJsValue;
    function NullValue: TXuiJsValue;
    function ObjectValue(AObj: TXuiJsObject): TXuiJsValue;
    function ArrayValue(AArr: TXuiJsArray): TXuiJsValue;
    function FunctionValue(AFn: TXuiJsFunction): TXuiJsValue;
    function ToStringValue(const V: TXuiJsValue): string;
    function ToNumberValue(const V: TXuiJsValue): Double;
    function ToBoolValue(const V: TXuiJsValue): Boolean;
    function ToInt32Value(const V: TXuiJsValue): Integer;
    function IsCallable(const V: TXuiJsValue): Boolean;
    function IsTruthy(const V: TXuiJsValue): Boolean;
    function StrictEquals(const A, B: TXuiJsValue): Boolean;
    function LooseEquals(const A, B: TXuiJsValue): Boolean;
    function PropValue(const AValue: TXuiJsValue; const AName: string): TXuiJsValue;
    procedure SetPropValue(const AValue: TXuiJsValue; const AName: string;
      const ANewValue: TXuiJsValue);
    function GlobalObject: TXuiJsObject;
    function ObjectProto: TXuiJsObject;
    function ArrayProto: TXuiJsObject;
    function MakeArray(const AItems: TXuiJsValueArray): TXuiJsValue;
    // 取第 AIndex 个实参的整数形式（缺失/NaN/Inf 时返回 ADefault）
    function ArgInt(const AArgs: TXuiJsValueArray; AIndex: Integer;
      ADefault: Integer = 0): Integer;
    function EmptyArray: TXuiJsValue;
    // 把 Pascal 字符串按 UTF-8 码点转为 JS 字符串值（同 Str）
    property OnLog: TXuiJsLogProc read FLog write FLog;
    property OnUnhandledRejection: TXuiJsUnhandledProc
      read FOnUnhandledRejection write FOnUnhandledRejection;
    property OnCallbackError: TXuiJsErrorProc
      read FOnCallbackError write FOnCallbackError;
    property OnCollectRoots: TXuiGcRootsProc
      read FOnCollectRoots write FOnCollectRoots;
    property OnReactiveWrite: TXuiGcRootsProc
      read FOnReactiveWrite write FOnReactiveWrite;   // reactive 写入即回调（置脏/请求调度）
    property MaxSteps: Int64 read FMaxSteps write FMaxSteps;
    property CollectThreshold: Integer read FCollectThreshold write FCollectThreshold;
    // 当前切片已消耗的步数（测试预算行为用）
    property Steps: Int64 read FSteps;
  end;
const
  JsFlowNormal = 0;
  JsFlowReturn = 1;
  JsFlowBreak = 2;
  JsFlowContinue = 3;
implementation
{ 值构造 }
function MakeUndefined: TXuiJsValue; inline;
begin
  Result.Kind := jvUndefined;
  Result.Num := 0;
  Result.Str := '';
  Result.Obj := nil;
end;
function MakeNull: TXuiJsValue; inline;
begin
  Result.Kind := jvNull;
  Result.Num := 0;
  Result.Str := '';
  Result.Obj := nil;
end;
function MakeBool(B: Boolean): TXuiJsValue; inline;
begin
  Result.Kind := jvBool;
  if B then Result.Num := 1 else Result.Num := 0;
  Result.Str := '';
  Result.Obj := nil;
end;
function MakeNumber(N: Double): TXuiJsValue; inline;
begin
  Result.Kind := jvNumber;
  Result.Num := N;
  Result.Str := '';
  Result.Obj := nil;
end;
function MakeString(const S: string): TXuiJsValue; inline;
begin
  Result.Kind := jvString;
  Result.Num := 0;
  Result.Str := S;
  Result.Obj := nil;
end;
function MakeObject(AObj: TXuiJsObject): TXuiJsValue; inline;
begin
  Result.Kind := jvObject;
  Result.Num := 0;
  Result.Str := '';
  Result.Obj := AObj;
end;
function IsNullish(const V: TXuiJsValue): Boolean; inline;
begin
  Result := (V.Kind = jvUndefined) or (V.Kind = jvNull);
end;

// 64 位安全的向下/向上取整（Math 单元的 Floor/Ceil 是 32 位 Integer，会截断大数）
function JsFloor(X: Double): Double; inline;
begin
  Result := Trunc(X);
  if (X < 0) and (Result <> X) then
    Result := Result - 1;
end;

function JsCeil(X: Double): Double; inline;
begin
  Result := Trunc(X);
  if (X > 0) and (Result <> X) then
    Result := Result + 1;
end;

// JS 数字 → 字符串（整数不带小数点）
function NumberToString(N: Double): string;
var
  fs: TFormatSettings;
begin
  if IsNan(N) then
    Exit('NaN');
  if IsInfinite(N) then
  begin
    if N > 0 then
      Exit('Infinity');
    Exit('-Infinity');
  end;
  if (N = Trunc(N)) and (Abs(N) < 1e15) then
    Exit(IntToStr(Trunc(N)));
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := FloatToStr(N, fs);
end;
{ TXuiJsObject }
constructor TXuiJsObject.Create;
begin
  inherited Create;
  Props := TObjectList.Create(True);
  Proto := nil;
  JsClass := 'Object';
end;
destructor TXuiJsObject.Destroy;
begin
  Props.Free;
  inherited Destroy;
end;
function TXuiJsObject.FindOwn(const AName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to Props.Count - 1 do
    if TXuiJsProp(Props[i]).Name = AName then
      Exit(i);
  Result := -1;
end;
function TXuiJsObject.GetOwn(const AName: string): TXuiJsValue;
var
  i: Integer;
begin
  i := FindOwn(AName);
  if i >= 0 then
    Result := TXuiJsProp(Props[i]).Value
  else
    Result := MakeUndefined;
end;
procedure TXuiJsObject.SetOwn(const AName: string; const AValue: TXuiJsValue);
var
  i: Integer;
  p: TXuiJsProp;
begin
  i := FindOwn(AName);
  if i >= 0 then
    TXuiJsProp(Props[i]).Value := AValue
  else
  begin
    p := TXuiJsProp.Create;
    p.Name := AName;
    p.Value := AValue;
    Props.Add(p);
  end;
end;
procedure TXuiJsObject.DeleteOwn(const AName: string);
var
  i: Integer;
begin
  i := FindOwn(AName);
  if i >= 0 then
    Props.Delete(i);
end;
{ TXuiJsArray }
constructor TXuiJsArray.Create;
begin
  inherited Create;
  JsClass := 'Array';
  SetLength(Items, 0);
end;
function TXuiJsArray.Length: Integer;
begin
  Result := System.Length(Items);
end;
{ TXuiJsFunction }
constructor TXuiJsFunction.Create;
begin
  inherited Create;
  JsClass := 'Function';
  FieldInits := TList.Create;
end;
destructor TXuiJsFunction.Destroy;
begin
  FieldInits.Free;
  inherited Destroy;
end;
{ TXuiJsEnv }
constructor TXuiJsEnv.Create(AParent: TXuiJsEnv);
begin
  inherited Create;
  Parent := AParent;
  // 注意：Names 必须与 Values 按下标一一对应（插入序），不能排序
  Names := TStringList.Create;
  SetLength(Values, 0);
end;
destructor TXuiJsEnv.Destroy;
begin
  Names.Free;
  inherited Destroy;
end;
function TXuiJsEnv.Define(const AName: string; const AValue: TXuiJsValue): Integer;
begin
  Result := Names.IndexOf(AName);
  if Result >= 0 then
  begin
    Values[Result] := AValue;
    Exit;
  end;
  Names.Add(AName);
  Result := Names.IndexOf(AName);
  if Result >= System.Length(Values) then
    SetLength(Values, Result + 1);
  Values[Result] := AValue;
end;
function TXuiJsEnv.Lookup(const AName: string; out AValue: TXuiJsValue): Boolean;
var
  env: TXuiJsEnv;
  i: Integer;
begin
  env := Self;
  while env <> nil do
  begin
    i := env.Names.IndexOf(AName);
    if i >= 0 then
    begin
      AValue := env.Values[i];
      Exit(True);
    end;
    env := env.Parent;
  end;
  AValue := MakeUndefined;
  Result := False;
end;
procedure TXuiJsEnv.Assign(const AName: string; const AValue: TXuiJsValue);
var
  env: TXuiJsEnv;
  i: Integer;
begin
  env := Self;
  while env <> nil do
  begin
    i := env.Names.IndexOf(AName);
    if i >= 0 then
    begin
      // const 语义：不在此处强制（简化），允许重新赋值
      env.Values[i] := AValue;
      Exit;
    end;
    env := env.Parent;
  end;
  // 未声明：定义在当前环境
  Define(AName, AValue);
end;
function TXuiJsEnv.FindHomeObject: TXuiJsObject;
var
  env: TXuiJsEnv;
begin
  env := Self;
  while env <> nil do
  begin
    if env.HomeObject <> nil then
      Exit(env.HomeObject);
    env := env.Parent;
  end;
  Result := nil;
end;
function TXuiJsEnv.FindFunctionEnv: TXuiJsEnv;
var
  env: TXuiJsEnv;
begin
  env := Self;
  while env <> nil do
  begin
    if env.IsFunctionScope then
      Exit(env);
    env := env.Parent;
  end;
  Result := Self;
end;
{ TXuiJsPromise }
constructor TXuiJsPromise.Create;
begin
  inherited Create;
  JsClass := 'Promise';
  State := psPending;
  Reactions := TObjectList.Create(True);
end;
destructor TXuiJsPromise.Destroy;
begin
  Reactions.Free;
  inherited Destroy;
end;
{ TXuiJsFrame / TXuiJsAsyncMachine（P3）}
constructor TXuiJsFrame.Create;
begin
  inherited Create;
  Links := TList.Create;
  Flow := JsFlowNormal;
  ChildFlow := JsFlowNormal;
  SavedFlow := JsFlowNormal;
  TryMode := 0;
end;
destructor TXuiJsFrame.Destroy;
begin
  Links.Free;
  inherited Destroy;
end;
constructor TXuiJsAsyncMachine.Create;
begin
  inherited Create;
  Frames := TObjectList.Create(True);
end;
destructor TXuiJsAsyncMachine.Destroy;
begin
  Frames.Free;
  inherited Destroy;
end;
{ ---- UTF-8 码点字符串工具（JS 字符串按码点计数） ---- }
function JsStrLength(const S: string): Integer;
begin
  Result := Utf8Length(S);
end;
// 第 AIndex 个码点（0 基）；越界返回空串
function JsStrCharAt(const S: string; AIndex: Integer): string;
var
  i, n, b, len: Integer;
begin
  if AIndex < 0 then
    Exit('');
  i := 1;
  n := 0;
  while i <= System.Length(S) do
  begin
    b := i;
    System.Inc(i, Utf8SeqLen(Byte(S[i])));
    if n = AIndex then
      Exit(Copy(S, b, i - b));
    System.Inc(n);
  end;
  Result := '';
end;
// 码点切片 [AStart, AEnd) ；负数按 JS 语义从尾部计
procedure JsStrSliceRange(const S: string; AStart, AEnd: Integer;
  out ALo, AHi: Integer);
var
  n: Integer;
begin
  n := JsStrLength(S);
  if AStart < 0 then
    AStart := n + AStart;
  if AEnd < 0 then
    AEnd := n + AEnd;
  if AStart < 0 then AStart := 0;
  if AEnd < 0 then AEnd := 0;
  if AStart > n then AStart := n;
  if AEnd > n then AEnd := n;
  ALo := AStart;
  AHi := AEnd;
  if AHi < ALo then
    AHi := ALo;
end;
// 按码点下标切片
function JsStrSlice(const S: string; ALo, AHi: Integer): string;
var
  i, n, startByte, endByte: Integer;
begin
  startByte := -1;
  endByte := -1;
  i := 1;
  n := 0;
  if ALo <= 0 then
    startByte := 1;
  while i <= System.Length(S) do
  begin
    if n = ALo then
      startByte := i;
    if n = AHi then
    begin
      endByte := i;
      Break;
    end;
    System.Inc(i, Utf8SeqLen(Byte(S[i])));
    System.Inc(n);
  end;
  if startByte < 0 then
    Exit('');
  if endByte < 0 then
    endByte := System.Length(S) + 1;
  if endByte <= startByte then
    Exit('');
  Result := Copy(S, startByte, endByte - startByte);
end;
function JsStrIndexOf(const S, ASub: string; AFrom: Integer): Integer;
var
  i, n: Integer;
begin
  if ASub = '' then
    Exit(AFrom);
  i := 1;
  n := 0;
  while i <= System.Length(S) do
  begin
    if n >= AFrom then
    begin
      if Copy(S, i, System.Length(ASub)) = ASub then
        Exit(n);
    end;
    System.Inc(i, Utf8SeqLen(Byte(S[i])));
    System.Inc(n);
  end;
  Result := -1;
end;
// 属性名 → 数组下标（非负整数形式）
function JsArrayIndex(const AName: string; out AIndex: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  AIndex := 0;
  if AName = '' then
    Exit;
  for i := 1 to System.Length(AName) do
  begin
    if (AName[i] < '0') or (AName[i] > '9') then
      Exit;
    AIndex := AIndex * 10 + (Ord(AName[i]) - Ord('0'));
    if AIndex > 1000000000 then
      Exit;
  end;
  if (System.Length(AName) > 1) and (AName[1] = '0') then
    Exit;
  Result := True;
end;
{ TXuiJsInterp — 生命周期 }
constructor TXuiJsInterp.Create;
begin
  inherited Create;
  FAllObjects := TObjectList.Create(False);
  FAllEnvs := TObjectList.Create(False);
  FRoots := TList.Create;
  FMicroTasks := TObjectList.Create(True);
  FAggregates := TObjectList.Create(True);
  FUnhandled := TObjectList.Create(False);
  FTimers := TObjectList.Create(True);
  FAsyncCalls := TObjectList.Create(True);
  FWatchers := TObjectList.Create(True);
  FMountHooks := TObjectList.Create(True);
  FReactiveVersion := 0;
  FSteps := 0;
  FMaxSteps := 2000000;
  FCollectThreshold := 50000;
  FDepth := 0;
  FDraining := False;
  FPumping := False;
  FClockMs := 0;
  FTimerSeq := 0;
  FGlobalEnv := TXuiJsEnv.Create(nil);
  FGlobalEnv.IsFunctionScope := True;
  FGlobal := TXuiJsObject.Create;
  FAllObjects.Add(FGlobal);
  InitGlobals;
end;
destructor TXuiJsInterp.Destroy;
begin
  FMountHooks.Free;
  FWatchers.Free;
  FAsyncCalls.Free;
  FTimers.Free;
  FUnhandled.Free;
  FAggregates.Free;
  FMicroTasks.Free;
  FRoots.Free;
  FAllEnvs.Free;
  FAllObjects.Free;
  FGlobalEnv.Free;
  inherited Destroy;
end;
procedure TXuiJsInterp.Step;
var
  e: EXuiJsThrow;
begin
  Inc(FSteps);
  if FSteps > FMaxSteps then
  begin
    FSteps := 0; // 已触发：重置计数，避免后续每次调用都立即再抛
    // 以脚本异常形式抛出：可被脚本的 try/catch 捕获；无人捕获时由门面上报。
    // Value 携带消息文本：经 Promise 拒绝冒泡后仍可按文本归类为预算错误
    e := EXuiJsThrow.Create('脚本执行步数超出预算（可能存在死循环）');
    e.Value := MakeString(e.Message);
    raise e;
  end;
end;
function TXuiJsInterp.NewObject(const AJsClass: string): TXuiJsObject;
begin
  Result := TXuiJsObject.Create;
  Result.JsClass := AJsClass;
  Result.Proto := FObjectProto;
  FAllObjects.Add(Result);
end;
function TXuiJsInterp.NewArray: TXuiJsArray;
begin
  Result := TXuiJsArray.Create;
  Result.Proto := FArrayProto;
  FAllObjects.Add(Result);
end;
function TXuiJsInterp.NewFunction: TXuiJsFunction;
begin
  Result := TXuiJsFunction.Create;
  Result.Proto := FFunctionProto;
  FAllObjects.Add(Result);
end;
function TXuiJsInterp.NewEnv(AParent: TXuiJsEnv): TXuiJsEnv;
begin
  Result := TXuiJsEnv.Create(AParent);
  FAllEnvs.Add(Result);
end;
{ ---- 公开值工具 ---- }
function TXuiJsInterp.Undefined: TXuiJsValue;
begin
  Result := MakeUndefined;
end;
function TXuiJsInterp.NullValue: TXuiJsValue;
begin
  Result := MakeNull;
end;
function TXuiJsInterp.Str(const S: string): TXuiJsValue;
begin
  Result := MakeString(S);
end;
function TXuiJsInterp.Num(const N: Double): TXuiJsValue;
begin
  Result := MakeNumber(N);
end;
function TXuiJsInterp.Bool(const B: Boolean): TXuiJsValue;
begin
  Result := MakeBool(B);
end;
function TXuiJsInterp.ObjectValue(AObj: TXuiJsObject): TXuiJsValue;
begin
  Result := MakeObject(AObj);
end;
function TXuiJsInterp.ArrayValue(AArr: TXuiJsArray): TXuiJsValue;
begin
  Result := MakeObject(AArr);
end;
function TXuiJsInterp.FunctionValue(AFn: TXuiJsFunction): TXuiJsValue;
begin
  Result := MakeObject(AFn);
end;
function TXuiJsInterp.IsCallable(const V: TXuiJsValue): Boolean;
begin
  Result := (V.Kind = jvObject) and (V.Obj is TXuiJsFunction);
end;
function TXuiJsInterp.ToStringValue(const V: TXuiJsValue): string;
var
  arr: TXuiJsArray;
  i: Integer;
  fn: TXuiJsFunction;
begin
  case V.Kind of
    jvUndefined: Result := 'undefined';
    jvNull: Result := 'null';
    jvBool:
      if V.Num <> 0 then
        Result := 'true'
      else
        Result := 'false';
    jvNumber: Result := NumberToString(V.Num);
    jvString: Result := V.Str;
  else
    begin
      if V.Obj is TXuiJsArray then
      begin
        arr := TXuiJsArray(V.Obj);
        Result := '';
        for i := 0 to arr.Length - 1 do
        begin
          if i > 0 then
            Result := Result + ',';
          if not IsNullish(arr.Items[i]) then
            Result := Result + ToStringValue(arr.Items[i]);
        end;
        Exit;
      end;
      if V.Obj is TXuiJsFunction then
      begin
        fn := TXuiJsFunction(V.Obj);
        if fn.Name <> '' then
          Exit('function ' + fn.Name + '() { ... }');
        Exit('function () { ... }');
      end;
      if V.Obj.JsClass = 'Promise' then
        Exit('[object Promise]');
      Result := '[object Object]';
    end;
  end;
end;
function TXuiJsInterp.ToNumberValue(const V: TXuiJsValue): Double;
var
  s: string;
  code: Integer;
begin
  case V.Kind of
    jvUndefined: Result := Nan;
    jvNull: Result := 0;
    jvBool: Result := V.Num;
    jvNumber: Result := V.Num;
    jvString:
      begin
        s := Trim(V.Str);
        if s = '' then
          Exit(0);
        if (System.Length(s) > 2) and (s[1] = '0') and ((s[2] = 'x') or (s[2] = 'X')) then
        begin
          Val('$' + Copy(s, 3, System.Length(s)), Result, code);
          if code <> 0 then
            Result := Nan;
          Exit;
        end;
        Val(s, Result, code);
        if code <> 0 then
          Result := Nan;
      end;
  else
    Result := Nan;
  end;
end;
function TXuiJsInterp.ToBoolValue(const V: TXuiJsValue): Boolean;
begin
  case V.Kind of
    jvUndefined, jvNull: Result := False;
    jvBool: Result := V.Num <> 0;
    jvNumber: Result := (V.Num <> 0) and (not IsNan(V.Num));
    jvString: Result := V.Str <> '';
  else
    Result := True;
  end;
end;
function TXuiJsInterp.IsTruthy(const V: TXuiJsValue): Boolean;
begin
  Result := ToBoolValue(V);
end;
function TXuiJsInterp.ToInt32Value(const V: TXuiJsValue): Integer;
var
  d: Double;
begin
  d := ToNumberValue(V);
  if IsNan(d) or IsInfinite(d) then
    Exit(0);
  d := Trunc(d);
  d := d - Floor(d / 4294967296) * 4294967296;
  if d >= 2147483648 then
    d := d - 4294967296;
  Result := Round(d);
end;
function TXuiJsInterp.StrictEquals(const A, B: TXuiJsValue): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    jvUndefined, jvNull: Result := True;
    jvBool: Result := (A.Num <> 0) = (B.Num <> 0);
    jvNumber: Result := (A.Num = B.Num);
    jvString: Result := A.Str = B.Str;
  else
    Result := A.Obj = B.Obj;
  end;
end;
function TXuiJsInterp.LooseEquals(const A, B: TXuiJsValue): Boolean;
begin
  if A.Kind = B.Kind then
    Exit(StrictEquals(A, B));
  if IsNullish(A) and IsNullish(B) then
    Exit(True);
  if IsNullish(A) or IsNullish(B) then
    Exit(False);
  if (A.Kind = jvBool) or (B.Kind = jvBool) then
    Exit(ToNumberValue(A) = ToNumberValue(B));
  if (A.Kind = jvNumber) and (B.Kind = jvString) then
    Exit(A.Num = ToNumberValue(B));
  if (A.Kind = jvString) and (B.Kind = jvNumber) then
    Exit(ToNumberValue(A) = B.Num);
  Result := False;
end;
{ ---- 属性访问 ---- }
function TXuiJsInterp.GetProp(const AValue: TXuiJsValue; const AName: string): TXuiJsValue;
var
  obj: TXuiJsObject;
  i, idx: Integer;
begin
  if AValue.Kind = jvObject then
  begin
    obj := AValue.Obj;
    if obj = nil then
      Exit(MakeUndefined);
    if obj is TXuiJsArray then
    begin
      if AName = 'length' then
        Exit(MakeNumber(TXuiJsArray(obj).Length));
      if JsArrayIndex(AName, idx) then
      begin
        if idx < TXuiJsArray(obj).Length then
          Exit(TXuiJsArray(obj).Items[idx]);
        Exit(MakeUndefined);
      end;
    end;
    while obj <> nil do
    begin
      i := obj.FindOwn(AName);
      if i >= 0 then
        Exit(obj.GetOwn(AName));
      if Assigned(obj.NativeGet) then
        if obj.NativeGet(obj, AName, Result) then
          Exit;
      obj := obj.Proto;
    end;
    Exit(MakeUndefined);
  end;
  if AValue.Kind = jvString then
  begin
    if AName = 'length' then
      Exit(MakeNumber(JsStrLength(AValue.Str)));
    if JsArrayIndex(AName, idx) then
      Exit(MakeString(JsStrCharAt(AValue.Str, idx)));
    obj := FStringProto;
  end
  else if AValue.Kind = jvNumber then
    obj := FNumberProto
  else if AValue.Kind = jvBool then
    obj := FBoolProto
  else
    raise EXuiJsRuntime.CreateFmt('无法读取 %s 的属性 "%s"',
      [ToStringValue(AValue), AName]);
  while obj <> nil do
  begin
    i := obj.FindOwn(AName);
    if i >= 0 then
      Exit(obj.GetOwn(AName));
    obj := obj.Proto;
  end;
  Result := MakeUndefined;
end;
procedure TXuiJsInterp.SetProp(const AValue: TXuiJsValue; const AName: string;
  const ANewValue: TXuiJsValue);
var
  obj: TXuiJsObject;
  idx: Integer;
  d: Double;
begin
  if AValue.Kind <> jvObject then
    raise EXuiJsRuntime.CreateFmt('无法给 %s 的属性 "%s" 赋值',
      [ToStringValue(AValue), AName]);
  obj := AValue.Obj;
  if obj is TXuiJsArray then
  begin
    if AName = 'length' then
    begin
      // 简单实现：仅支持扩大（缩容剪掉尾部）
      d := ToNumberValue(ANewValue);
      if IsNan(d) or IsInfinite(d) then
        idx := 0
      else
        idx := Round(d);
      if idx < 0 then
        idx := 0;
      if idx < TXuiJsArray(obj).Length then
        SetLength(TXuiJsArray(obj).Items, idx)
      else
        while TXuiJsArray(obj).Length < idx do
        begin
          SetLength(TXuiJsArray(obj).Items, TXuiJsArray(obj).Length + 1);
          TXuiJsArray(obj).Items[TXuiJsArray(obj).Length - 1] := MakeUndefined;
        end;
      Exit;
    end;
    if JsArrayIndex(AName, idx) then
    begin
      while TXuiJsArray(obj).Length <= idx do
      begin
        SetLength(TXuiJsArray(obj).Items, TXuiJsArray(obj).Length + 1);
        TXuiJsArray(obj).Items[TXuiJsArray(obj).Length - 1] := MakeUndefined;
      end;
      TXuiJsArray(obj).Items[idx] := ANewValue;
      Exit;
    end;
  end;
  if Assigned(obj.NativeSet) then
    if obj.NativeSet(obj, AName, ANewValue) then
    begin
      if obj.Reactive then
      begin
        FReactiveDirty := True;
      Inc(FReactiveVersion);
        if Assigned(FOnReactiveWrite) then
          FOnReactiveWrite;
      end;
      Exit;
    end;
  obj.SetOwn(AName, ANewValue);
  if obj.Reactive then
  begin
    FReactiveDirty := True;
      Inc(FReactiveVersion);
    if Assigned(FOnReactiveWrite) then
      FOnReactiveWrite;
  end;
end;
function TXuiJsInterp.PropValue(const AValue: TXuiJsValue; const AName: string): TXuiJsValue;
begin
  Result := GetProp(AValue, AName);
end;
procedure TXuiJsInterp.SetPropValue(const AValue: TXuiJsValue; const AName: string;
  const ANewValue: TXuiJsValue);
begin
  SetProp(AValue, AName, ANewValue);
end;
function TXuiJsInterp.GlobalObject: TXuiJsObject;
begin
  Result := FGlobal;
end;
function TXuiJsInterp.ObjectProto: TXuiJsObject;
begin
  Result := FObjectProto;
end;
function TXuiJsInterp.ArrayProto: TXuiJsObject;
begin
  Result := FArrayProto;
end;
function TXuiJsInterp.ArgInt(const AArgs: TXuiJsValueArray; AIndex: Integer;
  ADefault: Integer): Integer;
var
  d: Double;
begin
  d := ToNumberValue(ArgAt(AArgs, AIndex));
  if IsNan(d) or IsInfinite(d) then
    Result := ADefault
  else
    Result := Round(d);
end;
function TXuiJsInterp.MakeArray(const AItems: TXuiJsValueArray): TXuiJsValue;
var
  arr: TXuiJsArray;
begin
  arr := NewArray;
  arr.Items := Copy(AItems, 0, System.Length(AItems));
  Result := ArrayValue(arr);
end;
// 空数组（Pascal 无 [] 字面量）
function TXuiJsInterp.EmptyArray: TXuiJsValue;
begin
  Result := ArrayValue(NewArray);
end;
procedure TXuiJsInterp.AddRoot(const AValue: TXuiJsValue);
var
  p: TXuiJsProp;
begin
  p := TXuiJsProp.Create;
  p.Name := '';
  p.Value := AValue;
  FRoots.Add(p);
end;
procedure TXuiJsInterp.ClearRoots;
begin
  FRoots.Clear;
end;
{ ---- 全局与原生注册 ---- }
function TXuiJsInterp.Native(const AFn: TXuiJsNativeFunc): TXuiJsValue;
var
  fn: TXuiJsFunction;
begin
  fn := NewFunction;
  fn.Native := AFn;
  Result := FunctionValue(fn);
end;
procedure TXuiJsInterp.DefineValue(AObj: TXuiJsObject; const AName: string;
  const AValue: TXuiJsValue);
begin
  AObj.SetOwn(AName, AValue);
end;
procedure TXuiJsInterp.DefineNative(AObj: TXuiJsObject; const AName: string;
  AFn: TXuiJsNativeFunc);
var
  fn: TXuiJsFunction;
begin
  fn := NewFunction;
  fn.Native := AFn;
  fn.Name := AName;
  AObj.SetOwn(AName, FunctionValue(fn));
end;
procedure TXuiJsInterp.RegisterNative(const APath: string; AFn: TXuiJsNativeFunc);
begin
  RegisterValueTo(APath, Native(AFn));
end;
procedure TXuiJsInterp.RegisterValue(const APath: string; const AValue: TXuiJsValue);
begin
  RegisterValueTo(APath, AValue);
end;
procedure TXuiJsInterp.RegisterValueTo(const APath: string; const AValue: TXuiJsValue);
var
  parts: TStringList;
  i: Integer;
  obj: TXuiJsObject;
  v: TXuiJsValue;
begin
  parts := TStringList.Create;
  try
    ExtractStrings(['.'], [], PChar(APath), parts);
    if parts.Count = 0 then
      Exit;
    obj := FGlobal;
    for i := 0 to parts.Count - 2 do
    begin
      v := obj.GetOwn(parts[i]);
      if v.Kind <> jvObject then
      begin
        v := ObjectValue(NewObject);
        obj.SetOwn(parts[i], v);
      end;
      obj := v.Obj;
    end;
    obj.SetOwn(parts[parts.Count - 1], AValue);
  finally
    parts.Free;
  end;
end;
function TXuiJsInterp.GetGlobal(const AName: string): TXuiJsValue;
var
  v: TXuiJsValue;
begin
  if FGlobalEnv.Lookup(AName, v) then
    Exit(v);
  Result := FGlobal.GetOwn(AName);
end;
procedure TXuiJsInterp.SetGlobal(const AName: string; const AValue: TXuiJsValue);
begin
  FGlobalEnv.Define(AName, AValue);
end;
procedure TXuiJsInterp.ResetSteps;
begin
  FSteps := 0;
end;
{ ---- Promise 与微任务（P1）---- }
// 宿主 IO 桥（P4）：为挂起的 I/O 请求创建 promise 与控制函数
function TXuiJsInterp.NewControlFunction(const AName: string;
  APromise: TXuiJsPromise): TXuiJsFunction;
begin
  Result := NewFunction;
  Result.Name := AName;
  Result.Native := @NativePromiseCtl;
  Result.Tag := APromise;
end;
function TXuiJsInterp.PendingPromiseValue(APromise: TXuiJsPromise): TXuiJsValue;
begin
  Result := ObjectValue(APromise);
end;
function TXuiJsInterp.ArgAtPublic(const AArgs: TXuiJsValueArray;
  AIndex: Integer): TXuiJsValue;
begin
  Result := ArgAt(AArgs, AIndex);
end;
procedure TXuiJsInterp.MarkRootValue(const AValue: TXuiJsValue);
begin
  MarkValue(AValue);
end;
{ ---- 响应式内核（M7）---- }
procedure TXuiJsInterp.AddOnCollectRootsImpl(AProc: TXuiGcRootsProc);
begin
  SetLength(FExtraRoots, System.Length(FExtraRoots) + 1);
  FExtraRoots[High(FExtraRoots)] := AProc;
end;
procedure TXuiJsInterp.AddOnCollectRoots(AProc: TXuiGcRootsProc);
begin
  AddOnCollectRootsImpl(AProc);
end;
procedure TXuiJsInterp.MarkRootEnv(AEnv: TXuiJsEnv);
begin
  MarkEnv(AEnv);
end;
function TXuiJsInterp.GlobalEnv: TXuiJsEnv;
begin
  Result := FGlobalEnv;
end;
function TXuiJsInterp.NewChildEnv(AParent: TXuiJsEnv): TXuiJsEnv;
begin
  Result := NewEnv(AParent);
end;
function TXuiJsInterp.EvalAst(AAst: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
begin
  Inc(FDepth);
  try
    Result := EvalExpr(AAst, AEnv);
  finally
    Dec(FDepth);
  end;
end;
function TXuiJsInterp.ReactiveDirty: Boolean;
begin
  Result := FReactiveDirty;
end;
procedure TXuiJsInterp.MarkReactiveDirty;
begin
  FReactiveDirty := True;
      Inc(FReactiveVersion);
end;
procedure TXuiJsInterp.ClearReactiveDirty;
begin
  FReactiveDirty := False;
end;

procedure TXuiJsInterp.NotifyReactiveWrite(AObj: TXuiJsObject);
begin
  if (AObj = nil) or (not AObj.Reactive) then
    Exit;
  FReactiveDirty := True;
  Inc(FReactiveVersion);
  if Assigned(FOnReactiveWrite) then
    FOnReactiveWrite;
end;
procedure TXuiJsInterp.BumpReactiveVersion;
begin
  Inc(FReactiveVersion);
end;
function TXuiJsInterp.ReactiveVersion: Integer;
begin
  Result := FReactiveVersion;
end;
function TXuiJsInterp.MountHookCount: Integer;
begin
  Result := FMountHooks.Count;
end;
// 深度相等比较（watch deep）：对象/数组逐成员递归，严格相等语义
function TXuiJsInterp.EqualDeep(const A, B: TXuiJsValue): Boolean;
var
  i, j: Integer;
  ao, bo: TXuiJsObject;
  aa, ba: TXuiJsArray;
begin
  if StrictEquals(A, B) then
    Exit(True);
  if (A.Kind <> jvObject) or (B.Kind <> jvObject) then
    Exit(False);
  if (A.Obj = nil) or (B.Obj = nil) then
    Exit(A.Obj = B.Obj);
  ao := A.Obj;
  bo := B.Obj;
  if ao.JsClass <> bo.JsClass then
    Exit(False);
  if (ao is TXuiJsArray) and (bo is TXuiJsArray) then
  begin
    aa := TXuiJsArray(ao);
    ba := TXuiJsArray(bo);
    if aa.Length <> ba.Length then
      Exit(False);
    for i := 0 to aa.Length - 1 do
      if not EqualDeep(aa.Items[i], ba.Items[i]) then
        Exit(False);
    Exit(True);
  end;
  if (ao.Props.Count <> bo.Props.Count) then
    Exit(False);
  for i := 0 to ao.Props.Count - 1 do
  begin
    if TXuiJsProp(ao.Props[i]).Name <> TXuiJsProp(bo.Props[i]).Name then
      Exit(False);
    if not EqualDeep(TXuiJsProp(ao.Props[i]).Value, TXuiJsProp(bo.Props[i]).Value) then
      Exit(False);
  end;
  Result := True;
end;

// 内容指纹（deep watch 快照）
function TXuiJsInterp.DeepSnapshot(const AValue: TXuiJsValue): string;
var
  i: Integer;
begin
  if AValue.Kind <> jvObject then
    Exit(ToStringValue(AValue));
  if AValue.Obj = nil then
    Exit('null');
  if AValue.Obj is TXuiJsArray then
  begin
    Result := '[';
    for i := 0 to TXuiJsArray(AValue.Obj).Length - 1 do
      Result := Result + DeepSnapshot(TXuiJsArray(AValue.Obj).Items[i]) + ',';
    Result := Result + ']';
    Exit;
  end;
  Result := '{';
  for i := 0 to AValue.Obj.Props.Count - 1 do
    Result := Result + TXuiJsProp(AValue.Obj.Props[i]).Name + ':' +
      DeepSnapshot(TXuiJsProp(AValue.Obj.Props[i]).Value) + ',';
  Result := Result + '}';
end;

procedure TXuiJsInterp.RunWatchers;
var
  i: Integer;
  w: TXuiJsWatcher;
  nv: TXuiJsValue;
  changed: Boolean;
begin
  for i := 0 to FWatchers.Count - 1 do
  begin
    w := TXuiJsWatcher(FWatchers[i]);
    try
      nv := CallFunction(w.Fn, MakeUndefined, []);
      if w.Deep then
      begin
        // deep：以内容快照比较（原对象可能被原地修改，引用与旧值相同）
        changed := w.HasLast and (DeepSnapshot(nv) <> w.LastSnap);
        w.LastSnap := DeepSnapshot(nv);
        if changed then
          CallFunction(w.Cb, MakeUndefined, [nv, MakeUndefined]);
      end
      else
      begin
        changed := w.HasLast and (not StrictEquals(nv, w.Last));
        if changed then
          CallFunction(w.Cb, MakeUndefined, [nv, w.Last]);
      end;
      w.Last := nv;
      w.HasLast := True;
    except
      // 监听器内未捕获异常只上报不扩散（与宏任务回调一致）：不崩应用、不中断其余监听器
      on E: EXuiJsThrow do
        if Assigned(FOnCallbackError) then
          FOnCallbackError(ToStringValue(E.Value));
      on E: Exception do
        if Assigned(FOnCallbackError) then
          FOnCallbackError(E.Message);
    end;
  end;
end;
// 文档级响应式登记（watch / onMount）在文档替换时清空：
// 上一页注册的监听器不应继续作用于新页面的全局（否则会拿新 state 的旧引用求值而报错）
procedure TXuiJsInterp.ClearPageReactive;
begin
  FWatchers.Clear;
  FMountHooks.Clear;
end;
// 深度响应式标记：递归标记嵌套普通对象（函数除外；已标记子树剪枝）
procedure TXuiJsInterp.MarkReactiveDeep(AObj: TXuiJsObject; ADepth: Integer);
var
  i: Integer;
begin
  // 注意：不能对已标记（Reactive）对象剪枝——根先被浅标记时子对象会漏标
  if (AObj = nil) or (ADepth <= 0) then
    Exit;
  AObj.Reactive := True;
  for i := 0 to AObj.Props.Count - 1 do
    if (TXuiJsProp(AObj.Props[i]).Value.Kind = jvObject) and
       (TXuiJsProp(AObj.Props[i]).Value.Obj <> nil) and
       (not (TXuiJsProp(AObj.Props[i]).Value.Obj is TXuiJsFunction)) then
      MarkReactiveDeep(TXuiJsProp(AObj.Props[i]).Value.Obj, ADepth - 1);
end;

// 数组等可变方法（push/pop/splice…）的变更通知：仅响应式对象产生待刷新
procedure TXuiJsInterp.NotifyArrayWrite(AObj: TXuiJsObject);
begin
  NotifyReactiveWrite(AObj);
end;

procedure TXuiJsInterp.RunMountHooks;
var
  i: Integer;
begin
  for i := 0 to FMountHooks.Count - 1 do
    try
      CallFunction(TXuiJsProp(FMountHooks[i]).Value, MakeUndefined, []);
    except
      // 挂载钩子异常同样只上报不扩散
      on E: EXuiJsThrow do
        if Assigned(FOnCallbackError) then
          FOnCallbackError(ToStringValue(E.Value));
      on E: Exception do
        if Assigned(FOnCallbackError) then
          FOnCallbackError(E.Message);
    end;
  FMountHooks.Clear;
end;
// computed(fn) 的 value 取值：版本号缓存（响应式刷新后失效重算）
function TXuiJsInterp.ComputedGet(AObj: TXuiJsObject; const AName: string;
  out AValue: TXuiJsValue): Boolean;
var
  verV, fnV, val: TXuiJsValue;
begin
  Result := False;
  if AName <> 'value' then
    Exit;
  verV := AObj.GetOwn('__ver');
  if Round(verV.Num) = FReactiveVersion then
  begin
    AValue := AObj.GetOwn('__val');
    Exit(True);
  end;
  fnV := AObj.GetOwn('__fn');
  val := CallFunction(fnV, MakeUndefined, []);
  AObj.SetOwn('__val', val);
  AObj.SetOwn('__ver', MakeNumber(FReactiveVersion));
  AValue := val;
  Result := True;
end;
// reactive / computed / watch / onMount（按函数名分派）
function TXuiJsInterp.NativeVue(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  src, nv: TXuiJsValue;
  i: Integer;
  obj: TXuiJsObject;
  w: TXuiJsWatcher;
  p: TXuiJsProp;
begin
  if AFn.Name = 'reactive' then
  begin
    src := ArgAt(AArgs, 0);
    if (src.Kind = jvObject) and (src.Obj <> nil) and (not (src.Obj is TXuiJsFunction)) then
    begin
      src.Obj.Reactive := True;
      MarkReactiveDeep(src.Obj, 8);   // M7-2：深度标记（已标记子树剪枝）
    end;
    Exit(src);
  end;
  if AFn.Name = 'computed' then
  begin
    src := ArgAt(AArgs, 0);
    if not IsCallable(src) then
      raise EXuiJsRuntime.Create('computed 的参数必须是函数');
    obj := CreateHostObject('Computed');
    obj.SetOwn('__fn', src);
    obj.SetOwn('__ver', MakeNumber(-1));
    obj.SetOwn('__val', MakeUndefined);
    obj.NativeGet := @ComputedGet;
    Exit(ObjectValue(obj));
  end;
  if AFn.Name = 'watch' then
  begin
    src := ArgAt(AArgs, 0);
    if (not IsCallable(src)) or (not IsCallable(ArgAt(AArgs, 1))) then
      raise EXuiJsRuntime.Create('watch 的两个参数都必须是函数');
    w := TXuiJsWatcher.Create;
    w.Fn := src;
    w.Cb := ArgAt(AArgs, 1);
    w.HasLast := False;
    if (ArgAt(AArgs, 2).Kind = jvObject) and
       ToBoolValue(ArgAt(AArgs, 2).Obj.GetOwn('deep')) then
      w.Deep := True;
    // opts.immediate：注册立即以 (新值, undefined) 回调一次
    if (ArgAt(AArgs, 2).Kind = jvObject) and
       ToBoolValue(ArgAt(AArgs, 2).Obj.GetOwn('immediate')) then
    begin
      nv := CallFunction(w.Fn, MakeUndefined, []);
      CallFunction(w.Cb, MakeUndefined, [nv, MakeUndefined]);
      w.Last := nv;
      w.HasLast := True;
      Exit(MakeUndefined);
    end;
    FWatchers.Add(w);
    Exit(MakeUndefined);
  end;
  if AFn.Name = 'onMount' then
  begin
    src := ArgAt(AArgs, 0);
    if not IsCallable(src) then
      raise EXuiJsRuntime.Create('onMount 的参数必须是函数');
    p := TXuiJsProp.Create;
    p.Value := src;
    FMountHooks.Add(p);
    Exit(MakeUndefined);
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NewPromise: TXuiJsPromise;
begin
  Result := TXuiJsPromise.Create;
  Result.Proto := FPromiseProto;
  FAllObjects.Add(Result);
end;
function TXuiJsInterp.IsPromise(const AValue: TXuiJsValue): Boolean;
begin
  Result := (AValue.Kind = jvObject) and (AValue.Obj is TXuiJsPromise);
end;
// settle：状态不可逆；把反应项拷贝为微任务（回调永远异步），随后清空反应表。
// 拒绝且无人挂接处理 → 进入未处理表（排水结束时统一上报一次）
procedure TXuiJsInterp.PromiseSettle(AP: TXuiJsPromise; ARejected: Boolean;
  const AValue: TXuiJsValue);
var
  i: Integer;
  hadHandlers: Boolean;
begin
  if AP.State <> psPending then
    Exit;
  hadHandlers := AP.Reactions.Count > 0;   // 先记录（循环后即清空）
  if ARejected then
    AP.State := psRejected
  else
    AP.State := psFulfilled;
  AP.Value := AValue;
  for i := 0 to AP.Reactions.Count - 1 do
    EnqueueReactionJob(TXuiJsReaction(AP.Reactions[i]), not ARejected, AValue);
  AP.Reactions.Clear;
  // 拒绝且 settle 时无人挂接处理 → 进入未处理表（排水结束时统一上报一次）
  if ARejected and (not hadHandlers) and (FUnhandled.IndexOf(AP) < 0) then
    FUnhandled.Add(AP);
end;
// resolve 语义：值为 promise 时采纳（下游跟随其 settle），否则完成
procedure TXuiJsInterp.PromiseResolve(AP: TXuiJsPromise; const AValue: TXuiJsValue);
begin
  if IsPromise(AValue) then
  begin
    if AValue.Obj = AP then
    begin
      // 自引用：按规范以 TypeError 拒绝
      PromiseReject(AP, MakeString('TypeError: Chaining cycle detected for promise'));
      Exit;
    end;
    PromiseAddReaction(TXuiJsPromise(AValue.Obj), rkThen,
      MakeUndefined, MakeUndefined, AP, nil, 0);   // 透传反应
    Exit;
  end;
  PromiseSettle(AP, False, AValue);
end;
procedure TXuiJsInterp.PromiseReject(AP: TXuiJsPromise; const AReason: TXuiJsValue);
begin
  PromiseSettle(AP, True, AReason);
end;
procedure TXuiJsInterp.PromiseAddReaction(AP: TXuiJsPromise; AKind: TXuiJsReactionKind;
  const AOnOk, AOnErr: TXuiJsValue; ADownstream: TXuiJsPromise;
  AAggregate: TObject; AIndex: Integer);
var
  r: TXuiJsReaction;
begin
  r := TXuiJsReaction.Create;
  r.Kind := AKind;
  r.OnFulfilled := AOnOk;
  r.OnRejected := AOnErr;
  r.Downstream := ADownstream;
  r.Aggregate := AAggregate;
  r.Index := AIndex;
  FUnhandled.Remove(AP);   // 挂接处理即视为"已处理"
  if AP.State = psPending then
    AP.Reactions.Add(r)
  else
  begin
    // 已 settle：立即入队（回调仍然异步执行）
    EnqueueReactionJob(r, AP.State = psFulfilled, AP.Value);
    r.Free;
  end;
end;
procedure TXuiJsInterp.EnqueueReactionJob(AReaction: TXuiJsReaction;
  ASrcFulfilled: Boolean; const ASrcValue: TXuiJsValue);
var
  t: TXuiJsMicroTask;
begin
  t := TXuiJsMicroTask.Create;
  t.Kind := AReaction.Kind;
  t.OnFulfilled := AReaction.OnFulfilled;
  t.OnRejected := AReaction.OnRejected;
  t.SrcFulfilled := ASrcFulfilled;
  t.SrcValue := ASrcValue;
  t.Downstream := AReaction.Downstream;
  t.Aggregate := AReaction.Aggregate;
  t.Index := AReaction.Index;
  FMicroTasks.Add(t);
end;
// 执行一个微任务作业。任务内的脚本异常按 Promise 语义路由到下游（reject）；
// 下游无人处理时由排水末的未处理检查上报。
procedure TXuiJsInterp.RunJob(ATask: TXuiJsMicroTask);
var
  handler, v: TXuiJsValue;
  agg: TXuiJsAggregate;
  info: TXuiJsObject;
  procedure SettleDown(ARejected: Boolean; const AVal: TXuiJsValue);
  begin
    if ATask.Downstream = nil then
      Exit;
    if ARejected then
      PromiseReject(ATask.Downstream, AVal)
    else
      PromiseResolve(ATask.Downstream, AVal);
  end;
begin
  case ATask.Kind of
    rkThen:
      begin
        if ATask.SrcFulfilled then
          handler := ATask.OnFulfilled
        else
          handler := ATask.OnRejected;
        if IsCallable(handler) then
        begin
          try
            v := CallFunction(handler, MakeUndefined, [ATask.SrcValue]);
          except
            on E: EXuiJsThrow do
            begin
              SettleDown(True, E.Value);
              Exit;
            end;
            on E: Exception do
            begin
              SettleDown(True, MakeString(E.Message));
              Exit;
            end;
          end;
          SettleDown(False, v);
        end
        else if ATask.SrcFulfilled then   // 非函数参数：透传
          SettleDown(False, ATask.SrcValue)
        else
          SettleDown(True, ATask.SrcValue);
      end;
    rkFinally:
      begin
        // finally 回调无参调用，返回值忽略（v1 简化）；抛错则下游 reject
        if IsCallable(ATask.OnFulfilled) then
        begin
          try
            CallFunction(ATask.OnFulfilled, MakeUndefined, []);
          except
            on E: EXuiJsThrow do
            begin
              SettleDown(True, E.Value);
              Exit;
            end;
            on E: Exception do
            begin
              SettleDown(True, MakeString(E.Message));
              Exit;
            end;
          end;
        end;
        if ATask.SrcFulfilled then
          SettleDown(False, ATask.SrcValue)
        else
          SettleDown(True, ATask.SrcValue);
      end;
    rkAll, rkAllSettled:
      begin
        if ATask.Aggregate = nil then
          Exit;
        agg := TXuiJsAggregate(ATask.Aggregate);
        if ATask.Kind = rkAll then
        begin
          if ATask.SrcFulfilled then
          begin
            if ATask.Index < agg.Results.Length then
              agg.Results.Items[ATask.Index] := ATask.SrcValue;
          end
          else if (ATask.Downstream <> nil) and
                  (ATask.Downstream.State = psPending) then
            PromiseReject(ATask.Downstream, ATask.SrcValue);  // 任一 reject 即 reject
        end
        else
        begin
          info := NewObject;
          if ATask.SrcFulfilled then
          begin
            info.SetOwn('status', MakeString('fulfilled'));
            info.SetOwn('value', ATask.SrcValue);
          end
          else
          begin
            info.SetOwn('status', MakeString('rejected'));
            info.SetOwn('reason', ATask.SrcValue);
          end;
          if ATask.Index < agg.Results.Length then
            agg.Results.Items[ATask.Index] := ObjectValue(info);
        end;
        Dec(agg.PendingJobs);
        if (agg.PendingJobs <= 0) and (ATask.Downstream <> nil) and
           (ATask.Downstream.State = psPending) then
          PromiseResolve(ATask.Downstream, ObjectValue(agg.Results));
      end;
    rkRace:
      begin
        // 先到先得（状态不可逆保证首个 settle 生效）
        if ATask.SrcFulfilled then
          SettleDown(False, ATask.SrcValue)
        else
          SettleDown(True, ATask.SrcValue);
      end;
    rkResume:
      // async 机器恢复：await 的 promise 已 settle（值/原因冻结在任务里）
      ResumeMachine(TXuiJsAsyncMachine(ATask.Aggregate),
        ATask.SrcFulfilled, ATask.SrcValue);
  end;
end;
// 聚合状态：任务全部跑完即回收（避免长链泄漏）
procedure TXuiJsInterp.CleanupAggregates;
var
  i: Integer;
begin
  for i := FAggregates.Count - 1 downto 0 do
    if TXuiJsAggregate(FAggregates[i]).PendingJobs <= 0 then
      FAggregates.Delete(i);
end;
// 单个微任务 = 独立执行切片：预算重置（不跨任务累计，见 M6-异步设计 §8）
procedure TXuiJsInterp.RunMicroTaskSlice;
var
  t: TXuiJsMicroTask;
begin
  if FMicroTasks.Count = 0 then
    Exit;
  // Extract（而非 Delete）：任务所有权转移到本地，执行完再释放
  t := TXuiJsMicroTask(FMicroTasks[0]);
  FMicroTasks.Extract(t);
  FSteps := 0;
  Inc(FDepth);
  try
    RunJob(t);
  finally
    Dec(FDepth);
  end;
  t.Free;
  CleanupAggregates;
  MaybeCollect;
end;
procedure TXuiJsInterp.DrainMicrotasks;
begin
  if FDraining then
    Exit;   // 重入防护：排水期间新产生的微任务由当前循环继续排空（同一轮）
  FDraining := True;
  try
    while FMicroTasks.Count > 0 do
      RunMicroTaskSlice;
  finally
    FDraining := False;
  end;
  ScanUnhandledRejections;
end;
function TXuiJsInterp.MicroTaskCount: Integer;
begin
  Result := FMicroTasks.Count;
end;
// v1 简化：每次排水结束检查一次；上报后即从表中移除（同一拒绝只报一次）
procedure TXuiJsInterp.ScanUnhandledRejections;
var
  i: Integer;
  msg: string;
begin
  if FUnhandled.Count = 0 then
    Exit;
  try
    for i := 0 to FUnhandled.Count - 1 do
    begin
      msg := '未处理的 Promise 拒绝: ' +
        ToStringValue(TXuiJsPromise(FUnhandled[i]).Value);
      if Assigned(FOnUnhandledRejection) then
        FOnUnhandledRejection(msg);
    end;
  finally
    FUnhandled.Clear;
  end;
end;
procedure TXuiJsInterp.ForceCollectGarbage;
begin
  CollectGarbage;
end;
function TXuiJsInterp.ObjectCount: Integer;
begin
  Result := FAllObjects.Count;
end;
{ ---- 定时器与宏任务（P2，ADR 17）---- }
procedure TXuiJsInterp.SetClockMs(ANowMs: Int64);
begin
  FClockMs := ANowMs;
end;
function TXuiJsInterp.NowMs: Int64;
begin
  Result := FClockMs;
end;
function TXuiJsInterp.SetTimeout(const ACallback: TXuiJsValue; ADelayMs: Int64;
  const AArgs: TXuiJsValueArray): Integer;
var
  t: TXuiJsTimer;
begin
  if not IsCallable(ACallback) then
    raise EXuiJsRuntime.Create('setTimeout 的第一个参数必须是函数');
  Inc(FTimerSeq);
  t := TXuiJsTimer.Create;
  t.Id := FTimerSeq;
  t.Callback := ACallback;
  t.Args := Copy(AArgs, 0, System.Length(AArgs));
  if ADelayMs < 0 then
    ADelayMs := 0;
  t.DueMs := FClockMs + ADelayMs;
  FTimers.Add(t);
  Result := t.Id;
end;
function TXuiJsInterp.SetInterval(const ACallback: TXuiJsValue; ADelayMs: Int64;
  const AArgs: TXuiJsValueArray): Integer;
begin
  // 间隔下限 1ms：setInterval(fn, 0) 否则会在一次泵内无限循环
  if ADelayMs < 1 then
    ADelayMs := 1;
  Result := SetTimeout(ACallback, ADelayMs, AArgs);
  TXuiJsTimer(FTimers[FTimers.Count - 1]).Interval := ADelayMs;
end;
procedure TXuiJsInterp.ClearTimer(AId: Integer);
var
  i: Integer;
begin
  for i := 0 to FTimers.Count - 1 do
    if TXuiJsTimer(FTimers[i]).Id = AId then
    begin
      TXuiJsTimer(FTimers[i]).Cancelled := True;   // 泵内回收（可能正待执行）
      Exit;
    end;
end;
function TXuiJsInterp.TimersPending: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FTimers.Count - 1 do
    if not TXuiJsTimer(FTimers[i]).Cancelled then
      Inc(Result);
end;
function TXuiJsInterp.HasDueTimers: Boolean;
var
  i: Integer;
  t: TXuiJsTimer;
begin
  for i := 0 to FTimers.Count - 1 do
  begin
    t := TXuiJsTimer(FTimers[i]);
    if (not t.Cancelled) and (t.DueMs <= FClockMs) then
      Exit(True);
  end;
  Result := False;
end;
// 取最早已到期的未取消定时器（同为到期时按表中序 = 注册序）
function FindDueTimerIn(AList: TObjectList; AClockMs: Int64): TXuiJsTimer;
var
  i: Integer;
  t: TXuiJsTimer;
begin
  Result := nil;
  for i := 0 to AList.Count - 1 do
  begin
    t := TXuiJsTimer(AList[i]);
    if t.Cancelled then
      Continue;
    if (t.DueMs <= AClockMs) and
       ((Result = nil) or (t.DueMs < Result.DueMs)) then
      Result := t;
  end;
end;
// 单个宏任务 = 独立预算切片；回调后排水微任务（微任务优先于下一宏任务）。
// 回调内未捕获的脚本异常经 OnCallbackError 上报，不中断后续定时器。
procedure TXuiJsInterp.RunTimerSlice(ATimer: TXuiJsTimer);
var
  owned: Boolean;
begin
  // 出表（一次性）或固定间隔重排（先改表再执行：回调内注册/清除语义一致）
  owned := ATimer.Interval <= 0;
  if owned then
    FTimers.Extract(ATimer)
  else
    ATimer.DueMs := ATimer.DueMs + ATimer.Interval;
  FSteps := 0;
  Inc(FDepth);
  try
    CallFunction(ATimer.Callback, MakeUndefined, ATimer.Args);
  except
    // 宏任务回调内未捕获异常只上报不扩散：不中断后续定时器、不崩应用
    on E: EXuiJsThrow do
      if Assigned(FOnCallbackError) then
        FOnCallbackError(ToStringValue(E.Value));
    on E: Exception do
      if Assigned(FOnCallbackError) then
        FOnCallbackError(E.Message);
  end;
  Dec(FDepth);
  if owned then
    ATimer.Free;
  DrainMicrotasks;
  CleanupAggregates;
  MaybeCollect;
end;
function TXuiJsInterp.PumpTimers: Integer;
var
  t: TXuiJsTimer;
  i: Integer;
begin
  Result := 0;
  if FPumping or FDraining then
    Exit;   // 重入防护：回调内再触发泵无效（宿主驱动模型，不递归执行）
  FPumping := True;
  try
    // 先回收已取消的表项（clearTimeout 可能发生在注册后的任意时刻）
    for i := FTimers.Count - 1 downto 0 do
      if TXuiJsTimer(FTimers[i]).Cancelled then
        FTimers.Delete(i);
    while True do
    begin
      t := FindDueTimerIn(FTimers, FClockMs);
      if t = nil then
        Break;
      RunTimerSlice(t);
      Inc(Result);
    end;
  finally
    FPumping := False;
  end;
end;
// ui.setTimeout / ui.setInterval / ui.clearTimeout / ui.clearInterval / ui.delay / ui.now
function TXuiJsInterp.NativeUiTimer(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  id: Integer;
  ms: Int64;
  extra: TXuiJsValueArray;
  i: Integer;
  p: TXuiJsPromise;
  res: TXuiJsFunction;
begin
  if AFn.Name = 'now' then
    Exit(MakeNumber(FClockMs));
  if AFn.Name = 'time' then
    // 墙钟本地时间字符串：now() 是会话相对毫秒，无法表达"现在几点"；
    // 智能体（工具调用需要时间戳）等场景用本函数
    Exit(MakeString(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)));
  if (AFn.Name = 'clearTimeout') or (AFn.Name = 'clearInterval') then
  begin
    ClearTimer(ArgInt(AArgs, 0));
    Exit(MakeUndefined);
  end;
  if AFn.Name = 'delay' then
  begin
    // ui.delay(ms): Promise —— 定时器到点后 resolve(undefined)
    ms := ArgInt(AArgs, 0);
    if ms < 0 then
      ms := 0;
    p := NewPromise;
    res := NewFunction;
    res.Name := 'resolve';
    res.Native := @NativePromiseCtl;
    res.Tag := p;
    SetTimeout(FunctionValue(res), ms, nil);
    Exit(ObjectValue(p));
  end;
  // setTimeout / setInterval：额外参数作为回调实参
  if System.Length(AArgs) > 2 then
  begin
    SetLength(extra, System.Length(AArgs) - 2);
    for i := 2 to System.Length(AArgs) - 1 do
      extra[i - 2] := AArgs[i];
  end
  else
    SetLength(extra, 0);
  if AFn.Name = 'setTimeout' then
  begin
    ms := ArgInt(AArgs, 1);
    id := SetTimeout(ArgAt(AArgs, 0), ms, extra);
  end
  else
  begin
    ms := ArgInt(AArgs, 1);
    id := SetInterval(ArgAt(AArgs, 0), ms, extra);
  end;
  Result := MakeNumber(id);
end;
function TXuiJsInterp.CreateHostObject(const AJsClass: string): TXuiJsObject;
begin
  Result := NewObject(AJsClass);
end;
function TXuiJsInterp.CreateHostFunction(const AName: string;
  AFn: TXuiJsNativeFunc): TXuiJsValue;
var
  fn: TXuiJsFunction;
begin
  fn := NewFunction;
  fn.Name := AName;
  fn.Native := AFn;
  Result := FunctionValue(fn);
end;
{ ---- GC ---- }
procedure TXuiJsInterp.MarkValue(const AValue: TXuiJsValue);
begin
  if AValue.Kind = jvObject then
    MarkObject(AValue.Obj);
end;
procedure TXuiJsInterp.MarkObject(AObj: TXuiJsObject);
var
  i, j: Integer;
  arr: TXuiJsArray;
  fn: TXuiJsFunction;
  p: TXuiJsPromise;
  r: TXuiJsReaction;
begin
  if (AObj = nil) or AObj.Marked then
    Exit;
  AObj.Marked := True;
  for i := 0 to AObj.Props.Count - 1 do
    MarkValue(TXuiJsProp(AObj.Props[i]).Value);
  MarkObject(AObj.Proto);
  if AObj is TXuiJsArray then
  begin
    arr := TXuiJsArray(AObj);
    for j := 0 to arr.Length - 1 do
      MarkValue(arr.Items[j]);
  end;
  if AObj is TXuiJsFunction then
  begin
    fn := TXuiJsFunction(AObj);
    MarkEnv(fn.Closure);
    MarkObject(fn.HomeObject);
    MarkObject(fn.ParentCtor);
    MarkObject(fn.ProtoObject);
    // resolve/reject 控制函数经 Tag 携带目标 promise（保活，防止悬挂）
    if fn.Tag is TXuiJsPromise then
      MarkObject(TXuiJsPromise(fn.Tag));
  end;
  if AObj is TXuiJsPromise then
  begin
    p := TXuiJsPromise(AObj);
    MarkValue(p.Value);
    for i := 0 to p.Reactions.Count - 1 do
    begin
      r := TXuiJsReaction(p.Reactions[i]);
      MarkValue(r.OnFulfilled);
      MarkValue(r.OnRejected);
      MarkObject(r.Downstream);
      if r.Aggregate <> nil then
      begin
        if r.Kind = rkResume then
          MarkAsyncMachine(r.Aggregate)   // await 挂起中的机器
        else
          MarkObject(TXuiJsAggregate(r.Aggregate).Results);
      end;
    end;
  end;
  if AObj.Tag <> nil then
    Exit; // Tag 由宿主管理（弱引用）
end;
procedure TXuiJsInterp.MarkEnv(AEnv: TXuiJsEnv);
var
  i: Integer;
begin
  if (AEnv = nil) or AEnv.Marked then
    Exit;
  AEnv.Marked := True;
  MarkEnv(AEnv.Parent);
  for i := 0 to System.Length(AEnv.Values) - 1 do
    MarkValue(AEnv.Values[i]);
  MarkObject(AEnv.HomeObject);
  MarkValue(AEnv.ThisValue);
end;
procedure TXuiJsInterp.CollectGarbage;
var
  i: Integer;
  procedure MarkMicroTask(ATask: TXuiJsMicroTask);
  begin
    MarkValue(ATask.OnFulfilled);
    MarkValue(ATask.OnRejected);
    MarkValue(ATask.SrcValue);
    MarkObject(ATask.Downstream);
    if ATask.Aggregate <> nil then
    begin
      if ATask.Kind = rkResume then
        MarkAsyncMachine(ATask.Aggregate)
      else
        MarkObject(TXuiJsAggregate(ATask.Aggregate).Results);
    end;
  end;
  procedure MarkTimer(ATimer: TXuiJsTimer);
  var
    k: Integer;
  begin
    MarkValue(ATimer.Callback);
    for k := 0 to System.Length(ATimer.Args) - 1 do
      MarkValue(ATimer.Args[k]);
  end;
begin
  // 标记
  for i := 0 to FAllObjects.Count - 1 do
    TXuiJsObject(FAllObjects[i]).Marked := False;
  for i := 0 to FAllEnvs.Count - 1 do
    TXuiJsEnv(FAllEnvs[i]).Marked := False;
  MarkObject(FGlobal);
  MarkEnv(FGlobalEnv);
  MarkObject(FObjectProto);
  MarkObject(FFunctionProto);
  MarkObject(FArrayProto);
  MarkObject(FStringProto);
  MarkObject(FNumberProto);
  MarkObject(FBoolProto);
  MarkObject(FPromiseProto);
  for i := 0 to FRoots.Count - 1 do
    MarkValue(TXuiJsProp(FRoots[i]).Value);
  // P1 根扩展：微任务队列、未处理拒绝表、聚合收集状态
  for i := 0 to FMicroTasks.Count - 1 do
    MarkMicroTask(TXuiJsMicroTask(FMicroTasks[i]));
  for i := 0 to FUnhandled.Count - 1 do
    MarkObject(TXuiJsObject(FUnhandled[i]));
  for i := 0 to FAggregates.Count - 1 do
    MarkObject(TXuiJsAggregate(FAggregates[i]).Results);
  // P2 根扩展：定时器表（回调与参数）
  for i := 0 to FTimers.Count - 1 do
    MarkTimer(TXuiJsTimer(FTimers[i]));
  // P3 根扩展：活跃 async 机器（挂起中的帧栈不被回收）
  for i := 0 to FAsyncCalls.Count - 1 do
    MarkAsyncMachine(FAsyncCalls[i]);
  // P4：宿主子系统根（挂起 I/O 请求的 Promise 控制函数）
  if Assigned(FOnCollectRoots) then
    FOnCollectRoots;
  // M7：watcher 与挂载钩子保活 + 额外根回调
  for i := 0 to FWatchers.Count - 1 do
  begin
    MarkValue(TXuiJsWatcher(FWatchers[i]).Fn);
    MarkValue(TXuiJsWatcher(FWatchers[i]).Cb);
    MarkValue(TXuiJsWatcher(FWatchers[i]).Last);
  end;
  for i := 0 to FMountHooks.Count - 1 do
    MarkValue(TXuiJsProp(FMountHooks[i]).Value);
  for i := 0 to High(FExtraRoots) do
    FExtraRoots[i]();
  // 清扫
  for i := FAllEnvs.Count - 1 downto 0 do
    if not TXuiJsEnv(FAllEnvs[i]).Marked then
      FAllEnvs.Delete(i);
  for i := FAllObjects.Count - 1 downto 0 do
    if not TXuiJsObject(FAllObjects[i]).Marked then
      FAllObjects.Delete(i);
end;
// 活跃 async 机器的帧栈标记（环境、操作数、结果、被采纳的迭代数组等）
procedure TXuiJsInterp.MarkAsyncMachine(M: TObject);
var
  mach: TXuiJsAsyncMachine;
  i, j: Integer;
  f: TXuiJsFrame;
begin
  if M = nil then
    Exit;
  mach := TXuiJsAsyncMachine(M);
  MarkObject(mach.Promise);
  for i := 0 to mach.Frames.Count - 1 do
  begin
    f := TXuiJsFrame(mach.Frames[i]);
    MarkEnv(f.Env);
    MarkEnv(f.EnvNow);
    if f.DeclEnv <> nil then
      MarkEnv(f.DeclEnv);
    for j := 0 to System.Length(f.Values) - 1 do
      MarkValue(f.Values[j]);
    MarkValue(f.Value);
    MarkValue(f.ThrownValue);
    for j := 0 to System.Length(f.ArgsAcc) - 1 do
      MarkValue(f.ArgsAcc[j]);
    if (f.CursorObj <> nil) and (f.CursorObj is TXuiJsArray) then
      MarkObject(TXuiJsArray(f.CursorObj));
  end;
end;
procedure TXuiJsInterp.MaybeCollect;
begin
  if (FDepth = 0) and (FCollectThreshold > 0) and
     (FAllObjects.Count > FCollectThreshold) then
    CollectGarbage;
end;
{ ---- 执行：入口 ---- }
function TXuiJsInterp.Run(AProgram: TXuiJsNode): TXuiJsValue;
var
  flow: Integer;
begin
  MaybeCollect;
  Inc(FDepth);
  try
    HoistDeclarations(AProgram, FGlobalEnv);
    Result := ExecBlock(AProgram, FGlobalEnv, False, flow);
  finally
    Dec(FDepth);
  end;
end;
function TXuiJsInterp.Call(const AFn: TXuiJsValue; const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  Result := CallWithThis(AFn, MakeUndefined, AArgs);
end;
function TXuiJsInterp.CallWithThis(const AFn: TXuiJsValue; const AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  MaybeCollect;
  Inc(FDepth);
  try
    Result := CallFunction(AFn, AThis, AArgs);
  finally
    Dec(FDepth);
  end;
end;
function TXuiJsInterp.ArgAt(const AArgs: TXuiJsValueArray; AIndex: Integer): TXuiJsValue;
begin
  if (AIndex >= 0) and (AIndex < System.Length(AArgs)) then
    Result := AArgs[AIndex]
  else
    Result := MakeUndefined;
end;
function TXuiJsInterp.ThisOf(AEnv: TXuiJsEnv): TXuiJsValue;
var
  env: TXuiJsEnv;
begin
  env := AEnv;
  while env <> nil do
  begin
    if env.HasThis then
      Exit(env.ThisValue);
    env := env.Parent;
  end;
  Result := MakeUndefined;
end;
{ ---- 函数与类 ---- }
function TXuiJsInterp.MakeClosure(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
var
  fn: TXuiJsFunction;
  i: Integer;
begin
  fn := NewFunction;
  fn.Name := ANode.Name;
  fn.IsArrow := nfArrow in ANode.Flags;
  fn.IsAsync := nfAsync in ANode.Flags;
  fn.Body := ANode.B;
  if Assigned(ANode.A) and (ANode.A.Kind = nkSeq) then
  begin
    SetLength(fn.ParamItems, ANode.A.ItemCount);
    for i := 0 to ANode.A.ItemCount - 1 do
      fn.ParamItems[i] := ANode.A.Items[i];
  end;
  fn.Closure := AEnv;
  if nfMethod in ANode.Flags then
    fn.HomeObject := AEnv.FindHomeObject;
  Result := FunctionValue(fn);
end;
procedure TXuiJsInterp.BindPattern(APattern: TXuiJsNode; const AValue: TXuiJsValue;
  AEnv: TXuiJsEnv; ADeclare: Boolean);
var
  i: Integer;
  v, item: TXuiJsValue;
  target: TXuiJsNode;
begin
  if APattern = nil then
    Exit;
  case APattern.Kind of
    nkIdent:
      if ADeclare then
        AEnv.Define(APattern.Name, AValue)
      else
        AEnv.Assign(APattern.Name, AValue);
    nkAssignPat:
      begin
        v := AValue;
        if IsNullish(v) then
          v := EvalExpr(APattern.B, AEnv);
        BindPattern(APattern.A, v, AEnv, ADeclare);
      end;
    nkRestPat:
      BindPattern(APattern.A, AValue, AEnv, ADeclare);
    nkArrayPat:
      begin
        for i := 0 to APattern.ItemCount - 1 do
        begin
          target := APattern.Items[i];
          if target = nil then
            Continue;
          if target.Kind = nkEmpty then
            Continue;
          if target.Kind = nkRestPat then
          begin
            // 收集剩余元素
            if AValue.Kind = jvObject then
            begin
              // 简化：仅支持数组
            end;
            BindPattern(target.A, MakeUndefined, AEnv, ADeclare);
            Continue;
          end;
          if AValue.Kind = jvObject then
            item := GetProp(AValue, IntToStr(i))
          else
            item := MakeUndefined;
          BindPattern(target, item, AEnv, ADeclare);
        end;
      end;
    nkObjectPat:
      begin
        for i := 0 to APattern.ItemCount - 1 do
        begin
          target := APattern.Items[i];
          if target = nil then
            Continue;
          if target.Kind = nkRestPat then
            Continue;
          item := GetProp(AValue, target.Name);
          BindPattern(target.A, item, AEnv, ADeclare);
        end;
      end;
  end;
end;
procedure TXuiJsInterp.HoistDeclarations(ABody: TXuiJsNode; AEnv: TXuiJsEnv);
var
  i, j: Integer;
  stmt, fnNode: TXuiJsNode;
begin
  if ABody = nil then
    Exit;
  for i := 0 to ABody.ItemCount - 1 do
  begin
    stmt := ABody.Items[i];
    if stmt = nil then
      Continue;
    if stmt.Kind = nkFuncDecl then
    begin
      AEnv.Define(stmt.Name, MakeClosure(stmt.A, AEnv));
      Continue;
    end;
  end;
end;
procedure TXuiJsInterp.BindParams(AFn: TXuiJsFunction; AEnv: TXuiJsEnv;
  const AArgs: TXuiJsValueArray);
var
  i, argIdx: Integer;
  p: TXuiJsNode;
  v: TXuiJsValue;
begin
  for i := 0 to System.Length(AFn.ParamItems) - 1 do
  begin
    p := AFn.ParamItems[i];
    if p = nil then
      Continue;
    if p.Kind = nkRestPat then
    begin
      // 剩余参数：收集
      SetLength(v.Str, 0);
      v := MakeUndefined;
      // 用数组承载
      SetLength(v.Str, 0);
      v := ArrayValue(NewArray);
      for argIdx := i to System.Length(AArgs) - 1 do
      begin
        SetLength(TXuiJsArray(v.Obj).Items, TXuiJsArray(v.Obj).Length + 1);
        TXuiJsArray(v.Obj).Items[TXuiJsArray(v.Obj).Length - 1] := AArgs[argIdx];
      end;
      BindPattern(p.A, v, AEnv, True);
      Continue;
    end;
    v := ArgAt(AArgs, i);
    BindPattern(p, v, AEnv, True);
  end;
end;
procedure TXuiJsInterp.RunFieldInits(AFn: TXuiJsFunction; AEnv: TXuiJsEnv);
var
  i: Integer;
  field: TXuiJsNode;
  thisVal: TXuiJsValue;
  v: TXuiJsValue;
begin
  if (AFn = nil) or (AFn.FieldInits = nil) then
    Exit;
  thisVal := AEnv.ThisValue;
  for i := 0 to AFn.FieldInits.Count - 1 do
  begin
    field := TXuiJsNode(AFn.FieldInits[i]);
    if nfComputed in field.Flags then
      Continue;
    if field.B <> nil then
      v := EvalExpr(field.B, AEnv)
    else
      v := MakeUndefined;
    SetProp(thisVal, field.Name, v);
  end;
  // 注意：不能清空 FieldInits —— 同一类会被多次实例化，每次都要初始化
end;
// 隐式构造函数（派生类未声明 constructor）：沿继承链找到最近的显式构造函数（共享 this），
// 随后自基类向派生类依次执行字段初始化
procedure TXuiJsInterp.RunImplicitCtor(AFn: TXuiJsFunction; const AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray);
var
  chain: TList;
  f: TXuiJsFunction;
  env: TXuiJsEnv;
  i: Integer;
begin
  chain := TList.Create;
  try
    f := AFn;
    while f <> nil do
    begin
      chain.Add(f);
      f := f.ParentCtor;
    end;
    // 1) 运行最上层显式构造函数的函数体（this 贯穿全链）
    for i := chain.Count - 1 downto 0 do
    begin
      f := TXuiJsFunction(chain[i]);
      if f.Body <> nil then
      begin
        env := NewEnv(f.Closure);
        env.IsFunctionScope := True;
        env.HasThis := True;
        env.ThisValue := AThis;
        env.HomeObject := f.ProtoObject;
        RunCtorBody(f, env, AArgs);
        Break;
      end;
    end;
    // 2) 字段初始化：基类 → 派生类
    for i := chain.Count - 1 downto 0 do
    begin
      env := NewEnv(nil);
      env.IsFunctionScope := True;
      env.HasThis := True;
      env.ThisValue := AThis;
      RunFieldInits(TXuiJsFunction(chain[i]), env);
    end;
  finally
    chain.Free;
  end;
end;
procedure TXuiJsInterp.RunCtorBody(AFn: TXuiJsFunction; AEnv: TXuiJsEnv;
  const AArgs: TXuiJsValueArray);
var
  flow: Integer;
begin
  AEnv.Func := AFn;
  BindParams(AFn, AEnv, AArgs);
  HoistDeclarations(AFn.Body, AEnv);
  if AFn.ParentCtor = nil then
    RunFieldInits(AFn, AEnv);
  ExecBlock(AFn.Body, AEnv, False, flow);
end;
function TXuiJsInterp.Construct(const AFn: TXuiJsValue; const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  fn: TXuiJsFunction;
  obj: TXuiJsObject;
  env: TXuiJsEnv;
  flow: Integer;
  thisVal: TXuiJsValue;
begin
  if not IsCallable(AFn) then
    raise EXuiJsRuntime.Create('new 的目标不是构造函数');
  fn := TXuiJsFunction(AFn.Obj);
  if fn.IsCtor then
  begin
    obj := NewObject;
    if fn.ProtoObject <> nil then
      obj.Proto := fn.ProtoObject;
    thisVal := ObjectValue(obj);
    env := NewEnv(fn.Closure);
    env.IsFunctionScope := True;
    env.HasThis := True;
    env.ThisValue := thisVal;
    env.HomeObject := fn.ProtoObject;
    if fn.Body = nil then
      // 派生类未声明构造函数：沿继承链共享 this 执行
      RunImplicitCtor(fn, thisVal, AArgs)
    else
      RunCtorBody(fn, env, AArgs);
    Exit(thisVal);
  end;
  // 普通函数用 new 调用：创建对象并执行（简化语义）
  if fn.Native <> nil then
  begin
    obj := NewObject;
    thisVal := ObjectValue(obj);
    Result := CallFunction(AFn, thisVal, AArgs);
    if Result.Kind <> jvObject then
      Result := thisVal;
    Exit;
  end;
  obj := NewObject;
  thisVal := ObjectValue(obj);
  env := NewEnv(fn.Closure);
  env.IsFunctionScope := True;
  env.HasThis := True;
  env.ThisValue := thisVal;
  BindParams(fn, env, AArgs);
  HoistDeclarations(fn.Body, env);
  if fn.Body <> nil then
    ExecBlock(fn.Body, env, False, flow);
  Result := thisVal;
end;
function TXuiJsInterp.CallFunction(const AFn: TXuiJsValue; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  fn: TXuiJsFunction;
  env: TXuiJsEnv;
  flow: Integer;
begin
  if not IsCallable(AFn) then
    raise EXuiJsRuntime.CreateFmt('%s 不是函数', [ToStringValue(AFn)]);
  fn := TXuiJsFunction(AFn.Obj);
  if fn.Native <> nil then
    Exit(fn.Native(fn, AThis, AArgs));
  if fn.IsAsync then
    Exit(CallAsyncFunction(fn, AThis, AArgs));
  env := NewEnv(fn.Closure);
  env.IsFunctionScope := True;
  env.Func := fn;
  if not fn.IsArrow then
  begin
    env.HasThis := True;
    env.ThisValue := AThis;
  end;
  env.HomeObject := fn.HomeObject;
  BindParams(fn, env, AArgs);
  if fn.Body = nil then
    Exit(MakeUndefined);
  if (fn.Body.Kind <> nkBlock) then
    Exit(EvalExpr(fn.Body, env));   // 箭头函数单表达式体
  HoistDeclarations(fn.Body, env);
  Result := ExecBlock(fn.Body, env, False, flow);
  if flow <> JsFlowReturn then
    Result := MakeUndefined;
end;
function TXuiJsInterp.EvalClass(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
var
  ctorFn, parentFn: TXuiJsFunction;
  proto, parentProto, staticHome: TXuiJsObject;
  ctorVal: TXuiJsValue;
  i, k: Integer;
  m, mf: TXuiJsNode;
  memberVal: TXuiJsValue;
  mfn: TXuiJsFunction;
  hasCtor: Boolean;
begin
  ctorFn := NewFunction;
  ctorFn.Name := ANode.Name;
  ctorFn.IsCtor := True;
  ctorFn.Closure := AEnv;
  proto := NewObject('Object');
  proto.Proto := FObjectProto;
  parentFn := nil;
  parentProto := nil;
  if ANode.B <> nil then
  begin
    memberVal := EvalExpr(ANode.B, AEnv);
    if IsCallable(memberVal) and TXuiJsFunction(memberVal.Obj).IsCtor then
    begin
      parentFn := TXuiJsFunction(memberVal.Obj);
      parentProto := parentFn.ProtoObject;
      proto.Proto := parentProto;
      ctorFn.Proto := parentFn;   // 静态继承链
    end
    else if memberVal.Kind = jvObject then
      proto.Proto := memberVal.Obj;
  end;
  ctorFn.ParentCtor := parentFn;
  ctorFn.ProtoObject := proto;
  ctorVal := FunctionValue(ctorFn);
  proto.SetOwn('constructor', ctorVal);
  hasCtor := False;
  for i := 0 to ANode.A.ItemCount - 1 do
  begin
    m := ANode.A.Items[i];
    if m = nil then
      Continue;
    if m.Kind = nkMethod then
    begin
      mf := m.A;
      mfn := TXuiJsFunction(MakeClosure(mf, AEnv).Obj);
      if nfStatic in m.Flags then
        staticHome := ctorFn
      else
        staticHome := proto;
      mfn.HomeObject := staticHome;
      if (m.Name = 'constructor') and (not (nfStatic in m.Flags)) then
      begin
        ctorFn.Body := mf.B;
        SetLength(ctorFn.ParamItems, System.Length(mfn.ParamItems));
        for k := 0 to System.Length(mfn.ParamItems) - 1 do
          ctorFn.ParamItems[k] := mfn.ParamItems[k];
        hasCtor := True;
        Continue;
      end;
      staticHome.SetOwn(m.Name, FunctionValue(mfn));
    end
    else if m.Kind = nkClassField then
    begin
      if nfStatic in m.Flags then
      begin
        if m.B <> nil then
          ctorFn.SetOwn(m.Name, EvalExpr(m.B, AEnv))
        else
          ctorFn.SetOwn(m.Name, MakeUndefined);
      end
      else
        ctorFn.FieldInits.Add(m);
    end;
  end;
  if not hasCtor then
    ctorFn.Body := nil;
  Result := ctorVal;
end;
function TXuiJsInterp.EvalBinaryOp(const AOp: string; const A, B: TXuiJsValue): TXuiJsValue;
var
  d1, d2: Double;
  s1, s2: string;
begin
  if AOp = '+' then
  begin
    if (A.Kind = jvString) or (B.Kind = jvString) then
      Exit(MakeString(ToStringValue(A) + ToStringValue(B)));
    Exit(MakeNumber(ToNumberValue(A) + ToNumberValue(B)));
  end;
  if (AOp = '==') then
    Exit(MakeBool(LooseEquals(A, B)));
  if (AOp = '!=') then
    Exit(MakeBool(not LooseEquals(A, B)));
  if (AOp = '===') then
    Exit(MakeBool(StrictEquals(A, B)));
  if (AOp = '!==') then
    Exit(MakeBool(not StrictEquals(A, B)));
  if (AOp = '<') or (AOp = '>') or (AOp = '<=') or (AOp = '>=') then
  begin
    if (A.Kind = jvString) and (B.Kind = jvString) then
    begin
      s1 := A.Str;
      s2 := B.Str;
      if AOp = '<' then Exit(MakeBool(s1 < s2));
      if AOp = '>' then Exit(MakeBool(s1 > s2));
      if AOp = '<=' then Exit(MakeBool(s1 <= s2));
      Exit(MakeBool(s1 >= s2));
    end;
    d1 := ToNumberValue(A);
    d2 := ToNumberValue(B);
    if AOp = '<' then Exit(MakeBool(d1 < d2));
    if AOp = '>' then Exit(MakeBool(d1 > d2));
    if AOp = '<=' then Exit(MakeBool(d1 <= d2));
    Exit(MakeBool(d1 >= d2));
  end;
  if AOp = 'in' then
  begin
    if B.Kind <> jvObject then
      raise EXuiJsRuntime.Create('in 的右侧必须是对象');
    Exit(MakeBool(HasProp(B, ToStringValue(A))));
  end;
  if AOp = 'instanceof' then
    Exit(MakeBool(JsInstanceOf(A, B)));
  d1 := ToNumberValue(A);
  d2 := ToNumberValue(B);
  if AOp = '-' then Exit(MakeNumber(d1 - d2));
  if AOp = '*' then Exit(MakeNumber(d1 * d2));
  if AOp = '/' then Exit(MakeNumber(d1 / d2));
  if AOp = '%' then Exit(MakeNumber(Fmod(d1, d2)));
  if AOp = '**' then Exit(MakeNumber(Power(d1, d2)));
  if AOp = '&' then Exit(MakeNumber(ToInt32Value(A) and ToInt32Value(B)));
  if AOp = '|' then Exit(MakeNumber(ToInt32Value(A) or ToInt32Value(B)));
  if AOp = '^' then Exit(MakeNumber(ToInt32Value(A) xor ToInt32Value(B)));
  if AOp = '<<' then Exit(MakeNumber(ToInt32Value(A) shl (ToInt32Value(B) and 31)));
  if AOp = '>>' then Exit(MakeNumber(ToInt32Value(A) shr (ToInt32Value(B) and 31)));
  if AOp = '>>>' then
    Exit(MakeNumber(LongWord(ToInt32Value(A)) shr (ToInt32Value(B) and 31)));
  Result := MakeUndefined;
end;
{ ---- 属性/实例判定辅助 ---- }
function TXuiJsInterp.PropNameOf(const AValue: TXuiJsValue): string;
begin
  if AValue.Kind = jvNumber then
    Result := NumberToString(AValue.Num)
  else
    Result := ToStringValue(AValue);
end;
function TXuiJsInterp.HasProp(const AValue: TXuiJsValue; const AName: string): Boolean;
var
  obj: TXuiJsObject;
  idx: Integer;
begin
  Result := False;
  if AValue.Kind <> jvObject then
    Exit;
  obj := AValue.Obj;
  if obj is TXuiJsArray then
  begin
    if AName = 'length' then
      Exit(True);
    if JsArrayIndex(AName, idx) then
      Exit(idx < TXuiJsArray(obj).Length);
  end;
  while obj <> nil do
  begin
    if obj.FindOwn(AName) >= 0 then
      Exit(True);
    obj := obj.Proto;
  end;
end;
function TXuiJsInterp.JsInstanceOf(const A, B: TXuiJsValue): Boolean;
var
  proto, obj: TXuiJsObject;
begin
  Result := False;
  if (not IsCallable(B)) or (A.Kind <> jvObject) then
    Exit;
  proto := TXuiJsFunction(B.Obj).ProtoObject;
  if proto = nil then
    Exit;
  obj := A.Obj;
  while obj <> nil do
  begin
    if obj = proto then
      Exit(True);
    obj := obj.Proto;
  end;
end;
function TXuiJsInterp.EvalArgs(ACallNode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValueArray;
var
  i, j: Integer;
  node: TXuiJsNode;
  v: TXuiJsValue;
  procedure Add(const AValue: TXuiJsValue);
  var
    n: Integer;
  begin
    n := System.Length(Result);
    SetLength(Result, n + 1);
    Result[n] := AValue;
  end;
begin
  SetLength(Result, 0);
  for i := 0 to ACallNode.ItemCount - 1 do
  begin
    node := ACallNode.Items[i];
    if node = nil then
      Continue;
    if node.Kind = nkSpread then
    begin
      v := EvalExpr(node.A, AEnv);
      if v.Kind = jvObject then
      begin
        if v.Obj is TXuiJsArray then
          for j := 0 to TXuiJsArray(v.Obj).Length - 1 do
            Add(TXuiJsArray(v.Obj).Items[j]);
      end
      else if v.Kind = jvString then
        for j := 0 to JsStrLength(v.Str) - 1 do
          Add(MakeString(JsStrCharAt(v.Str, j)));
      Continue;
    end;
    Add(EvalExpr(node, AEnv));
  end;
end;
{ ---- 成员链求值（含可选链短路与 super） ---- }
function TXuiJsInterp.EvalMemberChain(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
var
  links: array of TXuiJsNode;
  n: Integer;
  node: TXuiJsNode;
  base, thisVal, argV: TXuiJsValue;
  lastMemberObj: TXuiJsValue;
  lastWasMember, shorted, baseIsSuper: Boolean;
  i, superFirstNameIdx: Integer;
  args: TXuiJsValueArray;
begin
  SetLength(links, 8);
  n := 0;
  node := ANode;
  while (node <> nil) and ((node.Kind = nkMember) or (node.Kind = nkCall)) do
  begin
    if n >= System.Length(links) then
      SetLength(links, n * 2);
    links[n] := node;
    Inc(n);
    node := node.A;
  end;
  baseIsSuper := (node <> nil) and (node.Kind = nkSuper);
  if baseIsSuper then
  begin
    // super(...) 构造调用
    if (n = 1) and (links[0].Kind = nkCall) then
    begin
      args := EvalArgs(links[0], AEnv);
      Exit(SuperConstructCall(AEnv, args));
    end;
    base := SuperBaseValue(AEnv);
    thisVal := ThisOf(AEnv);
  end
  else
  begin
    base := EvalExpr(node, AEnv);
    thisVal := MakeUndefined;
  end;
  superFirstNameIdx := -1;
  lastWasMember := False;
  lastMemberObj := MakeUndefined;
  shorted := False;
  for i := n - 1 downto 0 do
  begin
    if shorted then
      Continue;
    if links[i].Kind = nkMember then
    begin
      if IsNullish(base) then
      begin
        if nfOptional in links[i].Flags then
        begin
          shorted := True;
          Continue;
        end;
      end;
      lastMemberObj := base;
      if nfComputed in links[i].Flags then
        base := GetProp(base, PropNameOf(EvalExpr(links[i].B, AEnv)))
      else
        base := GetProp(base, links[i].Name);
      lastWasMember := True;
      if baseIsSuper and (superFirstNameIdx < 0) then
        superFirstNameIdx := i;
    end
    else
    begin
      if IsNullish(base) and (nfOptional in links[i].Flags) then
      begin
        shorted := True;
        Continue;
      end;
      args := EvalArgs(links[i], AEnv);
      if lastWasMember then
      begin
        if baseIsSuper and (superFirstNameIdx = i + 1) then
          base := CallFunction(base, thisVal, args)     // super.m(...)：this 保持
        else
          base := CallFunction(base, lastMemberObj, args)
      end
      else
        base := CallFunction(base, MakeUndefined, args);
      lastWasMember := False;
    end;
  end;
  Result := base;
end;
{ ---- 表达式求值 ---- }
function TXuiJsInterp.EvalExpr(ANode: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
  procedure WriteRef(const ATarget: TXuiJsNode; const AValue: TXuiJsValue);
  begin
    if ATarget.Kind = nkIdent then
      AEnv.Assign(ATarget.Name, AValue)
    else if ATarget.Kind = nkMember then
    begin
      if nfComputed in ATarget.Flags then
        SetProp(EvalExpr(ATarget.A, AEnv), PropNameOf(EvalExpr(ATarget.B, AEnv)), AValue)
      else
        SetProp(EvalExpr(ATarget.A, AEnv), ATarget.Name, AValue);
    end
    else if (ATarget.Kind = nkArrayPat) or (ATarget.Kind = nkObjectPat) then
      BindPattern(ATarget, AValue, AEnv, False)
    else
      raise EXuiJsRuntime.Create('赋值目标无效');
  end;
  function ReadRef(const ATarget: TXuiJsNode): TXuiJsValue;
  begin
    if ATarget.Kind = nkIdent then
    begin
      if not AEnv.Lookup(ATarget.Name, Result) then
        Result := FGlobal.GetOwn(ATarget.Name);
    end
    else if ATarget.Kind = nkMember then
    begin
      if nfComputed in ATarget.Flags then
        Result := GetProp(EvalExpr(ATarget.A, AEnv), PropNameOf(EvalExpr(ATarget.B, AEnv)))
      else
        Result := GetProp(EvalExpr(ATarget.A, AEnv), ATarget.Name);
    end
    else
      Result := MakeUndefined;
  end;
var
  a, b, c, v: TXuiJsValue;
  obj: TXuiJsObject;
  arr: TXuiJsArray;
  args: TXuiJsValueArray;
  i, j: Integer;
  op: string;
  part: TXuiJsNode;
begin
  if ANode = nil then
    Exit(MakeUndefined);
  Step;
  case ANode.Kind of
    nkNumber: Result := MakeNumber(ANode.Num);
    nkString: Result := MakeString(ANode.Str);
    nkBool: Result := MakeBool(ANode.Num <> 0);
    nkNull: Result := MakeNull;
    nkUndefined: Result := MakeUndefined;
    nkEmpty: Result := MakeUndefined;
    nkThis: Result := ThisOf(AEnv);
    nkIdent:
      begin
        if not AEnv.Lookup(ANode.Name, Result) then
          Result := FGlobal.GetOwn(ANode.Name);
      end;
    nkTemplate:
      begin
        op := '';
        for i := 0 to ANode.ItemCount - 1 do
          op := op + ToStringValue(EvalExpr(ANode.Items[i], AEnv));
        Result := MakeString(op);
      end;
    nkArrayLit:
      begin
        arr := NewArray;
        for i := 0 to ANode.ItemCount - 1 do
        begin
          part := ANode.Items[i];
          if part = nil then
            Continue;
          if part.Kind = nkEmpty then
          begin
            SetLength(arr.Items, arr.Length + 1);
            arr.Items[arr.Length - 1] := MakeUndefined;
          end
          else if part.Kind = nkSpread then
          begin
            v := EvalExpr(part.A, AEnv);
            if (v.Kind = jvObject) and (v.Obj is TXuiJsArray) then
            begin
              for j := 0 to TXuiJsArray(v.Obj).Length - 1 do
              begin
                SetLength(arr.Items, arr.Length + 1);
                arr.Items[arr.Length - 1] := TXuiJsArray(v.Obj).Items[j];
              end;
            end
            else if v.Kind = jvString then
              for j := 0 to JsStrLength(v.Str) - 1 do
              begin
                SetLength(arr.Items, arr.Length + 1);
                arr.Items[arr.Length - 1] := MakeString(JsStrCharAt(v.Str, j));
              end;
          end
          else
          begin
            SetLength(arr.Items, arr.Length + 1);
            arr.Items[arr.Length - 1] := EvalExpr(part, AEnv);
          end;
        end;
        Result := ArrayValue(arr);
      end;
    nkObjectLit:
      begin
        obj := NewObject;
        for i := 0 to ANode.ItemCount - 1 do
        begin
          part := ANode.Items[i];
          if part = nil then
            Continue;
          if part.Kind = nkSpread then
          begin
            v := EvalExpr(part.A, AEnv);
            if v.Kind = jvObject then
              for j := 0 to v.Obj.Props.Count - 1 do
                obj.SetOwn(TXuiJsProp(v.Obj.Props[j]).Name,
                  TXuiJsProp(v.Obj.Props[j]).Value);
            Continue;
          end;
          v := EvalExpr(part.B, AEnv);
          obj.SetOwn(part.Name, v);
        end;
        Result := ObjectValue(obj);
      end;
    nkFunc: Result := MakeClosure(ANode, AEnv);
    nkClass: Result := EvalClass(ANode, AEnv);
    nkUnary:
      begin
        op := ANode.Op;
        if op = 'typeof' then
        begin
          a := EvalExpr(ANode.A, AEnv);
          case a.Kind of
            jvUndefined: Result := MakeString('undefined');
            jvNull: Result := MakeString('object');
            jvBool: Result := MakeString('boolean');
            jvNumber: Result := MakeString('number');
            jvString: Result := MakeString('string');
          else
            if a.Obj is TXuiJsFunction then
              Result := MakeString('function')
            else
              Result := MakeString('object');
          end;
        end
        else if op = 'void' then
        begin
          EvalExpr(ANode.A, AEnv);
          Result := MakeUndefined;
        end
        else if op = 'delete' then
        begin
          if (ANode.A.Kind = nkMember) and (not (nfComputed in ANode.A.Flags)) then
          begin
            a := EvalExpr(ANode.A.A, AEnv);
            if a.Kind = jvObject then
              a.Obj.DeleteOwn(ANode.A.Name);
          end;
          Result := MakeBool(True);
        end
        else
        begin
          a := EvalExpr(ANode.A, AEnv);
          if op = '!' then Result := MakeBool(not ToBoolValue(a))
          else if op = '-' then Result := MakeNumber(-ToNumberValue(a))
          else if op = '+' then Result := MakeNumber(ToNumberValue(a))
          else if op = '~' then Result := MakeNumber(not ToInt32Value(a))
          else Result := MakeUndefined;
        end;
      end;
    nkUpdate:
      begin
        a := ReadRef(ANode.A);
        if ANode.Op = '++' then
          b := MakeNumber(ToNumberValue(a) + 1)
        else
          b := MakeNumber(ToNumberValue(a) - 1);
        WriteRef(ANode.A, b);
        if nfPrefix in ANode.Flags then
          Result := b
        else
          Result := a;
      end;
    nkBinary:
      Result := EvalBinaryOp(ANode.Op, EvalExpr(ANode.A, AEnv), EvalExpr(ANode.B, AEnv));
    nkLogical:
      begin
        a := EvalExpr(ANode.A, AEnv);
        if ANode.Op = '&&' then
        begin
          if not IsTruthy(a) then
            Result := a
          else
            Result := EvalExpr(ANode.B, AEnv);
        end
        else if ANode.Op = '||' then
        begin
          if IsTruthy(a) then
            Result := a
          else
            Result := EvalExpr(ANode.B, AEnv);
        end
        else // ??
        begin
          if not IsNullish(a) then
            Result := a
          else
            Result := EvalExpr(ANode.B, AEnv);
        end;
      end;
    nkCond:
      begin
        if IsTruthy(EvalExpr(ANode.A, AEnv)) then
          Result := EvalExpr(ANode.B, AEnv)
        else
          Result := EvalExpr(ANode.C, AEnv);
      end;
    nkAssign:
      begin
        op := ANode.Op;
        if op = '=' then
        begin
          v := EvalExpr(ANode.B, AEnv);
          WriteRef(ANode.A, v);
          Result := v;
          Exit;
        end;
        // 逻辑类复合赋值：短路，未触发才求值右侧
        if (op = '&&=') or (op = '||=') or (op = '??=') then
        begin
          a := ReadRef(ANode.A);
          if (op = '&&=') and (not IsTruthy(a)) then
            v := a
          else if (op = '||=') and IsTruthy(a) then
            v := a
          else if (op = '??=') and (not IsNullish(a)) then
            v := a
          else
            v := EvalExpr(ANode.B, AEnv);
          WriteRef(ANode.A, v);
          Result := v;
          Exit;
        end;
        // 其余复合赋值：等价于 a = a <op> b（复用二元运算符语义，含 '+' 的字符串拼接）
        a := ReadRef(ANode.A);
        b := EvalExpr(ANode.B, AEnv);
        v := EvalBinaryOp(Copy(op, 1, System.Length(op) - 1), a, b);
        WriteRef(ANode.A, v);
        Result := v;
      end;
    nkSeq:
      begin
        Result := MakeUndefined;
        for i := 0 to ANode.ItemCount - 1 do
          Result := EvalExpr(ANode.Items[i], AEnv);
      end;
    nkMember, nkCall: Result := EvalMemberChain(ANode, AEnv);
    nkAwait:
      // 解析期已做位置校验；此兜底覆盖"类字段初始化器含 await"等边缘
      raise EXuiJsRuntime.Create('await 只能在 async 函数内使用');
    nkNew:
      begin
        a := EvalExpr(ANode.A, AEnv);
        args := EvalArgs(ANode, AEnv);
        Result := Construct(a, args);
      end;
    nkSpread: Result := EvalExpr(ANode.A, AEnv);
  else
    raise EXuiJsRuntime.CreateFmt('暂不支持的表达式节点（kind=%d, %d 行 %d 列）',
      [Ord(ANode.Kind), ANode.Line, ANode.Col]);
  end;
end;
{ ---- 语句执行 ---- }
function TXuiJsInterp.ExecBlock(ABlock: TXuiJsNode; AEnv: TXuiJsEnv;
  ANewScope: Boolean; out AFlow: Integer): TXuiJsValue;
var
  env: TXuiJsEnv;
  i: Integer;
  v: TXuiJsValue;
begin
  env := AEnv;
  if ANewScope then
    env := NewEnv(AEnv);
  AFlow := JsFlowNormal;
  Result := MakeUndefined;
  if ABlock = nil then
    Exit;
  for i := 0 to ABlock.ItemCount - 1 do
  begin
    v := ExecStmt(ABlock.Items[i], env, AFlow);
    Result := v;
    if AFlow <> JsFlowNormal then
      Exit;
  end;
end;
function TXuiJsInterp.ExecStmt(ANode: TXuiJsNode; AEnv: TXuiJsEnv;
  out AFlow: Integer): TXuiJsValue;
var
  a, b, v: TXuiJsValue;
  i: Integer;
  decl: TXuiJsNode;
  env: TXuiJsEnv;
  target: TXuiJsEnv;
  iterArr: TXuiJsArray;
  iterStr: string;
  idx: Integer;
  caught: Boolean;
  thrown: EXuiJsThrow;
begin
  AFlow := JsFlowNormal;
  Result := MakeUndefined;
  if ANode = nil then
    Exit;
  Step;
  case ANode.Kind of
    nkExprStmt: Result := EvalExpr(ANode.A, AEnv);
    nkBlock: Result := ExecBlock(ANode, AEnv, True, AFlow);
    nkEmpty: ;
    nkVarDecl:
      begin
        for i := 0 to ANode.ItemCount - 1 do
        begin
          decl := ANode.Items[i];
          if ANode.Name = 'var' then
            target := AEnv.FindFunctionEnv
          else
            target := AEnv;
          if decl.B <> nil then
            v := EvalExpr(decl.B, AEnv)
          else
            v := MakeUndefined;
          BindPattern(decl.A, v, target, True);
        end;
      end;
    nkFuncDecl:
      ; // 已在 HoistDeclarations 中定义
    nkClassDecl:
      AEnv.Define(ANode.Name, EvalClass(ANode.A, AEnv));
    nkIf:
      begin
        if IsTruthy(EvalExpr(ANode.A, AEnv)) then
          Result := ExecStmt(ANode.B, AEnv, AFlow)
        else if ANode.C <> nil then
          Result := ExecStmt(ANode.C, AEnv, AFlow);
      end;
    nkWhile:
      begin
        while IsTruthy(EvalExpr(ANode.A, AEnv)) do
        begin
          v := ExecStmt(ANode.B, AEnv, AFlow);
          if AFlow = JsFlowBreak then
          begin
            AFlow := JsFlowNormal;
            Break;
          end;
          if AFlow = JsFlowContinue then
            AFlow := JsFlowNormal
          else if AFlow = JsFlowReturn then
            Exit(v);
        end;
      end;
    nkDoWhile:
      begin
        repeat
          v := ExecStmt(ANode.B, AEnv, AFlow);
          if AFlow = JsFlowBreak then
          begin
            AFlow := JsFlowNormal;
            Break;
          end;
          if AFlow = JsFlowContinue then
            AFlow := JsFlowNormal
          else if AFlow = JsFlowReturn then
            Exit(v);
        until not IsTruthy(EvalExpr(ANode.A, AEnv));
      end;
    nkFor:
      begin
        env := NewEnv(AEnv);
        if ANode.A <> nil then
        begin
          if ANode.A.Kind = nkVarDecl then
            ExecStmt(ANode.A, env, AFlow)
          else
            EvalExpr(ANode.A, env);
        end;
        while True do
        begin
          if ANode.B <> nil then
            if not IsTruthy(EvalExpr(ANode.B, env)) then
              Break;
          if ANode.ItemCount > 0 then
          begin
            v := ExecStmt(ANode.Items[0], env, AFlow);
            if AFlow = JsFlowBreak then
            begin
              AFlow := JsFlowNormal;
              Break;
            end;
            if AFlow = JsFlowContinue then
              AFlow := JsFlowNormal
            else if AFlow = JsFlowReturn then
              Exit(v);
          end;
          if ANode.C <> nil then
            EvalExpr(ANode.C, env);
        end;
      end;
    nkForOf:
      begin
        a := EvalExpr(ANode.B, AEnv);
        iterArr := nil;
        iterStr := '';
        if (a.Kind = jvObject) and (a.Obj is TXuiJsArray) then
          iterArr := TXuiJsArray(a.Obj)
        else if a.Kind = jvString then
          iterStr := a.Str
        else
          raise EXuiJsRuntime.Create('for..of 仅支持数组与字符串');
        env := NewEnv(AEnv);
        if iterArr <> nil then
        begin
          for idx := 0 to iterArr.Length - 1 do
          begin
            BindPattern(ANode.A, iterArr.Items[idx], env, True);
            v := ExecStmt(ANode.C, env, AFlow);
            if AFlow = JsFlowBreak then
            begin
              AFlow := JsFlowNormal;
              Break;
            end;
            if AFlow = JsFlowContinue then
              AFlow := JsFlowNormal
            else if AFlow = JsFlowReturn then
              Exit(v);
          end;
        end
        else
        begin
          for idx := 0 to JsStrLength(iterStr) - 1 do
          begin
            BindPattern(ANode.A, MakeString(JsStrCharAt(iterStr, idx)), env, True);
            v := ExecStmt(ANode.C, env, AFlow);
            if AFlow = JsFlowBreak then
            begin
              AFlow := JsFlowNormal;
              Break;
            end;
            if AFlow = JsFlowContinue then
              AFlow := JsFlowNormal
            else if AFlow = JsFlowReturn then
              Exit(v);
          end;
        end;
      end;
    nkReturn:
      begin
        if ANode.A <> nil then
          Result := EvalExpr(ANode.A, AEnv);
        AFlow := JsFlowReturn;
      end;
    nkBreak:
      AFlow := JsFlowBreak;
    nkContinue:
      AFlow := JsFlowContinue;
    nkThrow:
      begin
        v := EvalExpr(ANode.A, AEnv);
        thrown := EXuiJsThrow.Create(ToStringValue(v));
        thrown.Value := v;
        raise thrown;
      end;
    nkTry:
      begin
        caught := False;
        try
          Result := ExecBlock(ANode.B, AEnv, True, AFlow);
        except
          on E: EXuiJsThrow do
          begin
            caught := True;
            if ANode.C <> nil then
            begin
              env := NewEnv(AEnv);
              BindPattern(ANode.A, E.Value, env, True);
              Result := ExecBlock(ANode.C, env, False, AFlow);
            end;
          end;
        end;
        if ANode.ItemCount > 0 then
        begin
          // finally
          v := ExecBlock(ANode.Items[0], AEnv, True, AFlow);
          if AFlow = JsFlowNormal then
            Result := v;
        end;
      end;
  else
    raise EXuiJsRuntime.CreateFmt('暂不支持的语句节点（%d）', [Ord(ANode.Kind)]);
  end;
end;
{ ---- super 支持 ---- }
function TXuiJsInterp.SuperBaseValue(AEnv: TXuiJsEnv): TXuiJsValue;
var
  home: TXuiJsObject;
begin
  home := AEnv.FindHomeObject;
  if (home = nil) or (home.Proto = nil) then
    raise EXuiJsRuntime.Create('super 只能用于类的方法中');
  Result := ObjectValue(home.Proto);
end;
function TXuiJsInterp.SuperConstructCall(AEnv: TXuiJsEnv;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  env: TXuiJsEnv;
  parentEnv: TXuiJsEnv;
  fn: TXuiJsFunction;
begin
  env := AEnv;
  while (env <> nil) and (env.Func = nil) do
    env := env.Parent;
  if env = nil then
    raise EXuiJsRuntime.Create('super() 只能用于构造函数中');
  fn := env.Func;
  if fn.ParentCtor = nil then
    raise EXuiJsRuntime.Create('super() 只能用于派生类构造函数');
  parentEnv := NewEnv(fn.ParentCtor.Closure);
  parentEnv.IsFunctionScope := True;
  parentEnv.HasThis := True;
  parentEnv.ThisValue := env.ThisValue;
  parentEnv.HomeObject := fn.ParentCtor.ProtoObject;
  RunCtorBody(fn.ParentCtor, parentEnv, AArgs);
  // 父类就绪后执行本类字段初始化
  RunFieldInits(fn, env);
  Result := env.ThisValue;
end;
{ ---- 内建 ---- }
function TXuiJsInterp.OwnKeys(const AObj: TXuiJsObject): TXuiJsValueArray;
var
  i, n: Integer;
begin
  Result := nil;
  SetLength(Result, AObj.Props.Count);
  n := 0;
  for i := 0 to AObj.Props.Count - 1 do
  begin
    Result[n] := MakeString(TXuiJsProp(AObj.Props[i]).Name);
    Inc(n);
  end;
  SetLength(Result, n);
end;
procedure TXuiJsInterp.InitGlobals;
var
  mathObj, jsonObj, consoleObj, objCtor, arrCtor, strCtor, numCtor, boolCtor,
    uiObj: TXuiJsObject;
  promiseCtor: TXuiJsFunction;
  fn: TXuiJsFunction;
begin
  FObjectProto := TXuiJsObject.Create;
  FAllObjects.Add(FObjectProto);
  FObjectProto.JsClass := 'Object';
  FFunctionProto := TXuiJsObject.Create;
  FAllObjects.Add(FFunctionProto);
  FFunctionProto.Proto := FObjectProto;
  FArrayProto := TXuiJsObject.Create;
  FAllObjects.Add(FArrayProto);
  FArrayProto.Proto := FObjectProto;
  FStringProto := TXuiJsObject.Create;
  FAllObjects.Add(FStringProto);
  FStringProto.Proto := FObjectProto;
  FNumberProto := TXuiJsObject.Create;
  FAllObjects.Add(FNumberProto);
  FNumberProto.Proto := FObjectProto;
  FBoolProto := TXuiJsObject.Create;
  FAllObjects.Add(FBoolProto);
  FBoolProto.Proto := FObjectProto;
  FGlobal.Proto := FObjectProto;
  // 全局函数
  DefineNative(FGlobal, 'parseInt', @NativeGlobalFn);
  DefineNative(FGlobal, 'parseFloat', @NativeGlobalFn);
  DefineNative(FGlobal, 'isNaN', @NativeGlobalFn);
  DefineNative(FGlobal, 'isFinite', @NativeGlobalFn);
  DefineNative(FGlobal, 'String', @NativeGlobalFn);
  DefineNative(FGlobal, 'Number', @NativeGlobalFn);
  DefineNative(FGlobal, 'Boolean', @NativeGlobalFn);
  DefineNative(FGlobal, 'Array', @NativeGlobalFn);
  FGlobal.SetOwn('undefined', MakeUndefined);
  FGlobal.SetOwn('NaN', MakeNumber(Nan));
  FGlobal.SetOwn('Infinity', MakeNumber(Infinity));
  // console
  consoleObj := NewObject('Object');
  DefineNative(consoleObj, 'log', @NativeConsole);
  DefineNative(consoleObj, 'error', @NativeConsole);
  DefineNative(consoleObj, 'warn', @NativeConsole);
  FGlobal.SetOwn('console', ObjectValue(consoleObj));
  // Math
  mathObj := NewObject('Object');
  DefineNative(mathObj, 'abs', @NativeMath);
  DefineNative(mathObj, 'floor', @NativeMath);
  DefineNative(mathObj, 'ceil', @NativeMath);
  DefineNative(mathObj, 'round', @NativeMath);
  DefineNative(mathObj, 'trunc', @NativeMath);
  DefineNative(mathObj, 'sign', @NativeMath);
  DefineNative(mathObj, 'sqrt', @NativeMath);
  DefineNative(mathObj, 'pow', @NativeMath);
  DefineNative(mathObj, 'min', @NativeMath);
  DefineNative(mathObj, 'max', @NativeMath);
  DefineNative(mathObj, 'random', @NativeMath);
  mathObj.SetOwn('PI', MakeNumber(Pi));
  mathObj.SetOwn('E', MakeNumber(Exp(1)));
  FGlobal.SetOwn('Math', ObjectValue(mathObj));
  // JSON
  jsonObj := NewObject('Object');
  DefineNative(jsonObj, 'stringify', @NativeJson);
  DefineNative(jsonObj, 'parse', @NativeJson);
  FGlobal.SetOwn('JSON', ObjectValue(jsonObj));
  // Object / Array 等构造器（提供静态方法）
  objCtor := NewObject('Function');
  objCtor.Proto := FFunctionProto;
  DefineNative(objCtor, 'keys', @NativeObjectStatics);
  DefineNative(objCtor, 'values', @NativeObjectStatics);
  DefineNative(objCtor, 'entries', @NativeObjectStatics);
  DefineNative(objCtor, 'assign', @NativeObjectStatics);
  DefineNative(objCtor, 'freeze', @NativeObjectStatics);
  FGlobal.SetOwn('Object', ObjectValue(objCtor));
  objCtor.SetOwn('prototype', ObjectValue(FObjectProto));
  arrCtor := NewObject('Function');
  arrCtor.Proto := FFunctionProto;
  DefineNative(arrCtor, 'isArray', @NativeObjectStatics);
  arrCtor.SetOwn('prototype', ObjectValue(FArrayProto));
  FGlobal.SetOwn('Array', ObjectValue(arrCtor));
  // Promise（P1）：构造器为真函数（支持 new Promise(executor)）；静态方法挂构造器
  FPromiseProto := TXuiJsObject.Create;
  FAllObjects.Add(FPromiseProto);
  FPromiseProto.Proto := FObjectProto;
  DefineNative(FPromiseProto, 'then', @NativePromiseProto);
  DefineNative(FPromiseProto, 'catch', @NativePromiseProto);
  DefineNative(FPromiseProto, 'finally', @NativePromiseProto);
  promiseCtor := NewFunction;
  promiseCtor.Name := 'Promise';
  promiseCtor.Native := @NativePromise;
  promiseCtor.ProtoObject := FPromiseProto;   // instanceof Promise 支持
  DefineNative(promiseCtor, 'resolve', @NativePromiseStatics);
  DefineNative(promiseCtor, 'reject', @NativePromiseStatics);
  DefineNative(promiseCtor, 'all', @NativePromiseStatics);
  DefineNative(promiseCtor, 'allSettled', @NativePromiseStatics);
  DefineNative(promiseCtor, 'race', @NativePromiseStatics);
  promiseCtor.SetOwn('prototype', ObjectValue(FPromiseProto));
  FGlobal.SetOwn('Promise', FunctionValue(promiseCtor));
  // ui：定时器宏任务（P2，ADR 17）；bridge 等后续注册的 ui.* 子键并入同一对象
  uiObj := NewObject('Object');
  DefineNative(uiObj, 'setTimeout', @NativeUiTimer);
  DefineNative(uiObj, 'setInterval', @NativeUiTimer);
  DefineNative(uiObj, 'clearTimeout', @NativeUiTimer);
  DefineNative(uiObj, 'clearInterval', @NativeUiTimer);
  DefineNative(uiObj, 'delay', @NativeUiTimer);
  DefineNative(uiObj, 'now', @NativeUiTimer);
  DefineNative(uiObj, 'time', @NativeUiTimer);
  FGlobal.SetOwn('ui', ObjectValue(uiObj));
  // 响应式内核（M7）
  DefineNative(FGlobal, 'reactive', @NativeVue);
  DefineNative(FGlobal, 'computed', @NativeVue);
  DefineNative(FGlobal, 'watch', @NativeVue);
  DefineNative(FGlobal, 'onMount', @NativeVue);
  // 原型方法（按名分派）
  DefineNative(FStringProto, 'charAt', @NativeStringProto);
  DefineNative(FStringProto, 'indexOf', @NativeStringProto);
  DefineNative(FStringProto, 'lastIndexOf', @NativeStringProto);
  DefineNative(FStringProto, 'slice', @NativeStringProto);
  DefineNative(FStringProto, 'substring', @NativeStringProto);
  DefineNative(FStringProto, 'toUpperCase', @NativeStringProto);
  DefineNative(FStringProto, 'toLowerCase', @NativeStringProto);
  DefineNative(FStringProto, 'trim', @NativeStringProto);
  DefineNative(FStringProto, 'split', @NativeStringProto);
  DefineNative(FStringProto, 'replace', @NativeStringProto);
  DefineNative(FStringProto, 'includes', @NativeStringProto);
  DefineNative(FStringProto, 'startsWith', @NativeStringProto);
  DefineNative(FStringProto, 'endsWith', @NativeStringProto);
  DefineNative(FStringProto, 'repeat', @NativeStringProto);
  DefineNative(FStringProto, 'concat', @NativeStringProto);
  DefineNative(FStringProto, 'toString', @NativeStringProto);
  DefineNative(FArrayProto, 'push', @NativeArrayProto);
  DefineNative(FArrayProto, 'pop', @NativeArrayProto);
  DefineNative(FArrayProto, 'shift', @NativeArrayProto);
  DefineNative(FArrayProto, 'unshift', @NativeArrayProto);
  DefineNative(FArrayProto, 'slice', @NativeArrayProto);
  DefineNative(FArrayProto, 'indexOf', @NativeArrayProto);
  DefineNative(FArrayProto, 'includes', @NativeArrayProto);
  DefineNative(FArrayProto, 'join', @NativeArrayProto);
  DefineNative(FArrayProto, 'forEach', @NativeArrayProto);
  DefineNative(FArrayProto, 'map', @NativeArrayProto);
  DefineNative(FArrayProto, 'filter', @NativeArrayProto);
  DefineNative(FArrayProto, 'reduce', @NativeArrayProto);
  DefineNative(FArrayProto, 'reverse', @NativeArrayProto);
  DefineNative(FArrayProto, 'concat', @NativeArrayProto);
  DefineNative(FArrayProto, 'splice', @NativeArrayProto);
  // M13：查找与排序。移植真实应用（a_da 的 Agent 工具/会话/设置）时，缺这几个方法
  // 会把"挑出第一个满足条件的元素"写成手写 for 循环，散落在各处且易错。
  DefineNative(FArrayProto, 'find', @NativeArrayProto);
  DefineNative(FArrayProto, 'findIndex', @NativeArrayProto);
  DefineNative(FArrayProto, 'some', @NativeArrayProto);
  DefineNative(FArrayProto, 'every', @NativeArrayProto);
  DefineNative(FArrayProto, 'sort', @NativeArrayProto);
  DefineNative(FNumberProto, 'toFixed', @NativeNumberProto);
  DefineNative(FNumberProto, 'toString', @NativeNumberProto);
  DefineNative(FFunctionProto, 'call', @NativeFunctionProto);
  DefineNative(FFunctionProto, 'apply', @NativeFunctionProto);
end;
function TXuiJsInterp.NativeConsole(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  i: Integer;
  s: string;
begin
  s := '';
  for i := 0 to System.Length(AArgs) - 1 do
  begin
    if i > 0 then
      s := s + ' ';
    s := s + ToStringValue(AArgs[i]);
  end;
  if Assigned(FLog) then
    FLog(s);
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeMath(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  d: Double;
  i: Integer;
begin
  if AFn.Name = 'random' then
    Exit(MakeNumber(Random));
  if AFn.Name = 'min' then
  begin
    d := Infinity;
    for i := 0 to System.Length(AArgs) - 1 do
      d := Min(d, ToNumberValue(AArgs[i]));
    Exit(MakeNumber(d));
  end;
  if AFn.Name = 'max' then
  begin
    d := NegInfinity;
    for i := 0 to System.Length(AArgs) - 1 do
      d := Max(d, ToNumberValue(AArgs[i]));
    Exit(MakeNumber(d));
  end;
  d := ToNumberValue(ArgAt(AArgs, 0));
  if AFn.Name = 'abs' then Exit(MakeNumber(Abs(d)));
  // 注意：不能用 Math 单元的 Floor/Ceil —— 它们返回 32 位 Integer，会把 |x| ≥ 2^31
  // 的值静默截断（如 Math.round(9801000000) → 1211065408）。Trunc 返回 Int64，安全。
  if AFn.Name = 'floor' then Exit(MakeNumber(JsFloor(d)));
  if AFn.Name = 'ceil' then Exit(MakeNumber(JsCeil(d)));
  if AFn.Name = 'round' then Exit(MakeNumber(JsFloor(d + 0.5)));   // JS：半值向 +∞ 取整
  if AFn.Name = 'trunc' then Exit(MakeNumber(Trunc(d)));
  if AFn.Name = 'sign' then
  begin
    if d > 0 then Exit(MakeNumber(1));
    if d < 0 then Exit(MakeNumber(-1));
    Exit(MakeNumber(d));
  end;
  if AFn.Name = 'sqrt' then Exit(MakeNumber(Sqrt(d)));
  if AFn.Name = 'pow' then Exit(MakeNumber(Power(d, ToNumberValue(ArgAt(AArgs, 1)))));
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeJson(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
  function Escape(const S: string): string;
  var
    i: Integer;
    c: Char;
  begin
    Result := '';
    for i := 1 to System.Length(S) do
    begin
      c := S[i];
      case c of
        '"': Result := Result + '\"';
        '\': Result := Result + '\\';
        #8: Result := Result + '\b';
        #9: Result := Result + '\t';
        #10: Result := Result + '\n';
        #12: Result := Result + '\f';
        #13: Result := Result + '\r';
      else
        if Ord(c) < 32 then
          Result := Result + Format('\u%.4x', [Ord(c)])
        else
          Result := Result + c;
      end;
    end;
  end;
  function Stringify(const V: TXuiJsValue; ADepth: Integer): string; forward;
  function StringifyArray(AArr: TXuiJsArray; ADepth: Integer): string;
  var
    i: Integer;
    item: string;
  begin
    Result := '[';
    for i := 0 to AArr.Length - 1 do
    begin
      if i > 0 then
        Result := Result + ',';
      item := Stringify(AArr.Items[i], ADepth + 1);
      if item = '' then
        item := 'null';
      Result := Result + item;
    end;
    Result := Result + ']';
  end;
  function StringifyObject(AObj: TXuiJsObject; ADepth: Integer): string;
  var
    i: Integer;
    p: TXuiJsProp;
    item: string;
    first: Boolean;
  begin
    Result := '{';
    first := True;
    for i := 0 to AObj.Props.Count - 1 do
    begin
      p := TXuiJsProp(AObj.Props[i]);
      item := Stringify(p.Value, ADepth + 1);
      if item = '' then
        Continue;   // undefined / 函数：省略
      if not first then
        Result := Result + ',';
      first := False;
      Result := Result + '"' + Escape(p.Name) + '":' + item;
    end;
    Result := Result + '}';
  end;
  function Stringify(const V: TXuiJsValue; ADepth: Integer): string;
  begin
    if ADepth > 32 then
      Exit('null');
    case V.Kind of
      jvUndefined: Result := '';
      jvNull: Result := 'null';
      jvBool:
        if V.Num <> 0 then
          Result := 'true'
        else
          Result := 'false';
      jvNumber:
        if IsNan(V.Num) or IsInfinite(V.Num) then
          Result := 'null'
        else
          Result := NumberToString(V.Num);
      jvString: Result := '"' + Escape(V.Str) + '"';
    else
      if V.Obj is TXuiJsFunction then
        Result := ''
      else if V.Obj is TXuiJsArray then
        Result := StringifyArray(TXuiJsArray(V.Obj), ADepth)
      else
        Result := StringifyObject(V.Obj, ADepth);
    end;
  end;
var
  s: string;
begin
  if AFn.Name = 'stringify' then
  begin
    s := Stringify(ArgAt(AArgs, 0), 0);
    if s = '' then
      Exit(MakeUndefined);
    Exit(MakeString(s));
  end;
  // parse：递归下降（P4，ui.http 响应 json() 依赖）
  Exit(JsonParseText(ToStringValue(ArgAt(AArgs, 0))));
end;
{ ---- JSON.parse（递归下降；方法组实现）---- }
procedure TXuiJsInterp.JsonSkipWs;
begin
  while (FJsonPos <= System.Length(FJsonS)) and (Ord(FJsonS[FJsonPos]) <= 32) do
    Inc(FJsonPos);
end;
function TXuiJsInterp.JsonParseString: string;
var
  hex: string;
  cp, code: Integer;
begin
  Result := '';
  Inc(FJsonPos);   // 跳过开引号
  while FJsonPos <= System.Length(FJsonS) do
  begin
    case FJsonS[FJsonPos] of
      '"':
        begin
          Inc(FJsonPos);
          Exit;
        end;
      '\':
        begin
          Inc(FJsonPos);
          if FJsonPos > System.Length(FJsonS) then
            raise EXuiJsRuntime.Create('JSON 解析失败：字符串未闭合');
          case FJsonS[FJsonPos] of
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
                hex := Copy(FJsonS, FJsonPos + 1, 4);
                if System.Length(hex) < 4 then
                  raise EXuiJsRuntime.Create('JSON 解析失败：unicode 转义不完整');
                Val('$' + hex, cp, code);
                if code <> 0 then
                  raise EXuiJsRuntime.Create('JSON 解析失败：非法 unicode 转义');
                Result := Result + Utf8Encode(WideChar(Word(cp)));
                Inc(FJsonPos, 4);
              end;
          else
            raise EXuiJsRuntime.Create('JSON 解析失败：非法转义字符');
          end;
          Inc(FJsonPos);
        end;
    else
      begin
        Result := Result + FJsonS[FJsonPos];
        Inc(FJsonPos);
      end;
    end;
  end;
  raise EXuiJsRuntime.Create('JSON 解析失败：字符串未闭合');
end;
function TXuiJsInterp.JsonParseValue: TXuiJsValue;
var
  lit: string;
  numv: Double;
  code: Integer;
  arr: TXuiJsArray;
  obj: TXuiJsObject;
  key: string;
  v: TXuiJsValue;
begin
  JsonSkipWs;
  if FJsonPos > System.Length(FJsonS) then
    raise EXuiJsRuntime.Create('JSON 解析失败：意外结束');
  case FJsonS[FJsonPos] of
    '{':
      begin
        Inc(FJsonPos);
        obj := NewObject;
        JsonSkipWs;
        if (FJsonPos <= System.Length(FJsonS)) and (FJsonS[FJsonPos] = '}') then
        begin
          Inc(FJsonPos);
          Exit(ObjectValue(obj));
        end;
        while True do
        begin
          JsonSkipWs;
          if (FJsonPos > System.Length(FJsonS)) or (FJsonS[FJsonPos] <> '"') then
            raise EXuiJsRuntime.Create('JSON 解析失败：对象键须为字符串');
          key := JsonParseString;
          JsonSkipWs;
          if (FJsonPos > System.Length(FJsonS)) or (FJsonS[FJsonPos] <> ':') then
            raise EXuiJsRuntime.Create('JSON 解析失败：缺少冒号');
          Inc(FJsonPos);
          v := JsonParseValue();
          obj.SetOwn(key, v);
          JsonSkipWs;
          if FJsonPos > System.Length(FJsonS) then
            raise EXuiJsRuntime.Create('JSON 解析失败：对象未闭合');
          if FJsonS[FJsonPos] = ',' then
          begin
            Inc(FJsonPos);
            Continue;
          end;
          if FJsonS[FJsonPos] = '}' then
          begin
            Inc(FJsonPos);
            Exit(ObjectValue(obj));
          end;
          raise EXuiJsRuntime.CreateFmt('JSON 解析失败：对象内缺少逗号或右括号（位置 %d）', [FJsonPos]);
        end;
      end;
    '[':
      begin
        Inc(FJsonPos);
        arr := NewArray;
        JsonSkipWs;
        if (FJsonPos <= System.Length(FJsonS)) and (FJsonS[FJsonPos] = ']') then
        begin
          Inc(FJsonPos);
          Exit(ArrayValue(arr));
        end;
        while True do
        begin
          v := JsonParseValue();
          SetLength(arr.Items, arr.Length + 1);
          arr.Items[arr.Length - 1] := v;
          JsonSkipWs;
          if FJsonPos > System.Length(FJsonS) then
            raise EXuiJsRuntime.Create('JSON 解析失败：数组未闭合');
          if FJsonS[FJsonPos] = ',' then
          begin
            Inc(FJsonPos);
            Continue;
          end;
          if FJsonS[FJsonPos] = ']' then
          begin
            Inc(FJsonPos);
            Exit(ArrayValue(arr));
          end;
          raise EXuiJsRuntime.CreateFmt('JSON 解析失败：数组内缺少逗号或右括号（位置 %d）', [FJsonPos]);
        end;
      end;
    '"':
      Exit(MakeString(JsonParseString));
    't':
      begin
        lit := Copy(FJsonS, FJsonPos, 4);
        if lit = 'true' then
        begin
          Inc(FJsonPos, 4);
          Exit(MakeBool(True));
        end;
        raise EXuiJsRuntime.Create('JSON 解析失败：非法字面量');
      end;
    'f':
      begin
        lit := Copy(FJsonS, FJsonPos, 5);
        if lit = 'false' then
        begin
          Inc(FJsonPos, 5);
          Exit(MakeBool(False));
        end;
        raise EXuiJsRuntime.Create('JSON 解析失败：非法字面量');
      end;
    'n':
      begin
        lit := Copy(FJsonS, FJsonPos, 4);
        if lit = 'null' then
        begin
          Inc(FJsonPos, 4);
          Exit(MakeNull);
        end;
        raise EXuiJsRuntime.Create('JSON 解析失败：非法字面量');
      end;
  else
    begin
      lit := '';
      while (FJsonPos <= System.Length(FJsonS)) and
            (FJsonS[FJsonPos] in ['-', '+', '0'..'9', '.', 'e', 'E']) do
      begin
        lit := lit + FJsonS[FJsonPos];
        Inc(FJsonPos);
      end;
      if lit = '' then
        raise EXuiJsRuntime.CreateFmt('JSON 解析失败：意外字符（位置 %d，字符 %s）', [FJsonPos, FJsonS[FJsonPos]]);
      Val(lit, numv, code);
      if code <> 0 then
        raise EXuiJsRuntime.Create('JSON 解析失败：非法数字');
      Exit(MakeNumber(numv));
    end;
  end;
end;
function TXuiJsInterp.JsonParseText(const S: string): TXuiJsValue;
begin
  FJsonS := S;
  FJsonPos := 1;
  Result := JsonParseValue;
  JsonSkipWs;
  if FJsonPos <= System.Length(FJsonS) then
    raise EXuiJsRuntime.Create('JSON 解析失败：末尾有多余内容');
end;
function TXuiJsInterp.NativeGlobalFn(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  s: string;
  d: Double;
  code: Integer;
  arr: TXuiJsArray;
  i: Integer;
begin
  if (AFn.Name = 'parseInt') or (AFn.Name = 'parseFloat') then
  begin
    s := Trim(ToStringValue(ArgAt(AArgs, 0)));
    if AFn.Name = 'parseInt' then
    begin
      // 截取整数前缀
      i := 1;
      while (i <= System.Length(s)) and
            ((s[i] >= '0') and (s[i] <= '9') or (i = 1) and ((s[i] = '-') or (s[i] = '+'))) do
        Inc(i);
      s := Copy(s, 1, i - 1);
      Val(s, d, code);
      if code <> 0 then
        Exit(MakeNumber(Nan));
      Exit(MakeNumber(Trunc(d)));
    end;
    Val(s, d, code);
    if code <> 0 then
      Exit(MakeNumber(Nan));
    Exit(MakeNumber(d));
  end;
  if AFn.Name = 'isNaN' then
    Exit(MakeBool(IsNan(ToNumberValue(ArgAt(AArgs, 0)))));
  if AFn.Name = 'isFinite' then
  begin
    d := ToNumberValue(ArgAt(AArgs, 0));
    Exit(MakeBool((not IsNan(d)) and (not IsInfinite(d))));
  end;
  if AFn.Name = 'String' then
    Exit(MakeString(ToStringValue(ArgAt(AArgs, 0))));
  if AFn.Name = 'Number' then
    Exit(MakeNumber(ToNumberValue(ArgAt(AArgs, 0))));
  if AFn.Name = 'Boolean' then
    Exit(MakeBool(ToBoolValue(ArgAt(AArgs, 0))));
  if AFn.Name = 'Array' then
  begin
    if (System.Length(AArgs) = 1) and (AArgs[0].Kind = jvNumber) then
    begin
      arr := NewArray;
      SetLength(arr.Items, Round(AArgs[0].Num));
      for i := 0 to arr.Length - 1 do
        arr.Items[i] := MakeUndefined;
      Exit(ArrayValue(arr));
    end;
    arr := NewArray;
    SetLength(arr.Items, System.Length(AArgs));
    for i := 0 to System.Length(AArgs) - 1 do
      arr.Items[i] := AArgs[i];
    Exit(ArrayValue(arr));
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeObjectStatics(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  obj: TXuiJsObject;
  keys: TXuiJsValueArray;
  arr: TXuiJsArray;
  i, k: Integer;
  src: TXuiJsValue;
begin
  if AFn.Name = 'isArray' then
    Exit(MakeBool((ArgAt(AArgs, 0).Kind = jvObject) and
      (ArgAt(AArgs, 0).Obj is TXuiJsArray)));
  if AFn.Name = 'freeze' then
    Exit(ArgAt(AArgs, 0));
  if (AFn.Name = 'keys') or (AFn.Name = 'values') or (AFn.Name = 'entries') then
  begin
    if ArgAt(AArgs, 0).Kind <> jvObject then
      Exit(EmptyArray);
    obj := ArgAt(AArgs, 0).Obj;
    keys := OwnKeys(obj);
    if AFn.Name = 'keys' then
      Exit(MakeArray(keys));
    arr := NewArray;
    for i := 0 to System.Length(keys) - 1 do
    begin
      if AFn.Name = 'values' then
        SetLength(arr.Items, arr.Length + 1)
      else
      begin
        SetLength(arr.Items, arr.Length + 1);
      end;
      if AFn.Name = 'values' then
        arr.Items[arr.Length - 1] := GetProp(ArgAt(AArgs, 0), keys[i].Str)
      else
        arr.Items[arr.Length - 1] := MakeArray([keys[i],
          GetProp(ArgAt(AArgs, 0), keys[i].Str)]);
    end;
    Exit(ArrayValue(arr));
  end;
  if AFn.Name = 'assign' then
  begin
    if ArgAt(AArgs, 0).Kind <> jvObject then
      Exit(ArgAt(AArgs, 0));
    for k := 1 to System.Length(AArgs) - 1 do
    begin
      src := AArgs[k];
      if src.Kind = jvObject then
      begin
        obj := src.Obj;
        for i := 0 to obj.Props.Count - 1 do
          SetProp(ArgAt(AArgs, 0), TXuiJsProp(obj.Props[i]).Name,
            TXuiJsProp(obj.Props[i]).Value);
      end;
    end;
    Exit(ArgAt(AArgs, 0));
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeStringProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  s: string;
  i, lo, hi: Integer;
  parts: TStringList;
begin
  s := ToStringValue(AThis);
  if AFn.Name = 'toString' then Exit(MakeString(s));
  if AFn.Name = 'charAt' then
    Exit(MakeString(JsStrCharAt(s, ArgInt(AArgs, 0))));
  if AFn.Name = 'indexOf' then
    Exit(MakeNumber(JsStrIndexOf(s, ToStringValue(ArgAt(AArgs, 0)),
      ArgInt(AArgs, 1))));
  if AFn.Name = 'lastIndexOf' then
  begin
    Result := MakeNumber(-1);
    for i := JsStrLength(s) - 1 downto 0 do
      if JsStrSlice(s, i, i + System.Length(ToStringValue(ArgAt(AArgs, 0)))) =
         ToStringValue(ArgAt(AArgs, 0)) then
        Exit(MakeNumber(i));
    Exit;
  end;
  if AFn.Name = 'slice' then
  begin
    if System.Length(AArgs) < 2 then
      hi := JsStrLength(s)
    else
      hi := ArgInt(AArgs, 1);
    JsStrSliceRange(s, ArgInt(AArgs, 0), hi, lo, hi);
    Exit(MakeString(JsStrSlice(s, lo, hi)));
  end;
  if AFn.Name = 'substring' then
  begin
    lo := ArgInt(AArgs, 0);
    if System.Length(AArgs) < 2 then
      hi := JsStrLength(s)
    else
      hi := ArgInt(AArgs, 1);
    if lo < 0 then lo := 0;
    if hi < 0 then hi := 0;
    if lo > hi then
    begin
      i := lo; lo := hi; hi := i;
    end;
    if hi > JsStrLength(s) then hi := JsStrLength(s);
    Exit(MakeString(JsStrSlice(s, lo, hi)));
  end;
  if AFn.Name = 'toUpperCase' then Exit(MakeString(UpperCase(s)));
  if AFn.Name = 'toLowerCase' then Exit(MakeString(LowerCase(s)));
  if AFn.Name = 'trim' then Exit(MakeString(Trim(s)));
  if AFn.Name = 'includes' then
    Exit(MakeBool(JsStrIndexOf(s, ToStringValue(ArgAt(AArgs, 0)),
      ArgInt(AArgs, 1)) >= 0));
  if AFn.Name = 'startsWith' then
  begin
    i := ArgInt(AArgs, 1);
    Exit(MakeBool(JsStrSlice(s, i, i + JsStrLength(ToStringValue(ArgAt(AArgs, 0)))) =
      ToStringValue(ArgAt(AArgs, 0))));
  end;
  if AFn.Name = 'endsWith' then
  begin
    Result := MakeBool(JsStrSlice(s, JsStrLength(s) - JsStrLength(ToStringValue(ArgAt(AArgs, 0))),
      JsStrLength(s)) = ToStringValue(ArgAt(AArgs, 0)));
    Exit;
  end;
  if AFn.Name = 'repeat' then
  begin
    Result := MakeString('');
    for i := 1 to ArgInt(AArgs, 0) do
      Result.Str := Result.Str + s;
    Exit(Result);
  end;
  if AFn.Name = 'concat' then
  begin
    Result := MakeString(s);
    for i := 0 to System.Length(AArgs) - 1 do
      Result.Str := Result.Str + ToStringValue(AArgs[i]);
    Exit(Result);
  end;
  if AFn.Name = 'replace' then
  begin
    i := JsStrIndexOf(s, ToStringValue(ArgAt(AArgs, 0)), 0);
    if i < 0 then
      Exit(MakeString(s));
    Exit(MakeString(JsStrSlice(s, 0, i) + ToStringValue(ArgAt(AArgs, 1)) +
      JsStrSlice(s, i + JsStrLength(ToStringValue(ArgAt(AArgs, 0))), JsStrLength(s))));
  end;
  if AFn.Name = 'split' then
  begin
    parts := TStringList.Create;
    try
      if System.Length(AArgs) = 0 then
        parts.Add(s)
      else
      begin
        // 按分隔符切分（支持空分隔符 → 逐码点）
        if ToStringValue(AArgs[0]) = '' then
        begin
          for i := 0 to JsStrLength(s) - 1 do
            parts.Add(JsStrCharAt(s, i));
        end
        else
        begin
          // 简化的分隔切分
          parts.Delimiter := #1;
          parts.StrictDelimiter := True;
          parts.DelimitedText := StringReplace(s, ToStringValue(AArgs[0]), #1, [rfReplaceAll]);
        end;
      end;
      Result := EmptyArray;
      SetLength(TXuiJsArray(Result.Obj).Items, parts.Count);
      for i := 0 to parts.Count - 1 do
        TXuiJsArray(Result.Obj).Items[i] := MakeString(parts[i]);
      Exit;
    finally
      parts.Free;
    end;
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeArrayProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  arr: TXuiJsArray;
  i, j, n, lo, hi: Integer;
  outArr: TXuiJsArray;
  acc, cur: TXuiJsValue;
  hasCmp, less, hit: Boolean;
begin
  if (AThis.Kind <> jvObject) or (not (AThis.Obj is TXuiJsArray)) then
    raise EXuiJsRuntime.Create('数组方法调用者不是数组');
  arr := TXuiJsArray(AThis.Obj);
  if AFn.Name = 'push' then
  begin
    for i := 0 to System.Length(AArgs) - 1 do
    begin
      SetLength(arr.Items, arr.Length + 1);
      arr.Items[arr.Length - 1] := AArgs[i];
    end;
    NotifyArrayWrite(arr);
    Exit(MakeNumber(arr.Length));
  end;
  if AFn.Name = 'pop' then
  begin
    if arr.Length = 0 then
      Exit(MakeUndefined);
    Result := arr.Items[arr.Length - 1];
    SetLength(arr.Items, arr.Length - 1);
    NotifyArrayWrite(arr);
    Exit;
  end;
  if AFn.Name = 'shift' then
  begin
    if arr.Length = 0 then
      Exit(MakeUndefined);
    Result := arr.Items[0];
    for i := 1 to arr.Length - 1 do
      arr.Items[i - 1] := arr.Items[i];
    SetLength(arr.Items, arr.Length - 1);
    NotifyArrayWrite(arr);
    Exit;
  end;
  if AFn.Name = 'unshift' then
  begin
    n := System.Length(AArgs);
    SetLength(arr.Items, arr.Length + n);
    for i := arr.Length - 1 downto n do
      arr.Items[i] := arr.Items[i - n];
    for i := 0 to n - 1 do
      arr.Items[i] := AArgs[i];
    NotifyArrayWrite(arr);
    Exit(MakeNumber(arr.Length));
  end;
  if AFn.Name = 'slice' then
  begin
    JsStrSliceRange('', 0, 0, lo, hi);   // 占位（数组切片用整数区间）
    lo := ArgInt(AArgs, 0);
    if System.Length(AArgs) < 2 then
      hi := arr.Length
    else
      hi := ArgInt(AArgs, 1);
    if lo < 0 then lo := arr.Length + lo;
    if hi < 0 then hi := arr.Length + hi;
    if lo < 0 then lo := 0;
    if hi > arr.Length then hi := arr.Length;
    outArr := NewArray;
    for i := lo to hi - 1 do
    begin
      SetLength(outArr.Items, outArr.Length + 1);
      outArr.Items[outArr.Length - 1] := arr.Items[i];
    end;
    Exit(ArrayValue(outArr));
  end;
  if AFn.Name = 'splice' then
  begin
    lo := ArgInt(AArgs, 0);
    if lo < 0 then lo := arr.Length + lo;
    if lo < 0 then lo := 0;
    if lo > arr.Length then lo := arr.Length;
    if System.Length(AArgs) < 2 then
      hi := arr.Length
    else
      hi := lo + ArgInt(AArgs, 1);
    if hi > arr.Length then hi := arr.Length;
    outArr := NewArray;
    for i := lo to hi - 1 do
    begin
      SetLength(outArr.Items, outArr.Length + 1);
      outArr.Items[outArr.Length - 1] := arr.Items[i];
    end;
    // 删除 [lo, hi) 并插入 AArgs[2..]
    n := System.Length(AArgs) - 2;
    if n < 0 then n := 0;
    if hi - lo <> n then
    begin
      if n < hi - lo then
      begin
        for i := hi to arr.Length - 1 do
          arr.Items[i - (hi - lo) + n] := arr.Items[i];
        SetLength(arr.Items, arr.Length - (hi - lo) + n);
      end
      else
      begin
        SetLength(arr.Items, arr.Length + (n - (hi - lo)));
        for i := arr.Length - 1 downto hi do
          arr.Items[i + (n - (hi - lo))] := arr.Items[i];
      end;
    end;
    for i := 0 to n - 1 do
      arr.Items[lo + i] := AArgs[2 + i];
    NotifyArrayWrite(arr);
    Exit(ArrayValue(outArr));
  end;
  if AFn.Name = 'indexOf' then
  begin
    n := ArgInt(AArgs, 1);
    for i := n to arr.Length - 1 do
      if StrictEquals(arr.Items[i], ArgAt(AArgs, 0)) then
        Exit(MakeNumber(i));
    Exit(MakeNumber(-1));
  end;
  if AFn.Name = 'includes' then
  begin
    for i := 0 to arr.Length - 1 do
      if StrictEquals(arr.Items[i], ArgAt(AArgs, 0)) then
        Exit(MakeBool(True));
    Exit(MakeBool(False));
  end;
  if AFn.Name = 'join' then
  begin
    Result := MakeString('');
    for i := 0 to arr.Length - 1 do
    begin
      if i > 0 then
        Result.Str := Result.Str + ToStringValue(ArgAt(AArgs, 0));
      if not IsNullish(arr.Items[i]) then
        Result.Str := Result.Str + ToStringValue(arr.Items[i]);
    end;
    Exit;
  end;
  if AFn.Name = 'reverse' then
  begin
    for i := 0 to (arr.Length div 2) - 1 do
    begin
      acc := arr.Items[i];
      arr.Items[i] := arr.Items[arr.Length - 1 - i];
      arr.Items[arr.Length - 1 - i] := acc;
    end;
    NotifyArrayWrite(arr);
    Exit(AThis);
  end;
  if AFn.Name = 'concat' then
  begin
    outArr := NewArray;
    for i := 0 to arr.Length - 1 do
    begin
      SetLength(outArr.Items, outArr.Length + 1);
      outArr.Items[outArr.Length - 1] := arr.Items[i];
    end;
    for i := 0 to System.Length(AArgs) - 1 do
      if (AArgs[i].Kind = jvObject) and (AArgs[i].Obj is TXuiJsArray) then
      begin
        for n := 0 to TXuiJsArray(AArgs[i].Obj).Length - 1 do
        begin
          SetLength(outArr.Items, outArr.Length + 1);
          outArr.Items[outArr.Length - 1] := TXuiJsArray(AArgs[i].Obj).Items[n];
        end;
      end
      else
      begin
        SetLength(outArr.Items, outArr.Length + 1);
        outArr.Items[outArr.Length - 1] := AArgs[i];
      end;
    Exit(ArrayValue(outArr));
  end;
  if AFn.Name = 'forEach' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('forEach 需要函数参数');
    for i := 0 to arr.Length - 1 do
      CallFunction(AArgs[0], MakeUndefined,
        [arr.Items[i], MakeNumber(i), AThis]);
    Exit(MakeUndefined);
  end;
  if AFn.Name = 'map' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('map 需要函数参数');
    outArr := NewArray;
    for i := 0 to arr.Length - 1 do
    begin
      SetLength(outArr.Items, outArr.Length + 1);
      outArr.Items[outArr.Length - 1] :=
        CallFunction(AArgs[0], MakeUndefined, [arr.Items[i], MakeNumber(i), AThis]);
    end;
    Exit(ArrayValue(outArr));
  end;
  if AFn.Name = 'filter' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('filter 需要函数参数');
    outArr := NewArray;
    for i := 0 to arr.Length - 1 do
      if IsTruthy(CallFunction(AArgs[0], MakeUndefined,
        [arr.Items[i], MakeNumber(i), AThis])) then
      begin
        SetLength(outArr.Items, outArr.Length + 1);
        outArr.Items[outArr.Length - 1] := arr.Items[i];
      end;
    Exit(ArrayValue(outArr));
  end;
  if AFn.Name = 'reduce' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('reduce 需要函数参数');
    if System.Length(AArgs) >= 2 then
    begin
      acc := AArgs[1];
      i := 0;
    end
    else
    begin
      acc := arr.Items[0];
      i := 1;
    end;
    while i < arr.Length do
    begin
      acc := CallFunction(AArgs[0], MakeUndefined,
        [acc, arr.Items[i], MakeNumber(i), AThis]);
      Inc(i);
    end;
    Exit(acc);
  end;
  if AFn.Name = 'find' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('find 需要函数参数');
    for i := 0 to arr.Length - 1 do
      if IsTruthy(CallFunction(AArgs[0], MakeUndefined,
        [arr.Items[i], MakeNumber(i), AThis])) then
        Exit(arr.Items[i]);
    Exit(MakeUndefined);
  end;
  if AFn.Name = 'findIndex' then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create('findIndex 需要函数参数');
    for i := 0 to arr.Length - 1 do
      if IsTruthy(CallFunction(AArgs[0], MakeUndefined,
        [arr.Items[i], MakeNumber(i), AThis])) then
        Exit(MakeNumber(i));
    Exit(MakeNumber(-1));
  end;
  if (AFn.Name = 'some') or (AFn.Name = 'every') then
  begin
    if not IsCallable(ArgAt(AArgs, 0)) then
      raise EXuiJsRuntime.Create(AFn.Name + ' 需要函数参数');
    for i := 0 to arr.Length - 1 do
    begin
      hit := IsTruthy(CallFunction(AArgs[0], MakeUndefined,
        [arr.Items[i], MakeNumber(i), AThis]));
      // some：命中即真；every：不命中即假。空数组上 some=false / every=true（与 JS 一致）
      if (AFn.Name = 'some') and hit then
        Exit(MakeBool(True));
      if (AFn.Name = 'every') and (not hit) then
        Exit(MakeBool(False));
    end;
    Exit(MakeBool(AFn.Name = 'every'));
  end;
  if AFn.Name = 'sort' then
  begin
    // 原地排序（与 JS 一致）。无比较函数时按字符串比较——JS 的默认行为就是这样，
    // 所以 [10,9].sort() 得 [10,9]；要数值序必须传比较函数。
    // 用插入排序：稳定、无额外分配、代码短；UI 规模的数据（几十到几千）足够。
    hasCmp := System.Length(AArgs) >= 1;
    if hasCmp and (not IsCallable(ArgAt(AArgs, 0))) then
      raise EXuiJsRuntime.Create('sort 的比较参数必须是函数');
    for i := 1 to arr.Length - 1 do
    begin
      cur := arr.Items[i];
      j := i - 1;
      while j >= 0 do
      begin
        if hasCmp then
          less := ToNumberValue(CallFunction(AArgs[0], MakeUndefined,
            [cur, arr.Items[j]])) < 0
        else
          less := ToStringValue(cur) < ToStringValue(arr.Items[j]);
        if not less then
          Break;
        arr.Items[j + 1] := arr.Items[j];
        Dec(j);
      end;
      arr.Items[j + 1] := cur;
    end;
    NotifyArrayWrite(arr);
    Exit(AThis);
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeNumberProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  fs: TFormatSettings;
begin
  if AFn.Name = 'toString' then
    Exit(MakeString(ToStringValue(AThis)));
  if AFn.Name = 'toFixed' then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    Exit(MakeString(FloatToStrF(ToNumberValue(AThis), ffFixed, 15,
      ArgInt(AArgs, 0), fs)));
  end;
  Result := MakeUndefined;
end;
function TXuiJsInterp.NativeFunctionProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  args: TXuiJsValueArray;
  arr: TXuiJsArray;
  i: Integer;
  thisArg: TXuiJsValue;
begin
  thisArg := ArgAt(AArgs, 0);
  if AFn.Name = 'call' then
  begin
    SetLength(args, System.Length(AArgs) - 1);
    for i := 1 to System.Length(AArgs) - 1 do
      args[i - 1] := AArgs[i];
    Exit(CallFunction(AThis, thisArg, args));
  end;
  if AFn.Name = 'apply' then
  begin
    SetLength(args, 0);
    if (ArgAt(AArgs, 1).Kind = jvObject) and (ArgAt(AArgs, 1).Obj is TXuiJsArray) then
    begin
      arr := TXuiJsArray(ArgAt(AArgs, 1).Obj);
      SetLength(args, arr.Length);
      for i := 0 to arr.Length - 1 do
        args[i] := arr.Items[i];
    end;
    Exit(CallFunction(AThis, thisArg, args));
  end;
  Result := MakeUndefined;
end;
{ ---- Promise 内建（P1）---- }
// new Promise(executor)：executor 同步执行，收到 resolve/reject 控制函数；
// executor 抛错且 promise 仍 pending → reject
function TXuiJsInterp.NativePromise(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  p: TXuiJsPromise;
  executor: TXuiJsValue;
  res, rej: TXuiJsFunction;
begin
  executor := ArgAt(AArgs, 0);
  if not IsCallable(executor) then
    raise EXuiJsRuntime.Create('Promise 的参数必须是执行器函数');
  p := NewPromise;
  res := NewFunction;
  res.Name := 'resolve';
  res.Native := @NativePromiseCtl;
  res.Tag := p;
  rej := NewFunction;
  rej.Name := 'reject';
  rej.Native := @NativePromiseCtl;
  rej.Tag := p;
  try
    CallFunction(executor, MakeUndefined, [FunctionValue(res), FunctionValue(rej)]);
  except
    on E: EXuiJsThrow do
      PromiseReject(p, E.Value);
    on E: Exception do
      PromiseReject(p, MakeString(E.Message));
  end;
  Result := ObjectValue(p);
end;
// executor 的 resolve/reject 控制函数（经 Tag 找到目标 promise）
function TXuiJsInterp.NativePromiseCtl(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
begin
  if not (AFn.Tag is TXuiJsPromise) then
    raise EXuiJsRuntime.Create('Promise 控制函数状态无效');
  if AFn.Name = 'resolve' then
    PromiseResolve(TXuiJsPromise(AFn.Tag), ArgAt(AArgs, 0))
  else
    PromiseReject(TXuiJsPromise(AFn.Tag), ArgAt(AArgs, 0));
  Result := MakeUndefined;
end;
// 原型方法 then / catch / finally（返回下游 Promise）
function TXuiJsInterp.NativePromiseProto(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  p, down: TXuiJsPromise;
begin
  if (AThis.Kind <> jvObject) or (not (AThis.Obj is TXuiJsPromise)) then
    raise EXuiJsRuntime.CreateFmt('%s 的调用者必须是 Promise', [AFn.Name]);
  p := TXuiJsPromise(AThis.Obj);
  down := NewPromise;
  if AFn.Name = 'then' then
    PromiseAddReaction(p, rkThen, ArgAt(AArgs, 0), ArgAt(AArgs, 1), down, nil, 0)
  else if AFn.Name = 'catch' then
    PromiseAddReaction(p, rkThen, MakeUndefined, ArgAt(AArgs, 0), down, nil, 0)
  else
    PromiseAddReaction(p, rkFinally, ArgAt(AArgs, 0), MakeUndefined, down, nil, 0);
  Result := ObjectValue(down);
end;
// 静态方法 resolve / reject / all / allSettled / race
function TXuiJsInterp.NativePromiseStatics(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  p, down: TXuiJsPromise;
  agg: TXuiJsAggregate;
  src: TXuiJsValue;
  arr: TXuiJsArray;
  i: Integer;
  kind: TXuiJsReactionKind;
  r: TXuiJsReaction;
begin
  if AFn.Name = 'resolve' then
  begin
    src := ArgAt(AArgs, 0);
    if IsPromise(src) then
      Exit(src);   // 原生 promise 原样返回
    p := NewPromise;
    PromiseResolve(p, src);
    Exit(ObjectValue(p));
  end;
  if AFn.Name = 'reject' then
  begin
    p := NewPromise;
    PromiseReject(p, ArgAt(AArgs, 0));
    Exit(ObjectValue(p));
  end;
  // all / allSettled / race：v1 参数简化为数组
  if not ((ArgAt(AArgs, 0).Kind = jvObject) and
          (ArgAt(AArgs, 0).Obj is TXuiJsArray)) then
    raise EXuiJsRuntime.CreateFmt('Promise.%s 的参数必须是数组', [AFn.Name]);
  arr := TXuiJsArray(ArgAt(AArgs, 0).Obj);
  down := NewPromise;
  if AFn.Name = 'race' then
  begin
    // 先到先得；非 promise 值按 FIFO 立即入队（首个任务生效）
    for i := 0 to arr.Length - 1 do
    begin
      src := arr.Items[i];
      if IsPromise(src) then
        PromiseAddReaction(TXuiJsPromise(src.Obj), rkRace,
          MakeUndefined, MakeUndefined, down, nil, 0)
      else
      begin
        r := TXuiJsReaction.Create;
        r.Kind := rkRace;
        r.Downstream := down;
        EnqueueReactionJob(r, True, src);
        r.Free;
      end;
    end;
    Exit(ObjectValue(down));
  end;
  // all / allSettled：聚合收集（结果按下标写回，全部到达即完成）
  if AFn.Name = 'all' then
    kind := rkAll
  else
    kind := rkAllSettled;
  agg := TXuiJsAggregate.Create;
  agg.Downstream := down;
  agg.Results := NewArray;
  SetLength(agg.Results.Items, arr.Length);
  agg.PendingJobs := 0;
  for i := 0 to arr.Length - 1 do
  begin
    src := arr.Items[i];
    if IsPromise(src) then
    begin
      Inc(agg.PendingJobs);
      PromiseAddReaction(TXuiJsPromise(src.Obj), kind,
        MakeUndefined, MakeUndefined, down, agg, i);
    end
    else
      agg.Results.Items[i] := src;
  end;
  FAggregates.Add(agg);
  if agg.PendingJobs = 0 then
  begin
    // 全为普通值（含空数组）：直接完成
    PromiseResolve(down, ObjectValue(agg.Results));
    CleanupAggregates;
  end;
  Result := ObjectValue(down);
end;
{ ---- async/await 机器（P3，ADR 16）----
  帧栈按"节点种类 × 相位"推进；每相一停。子操作数：
  - 不含 await（nfHasAwait 未置位）→ 委托既有递归求值器同步算完（快路径）
  - 含 await → 压入子帧（慢路径），完成时交付回父帧槽位
  遇 nkAwait：把被等待值注册为"恢复本机器"的微任务 → 机器挂起，切片退出。
  脚本异常由 RunMachine 捕获并展开帧栈：找最近仍在本保护范围内的 try 帧（catch/finally），
  无 handler 时 reject async promise。async 函数同步执行到首个 await，返回其 promise。 }
procedure TXuiJsInterp.PushFrame(M: TObject; ANode: TXuiJsNode;
  ARole: TXuiJsFrameRole; AEnv: TXuiJsEnv; AParent: TXuiJsFrame; ASlot: Integer);
var
  f: TXuiJsFrame;
begin
  f := TXuiJsFrame.Create;
  f.Machine := M;
  f.Node := ANode;
  f.Role := ARole;
  f.Env := AEnv;
  f.EnvNow := AEnv;
  f.Parent := AParent;
  f.Slot := ASlot;
  f.DeliverFlow := (ARole = frStmt);
  TXuiJsAsyncMachine(M).Frames.Add(f);
end;
procedure TXuiJsInterp.SetSlot(F: TXuiJsFrame; ASlot: Integer;
  const AValue: TXuiJsValue);
begin
  if ASlot >= System.Length(F.Values) then
    SetLength(F.Values, ASlot + 1);
  F.Values[ASlot] := AValue;
end;
// 求值子表达式：无 await 走快路径，有 await 压子帧
procedure TXuiJsInterp.NeedChildValue(F: TXuiJsFrame; ASlot: Integer;
  AChild: TXuiJsNode);
begin
  F.Waiting := False;
  if (AChild <> nil) and (nfHasAwait in AChild.Flags) then
  begin
    PushFrame(F.Machine, AChild, frExpr, F.EnvNow, F, ASlot);
    F.Waiting := True;
  end
  else
    SetSlot(F, ASlot, EvalExpr(AChild, F.EnvNow));
end;
// 执行子语句：无 await 走 ExecStmt 快路径（flow 写入 ChildFlow），有 await 压子帧
procedure TXuiJsInterp.NeedChildStmt(F: TXuiJsFrame; ASlot: Integer;
  AChild: TXuiJsNode);
var
  v: TXuiJsValue;
  flow: Integer;
begin
  F.Waiting := False;
  if (AChild <> nil) and (nfHasAwait in AChild.Flags) then
  begin
    PushFrame(F.Machine, AChild, frStmt, F.EnvNow, F, ASlot);
    F.Waiting := True;
  end
  else
  begin
    v := ExecStmt(AChild, F.EnvNow, flow);
    SetSlot(F, ASlot, v);
    F.ChildFlow := flow;
  end;
end;
procedure TXuiJsInterp.FinishFrame(F: TXuiJsFrame; const AValue: TXuiJsValue;
  AFlow: Integer);
begin
  F.Done := True;
  F.Value := AValue;
  F.Flow := AFlow;
end;
// async 函数调用：建机器同步跑到首个 await（或完成），立即返回 promise
function TXuiJsInterp.CallAsyncFunction(AFn: TXuiJsFunction; AThis: TXuiJsValue;
  const AArgs: TXuiJsValueArray): TXuiJsValue;
var
  env: TXuiJsEnv;
  p: TXuiJsPromise;
  M: TXuiJsAsyncMachine;
begin
  p := NewPromise;
  M := TXuiJsAsyncMachine.Create;
  M.Promise := p;
  if AFn.Body = nil then
  begin
    PromiseResolve(p, MakeUndefined);
    M.Free;
    Exit(ObjectValue(p));
  end;
  env := NewEnv(AFn.Closure);
  env.IsFunctionScope := True;
  env.Func := AFn;
  if not AFn.IsArrow then
  begin
    env.HasThis := True;
    env.ThisValue := AThis;
  end;
  env.HomeObject := AFn.HomeObject;
  BindParams(AFn, env, AArgs);
  if AFn.Body.Kind = nkBlock then
    PushFrame(M, AFn.Body, frStmt, env, nil, 0)
  else
    PushFrame(M, AFn.Body, frExpr, env, nil, 0);   // async 箭头单表达式体
  FAsyncCalls.Add(M);
  RunMachine(M);   // 挂起或完成；脚本异常在机器内转成 promise 拒绝
  Result := ObjectValue(p);
end;
// 机器完成：settle promise 并摘除（M 在此释放，调用方不得再触碰）
procedure TXuiJsInterp.CompleteMachine(M: TObject; ARejected: Boolean;
  const AValue: TXuiJsValue);
var
  mach: TXuiJsAsyncMachine;
begin
  mach := TXuiJsAsyncMachine(M);
  mach.Done := True;
  if ARejected then
    PromiseReject(mach.Promise, AValue)
  else
    PromiseResolve(mach.Promise, AValue);
  FAsyncCalls.Extract(mach);
  mach.Free;
end;
// 主循环：推进栈顶帧直至 挂起 / 完成。返回 True = 机器已结束。
function TXuiJsInterp.RunMachine(M: TObject): Boolean;
var
  mach: TXuiJsAsyncMachine;
  top, parent: TXuiJsFrame;
  doneValue: TXuiJsValue;
begin
  Result := False;
  mach := TXuiJsAsyncMachine(M);
  mach.Suspended := False;
  while mach.Frames.Count > 0 do
  begin
    top := TXuiJsFrame(mach.Frames[mach.Frames.Count - 1]);
    try
      StepFrame(M, top);
    except
      on E: EXuiJsThrow do
      begin
        if UnwindMachine(M, E.Value) then
          Exit(True);
        Continue;
      end;
      on E: EXuiJsRuntime do
      begin
        if UnwindMachine(M, MakeString(E.Message)) then
          Exit(True);
        Continue;
      end;
    end;
    if mach.Suspended then
      Exit(False);
    if top.Done then
    begin
      parent := top.Parent;
      if parent = nil then
      begin
        // 栈底帧完成：async 调用结束（取值须在释放帧之前）
        doneValue := top.Value;
        mach.Frames.Extract(top);
        top.Free;
        CompleteMachine(M, False, doneValue);
        Result := True;
        Exit;
      end;
      parent.Waiting := False;
      SetSlot(parent, top.Slot, top.Value);
      if top.DeliverFlow then
        parent.ChildFlow := top.Flow;
      mach.Frames.Extract(top);
      top.Free;
    end;
    // 未完成且未挂起：StepFrame 只推进一步，继续循环
  end;
  Result := True;
end;
// 异常展开：自栈顶向下找仍在本保护范围内的 try 帧。返回 True = 机器已结束（拒绝）。
function TXuiJsInterp.UnwindMachine(M: TObject; const AThrown: TXuiJsValue): Boolean;
var
  mach: TXuiJsAsyncMachine;
  f: TXuiJsFrame;
  env: TXuiJsEnv;
begin
  Result := False;
  mach := TXuiJsAsyncMachine(M);
  while mach.Frames.Count > 0 do
  begin
    f := TXuiJsFrame(mach.Frames[mach.Frames.Count - 1]);
    if f.Node.Kind = nkTry then
    begin
      case f.TryMode of
        0:  // try 块内抛出：有 catch 进 catch；否则若有 finally 先跑 finally 再重抛
            if f.Node.C <> nil then
            begin
              f.TryMode := 1;
              env := NewEnv(f.EnvNow);
              f.EnvNow := env;
              BindPattern(f.Node.A, AThrown, env, True);
              f.Phase := 4;   // 进入 catch 块
              Exit;
            end
            else if f.Node.ItemCount > 0 then
            begin
              f.TryMode := 2;
              f.HasThrown := True;
              f.ThrownValue := AThrown;
              f.Phase := 2;   // 进入 finally 块
              Exit;
            end;
        1:  // catch 块内抛出：有 finally 先跑 finally 再重抛
            if f.Node.ItemCount > 0 then
            begin
              f.TryMode := 2;
              f.HasThrown := True;
              f.ThrownValue := AThrown;
              f.Phase := 2;
              Exit;
            end;
        2:  // finally 块自身抛出：向外传播（原待重抛被覆盖）
            f.TryMode := 3;
      end;
    end;
    mach.Frames.Extract(f);
    f.Free;
  end;
  // 无人处理：reject async promise
  CompleteMachine(M, True, AThrown);
  Result := True;
end;
// await 恢复（微任务内调用）：把 settle 结果交回机器继续跑
procedure TXuiJsInterp.ResumeMachine(M: TObject; AOk: Boolean;
  const AValue: TXuiJsValue);
var
  mach: TXuiJsAsyncMachine;
  top: TXuiJsFrame;
begin
  mach := TXuiJsAsyncMachine(M);
  if mach.Done or (mach.Frames.Count = 0) then
    Exit;
  mach.Suspended := False;
  top := TXuiJsFrame(mach.Frames[mach.Frames.Count - 1]);
  if AOk then
  begin
    SetSlot(top, 0, AValue);
    top.Phase := 2;   // nkAwait 帧恢复相位
    top.Waiting := False;
  end
  else if UnwindMachine(M, AValue) then
    Exit;
  RunMachine(M);
end;
// 抛出脚本值（throw 语句帧 / finally 重抛用）
procedure ThrowScriptValue(const AValue: TXuiJsValue);
var
  e: EXuiJsThrow;
begin
  e := EXuiJsThrow.Create('未处理的脚本异常');
  e.Value := AValue;
  raise e;
end;
// 赋值目标写（与 EvalExpr 内嵌 WriteRef 逻辑一致）
procedure TXuiJsInterp.WriteRefTo(ATarget: TXuiJsNode; const AValue: TXuiJsValue;
  AEnv: TXuiJsEnv);
begin
  if ATarget = nil then
    raise EXuiJsRuntime.Create('赋值目标无效');
  if ATarget.Kind = nkIdent then
    AEnv.Assign(ATarget.Name, AValue)
  else if ATarget.Kind = nkMember then
  begin
    if nfComputed in ATarget.Flags then
      SetProp(EvalExpr(ATarget.A, AEnv), PropNameOf(EvalExpr(ATarget.B, AEnv)), AValue)
    else
      SetProp(EvalExpr(ATarget.A, AEnv), ATarget.Name, AValue);
  end
  else if (ATarget.Kind = nkArrayPat) or (ATarget.Kind = nkObjectPat) then
    BindPattern(ATarget, AValue, AEnv, False)
  else
    raise EXuiJsRuntime.Create('赋值目标无效');
end;
// 赋值目标读（与 EvalExpr 内嵌 ReadRef 逻辑一致）
function TXuiJsInterp.ReadRefOf(ATarget: TXuiJsNode; AEnv: TXuiJsEnv): TXuiJsValue;
begin
  if ATarget = nil then
    Exit(MakeUndefined);
  if ATarget.Kind = nkIdent then
  begin
    if not AEnv.Lookup(ATarget.Name, Result) then
      Result := FGlobal.GetOwn(ATarget.Name);
  end
  else if ATarget.Kind = nkMember then
  begin
    if nfComputed in ATarget.Flags then
      Result := GetProp(EvalExpr(ATarget.A, AEnv), PropNameOf(EvalExpr(ATarget.B, AEnv)))
    else
      Result := GetProp(EvalExpr(ATarget.A, AEnv), ATarget.Name);
  end
  else
    Result := MakeUndefined;
end;
{ TXuiJsInterp.StepFrame —— 按节点种类 × 相位推进一相 }
procedure TXuiJsInterp.StepFrame(M: TObject; F: TXuiJsFrame);
  procedure AddArg(const AVal: TXuiJsValue);
  var
    n: Integer;
  begin
    n := System.Length(F.ArgsAcc);
    SetLength(F.ArgsAcc, n + 1);
    F.ArgsAcc[n] := AVal;
  end;
var
  node, lnk, part, decl: TXuiJsNode;
  v: TXuiJsValue;
  arr: TXuiJsArray;
  task: TXuiJsMicroTask;
  i: Integer;
begin
  case F.Node.Kind of
    // ---- await：挂起 / 恢复 ----
    nkAwait:
      case F.Phase of
        0:
          begin
            F.Phase := 1;
            NeedChildValue(F, 0, F.Node.A);
          end;
        1:
          begin
            v := F.Values[0];
            if IsPromise(v) then
              // 反应项在 settle 时拷贝为恢复任务（回调保证异步）
              PromiseAddReaction(TXuiJsPromise(v.Obj), rkResume,
                MakeUndefined, MakeUndefined, nil, M, 0)
            else
            begin
              // 非 promise 值：直接排入微任务（等价 await Promise.resolve(v) 的延迟语义）
              task := TXuiJsMicroTask.Create;
              task.Kind := rkResume;
              task.SrcFulfilled := True;
              task.SrcValue := v;
              task.Aggregate := M;
              FMicroTasks.Add(task);
            end;
            TXuiJsAsyncMachine(M).Suspended := True;
            F.Phase := 2;
          end;
        2:
          FinishFrame(F, F.Values[0], JsFlowNormal);
      end;
    // ---- 表达式 ----
    nkBinary:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1: begin F.Phase := 2; NeedChildValue(F, 1, F.Node.B); end;
        2: FinishFrame(F, EvalBinaryOp(F.Node.Op, F.Values[0], F.Values[1]), JsFlowNormal);
      end;
    nkLogical:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1:
          begin
            v := F.Values[0];
            if ((F.Node.Op = '&&') and (not IsTruthy(v))) or
               ((F.Node.Op = '||') and IsTruthy(v)) or
               ((F.Node.Op = '??') and (not IsNullish(v))) then
              FinishFrame(F, v, JsFlowNormal)
            else
            begin
              F.Phase := 2;
              NeedChildValue(F, 1, F.Node.B);
            end;
          end;
        2: FinishFrame(F, F.Values[1], JsFlowNormal);
      end;
    nkCond:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1:
          if IsTruthy(F.Values[0]) and (F.Node.B <> nil) then
          begin
            F.Phase := 2;
            NeedChildValue(F, 1, F.Node.B);
          end
          else if (not IsTruthy(F.Values[0])) and (F.Node.C <> nil) then
          begin
            F.Phase := 2;
            NeedChildValue(F, 1, F.Node.C);
          end
          else
            FinishFrame(F, MakeUndefined, JsFlowNormal);
        2: FinishFrame(F, F.Values[1], JsFlowNormal);
      end;
    nkAssign:
      case F.Phase of
        0:
          if F.Node.Op = '=' then
          begin
            // 目标成员链含 await：先求目标基/键，再求值
            if (nfHasAwait in F.Node.A.Flags) and (F.Node.A.Kind = nkMember) then
            begin
              if nfComputed in F.Node.A.Flags then
                F.Sub := 1
              else
                F.Sub := 2;
              F.Phase := 1;
              NeedChildValue(F, 1, F.Node.A.A);
            end
            else
            begin
              F.Sub := 0;
              F.Phase := 3;
              NeedChildValue(F, 0, F.Node.B);
            end;
          end
          else if (F.Node.Op = '&&=') or (F.Node.Op = '||=') or (F.Node.Op = '??=') then
          begin
            if nfHasAwait in F.Node.A.Flags then
              raise EXuiJsRuntime.Create('暂不支持：await 出现在复合赋值目标中');
            F.Sub := 3;
            SetSlot(F, 0, ReadRefOf(F.Node.A, F.EnvNow));
            F.Phase := 1;
          end
          else
          begin
            if nfHasAwait in F.Node.A.Flags then
              raise EXuiJsRuntime.Create('暂不支持：await 出现在复合赋值目标中');
            SetSlot(F, 0, ReadRefOf(F.Node.A, F.EnvNow));
            F.Phase := 2;
            NeedChildValue(F, 1, F.Node.B);
          end;
        1:
          if F.Sub = 1 then   // = ：目标基就绪，接着求计算键
          begin
            F.Phase := 2;
            NeedChildValue(F, 2, F.Node.A.B);
          end
          else if F.Sub = 2 then   // = ：命名成员目标基就绪，直接求值
          begin
            F.Phase := 3;
            NeedChildValue(F, 0, F.Node.B);
          end
          else                // 逻辑复合赋值：短路判定
          begin
            v := F.Values[0];
            if ((F.Node.Op = '&&=') and (not IsTruthy(v))) or
               ((F.Node.Op = '||=') and IsTruthy(v)) or
               ((F.Node.Op = '??=') and (not IsNullish(v))) then
            begin
              SetSlot(F, 1, v);
              F.Phase := 3;
            end
            else
            begin
              F.Phase := 2;
              NeedChildValue(F, 1, F.Node.B);
            end;
          end;
        2:
          if F.Sub = 1 then   // = ：键就绪，求值
          begin
            F.Phase := 3;
            NeedChildValue(F, 0, F.Node.B);
          end
          else                // 算术复合赋值：合并写回
          begin
            v := EvalBinaryOp(Copy(F.Node.Op, 1, System.Length(F.Node.Op) - 1),
              F.Values[0], F.Values[1]);
            WriteRefTo(F.Node.A, v, F.EnvNow);
            FinishFrame(F, v, JsFlowNormal);
          end;
        3:
          begin
            // Sub=1/2：'=' 计算成员 / 命名成员目标；Sub=3：逻辑复合赋值；Sub=0：简单 '='
            if F.Sub = 1 then
            begin
              v := F.Values[0];
              SetProp(F.Values[1], PropNameOf(F.Values[2]), v);
              FinishFrame(F, v, JsFlowNormal);
            end
            else if F.Sub = 2 then
            begin
              v := F.Values[0];
              SetProp(F.Values[1], F.Node.A.Name, v);
              FinishFrame(F, v, JsFlowNormal);
            end
            else if F.Sub = 3 then
            begin
              v := F.Values[1];   // 短路时为原值，否则为新值（与快路径语义一致）
              WriteRefTo(F.Node.A, v, F.EnvNow);
              FinishFrame(F, v, JsFlowNormal);
            end
            else
            begin
              v := F.Values[0];
              WriteRefTo(F.Node.A, v, F.EnvNow);
              FinishFrame(F, v, JsFlowNormal);
            end;
          end;
      end;
    nkUnary:
      case F.Phase of
        0:
          if F.Node.Op = 'delete' then
          begin
            if (nfHasAwait in F.Node.A.Flags) or (F.Node.A.Kind <> nkMember) or
               (nfComputed in F.Node.A.Flags) then
              raise EXuiJsRuntime.Create('暂不支持：await 出现在 delete 目标中');
            v := EvalExpr(F.Node.A.A, F.EnvNow);
            if (v.Kind = jvObject) and (v.Obj <> nil) then
              v.Obj.DeleteOwn(F.Node.A.Name);
            FinishFrame(F, MakeBool(True), JsFlowNormal);
          end
          else
          begin
            F.Phase := 1;
            NeedChildValue(F, 0, F.Node.A);
          end;
        1:
          begin
            v := F.Values[0];
            if F.Node.Op = 'typeof' then
            begin
              case v.Kind of
                jvUndefined: v := MakeString('undefined');
                jvNull: v := MakeString('object');
                jvBool: v := MakeString('boolean');
                jvNumber: v := MakeString('number');
                jvString: v := MakeString('string');
              else
                if (v.Obj <> nil) and (v.Obj is TXuiJsFunction) then
                  v := MakeString('function')
                else
                  v := MakeString('object');
              end;
              FinishFrame(F, v, JsFlowNormal);
            end
            else if F.Node.Op = 'void' then
              FinishFrame(F, MakeUndefined, JsFlowNormal)
            else if F.Node.Op = '!' then
              FinishFrame(F, MakeBool(not ToBoolValue(v)), JsFlowNormal)
            else if F.Node.Op = '-' then
              FinishFrame(F, MakeNumber(-ToNumberValue(v)), JsFlowNormal)
            else if F.Node.Op = '+' then
              FinishFrame(F, MakeNumber(ToNumberValue(v)), JsFlowNormal)
            else if F.Node.Op = '~' then
              FinishFrame(F, MakeNumber(not ToInt32Value(v)), JsFlowNormal)
            else
              FinishFrame(F, MakeUndefined, JsFlowNormal);
          end;
      end;
    nkUpdate:
      raise EXuiJsRuntime.Create('暂不支持：await 出现在自增/自减目标中');
    nkTemplate:
      case F.Phase of
        0:
          begin
            F.StrAcc := '';
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, MakeString(F.StrAcc), JsFlowNormal)
          else
          begin
            part := F.Node.Items[F.Idx];
            Inc(F.Idx);
            if part = nil then
              Exit;
            if part.Kind = nkString then
              F.StrAcc := F.StrAcc + part.Str
            else
            begin
              F.Phase := 2;
              NeedChildValue(F, 0, part);
            end;
          end;
        2:
          begin
            F.StrAcc := F.StrAcc + ToStringValue(F.Values[0]);
            F.Phase := 1;
          end;
      end;
    nkArrayLit:
      case F.Phase of
        0:
          begin
            F.CursorObj := NewArray;
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, ObjectValue(TXuiJsObject(F.CursorObj)), JsFlowNormal)
          else
          begin
            part := F.Node.Items[F.Idx];
            Inc(F.Idx);
            if part = nil then
              Exit;
            if part.Kind = nkEmpty then
            begin
              arr := TXuiJsArray(F.CursorObj);
              SetLength(arr.Items, arr.Length + 1);
              arr.Items[arr.Length - 1] := MakeUndefined;
              Exit;
            end;
            if part.Kind = nkSpread then
            begin
              F.Sub := 1;
              F.Phase := 2;
              NeedChildValue(F, 0, part.A);
            end
            else
            begin
              F.Sub := 0;
              F.Phase := 2;
              NeedChildValue(F, 0, part);
            end;
          end;
        2:
          begin
            arr := TXuiJsArray(F.CursorObj);
            v := F.Values[0];
            if F.Sub = 1 then
            begin
              if (v.Kind = jvObject) and (v.Obj is TXuiJsArray) then
                for i := 0 to TXuiJsArray(v.Obj).Length - 1 do
                begin
                  SetLength(arr.Items, arr.Length + 1);
                  arr.Items[arr.Length - 1] := TXuiJsArray(v.Obj).Items[i];
                end
              else if v.Kind = jvString then
                for i := 0 to JsStrLength(v.Str) - 1 do
                begin
                  SetLength(arr.Items, arr.Length + 1);
                  arr.Items[arr.Length - 1] := MakeString(JsStrCharAt(v.Str, i));
                end;
            end
            else
            begin
              SetLength(arr.Items, arr.Length + 1);
              arr.Items[arr.Length - 1] := v;
            end;
            F.Phase := 1;
          end;
      end;
    nkObjectLit:
      case F.Phase of
        0:
          begin
            F.CursorObj := NewObject('Object');
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, ObjectValue(TXuiJsObject(F.CursorObj)), JsFlowNormal)
          else
          begin
            part := F.Node.Items[F.Idx];
            Inc(F.Idx);
            if part = nil then
              Exit;
            if part.Kind = nkSpread then
            begin
              // 对象展开（await 于展开源 v1 不支持：走同步求值，含 await 会兜底报错）
              v := EvalExpr(part.A, F.EnvNow);
              if (v.Kind = jvObject) and (v.Obj <> nil) then
                for i := 0 to v.Obj.Props.Count - 1 do
                  TXuiJsObject(F.CursorObj).SetOwn(
                    TXuiJsProp(v.Obj.Props[i]).Name, TXuiJsProp(v.Obj.Props[i]).Value);
              Exit;
            end;
            if part.Kind <> nkProperty then
              Exit;
            if nfComputed in part.Flags then
              F.StrAcc := PropNameOf(EvalExpr(part.A, F.EnvNow))
            else
              F.StrAcc := part.Name;
            F.Ref := part;
            if part.B = nil then
              Exit;
            F.Phase := 2;
            NeedChildValue(F, 0, part.B);
          end;
        2:
          begin
            TXuiJsObject(F.CursorObj).SetOwn(F.StrAcc, F.Values[0]);
            F.Phase := 1;
          end;
      end;
    nkSeq:
      case F.Phase of
        0:
          begin
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
          begin
            part := F.Node.Items[F.Idx];
            Inc(F.Idx);
            if part = nil then
              Exit;
            F.Phase := 2;
            NeedChildValue(F, 0, part);
          end;
        2:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, F.Values[0], JsFlowNormal)
          else
            F.Phase := 1;
      end;
    // ---- 成员链 / 调用 / new ----
    nkMember, nkCall:
      case F.Phase of
        0:
          begin
            node := F.Node;
            F.Links.Clear;
            while (node <> nil) and ((node.Kind = nkMember) or (node.Kind = nkCall)) do
            begin
              F.Links.Add(node);
              node := node.A;
            end;
            F.Flag := (node <> nil) and (node.Kind = nkSuper);
            F.Idx := F.Links.Count - 1;
            F.Sub := 0;
            F.Sub2 := -1;
            F.Flag2 := False;
            if F.Flag then
            begin
              SetSlot(F, 0, SuperBaseValue(F.EnvNow));
              SetSlot(F, 2, ThisOf(F.EnvNow));
              if (F.Links.Count = 1) and (TXuiJsNode(F.Links[0]).Kind = nkCall) then
                FinishFrame(F, SuperConstructCall(F.EnvNow,
                  EvalArgs(TXuiJsNode(F.Links[0]), F.EnvNow)), JsFlowNormal)
              else
                F.Phase := 3;
            end
            else
            begin
              F.Phase := 2;
              NeedChildValue(F, 0, node);
            end;
          end;
        2: F.Phase := 3;
        3:
            if F.Sub = 0 then
            begin
              if F.Idx < 0 then
                FinishFrame(F, F.Values[0], JsFlowNormal)
              else
              begin
                lnk := TXuiJsNode(F.Links[F.Idx]);
                if lnk.Kind = nkMember then
                begin
                  if IsNullish(F.Values[0]) and (nfOptional in lnk.Flags) then
                    Dec(F.Idx)
                  else if nfComputed in lnk.Flags then
                  begin
                    if nfHasAwait in lnk.Flags then
                    begin
                      F.Sub := 1;
                      F.Phase := 4;
                      NeedChildValue(F, 0, lnk.B);
                    end
                    else
                    begin
                      SetSlot(F, 0, GetProp(F.Values[0],
                        PropNameOf(EvalExpr(lnk.B, F.EnvNow))));
                      if F.Flag and (F.Sub2 < 0) then
                        F.Sub2 := F.Idx;
                      F.Flag2 := True;
                      Dec(F.Idx);
                    end;
                  end
                  else
                  begin
                    SetSlot(F, 0, GetProp(F.Values[0], lnk.Name));
                    if F.Flag and (F.Sub2 < 0) then
                      F.Sub2 := F.Idx;
                    F.Flag2 := True;
                    Dec(F.Idx);
                  end;
                end
                else
                begin
                  if IsNullish(F.Values[0]) and (nfOptional in lnk.Flags) then
                    Dec(F.Idx)
                  else
                  begin
                    SetLength(F.ArgsAcc, 0);
                    F.Idx2 := 0;
                    F.Sub := 2;
                  end;
                end;
              end;
            end
            else if F.Sub = 2 then
            begin
              lnk := TXuiJsNode(F.Links[F.Idx]);
              if F.Idx2 >= lnk.ItemCount then
              begin
                if F.Flag2 then
                begin
                  if F.Flag and (F.Sub2 = F.Idx + 1) then
                    v := CallFunction(F.Values[0], F.Values[2], F.ArgsAcc)
                  else
                    v := CallFunction(F.Values[0], F.Values[1], F.ArgsAcc);
                end
                else
                  v := CallFunction(F.Values[0], MakeUndefined, F.ArgsAcc);
                SetSlot(F, 0, v);
                F.Flag2 := False;
                Dec(F.Idx);
                F.Sub := 0;
              end
              else
              begin
                part := lnk.Items[F.Idx2];
                if part = nil then
                  Inc(F.Idx2)
                else if part.Kind = nkSpread then
                begin
                  F.Sub := 3;
                  F.Phase := 5;
                  NeedChildValue(F, 3, part.A);   // 槽 3：不覆盖槽 0 的被调者
                end
                else
                begin
                  F.Sub := 4;
                  F.Phase := 5;
                  NeedChildValue(F, 3, part);
                end;
              end;
            end;
        4:
          begin
            // 计算键就绪
            SetSlot(F, 0, GetProp(F.Values[1], PropNameOf(F.Values[0])));
            if F.Flag and (F.Sub2 < 0) then
              F.Sub2 := F.Idx;
            F.Flag2 := True;
            Dec(F.Idx);
            F.Sub := 0;
            F.Phase := 3;
          end;
        5:
          begin
            // 实参就绪（Sub=3 展开 / Sub=4 直接）；值在槽 3
            if F.Sub = 3 then
            begin
              v := F.Values[3];
              if (v.Kind = jvObject) and (v.Obj is TXuiJsArray) then
              begin
                for i := 0 to TXuiJsArray(v.Obj).Length - 1 do
                  AddArg(TXuiJsArray(v.Obj).Items[i]);
              end
              else if v.Kind = jvString then
              begin
                for i := 0 to JsStrLength(v.Str) - 1 do
                  AddArg(MakeString(JsStrCharAt(v.Str, i)));
              end;
            end
            else
              AddArg(F.Values[3]);
            Inc(F.Idx2);
            F.Sub := 2;
            F.Phase := 3;
          end;
      end;
    nkNew:
      case F.Phase of
        0:
          begin
            F.Phase := 1;
            NeedChildValue(F, 0, F.Node.A);
          end;
        1:
          begin
            SetLength(F.ArgsAcc, 0);
            F.Idx2 := 0;
            F.Phase := 2;
          end;
        2:
          if F.Idx2 >= F.Node.ItemCount then
            F.Phase := 4
          else
          begin
            part := F.Node.Items[F.Idx2];
            if part = nil then
              Inc(F.Idx2)
            else if part.Kind = nkSpread then
            begin
              F.Sub := 3;
              F.Phase := 3;
              NeedChildValue(F, 3, part.A);
            end
            else
            begin
              F.Sub := 4;
              F.Phase := 3;
              NeedChildValue(F, 3, part);
            end;
          end;
        3:
          begin
            if F.Sub = 3 then
            begin
              v := F.Values[3];
              if (v.Kind = jvObject) and (v.Obj is TXuiJsArray) then
              begin
                for i := 0 to TXuiJsArray(v.Obj).Length - 1 do
                  AddArg(TXuiJsArray(v.Obj).Items[i]);
              end
              else if v.Kind = jvString then
              begin
                for i := 0 to JsStrLength(v.Str) - 1 do
                  AddArg(MakeString(JsStrCharAt(v.Str, i)));
              end;
            end
            else
              AddArg(F.Values[3]);
            Inc(F.Idx2);
            F.Phase := 2;
          end;
        4: FinishFrame(F, Construct(F.Values[0], F.ArgsAcc), JsFlowNormal);
      end;
    nkSpread:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1: FinishFrame(F, F.Values[0], JsFlowNormal);
      end;
    // ---- 语句 ----
    nkBlock:
      case F.Phase of
        0:
          begin
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
          begin
            part := F.Node.Items[F.Idx];
            Inc(F.Idx);
            F.Phase := 2;
            NeedChildStmt(F, 0, part);
          end;
        2:
          if F.ChildFlow <> JsFlowNormal then
            FinishFrame(F, F.Values[0], F.ChildFlow)
          else
            F.Phase := 1;
      end;
    nkExprStmt:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1: FinishFrame(F, F.Values[0], JsFlowNormal);
      end;
    nkVarDecl:
      case F.Phase of
        0:
          begin
            F.Idx := 0;
            F.Phase := 1;
          end;
        1:
          if F.Idx >= F.Node.ItemCount then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
          begin
            decl := F.Node.Items[F.Idx];
            Inc(F.Idx);
            if decl = nil then
              Exit;
            F.Ref := decl;
            if F.Node.Name = 'var' then
              F.DeclEnv := F.EnvNow.FindFunctionEnv
            else
              F.DeclEnv := F.EnvNow;
            if decl.B <> nil then
            begin
              F.Phase := 2;
              NeedChildValue(F, 0, decl.B);
            end
            else
            begin
              BindPattern(decl.A, MakeUndefined, F.DeclEnv, True);
              Exit;
            end;
          end;
        2:
          begin
            BindPattern(F.Ref.A, F.Values[0], F.DeclEnv, True);
            F.Phase := 1;
          end;
      end;
    nkIf:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1:
          if IsTruthy(F.Values[0]) and (F.Node.B <> nil) then
          begin
            F.Phase := 2;
            NeedChildStmt(F, 0, F.Node.B);
          end
          else if (not IsTruthy(F.Values[0])) and (F.Node.C <> nil) then
          begin
            F.Phase := 2;
            NeedChildStmt(F, 0, F.Node.C);
          end
          else
            FinishFrame(F, MakeUndefined, JsFlowNormal);
        2: FinishFrame(F, F.Values[0], F.ChildFlow);
      end;
    nkWhile:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1:
          if not IsTruthy(F.Values[0]) then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
          begin
            F.Phase := 2;
            NeedChildStmt(F, 0, F.Node.B);
          end;
        2:
          if F.ChildFlow = JsFlowBreak then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else if F.ChildFlow = JsFlowReturn then
            FinishFrame(F, F.Values[0], JsFlowReturn)
          else
            F.Phase := 0;   // continue / 正常：重估条件
      end;
    nkDoWhile:
      case F.Phase of
        0:
          begin
            F.Phase := 1;
            NeedChildStmt(F, 0, F.Node.B);
          end;
        1:
          if F.ChildFlow = JsFlowBreak then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else if F.ChildFlow = JsFlowReturn then
            FinishFrame(F, F.Values[0], JsFlowReturn)
          else
          begin
            F.Phase := 2;
            NeedChildValue(F, 0, F.Node.A);
          end;
        2: F.Phase := 3;
        3:
          if IsTruthy(F.Values[0]) then
            F.Phase := 0
          else
            FinishFrame(F, MakeUndefined, JsFlowNormal);
      end;
    nkFor:
      case F.Phase of
        0:
          begin
            F.EnvNow := NewEnv(F.Env);
            if F.Node.A = nil then
              F.Phase := 2
            else
            begin
              if F.Node.A.Kind = nkVarDecl then
                NeedChildStmt(F, 0, F.Node.A)
              else
                NeedChildValue(F, 0, F.Node.A);
              F.Phase := 1;
            end;
          end;
        1: F.Phase := 2;
        2:
          if F.Node.B = nil then
            F.Phase := 4
          else
          begin
            F.Phase := 3;
            NeedChildValue(F, 0, F.Node.B);
          end;
        3:
          if not IsTruthy(F.Values[0]) then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
            F.Phase := 4;
        4:
          if F.Node.ItemCount = 0 then
            F.Phase := 6
          else
          begin
            F.Phase := 5;
            NeedChildStmt(F, 0, F.Node.Items[0]);
          end;
        5:
          if F.ChildFlow = JsFlowBreak then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else if F.ChildFlow = JsFlowReturn then
            FinishFrame(F, F.Values[0], JsFlowReturn)
          else
            F.Phase := 6;   // continue 也先走步进
        6:
          if F.Node.C = nil then
            F.Phase := 2
          else
          begin
            F.Phase := 7;
            NeedChildValue(F, 0, F.Node.C);
          end;
        7: F.Phase := 2;
      end;
    nkForOf:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.B); end;
        1:
          begin
            v := F.Values[0];
            F.Sub := 0;
            if (v.Kind = jvObject) and (v.Obj is TXuiJsArray) then
            begin
              F.CursorObj := v.Obj;
              F.Idx2 := TXuiJsArray(v.Obj).Length;
            end
            else if v.Kind = jvString then
            begin
              F.CursorObj := nil;
              F.StrAcc := v.Str;
              F.Sub := 1;
              F.Idx2 := JsStrLength(v.Str);
            end
            else
              raise EXuiJsRuntime.Create('for..of 仅支持数组与字符串');
            F.EnvNow := NewEnv(F.Env);
            F.Idx := 0;
            F.Phase := 2;
          end;
        2:
          if F.Idx >= F.Idx2 then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else
          begin
            if F.Sub = 0 then
              v := TXuiJsArray(F.CursorObj).Items[F.Idx]
            else
              v := MakeString(JsStrCharAt(F.StrAcc, F.Idx));
            BindPattern(F.Node.A, v, F.EnvNow, True);
            F.Phase := 3;
            NeedChildStmt(F, 0, F.Node.C);
          end;
        3:
          if F.ChildFlow = JsFlowBreak then
            FinishFrame(F, MakeUndefined, JsFlowNormal)
          else if F.ChildFlow = JsFlowReturn then
            FinishFrame(F, F.Values[0], JsFlowReturn)
          else
          begin
            Inc(F.Idx);
            F.Phase := 2;
          end;
      end;
    nkReturn:
      case F.Phase of
        0:
          if F.Node.A = nil then
            FinishFrame(F, MakeUndefined, JsFlowReturn)
          else
          begin
            F.Phase := 1;
            NeedChildValue(F, 0, F.Node.A);
          end;
        1: FinishFrame(F, F.Values[0], JsFlowReturn);
      end;
    nkThrow:
      case F.Phase of
        0: begin F.Phase := 1; NeedChildValue(F, 0, F.Node.A); end;
        1: ThrowScriptValue(F.Values[0]);
      end;
    nkBreak: FinishFrame(F, MakeUndefined, JsFlowBreak);
    nkContinue: FinishFrame(F, MakeUndefined, JsFlowContinue);
    nkEmpty: FinishFrame(F, MakeUndefined, JsFlowNormal);
    nkClassDecl:
      begin
        F.Env.Define(F.Node.Name, EvalClass(F.Node.A, F.EnvNow));
        FinishFrame(F, MakeUndefined, JsFlowNormal);
      end;
    nkTry:
      case F.Phase of
        0:
          begin
            F.DeclEnv := F.EnvNow;   // 记住外层环境（catch 用子环境，finally 回到外层）
            F.Phase := 1;
            NeedChildStmt(F, 0, F.Node.B);
          end;
        1:
          if F.Node.ItemCount = 0 then
            FinishFrame(F, F.Values[0], F.ChildFlow)
          else
          begin
            SetSlot(F, 2, F.Values[0]);
            F.SavedFlow := F.ChildFlow;
            F.TryMode := 2;
            F.HasThrown := False;
            F.EnvNow := F.DeclEnv;
            F.Phase := 2;
          end;
        2:
          begin
            F.Phase := 3;
            NeedChildStmt(F, 1, F.Node.Items[0]);
          end;
        3:
          if F.ChildFlow <> JsFlowNormal then
            FinishFrame(F, F.Values[1], F.ChildFlow)   // finally 的流程覆盖原结果
          else if F.HasThrown then
          begin
            F.TryMode := 3;   // 标记后再抛：展开时不再进入本帧
            ThrowScriptValue(F.ThrownValue);
          end
          else
            FinishFrame(F, F.Values[2], F.SavedFlow);
        4:
          begin
            F.Phase := 5;
            NeedChildStmt(F, 0, F.Node.C);
          end;
        5:
          if F.Node.ItemCount = 0 then
            FinishFrame(F, F.Values[0], F.ChildFlow)
          else
          begin
            SetSlot(F, 2, F.Values[0]);
            F.SavedFlow := F.ChildFlow;
            F.TryMode := 2;
            F.HasThrown := False;
            F.EnvNow := F.DeclEnv;
            F.Phase := 2;
          end;
      end;
  else
    raise EXuiJsRuntime.CreateFmt('async 机器不支持该节点（kind=%d，%d 行 %d 列）',
      [Ord(F.Node.Kind), F.Node.Line, F.Node.Col]);
  end;
end;
end.
