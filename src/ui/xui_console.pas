unit xui_console;

{$mode objfpc}{$H+}

{ 控制台输出的健壮化与编码统一（M11）。

  两个实测问题：

  1) **写失败会让工具直接崩掉。** FPC 的 WriteLn 带 I/O 检查：目标句柄不可写时
     （stdout 被重定向到已关闭的管道、无控制台的宿主等）写操作失败，随后的 I/O 检查
     抛出 EInOutError。FPC 把它映射成错误码 101 的固定文案 "Disk Full"，于是用户看到
     "Exception ... EInOutError: Disk Full" —— 一个与磁盘毫无关系的误导性崩溃，
     连 --help / 参数错误这类纯诊断输出也会崩（实测：关闭 stdout 句柄即可复现）。
     诊断输出不该决定工具的成败，因此这里把写入包成"永不抛异常"，并在首次失败后
     停止继续尝试（后续写入必然同样失败，继续写只会重复触发）。

  2) **同一次运行里输出两种编码，导致乱码。** 实测把渲染器输出抓成字节看：
       WriteLn('参数错误: ' + AMsg)   → GBK 字节（B2 CE CA FD…）
       WriteLn('使用 --help 查看用法。') → 原样 UTF-8 字节（E4 BD BF…）
     即"表达式"会经 RTL 按控制台/系统码页转换，而**纯字面量被直写**（编译器把常量串
     直接交给写例程，跳过了转换）。于是同一屏里一半 GBK、一半 UTF-8，在 GBK 控制台上
     后半必然乱码（用户看到的"浣跨敤"），某些宿主还因此写入失败，触发问题 1 的崩溃。
     解法不是在两种编码里挑一个，而是**让所有输出走同一条路径**：ConWriteLn 的形参是
     运行时字符串，一律经 RTL 转换，从而与表达式输出同编码（跟随控制台码页）。
     因此这里**不再修改控制台码页**：RTL 本来就会对齐控制台码页，切码页反而会引入
     新的"字节与码页不匹配"，而且擅自改用户的控制台状态也不合适（实测 cmd 下有无
     码页覆盖都能正确显示中文）。

  两者都不改变正常环境下的行为：输出能写就照常写，控制台支持就照常显示中文。 }

interface

{ 初始化控制台。保留为显式钩子（主流程调用一次），当前实现不做任何事：
  编码一致性由 ConWriteLn 这条统一路径保证（见上文问题 2），不需要改码页。
  保留函数是为了让"控制台初始化"有一个明确的落点，也便于将来真需要时补逻辑。 }
procedure XuiConsoleInit;

{ 安全写：目标不可写时不抛异常；首次失败后停止后续写入。
  返回值：本次是否成功写出。 }
function ConWrite(const S: string): Boolean;
function ConWriteLn: Boolean; overload;
function ConWriteLn(const S: string): Boolean; overload;
{ 与 WriteLn 一致，支持 Format 风格（内部先格式化再安全写） }
function ConWriteLnFmt(const AFmt: string; const AArgs: array of const): Boolean;

{ 以上写 stdout；以下写 stderr（同样不抛异常）。
  用途：--json 模式下 stdout 必须只含 JSON，人读的日志一律走 stderr，
  这样 `lui-render ... --json | jq` 才成立（ADR 32 的约定）。 }
function ConErrWrite(const S: string): Boolean;
function ConErrWriteLn: Boolean; overload;
function ConErrWriteLn(const S: string): Boolean; overload;
function ConErrWriteLnFmt(const AFmt: string; const AArgs: array of const): Boolean;

{ 输出是否仍然可写（用于诊断/测试；不可写时为 False） }
function ConsoleWritable: Boolean;

implementation

uses
  SysUtils;

var
  GWritable: Boolean = True;   // 首次写失败后置 False

procedure XuiConsoleInit;
begin
  // 无操作：编码一致性由 ConWriteLn 统一路径保证（详见单元头问题 2）。
  // 此处刻意不修改控制台码页——那会改变用户的终端状态，且实测并非必要。
end;

function ConsoleWritable: Boolean;
begin
  Result := GWritable;
end;

function ConWrite(const S: string): Boolean;
begin
  Result := False;
  if (not GWritable) or (S = '') then
    Exit(GWritable);
  {$I-}
  Write(Output, S);
  {$I+}
  if IOResult <> 0 then
  begin
    GWritable := False;   // 句柄不可写：后续写入不再尝试，避免反复触发异常
    Exit(False);
  end;
  Result := True;
end;

function ConWriteLn: Boolean;
begin
  Result := False;
  if not GWritable then
    Exit;
  {$I-}
  WriteLn(Output);
  {$I+}
  if IOResult <> 0 then
  begin
    GWritable := False;
    Exit(False);
  end;
  Result := True;
end;

function ConWriteLn(const S: string): Boolean;
begin
  Result := False;
  if not GWritable then
    Exit;
  {$I-}
  WriteLn(Output, S);
  {$I+}
  if IOResult <> 0 then
  begin
    GWritable := False;
    Exit(False);
  end;
  Result := True;
end;

function ConWriteLnFmt(const AFmt: string; const AArgs: array of const): Boolean;
begin
  Result := ConWriteLn(Format(AFmt, AArgs));
end;

{ ---- stderr：与 stdout 各自独立判定可写性（可能只有一路不可用） ---- }

var
  GErrWritable: Boolean = True;

function ConErrWrite(const S: string): Boolean;
begin
  Result := False;
  if (not GErrWritable) or (S = '') then
    Exit(GErrWritable);
  {$I-}
  Write(ErrOutput, S);
  {$I+}
  if IOResult <> 0 then
  begin
    GErrWritable := False;
    Exit(False);
  end;
  Result := True;
end;

function ConErrWriteLn: Boolean;
begin
  Result := False;
  if not GErrWritable then
    Exit;
  {$I-}
  WriteLn(ErrOutput);
  {$I+}
  if IOResult <> 0 then
  begin
    GErrWritable := False;
    Exit;
  end;
  Result := True;
end;

function ConErrWriteLn(const S: string): Boolean;
begin
  Result := False;
  if not GErrWritable then
    Exit;
  {$I-}
  WriteLn(ErrOutput, S);
  {$I+}
  if IOResult <> 0 then
  begin
    GErrWritable := False;
    Exit;
  end;
  Result := True;
end;

function ConErrWriteLnFmt(const AFmt: string; const AArgs: array of const): Boolean;
begin
  Result := ConErrWriteLn(Format(AFmt, AArgs));
end;

end.
