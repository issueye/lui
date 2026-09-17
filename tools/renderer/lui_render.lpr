program lui_render;

{$mode objfpc}{$H+}

{ lui 独立渲染器程序 (lui-render) — M9
  兼具 CLI 离线导出与 GUI 实时交互查看功能。装配逻辑统一走 xui_app 装配门面
  （与 demo1 共用，ADR 30）。

  零外部第三方依赖：使用 Free Pascal RTL + LazUtils + LCL + GDI/GDI+。

  M9-P0/P1（本版，ADR 30–33）：
  - CLI 规范收敛：-h 独占帮助；视口高度用 -H/--height；未知参数报错（退出码 2）
  - --version 输出版本；-o 输出目录不存在时自动创建
  - 多输入批量 + --outdir + --theme both + --json 汇总（ADR 32 退出码 0/1/2/3）
  - 装配统一走 xui_app 装配门面（复位样式表，重载不累积）

  M11（本版，ADR 41–44）——把渲染器从"出图工具"扩成"项目工具链入口"：
  - --init <目录>   生成可开发/测试/打包/交付的工程骨架（模板取自 scaffold/，含 ui/ 运行时）
  - --check         离屏渲染并收集脚本错误：有错退出码 1，把"页面能跑"变成 CI 可判定的事
  - --pack <目录>   组装交付目录（渲染器 + ui/ + 工程页面 + 预览图 + 说明）
  - GUI/CLI 预览补上依赖热重载（原来只盯输入文件自身，改 CSS/ts 不生效） }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Controls, ExtCtrls, Graphics, LCLType,
  Classes, SysUtils, Types, Math, StrUtils, FileUtil,
  xui_types, xui_style, xui_dom, xui_xml, xui_layout, xui_render,
  xui_css_parser, xui_css_match, xui_engine, xui_events, xui_widget,
  xui_input, xui_svg, xui_script, xui_script_dom, xui_script_bind, xui_app,
  xui_scaffold, xui_console,
  {$IFDEF WINDOWS}xui_render_gdiplus,{$ENDIF}
  xui_host, xui_embed
  // 单程序版（-dLUI_EMBED）额外链接构建期生成的内嵌资源单元；
  // 该单元在 initialization 中把资源清单注册给 xui_embed
  {$IFDEF LUI_EMBED}, xui_embed_assets{$ENDIF}
  ;

const
  AppVersion = '0.10.0';

type
  { CLI / GUI 运行时配置参数 }
  TRenderOptions = record
    Inputs: TStringList;     // 输入文件（可多个 = 批量）
    OutDir: string;          // --outdir（批量模式）
    OutputFile: string;      // -o（单文件模式）
    Width: Integer;
    Height: Integer;
    WidthGiven: Boolean;     // -w 是否显式给出（--init 需要区分"默认"与"指定"）
    HeightGiven: Boolean;
    Theme: string;           // 'light' / 'dark' / 'both'
    ThemeGiven: Boolean;
    ExtraCss: string;
    Watch: Boolean;
    Verbose: Boolean;
    Bench: Integer;          // --bench N：渲染后重复 N 次完整重排（性能基准）
    BenchMode: string;       // --bench-mode full|layout|paint：基准的失效级别（默认 full）
    JsonOut: Boolean;        // --json：结果以 JSON 输出到 stdout
    ListEmbedded: Boolean;   // --list-embedded：列出内嵌资源后退出
    AddPage: string;         // --add-page <xml>：输出该页面的资源清单（供打包脚本内嵌）
    // ---- M11：项目工具链 ----
    InitDir: string;         // --init <目录>：生成工程骨架后退出
    InitName: string;        // --name <工程名>
    Force: Boolean;          // --force：--init 覆盖已存在文件（默认跳过保留）
    Check: Boolean;          // --check：离屏渲染并收集脚本错误（有错退出码 1）
    PackDir: string;         // --pack <目录>：组装交付目录后退出
    IsCliMode: Boolean;
  end;

  TJobResult = record
    Input: string;
    Output: string;
    Theme: string;
    OK: Boolean;
  end;

var
  Opt: TRenderOptions;

{ 人读日志：--json 时一律走 stderr。
  ADR 32 约定"stdout 只含 JSON、日志走 stderr"，否则 `lui-render ... --json | jq` 会被
  混进的 [成功]/[打包] 之类日志行破坏（实测过）。非 --json 时仍走 stdout，保持原有观感。 }
function LogLn(const S: string): Boolean; overload;
begin
  if Opt.JsonOut then
    Result := ConErrWriteLn(S)
  else
    Result := ConWriteLn(S);
end;

function LogLn: Boolean; overload;
begin
  if Opt.JsonOut then
    Result := ConErrWriteLn
  else
    Result := ConWriteLn;
end;

function LogLnFmt(const AFmt: string; const AArgs: array of const): Boolean;
begin
  Result := LogLn(Format(AFmt, AArgs));
end;

procedure PrintUsage;
begin
  LogLn('lui 渲染器程序 (lui-render) v' + AppVersion);
  LogLn('用法: lui-render <输入.xml|svg> [更多输入...] [选项]');
  LogLn('      lui-render --init <目录> [选项]     生成项目骨架');
  LogLn('      lui-render --check <输入...>        脚本自检（CI 用）');
  LogLn('      lui-render --pack <目录> <输入...>  组装交付目录');
  LogLn;
  LogLn('渲染选项:');
  LogLn('  -o, --output <文件.png>   单文件输出（CLI 模式；目录不存在会自动创建）');
  LogLn('  -O, --outdir <目录>       批量输出目录（与多个输入搭配使用）');
  LogLn('  -w, --width <像素>        视口宽度 (默认 800)');
  LogLn('  -H, --height <像素>       视口高度 (默认 600)');
  LogLn('  -t, --theme <light|dark|both>  主题（both = 双主题各出一张）');
  LogLn('  -c, --css <样式文件>      附加加载的自定义 CSS 样式文件');
  LogLn('  --watch                   监听输入与其依赖变更并自动重跑');
  LogLn('  --bench <次数>            渲染后重复 N 次完整重排并输出耗时（性能基准）');
  LogLn('  --bench-mode <级别>       full(默认)=级联+布局+绘制 / layout=仅布局+绘制 / paint=仅绘制');
  LogLn('  --json                    结果以 JSON 输出到 stdout（日志走 stderr）');
  LogLn;
  LogLn('项目工具链 (M11):');
  LogLn('  --init <目录>             生成工程骨架（页面/脚本/样式 + ui/ 运行时 +脚本）');
  LogLn('  --name <工程名>           --init 的工程名（默认取目录名）');
  LogLn('  --check                   离屏渲染并收集脚本错误；有错退出码 1（CI 门禁）');
  LogLn('  --pack <目录>             组装交付目录（渲染器 + ui/ + 页面 + 预览图 + 说明）');
  LogLn('  --force                   --init 覆盖已存在文件；--pack 清空非空的目标目录');
  LogLn;
  LogLn('其它:');
  LogLn('  --list-embedded           列出 exe 内嵌的资源（单程序版；普通版为空）');
  LogLn('  --add-page <页面.xml>     输出该页面的资源清单（供 npm run embed 打包内嵌）');
  LogLn('  -v, --verbose             输出详细过程日志');
  LogLn('  -V, --version             输出版本号');
  LogLn('  -?, --help                显示此帮助说明');
  LogLn;
  LogLn('生成的项目里:');
  LogLn('  run-dev.cmd               开发：GUI 预览（F5 刷新 / T 切主题 / Esc 退出，改文件自动重载）');
  LogLn('  run-test.cmd              测试：--check 自检 + 双主题出图到 out\\');
  LogLn('  run-pack.cmd              打包：组装 dist\\ 交付目录');
end;

// 参数错误：退出码 2（区别于渲染失败的 1）
procedure ParamError(const AMsg: string);
begin
  LogLn('参数错误: ' + AMsg);
  LogLn('使用 --help 查看用法。');
  Halt(2);
end;

{ --list-embedded：列出可执行文件中内嵌的资源（单程序版）；
  普通版（无内嵌）输出提示后返回，用于自动化验证两种构建的差异 }
procedure ListEmbeddedAssets;
var
  names: TStringList;
  i: Integer;
begin
  if not XuiEmbedAvailable then
  begin
    LogLn('（本可执行文件未内嵌任何资源；单程序版请用 npm run build:single 构建）');
    Exit;
  end;
  names := XuiEmbedNames;
  try
    LogLn(Format('内嵌资源 %d 项:', [names.Count]));
    for i := 0 to names.Count - 1 do
      LogLn('  ' + names[i]);
  finally
    names.Free;
  end;
end;

function IIf(const ACond: Boolean; const ATrue, AFalse: string): string;
begin
  if ACond then
    Result := ATrue
  else
    Result := AFalse;
end;

{ JSON 字符串转义。

  注意 Pascal 字符串里反斜杠**不是**转义符：'\\' 是"两个反斜杠"这个两字符序列。
  早前写成 StringReplace(S, '\\', '\\\\') 是想把单个 \ 变成 \\，实际却只在出现连续
  两个反斜杠时才替换，于是 Windows 绝对路径（E:\codes\...）原样进了 JSON —— `\c` 不是
  合法转义，整个输出解析失败（实测由 npm run pack 的 --json 冒烟抓到）。引号的替换同理
  （'\\\"' 是 3 个字符，多了一层）。这里按"单字符 → 单字符 + 转义"改写。
  一并处理控制字符：JSON 规范不允许字符串里出现裸的换行/制表符。 }
function JsonEscape(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:  Result := Result + '\b';
      #9:  Result := Result + '\t';
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

{ 页面资源发现：把一个页面 xml 连同其同目录关联资源（同名 css/ts、nav-*.css、
  <include src>、<script src>）梳理成"相对页面目录"的文件清单。

  输出 ABasedir（页面绝对目录，无尾分隔符）与 ADeps（'/' 分隔的相对文件名，去重、只含
  真实存在的文件）。规则与引擎一致（同名-主题.css 优先、include/script 相对页面目录解析），
  故 --add-page（打包内嵌）与 --pack（交付目录）共用同一份真相，不会漂移。 }
function CollectPageDeps(const APageFile: string; out ABasedir: string;
  ADeps: TStringList): Boolean;
var
  pageDir, pageFile, line, ref, token, norm: string;
  lines: TStringList;
  i, p, q: Integer;

  procedure Emit(const ARel: string);
  begin
    norm := StringReplace(ARel, '\', '/', [rfReplaceAll]);
    if (norm = '') or (ADeps.IndexOf(norm) >= 0) then
      Exit;
    if not FileExists(pageDir + StringReplace(norm, '/', PathDelim, [rfReplaceAll])) then
      Exit;
    ADeps.Add(norm);
  end;

begin
  Result := False;
  ABasedir := '';
  if not FileExists(APageFile) then
    Exit;
  pageFile := ExpandFileName(APageFile);
  pageDir := IncludeTrailingPathDelimiter(ExtractFileDir(pageFile));
  ABasedir := ExcludeTrailingPathDelimiter(pageDir);

  // 页面自身 + 同名样式/脚本（浅色/深色/无后缀，与 xui_app 的发现顺序一致）
  Emit(ExtractFileName(pageFile));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '.ts'));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '-light.ts'));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '-dark.ts'));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '-light.css'));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '-dark.css'));
  Emit(ChangeFileExt(ExtractFileName(pageFile), '.css'));
  Emit('nav-light.css');
  Emit('nav-dark.css');

  // XML 中的 src 引用（<include src> / <script src>）：仅接受页面目录内的相对路径
  lines := TStringList.Create;
  try
    lines.LoadFromFile(pageFile);
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      token := 'src="';
      p := Pos(token, line);
      while p > 0 do
      begin
        q := PosEx('"', line, p + Length(token));
        if q = 0 then
          Break;
        ref := Trim(Copy(line, p + Length(token), q - (p + Length(token))));
        // 跳过上级/绝对引用（如 ../ui/index.ts —— 组件库由 ui/ 运行时提供）
        if (ref <> '') and (Pos('..', ref) = 0) and (Pos(':', ref) = 0) and
           (Copy(ref, 1, 1) <> '/') and (Copy(ref, 1, 1) <> '\') then
          Emit(ref);
        p := PosEx(token, line, q + 1);
      end;
    end;
  finally
    lines.Free;
  end;
  Result := True;
end;

{ --add-page：把一个页面 xml 连同其同目录关联资源（同名 css/ts、nav-*.css、
  <include src>、<script src>、assets/ 下的资产）梳理成清单，供打包脚本暂存内嵌。

  输出协议（stdout，TAB 分隔，供 scripts/embed.js 解析；此模式下不渲染、不打印其它内容）：
    BASEDIR<TAB><页面绝对目录>
    FILE<TAB><相对该目录的文件名，'/' 分隔> }
procedure DumpPageBundle(const APageFile: string);
var
  basedir: string;
  deps: TStringList;
  i: Integer;
begin
  deps := TStringList.Create;
  try
    if not CollectPageDeps(APageFile, basedir, deps) then
    begin
      LogLn(Format('[错误] 页面文件不存在: %s', [APageFile]));
      Halt(1);
    end;
    LogLn('BASEDIR'#9 + basedir);
    for i := 0 to deps.Count - 1 do
      LogLn('FILE'#9 + deps[i]);
  finally
    deps.Free;
  end;
end;

function ParseCommandLine: Boolean;
var
  i: Integer;
  arg: string;

  { 取选项值。下一个参数若长成选项（以 '-' 开头且不是单独的 '-'）就判为缺值——
    否则 `--init --force` 会把 --force 当成目录名真的建出一个叫 "--force" 的目录
    （实测过），用户看到的现象是"命令成功了但什么都没生成对"。}
  procedure NeedValue(const AOpt: string; out AVal: string);
  begin
    Inc(i);
    if i > ParamCount then
      ParamError('选项 ' + AOpt + ' 缺少参数值');
    AVal := ParamStr(i);
    if (Length(AVal) > 1) and (AVal[1] = '-') then
      ParamError('选项 ' + AOpt + ' 缺少参数值（后面跟的是选项 ' + AVal + '）');
  end;

  { 输入解析（单程序版）：磁盘上的原样路径优先（超集语义）；磁盘上没有时，
    回落到 exe 内嵌资源（相对路径，'..' 引用不参与内嵌解析）。 }
  procedure AddInput(const AFile: string);
  var
    resolved: string;
  begin
    if FileExists(AFile) then
    begin
      Opt.Inputs.Add(AFile);
      Exit;
    end;
    if Pos('..', AFile) = 0 then
    begin
      resolved := XuiEmbedResolve(AFile);
      if resolved <> '' then
      begin
        Opt.Inputs.Add(resolved);
        Exit;
      end;
    end;
    LogLn(Format('错误: 输入文件不存在: "%s"', [AFile]));
    Halt(1);
  end;

begin
  Result := True;
  Opt.Inputs := TStringList.Create;
  Opt.OutDir := '';
  Opt.OutputFile := '';
  Opt.Width := 800;
  Opt.Height := 600;
  Opt.WidthGiven := False;
  Opt.HeightGiven := False;
  Opt.Theme := 'light';
  Opt.ThemeGiven := False;
  Opt.ExtraCss := '';
  Opt.Watch := False;
  Opt.Verbose := False;
  Opt.Bench := 0;
  Opt.JsonOut := False;
  Opt.ListEmbedded := False;
  Opt.AddPage := '';
  Opt.InitDir := '';
  Opt.InitName := '';
  Opt.Force := False;
  Opt.Check := False;
  Opt.PackDir := '';
  Opt.IsCliMode := False;

  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if (arg = '-?') or (arg = '-h') or (arg = '--help') then
    begin
      PrintUsage;
      Halt(0);
    end
    else if (arg = '-V') or (arg = '--version') then
    begin
      LogLn('lui-render v' + AppVersion);
      Halt(0);
    end
    else if (arg = '-o') or (arg = '--output') then
      NeedValue('-o/--output', Opt.OutputFile)
    else if (arg = '-O') or (arg = '--outdir') then
      NeedValue('-O/--outdir', Opt.OutDir)
    else if (arg = '-w') or (arg = '--width') then
    begin
      NeedValue('-w/--width', arg);
      Opt.Width := StrToIntDef(arg, -1);
      if Opt.Width <= 0 then
        ParamError('视口宽度必须是正整数: ' + arg);
      Opt.WidthGiven := True;
    end
    else if (arg = '-H') or (arg = '--height') then
    begin
      NeedValue('-H/--height', arg);
      Opt.Height := StrToIntDef(arg, -1);
      if Opt.Height <= 0 then
        ParamError('视口高度必须是正整数: ' + arg);
      Opt.HeightGiven := True;
    end
    else if (arg = '-t') or (arg = '--theme') then
    begin
      NeedValue('-t/--theme', arg);
      Opt.Theme := LowerCase(arg);
      if (Opt.Theme <> 'light') and (Opt.Theme <> 'dark') and (Opt.Theme <> 'both') then
        ParamError('主题只能是 light、dark 或 both: ' + arg);
      Opt.ThemeGiven := True;
    end
    else if (arg = '-c') or (arg = '--css') then
      NeedValue('-c/--css', Opt.ExtraCss)
    else if arg = '--watch' then
      Opt.Watch := True
    else if arg = '--bench' then
    begin
      NeedValue('--bench', arg);
      Opt.Bench := StrToIntDef(arg, -1);
      if Opt.Bench <= 0 then
        ParamError('基准次数必须是正整数: ' + arg);
    end
    else if arg = '--bench-mode' then
    begin
      NeedValue('--bench-mode', Opt.BenchMode);
      Opt.BenchMode := LowerCase(Opt.BenchMode);
      if (Opt.BenchMode <> 'full') and (Opt.BenchMode <> 'layout') and
         (Opt.BenchMode <> 'paint') then
        ParamError('--bench-mode 只支持 full|layout|paint: ' + Opt.BenchMode);
    end
    else if arg = '--json' then
      Opt.JsonOut := True
    else if arg = '--list-embedded' then
      Opt.ListEmbedded := True
    else if arg = '--add-page' then
      NeedValue('--add-page', Opt.AddPage)
    else if arg = '--init' then
      NeedValue('--init', Opt.InitDir)
    else if arg = '--name' then
      NeedValue('--name', Opt.InitName)
    else if arg = '--force' then
      Opt.Force := True
    else if arg = '--check' then
      Opt.Check := True
    else if arg = '--pack' then
      NeedValue('--pack', Opt.PackDir)
    else if (arg = '-v') or (arg = '--verbose') then
      Opt.Verbose := True
    else if (Copy(arg, 1, 1) = '-') and (arg <> '-') then
      ParamError('未知选项: ' + arg)
    else
      AddInput(arg);
    Inc(i);
  end;

  // ---- 以下为"立即执行后退出"的模式；--init/--pack 由主流程分派（其实现依赖
  //      本函数之后的单页渲染与 JSON 辅助函数）----
  if Opt.ListEmbedded then
  begin
    ListEmbeddedAssets;
    Halt(0);
  end;

  // --add-page：仅输出资源清单（供打包脚本内嵌），不渲染
  if Opt.AddPage <> '' then
  begin
    DumpPageBundle(Opt.AddPage);
    Halt(0);
  end;

  if (Opt.InitDir <> '') or (Opt.PackDir <> '') then
    Exit(True);   // 交给主流程；这两者不需要页面输入（--pack 由主流程校验）

  if Opt.Inputs.Count = 0 then
  begin
    LogLn('错误: 未指定输入文件。');
    PrintUsage;
    Exit(False);
  end;

  if (Opt.OutputFile <> '') and (Opt.Inputs.Count > 1) then
    ParamError('-o 只能与单个输入搭配；多输入请使用 -O/--outdir');

  if Opt.Check and ((Opt.OutputFile <> '') or (Opt.OutDir <> '')) then
    ParamError('--check 只做自检，不与 -o/-O 同时使用');

  Opt.IsCliMode := Opt.Check or (Opt.OutputFile <> '') or (Opt.OutDir <> '') or
    (Opt.Inputs.Count > 1);
end;

// 确保输出目录存在；失败给出中文提示
function EnsureOutputDir(const AOutputFile: string): Boolean;
var
  dir: string;
begin
  Result := True;
  dir := ExtractFilePath(AOutputFile);
  if (dir <> '') and (not DirectoryExists(dir)) then
  begin
    if not ForceDirectories(dir) then
    begin
      LogLn(Format('[错误] 无法创建输出目录: %s', [dir]));
      Result := False;
    end;
  end;
end;

{ 离屏渲染后端：画布是 TBitmap（CLI 无窗口），故与 GUI 的宿主画布无关；
  调用方负责随 app 一并释放 renderer（引擎持有并释放它） }
function NewOffscreenRenderer(ACanvas: TCanvas): TXuiCustomRenderer;
begin
  {$IFDEF WINDOWS}
  if GdiPlusAvailable then
    Result := TGdiPlusRenderer.Create(ACanvas)
  else
    Result := TGdiRenderer.Create(ACanvas);
  {$ELSE}
  Result := TGdiRenderer.Create(ACanvas);
  {$ENDIF}
end;

{ 单页渲染：xui_app 装配（复位样式表 → 组件库主题 → ui/index.ts → 关联 CSS →
  加载文档）→ 排版 → 绘制 → PNG；Opt.Bench > 0 时追加 N 次完整重排并计时 }
function RenderOne(const AInputFile, AOutputFile: string; AWidth, AHeight: Integer;
  const ATheme, AExtraCss: string; AVerbose: Boolean): Boolean;
var
  app: TXuiApp;
  bmp: TBitmap;
  png: TPortableNetworkGraphic;
  i: Integer;
  t0, t1, total: QWord;
  viewRect: TRect;
begin
  Result := False;
  if not EnsureOutputDir(AOutputFile) then
    Exit;
  app := TXuiApp.CreateOwned;
  bmp := TBitmap.Create;
  png := TPortableNetworkGraphic.Create;
  try
    bmp.SetSize(AWidth, AHeight);
    bmp.Canvas.Brush.Color := clWhite;
    bmp.Canvas.FillRect(0, 0, AWidth, AHeight);

    app.Engine.Renderer := NewOffscreenRenderer(bmp.Canvas); // engine 拥有 renderer 实例

    if AVerbose then
      LogLn(Format('[信息] 正在排版与渲染: %s (%dx%d, 主题: %s)...', [AInputFile, AWidth, AHeight, ATheme]));

    app.Configure(AInputFile, ATheme, AExtraCss);
    viewRect := Types.Rect(0, 0, AWidth, AHeight);
    app.Engine.Draw(bmp.Canvas, viewRect);

    // 性能基准：InvalidateStyles + Draw = 完整的样式级联 + 布局 + 绘制回路，
    // 与 GUI 稳态失效重算同路径；首个工程文件（组件库脚本）已就位，可复用
    if Opt.Bench > 0 then
    begin
      total := 0;
      for i := 1 to Opt.Bench do
      begin
        t0 := GetTickCount64;
        // 失效级别可分离：full=整树样式重算+布局+绘制（最坏情况）；
        // layout=仅布局+绘制（新增节点/尺寸变化）；paint=仅绘制（纯重绘）
        if (Opt.BenchMode = '') or (Opt.BenchMode = 'full') then
          app.Engine.InvalidateStyles
        else if Opt.BenchMode = 'layout' then
          app.Engine.InvalidateLayout;
        app.Engine.Draw(bmp.Canvas, viewRect);
        t1 := GetTickCount64;
        total := total + (t1 - t0);
      end;
      LogLn(Format('[基准] %d 次重排(mode=%s): %d ms（平均 %.2f ms/次）',
        [Opt.Bench, IfThen(Opt.BenchMode = '', 'full', Opt.BenchMode), total, total / Opt.Bench]));
    end;

    png.Assign(bmp);
    png.SaveToFile(AOutputFile);
    LogLn(Format('[成功] 已渲染导出至: %s (%dx%d)', [AOutputFile, AWidth, AHeight]));
    Result := True;
  except
    on E: Exception do
      LogLn(Format('[错误] 渲染失败: %s', [E.Message]));
  end;
  png.Free;
  bmp.Free;
  app.Free;
end;

{ ---- M11：--check（脚本自检）---- }

type
  TScriptIssues = class
  public
    Items: TStringList;      // 已格式化的问题行（文件(行,列) [阶段] 消息）
    constructor Create;
    destructor Destroy; override;
    procedure OnError(const AFile, AMessage: string; ALine, ACol: Integer;
      AStage: TXuiScriptStage);   // 含未处理 Promise 拒绝（ssUnhandledRejection）
    procedure OnLog(const AText: string);   // 页面 console.log 透传（诊断上下文）
  end;

function StageName(AStage: TXuiScriptStage): string;
begin
  case AStage of
    ssCompile: Result := '编译';
    ssRuntime: Result := '运行';
    ssUnhandledRejection: Result := '未处理拒绝';
    ssIO: Result := 'I/O';
    ssBudget: Result := '超预算';
  else
    Result := '未知';
  end;
end;

constructor TScriptIssues.Create;
begin
  inherited Create;
  Items := TStringList.Create;
end;

destructor TScriptIssues.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

procedure TScriptIssues.OnError(const AFile, AMessage: string;
  ALine, ACol: Integer; AStage: TXuiScriptStage);
var
  where: string;
begin
  where := AFile;
  if where = '' then
    where := '<脚本>';
  if ALine > 0 then
    where := Format('%s(%d,%d)', [where, ALine, ACol]);
  Items.Add(Format('  %s [%s] %s', [where, StageName(AStage), AMessage]));
end;

procedure TScriptIssues.OnLog(const AText: string);
begin
  if Opt.Verbose then
    LogLn('  [页面日志] ' + AText);
end;

{ 单个页面的自检：完整装配 + 一次绘制（触发 onMount / 首轮绑定求值 / 布局），
  收集脚本诊断。装配失败（XML 非法等）按渲染错误计。
  返回 True = 无脚本错误。 }
function CheckOne(const AInputFile: string; AWidth, AHeight: Integer;
  const ATheme, AExtraCss: string; out AIssueCount: Integer): Boolean;
var
  app: TXuiApp;
  bmp: TBitmap;
  sink: TScriptIssues;
  viewRect: TRect;
begin
  Result := False;
  AIssueCount := 0;
  app := TXuiApp.CreateOwned;
  bmp := TBitmap.Create;
  sink := TScriptIssues.Create;
  try
    bmp.SetSize(AWidth, AHeight);
    bmp.Canvas.Brush.Color := clWhite;
    bmp.Canvas.FillRect(0, 0, AWidth, AHeight);
    app.Engine.Renderer := NewOffscreenRenderer(bmp.Canvas);

    app.Script.OnError := @sink.OnError;
    if app.Script.Interp <> nil then
      app.Script.Interp.OnLog := @sink.OnLog;

    // 组件库加载期的错误也算本页自检结果（ui/index.ts 是页面的依赖）
    app.Configure(AInputFile, ATheme, AExtraCss);
    viewRect := Types.Rect(0, 0, AWidth, AHeight);
    app.Engine.Draw(bmp.Canvas, viewRect);
    app.Script.FlushReactive;   // 首屏后可能还有排队中的状态写入

    AIssueCount := sink.Items.Count;
    Result := AIssueCount = 0;
  except
    on E: Exception do
    begin
      sink.Items.Add('  <装配> ' + E.Message);
      AIssueCount := sink.Items.Count;
      Result := False;
    end;
  end;

  if sink.Items.Count > 0 then
  begin
    LogLn(Format('[自检失败] %s（%d 个脚本问题）', [AInputFile, sink.Items.Count]));
    LogLn(sink.Items.Text);
  end
  else if Opt.Verbose then
    LogLn('[自检通过] ' + AInputFile);

  sink.Free;
  bmp.Free;
  app.Free;
end;

{ --check：逐页自检；有任一页报错则整体退出码 1（CI 可判定）。--json 时把逐页结果
  以 JSON 汇总写 stdout（日志走 stderr，保证可解析）。 }
procedure RunCheck;
var
  i, issues, badPages: Integer;
  ok: Boolean;
  itemsJson, theme: string;
begin
  badPages := 0;
  itemsJson := '';
  theme := Opt.Theme;
  if theme = 'both' then
    theme := 'light';   // 自检只跑一档：脚本错误与主题无关
  for i := 0 to Opt.Inputs.Count - 1 do
  begin
    ok := CheckOne(Opt.Inputs[i], Opt.Width, Opt.Height, theme, Opt.ExtraCss, issues);
    if not ok then
      Inc(badPages);
    if Opt.JsonOut then
    begin
      if itemsJson <> '' then
        itemsJson := itemsJson + ',' + LineEnding;   // 与批量一致：按已产出条目数决定分隔符
      itemsJson := itemsJson + Format(
        '  {"input": "%s", "ok": %s, "issues": %d}',
        [JsonEscape(Opt.Inputs[i]), IIf(ok, 'true', 'false'), issues]);
    end;
  end;

  if Opt.JsonOut then
    ConWriteLn('{"mode": "check", "total": ' + IntToStr(Opt.Inputs.Count) +
      ', "failed": ' + IntToStr(badPages) + ', "items": [' + LineEnding +
      itemsJson + LineEnding + ']}')
  else if badPages = 0 then
    LogLn(Format('[完成] 自检通过 %d 个页面', [Opt.Inputs.Count]))
  else
    LogLn(Format('[失败] %d/%d 个页面存在脚本错误', [badPages, Opt.Inputs.Count]));

  if badPages > 0 then
    Halt(1);
  Halt(0);   // 自检是终结模式：通过后不再走渲染路径
end;

{ ---- M11：--init（生成项目骨架）---- }

procedure RunInit;
var
  opts: TXuiScaffoldOptions;
  res: TXuiScaffoldResult;
  i, appFiles: Integer;
  target: string;
begin
  opts.TargetDir := Opt.InitDir;
  opts.Name := Opt.InitName;
  opts.Width := 0;
  opts.Height := 0;
  opts.Theme := '';
  if Opt.WidthGiven then
    opts.Width := Opt.Width;
  if Opt.HeightGiven then
    opts.Height := Opt.Height;
  if Opt.ThemeGiven then
    opts.Theme := Opt.Theme;
  opts.LuiVersion := AppVersion;
  opts.RendererPath := '';      // 由脚手架取 ParamStr(0)
  opts.Force := Opt.Force;
  opts.Verbose := Opt.Verbose;

  if not XuiScaffoldCreate(opts, res) then
  begin
    LogLn('[错误] ' + res.Error);
    res.Files.Free;
    res.Skipped.Free;
    Halt(1);
  end;

  target := ExpandFileName(Opt.InitDir);
  appFiles := res.Files.Count - res.UiFiles;
  if Opt.JsonOut then
    ConWriteLn(Format('{"mode": "init", "target": "%s", "created": %d, "uiFiles": %d, "skipped": %d}',
      [JsonEscape(StringReplace(target, '\', '/', [rfReplaceAll])), res.Files.Count,
       res.UiFiles, res.Skipped.Count]))
  else
  begin
    LogLn(Format('[完成] 工程已生成: %s', [target]));
    if Opt.Verbose then
      for i := 0 to res.Files.Count - 1 do
        LogLn('  + ' + res.Files[i]);
    LogLn(Format('  工程文件 %d 个 + 组件库运行时 %d 个文件', [appFiles, res.UiFiles]));
    if res.Skipped.Count > 0 then
      LogLn(Format('  （已存在而保留 %d 个文件；如需覆盖加 --force）', [res.Skipped.Count]));
    LogLn;
    LogLn('下一步:');
    LogLn('  cd ' + Opt.InitDir);
    LogLn('  run-dev.cmd      开发预览（F5 刷新 / T 切主题 / Esc 退出）');
    LogLn('  run-test.cmd     自检 + 双主题出图到 out\\');
    LogLn('  run-pack.cmd     打包成 dist\\ 交付目录');
  end;

  res.Files.Free;
  res.Skipped.Free;
end;

{ ---- M11：--pack（组装交付目录）---- }

{ 目录顶层条目数（判定"非空"，用于要求 --force） }
function TopLevelEntries(const ADir: string): Integer;
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

{ 交付目录布局（与 npm run pack 的 dist/lui/ 同构，便于共用文档与心智）：
    <目标>/app.exe            渲染器副本
    <目标>/ui/                组件库运行时（工程自带的那份）
    <目标>/pages/             页面及其关联资源（含 assets/，保持相对引用成立）
    <目标>/README.txt         交付说明
    <目标>/preview-*.png      预览图（可选，-t 决定）
  三处路径解析同时成立（见 src/ui/xui_app.FindRepoRoot 与引擎的关联样式发现）：
    ① ui/ 与 pages/ 是 app.exe 的子目录 → 从 exe 目录向上能找到 ui/index.ts
    ② cd pages 后运行 ..\app.exe → 从当前目录向上也能找到（页面同级没有 ui/ 时回退上一层）
    ③ <include>/<script>/同名 css 全部是 pages/ 内的相对引用 }
procedure RunPack;
var
  stage, pagesDir, uiSrc, exeSrc, exeName, readme, preview, SingleTheme: string;
  app: TXuiApp;
  basedir: string;
  deps: TStringList;
  i: Integer;
  rel: string;

  procedure CopyTree(const ASrc, ADest: string; ARecurse: Boolean);
  var
    sr: TSearchRec;
    src, dest: string;
  begin
    if not DirectoryExists(ASrc) then
      Exit;
    if not ForceDirectories(ADest) then
    begin
      LogLn('[错误] 无法创建目录: ' + ADest);
      Halt(1);
    end;
    if FindFirst(IncludeTrailingPathDelimiter(ASrc) + '*', faAnyFile, sr) <> 0 then
      Exit;
    try
      repeat
        if (sr.Name = '') or (sr.Name[1] = '.') then
          Continue;
        src := IncludeTrailingPathDelimiter(ASrc) + sr.Name;
        dest := IncludeTrailingPathDelimiter(ADest) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
        begin
          if ARecurse then
            CopyTree(src, dest, ARecurse);
        end
        else if not CopyFile(src, dest) then
        begin
          LogLn('[错误] 复制失败: ' + src);
          Halt(1);
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

  procedure CopyFileOrDie(const ASrc, ADest: string);
  begin
    if not ForceDirectories(ExtractFilePath(ADest)) then
    begin
      LogLn('[错误] 无法创建目录: ' + ExtractFilePath(ADest));
      Halt(1);
    end;
    if not CopyFile(ASrc, ADest) then
    begin
      LogLn('[错误] 复制失败: ' + ASrc + ' → ' + ADest);
      Halt(1);
    end;
  end;

begin
  stage := ExcludeTrailingPathDelimiter(Opt.PackDir);
  pagesDir := IncludeTrailingPathDelimiter(stage) + 'pages';
  exeSrc := ExpandFileName(ParamStr(0));
  exeName := ExtractFileName(exeSrc);
  SingleTheme := Opt.Theme;
  if SingleTheme = 'both' then
    SingleTheme := 'light';   // 单文件 -o 一次只出一张，说明里的示例用浅色档

  // 1) 目标目录：不存在则创建；非空时需要 --force 才清空重建
  //    （--pack 的语义是"重建交付物"，所以会删；但删除必须是用户显式要求的）
  if DirectoryExists(stage) and (TopLevelEntries(stage) > 0) then
  begin
    if not Opt.Force then
      ParamError(Format('交付目录已存在且非空: %s（加 --force 清空重建，或换一个 -O/目录）',
        [ExpandFileName(stage)]));
    if not DeleteDirectory(stage, True) then
    begin
      LogLn('[错误] 无法清空目标目录: ' + stage);
      Halt(1);
    end;
  end;
  LogLn('[打包] 目标目录: ' + ExpandFileName(stage));

  // 2) 渲染器副本
  CopyFileOrDie(exeSrc, IncludeTrailingPathDelimiter(stage) + exeName);

  // 3) ui/ 运行时：优先用工程自己的那份（--init 生成的工程自带）；不在工程内时
  //    回落到渲染器所在仓库/内嵌的运行时（xui_app 的根目录发现已覆盖这两种情形）
  uiSrc := '';
  if DirectoryExists('ui') and FileExists('ui' + PathDelim + 'index.ts') then
    uiSrc := ExcludeTrailingPathDelimiter('ui')
  else
  begin
    app := TXuiApp.CreateOwned;
    try
      if app.Root <> '' then
        uiSrc := IncludeTrailingPathDelimiter(app.Root) + 'ui';
    finally
      app.Free;
    end;
  end;
  if (uiSrc = '') or (not FileExists(IncludeTrailingPathDelimiter(uiSrc) + 'index.ts')) then
  begin
    LogLn('[错误] 未找到组件库运行时 ui/（在工程根或渲染器所在仓库运行 --pack，或用单程序版）');
    Halt(1);
  end;
  CopyTree(uiSrc, IncludeTrailingPathDelimiter(stage) + 'ui', True);
  LogLn('[打包] ui/ 运行时 ← ' + ExpandFileName(uiSrc));

  // 4) 页面及其关联资源（与 --add-page 同一份发现规则）→ pages/，保持相对引用
  deps := TStringList.Create;
  try
    for i := 0 to Opt.Inputs.Count - 1 do
    begin
      if not CollectPageDeps(Opt.Inputs[i], basedir, deps) then
      begin
        LogLn('[错误] 页面文件不存在: ' + Opt.Inputs[i]);
        Halt(1);
      end;
    end;
    for i := 0 to deps.Count - 1 do
    begin
      rel := StringReplace(deps[i], '/', PathDelim, [rfReplaceAll]);
      CopyFileOrDie(basedir + PathDelim + rel, pagesDir + PathDelim + rel);
    end;
    // 页面用到的资产目录（<svg src="assets/x.svg"> 一类）整树带上
    if DirectoryExists(basedir + PathDelim + 'assets') then
      CopyTree(basedir + PathDelim + 'assets', pagesDir + PathDelim + 'assets', True);
  finally
    deps.Free;
  end;
  LogLn(Format('[打包] pages/: %d 个页面及其关联资源', [Opt.Inputs.Count]));
  if Opt.Verbose then
    for i := 0 to deps.Count - 1 do
      LogLn('  + pages/' + deps[i]);

  // 5) 预览图（用户在 CLI 里 -t 给的主题；both 出两张）
  if Opt.Theme = 'both' then
  begin
    preview := IncludeTrailingPathDelimiter(stage) + 'preview-light.png';
    if not RenderOne(Opt.Inputs[0], preview, Opt.Width, Opt.Height, 'light', Opt.ExtraCss,
      False) then
      Halt(1);
    preview := IncludeTrailingPathDelimiter(stage) + 'preview-dark.png';
    if not RenderOne(Opt.Inputs[0], preview, Opt.Width, Opt.Height, 'dark', Opt.ExtraCss,
      False) then
      Halt(1);
  end
  else
  begin
    preview := IncludeTrailingPathDelimiter(stage) + 'preview-' + Opt.Theme + '.png';
    if not RenderOne(Opt.Inputs[0], preview, Opt.Width, Opt.Height, Opt.Theme, Opt.ExtraCss,
      False) then
      Halt(1);
  end;

  // 6) 交付说明（单文件 -o 一次只出一张图，示例用具体主题而非 both）
  readme := Format(
    'lui 应用交付包'#13#10 +
    '================'#13#10#13#10 +
    '入口页面: %s'#13#10 +
    '视口: %dx%d    主题: %s'#13#10 +
    '渲染器: lui-render v%s'#13#10#13#10 +
    '运行（务必先 cd pages，页面按相对路径引用 ../ui 与同目录资源）：'#13#10 +
    '  cd pages'#13#10 +
    '  ..\%s %s -o out.png -t %s -w %d -H %d   出图'#13#10 +
    '  ..\%s %s -t %s --watch                  预览窗口（F5 刷新 / T 切主题 / Esc 退出）'#13#10 +
    '  ..\%s --help                            完整选项'#13#10#13#10 +
    '目录:'#13#10 +
    '  pages\        页面与关联资源（xml/css/ts/include/assets）'#13#10 +
    '  ui\           组件库运行时（页面里的 ../ui/index.ts 指向它）'#13#10 +
    '  preview-*.png 预览图'#13#10,
    [ExtractFileName(Opt.Inputs[0]), Opt.Width, Opt.Height, Opt.Theme, AppVersion,
     exeName, ExtractFileName(Opt.Inputs[0]), SingleTheme, Opt.Width, Opt.Height,
     exeName, ExtractFileName(Opt.Inputs[0]), SingleTheme,
     exeName]);
  with TStringList.Create do
  try
    Text := readme;
    SaveToFile(IncludeTrailingPathDelimiter(stage) + 'README.txt');
  finally
    Free;
  end;

  LogLn('[完成] 交付目录已就绪: ' + ExpandFileName(stage));
end;

// 输出文件名推断（批量模式）：输出目录 + 输入主名 [-主题].png
function BatchOutputName(const AOutDir, AInputFile, ATheme: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AOutDir) +
    ChangeFileExt(ExtractFileName(AInputFile), '') + '-' + ATheme + '.png';
end;

{ 批量执行：遍历输入 × 主题，逐项渲染并汇总结果（ADR 32 退出码分级） }
procedure RunBatch;
var
  themes: array of string;
  i, t, fails, total: Integer;
  inp, outName: string;
  itemsJson: string;
begin
  if Opt.Theme = 'both' then
  begin
    SetLength(themes, 2);
    themes[0] := 'light';
    themes[1] := 'dark';
  end
  else
  begin
    SetLength(themes, 1);
    themes[0] := Opt.Theme;
  end;

  total := 0;
  fails := 0;
  itemsJson := '';
  for i := 0 to Opt.Inputs.Count - 1 do
  begin
    inp := Opt.Inputs[i];
    for t := Low(themes) to High(themes) do
    begin
      outName := BatchOutputName(Opt.OutDir, inp, themes[t]);
      Inc(total);
      // 分隔符按"已输出的条目数"决定，不能按输入下标：一条输入会产出多个条目
      // （--theme both 出两份），按下标算会让中间条目丢掉逗号、JSON 非法（曾经如此）
      if Opt.JsonOut and (itemsJson <> '') then
        itemsJson := itemsJson + ',' + LineEnding;
      if RenderOne(inp, outName, Opt.Width, Opt.Height, themes[t],
        Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut)) then
      begin
        if Opt.JsonOut then
          itemsJson := itemsJson + Format(
            '  {"input": "%s", "output": "%s", "theme": "%s", "ok": true}',
            [JsonEscape(inp), JsonEscape(StringReplace(outName, '\', '/', [rfReplaceAll])),
             themes[t]]);
      end
      else
      begin
        Inc(fails);
        if Opt.JsonOut then
          itemsJson := itemsJson + Format(
            '  {"input": "%s", "theme": "%s", "ok": false}',
            [JsonEscape(inp), themes[t]]);
      end;
    end;
  end;

  if Opt.JsonOut then
    ConWriteLn('{"total": ' + IntToStr(total) + ', "failed": ' + IntToStr(fails) +
      ', "items": [' + LineEnding + itemsJson + LineEnding + ']}');

  if fails > 0 then
    Halt(3);   // 批量部分失败（ADR 32 退出码 3）
end;

{ GUI 模式交互查看窗体 }
type
  TRenderViewerForm = class(TForm)
  private
    FHost: TXuiHost;
    FApp: TXuiApp;
    FTheme: string;
    FInputFile: string;
    FExtraCss: string;
    FWatch: Boolean;
    FWatchTimer: TTimer;
    FLastMTime: LongInt;
    procedure DestroyAll;
    procedure InitHost;
    procedure HandleWatchTimer(Sender: TObject);
    procedure DoReload;
    procedure ToggleTheme;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateViewer(const AFile: string; AWidth, AHeight: Integer;
      const ATheme, AExtraCss: string; AWatch: Boolean);
    destructor Destroy; override;
  end;

constructor TRenderViewerForm.CreateViewer(const AFile: string; AWidth, AHeight: Integer;
  const ATheme, AExtraCss: string; AWatch: Boolean);
begin
  inherited CreateNew(nil);
  FInputFile := AFile;
  FTheme := ATheme;
  FExtraCss := AExtraCss;
  FWatch := AWatch;
  Caption := Format('lui 渲染器预览 — %s [%s] (F5: 刷新, T: 切换主题)', [ExtractFileName(AFile), FTheme]);
  ClientWidth := AWidth;
  ClientHeight := AHeight;
  Position := poScreenCenter;
  KeyPreview := True;

  InitHost;

  if AWatch then
  begin
    FLastMTime := FileAge(FInputFile);
    FWatchTimer := TTimer.Create(Self);
    FWatchTimer.Interval := 250;
    FWatchTimer.OnTimer := @HandleWatchTimer;
    FWatchTimer.Enabled := True;
  end;
end;

destructor TRenderViewerForm.Destroy;
begin
  DestroyAll;
  inherited Destroy;
end;

procedure TRenderViewerForm.DestroyAll;
begin
  // TXuiApp 以附着模式引用宿主引擎/脚本；先释放门面再释放宿主（级联释放引擎）
  FreeAndNil(FApp);
  FreeAndNil(FHost);
end;

procedure TRenderViewerForm.InitHost;
begin
  if FHost = nil then
  begin
    FHost := TXuiHost.Create(Self);   // TXuiHost 自建并拥有 Engine/Script/Bridge
    // 必须挂到窗体上：TXuiHost.Create 不设 Parent，漏掉这行宿主就不在窗体的控件树里，
    // 客户区永远是空白（窗口出来了、引擎也装配了，就是没有任何像素被画上去）。
    // demo1 一直有这行；渲染器的预览窗漏了它——由 run-dev.cmd 的实测暴露。
    FHost.Parent := Self;
  end;
  FHost.Align := alClient;

  if FApp = nil then
    FApp := TXuiApp.CreateAttached(FHost.Engine, FHost.Script);

  // M9：装配统一走门面（复位样式表 → 组件库主题 → ui/index.ts → 关联 CSS → 文档）
  FApp.Configure(FInputFile, FTheme, FExtraCss);

  // M11：预览窗开启引擎自带的依赖热重载——XML/include、<script src>、关联 CSS 与
  // ui/theme/*.css 变化都会就地重载（仅 CSS 变化时保留 DOM 与运行时状态）。
  // 原来只轮询输入文件自身的时间戳，改样式/脚本不生效（P4 遗留）。
  FHost.Engine.HotReload := FWatch;

  FHost.Invalidate;
end;

procedure TRenderViewerForm.DoReload;
begin
  DestroyAll;          // 销毁重建：根治样式与组件库脚本的累积
  InitHost;
  FHost.Invalidate;
  LogLn(Format('[热重载] 文件已更新并重新载入: %s', [TimeToStr(Now)]));
end;

procedure TRenderViewerForm.ToggleTheme;
begin
  if FTheme = 'light' then
    FTheme := 'dark'
  else
    FTheme := 'light';
  Caption := Format('lui 渲染器预览 — %s [%s] (F5: 刷新, T: 切换主题)', [ExtractFileName(FInputFile), FTheme]);
  DestroyAll;
  InitHost;
end;

procedure TRenderViewerForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = VK_F5 then
  begin
    DoReload;
    Key := 0;
  end
  else if (Key = VK_T) and (Shift = []) then
  begin
    ToggleTheme;
    Key := 0;
  end
  else if Key = VK_ESCAPE then
  begin
    Close;
    Key := 0;
  end;
end;

procedure TRenderViewerForm.HandleWatchTimer(Sender: TObject);
var
  currMTime: LongInt;
begin
  // M11：引擎自带的热重载已覆盖 XML/include/脚本/关联 CSS（含 ui/theme）。
  // 这里只补引擎监测不到的一种情况：输入文件本身曾不存在（引擎没记进监测表）。
  if FApp = nil then
    Exit;
  currMTime := FileAge(FInputFile);
  if (currMTime <> -1) and (currMTime <> FLastMTime) then
  begin
    FLastMTime := currMTime;
    if FApp.Engine.Document = nil then
      DoReload;
  end;
end;

{ --watch（CLI）：按固定间隔重跑整轮导出，但只在"确实变了"时重导出。
  变化判定沿用引擎的依赖监测（XML/include/脚本/关联 CSS + ui/theme）——
  比只比对输入文件时间戳更准（改 CSS 或 <script src> 也能触发，见 M11 修复）。
  每轮重建 TXuiApp：样式表与组件库脚本的装配是复位式的，不会累积。 }
procedure WatchLoop(const AInputFile: string);
var
  app: TXuiApp;
  bmp: TBitmap;
  rect: TRect;
  changed: Boolean;
begin
  LogLn('[监听] 已开启文件监听模式，按 Ctrl+C 退出...');
  while True do
  begin
    Sleep(300);
    // 用一个轻量引擎实例做"依赖时间戳比对"（不绘制）；变化则整轮重导出
    app := TXuiApp.CreateOwned;
    bmp := TBitmap.Create;
    try
      bmp.SetSize(8, 8);
      app.Engine.Renderer := NewOffscreenRenderer(bmp.Canvas);
      app.ConfigureStyles(Opt.Theme, Opt.ExtraCss, AInputFile);
      app.LoadDocument(AInputFile);
      rect := Types.Rect(0, 0, 8, 8);
      app.Engine.Draw(bmp.Canvas, rect);
      changed := app.Engine.ReloadChangedFiles;
    finally
      bmp.Free;
      app.Free;
    end;
    if not changed then
      Continue;

    LogLn(Format('[变更检测] 依赖文件发生改动，重新导出: %s', [TimeToStr(Now)]));
    if (Opt.Inputs.Count = 1) and (Opt.OutputFile <> '') then
      RenderOne(Opt.Inputs[0], Opt.OutputFile, Opt.Width, Opt.Height,
        Opt.Theme, Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut))
    else
      RunBatch;
  end;
end;

{ 主执行流程 }
var
  viewer: TRenderViewerForm;

begin
  // 控制台就绪：Windows 上切输出码页让中文正常显示（失败静默）。
  // 之后所有输出走 ConWriteLn：目标不可写时不再抛异常（否则诊断输出失败会让工具崩溃）
  XuiConsoleInit;

  if not ParseCommandLine then
    Halt(1);

  // ---- M11 项目工具链模式（立即执行后退出）----
  if Opt.InitDir <> '' then
  begin
    RunInit;      // 失败时内部 Halt(1)
    Halt(0);
  end;
  if Opt.PackDir <> '' then
  begin
    if Opt.Inputs.Count = 0 then
      ParamError('--pack 需要至少一个输入页面');
    RunPack;      // 失败时内部 Halt(1)
    Halt(0);
  end;

  if Opt.Check then
    RunCheck;

  if Opt.IsCliMode then
  begin
    if Opt.Watch then
    begin
      // --watch：先出一次图，再监听变更重跑
      if (Opt.Inputs.Count = 1) and (Opt.OutputFile <> '') then
        RenderOne(Opt.Inputs[0], Opt.OutputFile, Opt.Width, Opt.Height,
          Opt.Theme, Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut))
      else
        RunBatch;
      LogLn('[监听] 已开启文件监听模式，按 Ctrl+C 退出...');
      WatchLoop(Opt.Inputs[0]);
    end
    else if (Opt.Inputs.Count = 1) and (Opt.OutputFile <> '') then
    begin
      if not RenderOne(Opt.Inputs[0], Opt.OutputFile, Opt.Width, Opt.Height,
        Opt.Theme, Opt.ExtraCss, Opt.Verbose) then
        Halt(1);
    end
    else
      RunBatch;
  end
  else
  begin
    // GUI 模式：窗口预览与交互（单输入；--theme both 预览按浅色档）
    if Opt.Theme = 'both' then
      Opt.Theme := 'light';
    Application.Initialize;
    viewer := TRenderViewerForm.CreateViewer(Opt.Inputs[0], Opt.Width, Opt.Height,
      Opt.Theme, Opt.ExtraCss, Opt.Watch);
    viewer.Show;
    Application.Run;
  end;
end.
