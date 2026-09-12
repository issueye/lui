program lui_render;

{$mode objfpc}{$H+}

{ lui 独立渲染器程序 (lui-render) — M9
  兼具 CLI 离线导出与 GUI 实时交互查看功能。

  零外部第三方依赖：使用 Free Pascal RTL + LazUtils + LCL + GDI/GDI+。

  M9-P0（本版，ADR 30–33）：
  - CLI 规范收敛：-h 独占帮助；视口高度用 -H/--height；未知参数报错（退出码 2）
  - --version 输出版本；-o 输出目录不存在时自动创建
  - SetupEngine 复位样式表；GUI 热重载/切主题销毁重建宿主
    （修复重复重载时样式表与组件库脚本累积的缺陷） }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Controls, ExtCtrls, Graphics, LCLType,
  Classes, SysUtils, Types, Math, StrUtils,
  xui_types, xui_style, xui_dom, xui_xml, xui_layout, xui_render,
  xui_css_parser, xui_css_match, xui_engine, xui_events, xui_widget,
  xui_input, xui_svg, xui_script, xui_script_dom, xui_script_bind,
  {$IFDEF WINDOWS}xui_render_gdiplus,{$ENDIF}
  xui_host;

const
  AppVersion = '0.9.0';

type
  { CLI / GUI 运行时配置参数 }
  TRenderOptions = record
    InputFile: string;
    OutputFile: string;
    Width: Integer;
    Height: Integer;
    Theme: string;       // 'light' 或 'dark'
    ExtraCss: string;
    Watch: Boolean;
    Verbose: Boolean;
    IsCliMode: Boolean;
  end;

var
  Opt: TRenderOptions;

procedure PrintUsage;
begin
  WriteLn('lui 渲染器程序 (lui-render) v' + AppVersion);
  WriteLn('用法: lui-render <输入文件.xml|svg> [选项]');
  WriteLn;
  WriteLn('选项:');
  WriteLn('  -o, --output <文件.png>   离线渲染导出为 PNG 图片 (CLI 模式；目录不存在会自动创建)');
  WriteLn('  -w, --width <像素>        视口宽度 (默认 800)');
  WriteLn('  -H, --height <像素>       视口高度 (默认 600)');
  WriteLn('  -t, --theme <light|dark>  界面主题风格 (默认 light)');
  WriteLn('  -c, --css <样式文件>      附加加载的自定义 CSS 样式文件');
  WriteLn('  --watch                   监听输入文件变更并自动热重载');
  WriteLn('  -v, --verbose             输出详细过程日志');
  WriteLn('  -V, --version             输出版本号');
  WriteLn('  -?, --help                显示此帮助说明');
  WriteLn;
  WriteLn('快捷键 (GUI 模式):');
  WriteLn('  F5                        重新加载并刷新渲染');
  WriteLn('  T                         切换浅色 / 深色主题');
  WriteLn('  Esc                       退出程序');
end;

// 参数错误：退出码 2（区别于渲染失败的 1）
procedure ParamError(const AMsg: string);
begin
  WriteLn('参数错误: ' + AMsg);
  WriteLn('使用 --help 查看用法。');
  Halt(2);
end;

function ParseCommandLine: Boolean;
var
  i: Integer;
  arg: string;

  procedure NeedValue(const AOpt: string; out AVal: string);
  begin
    Inc(i);
    if i > ParamCount then
      ParamError('选项 ' + AOpt + ' 缺少参数值');
    AVal := ParamStr(i);
  end;

begin
  Result := True;
  Opt.InputFile := '';
  Opt.OutputFile := '';
  Opt.Width := 800;
  Opt.Height := 600;
  Opt.Theme := 'light';
  Opt.ExtraCss := '';
  Opt.Watch := False;
  Opt.Verbose := False;
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
      WriteLn('lui-render v' + AppVersion);
      Halt(0);
    end
    else if (arg = '-o') or (arg = '--output') then
      NeedValue('-o/--output', Opt.OutputFile)
    else if (arg = '-w') or (arg = '--width') then
    begin
      NeedValue('-w/--width', arg);
      Opt.Width := StrToIntDef(arg, -1);
      if Opt.Width <= 0 then
        ParamError('视口宽度必须是正整数: ' + arg);
    end
    else if (arg = '-H') or (arg = '--height') then
    begin
      NeedValue('-H/--height', arg);
      Opt.Height := StrToIntDef(arg, -1);
      if Opt.Height <= 0 then
        ParamError('视口高度必须是正整数: ' + arg);
    end
    else if (arg = '-t') or (arg = '--theme') then
    begin
      NeedValue('-t/--theme', arg);
      Opt.Theme := LowerCase(arg);
      if (Opt.Theme <> 'light') and (Opt.Theme <> 'dark') then
        ParamError('主题只能是 light 或 dark: ' + arg);
    end
    else if (arg = '-c') or (arg = '--css') then
      NeedValue('-c/--css', Opt.ExtraCss)
    else if arg = '--watch' then
      Opt.Watch := True
    else if (arg = '-v') or (arg = '--verbose') then
      Opt.Verbose := True
    else if (Copy(arg, 1, 1) = '-') and (arg <> '-') then
      ParamError('未知选项: ' + arg)   // 未知参数报错（退出码 2），不再静默忽略
    else if Opt.InputFile = '' then
      Opt.InputFile := arg
    else
      ParamError('多余的位置参数: ' + arg);
    Inc(i);
  end;

  if Opt.InputFile = '' then
  begin
    WriteLn('错误: 未指定输入文件。');
    PrintUsage;
    Exit(False);
  end;

  if not FileExists(Opt.InputFile) then
  begin
    WriteLn(Format('错误: 输入文件不存在: "%s"', [Opt.InputFile]));
    Exit(False);
  end;

  Opt.IsCliMode := (Opt.OutputFile <> '');
end;

{ 寻找项目根目录与资源辅助 }
function FindRepoRoot: string;
var
  dir: string;

  function LooksLikeRoot(const ADir: string): Boolean;
  begin
    Result := DirectoryExists(ADir + PathDelim + 'ui') and
      FileExists(ADir + PathDelim + 'ui' + PathDelim + 'index.ts');
  end;

begin
  dir := GetCurrentDir;
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if LooksLikeRoot(dir) then
      Exit(dir);
    dir := ExtractFileDir(dir);
  end;
  dir := ExtractFilePath(ParamStr(0));
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if LooksLikeRoot(dir) then
      Exit(dir);
    dir := ExtractFileDir(dir);
  end;
  Result := '';
end;

{ 构建并初始化渲染环境。
  每次调用都会复位样式表（修复重复调用时样式与组件库脚本累积的缺陷）。 }
procedure SetupEngine(AEngine: TXuiEngine; AScript: TXuiScript; var ABride: TXuiDomBridge;
  const AInputFile: string; const ATheme: string; const AExtraCss: string);
var
  root, themePath, indexPath: string;
  ext: string;
  xmlContent: string;
begin
  root := FindRepoRoot;

  // 1. 初始化脚本与 DOM 桥
  if (AScript <> nil) and (ABride = nil) then
  begin
    ABride := TXuiDomBridge.Create(AEngine, AScript);
    ABride.Install;
    AEngine.AttachScript(AScript);
  end;

  // 2. 复位样式表：修复重载/切主题时样式累积（M9-P0 修复项）
  AEngine.ClearStyleSheets;

  // 3. 加载内置主题（深色模式在浅色基底上叠加覆盖 Token）
  if root <> '' then
  begin
    themePath := root + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css';
    if FileExists(themePath) then
      AEngine.LoadStyleSheetFromFile(themePath);

    if SameText(ATheme, 'dark') then
    begin
      themePath := root + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-dark.css';
      if FileExists(themePath) then
        AEngine.LoadStyleSheetFromFile(themePath);
    end;

    indexPath := root + PathDelim + 'ui' + PathDelim + 'index.ts';
    if (AScript <> nil) and FileExists(indexPath) then
    begin
      try
        AScript.RunFile(indexPath);
      except
        on E: Exception do
          WriteLn('警告: 组件库加载提示: ' + E.Message);
      end;
    end;
  end;

  // 4. 加载附加自定义 CSS 与智能关联样式
  if (AExtraCss <> '') and FileExists(AExtraCss) then
    AEngine.LoadStyleSheetFromFile(AExtraCss)
  else
  begin
    // 未指定附加 CSS 时，尝试检测输入文件同目录下的关联样式
    if FileExists(ChangeFileExt(AInputFile, '') + '-' + ATheme + '.css') then
      AEngine.LoadStyleSheetFromFile(ChangeFileExt(AInputFile, '') + '-' + ATheme + '.css')
    else if FileExists(ChangeFileExt(AInputFile, '') + '.css') then
      AEngine.LoadStyleSheetFromFile(ChangeFileExt(AInputFile, '') + '.css');

    if FileExists(ExtractFilePath(AInputFile) + 'nav-' + ATheme + '.css') then
      AEngine.LoadStyleSheetFromFile(ExtractFilePath(AInputFile) + 'nav-' + ATheme + '.css');
  end;

  // 5. 加载输入文档
  ext := LowerCase(ExtractFileExt(AInputFile));
  if ext = '.svg' then
  begin
    // 纯 SVG 文件：包裹为全视口展示窗口
    xmlContent := Format(
      '<window style="margin:0;padding:0;background-color:#ffffff;display:flex;justify-content:center;align-items:center;">' +
      '  <svg src="%s" width="100%%" height="100%%"/>' +
      '</window>', [AInputFile]);
    AEngine.LoadFromString(xmlContent);
  end
  else
  begin
    AEngine.LoadFromFile(AInputFile);
  end;
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
      WriteLn(Format('[错误] 无法创建输出目录: %s', [dir]));
      Result := False;
    end;
  end;
end;

{ 离线渲染导出为图片 }
function RenderToImage(const AInputFile, AOutputFile: string; AWidth, AHeight: Integer;
  const ATheme, AExtraCss: string; AVerbose: Boolean): Boolean;
var
  engine: TXuiEngine;
  script: TXuiScript;
  bridge: TXuiDomBridge;
  bmp: TBitmap;
  png: TPortableNetworkGraphic;
  renderer: TXuiCustomRenderer;
begin
  Result := False;
  if not EnsureOutputDir(AOutputFile) then
    Exit;
  engine := TXuiEngine.Create;
  script := TXuiScript.Create;
  bridge := nil;
  bmp := TBitmap.Create;
  png := TPortableNetworkGraphic.Create;
  try
    bmp.SetSize(AWidth, AHeight);
    bmp.Canvas.Brush.Color := clWhite;
    bmp.Canvas.FillRect(0, 0, AWidth, AHeight);

    // Windows 平台优先使用高质量 GDI+ 抗锯齿渲染后端
    {$IFDEF WINDOWS}
    if GdiPlusAvailable then
      renderer := TGdiPlusRenderer.Create(bmp.Canvas)
    else
      renderer := TGdiRenderer.Create(bmp.Canvas);
    {$ELSE}
    renderer := TGdiRenderer.Create(bmp.Canvas);
    {$ENDIF}

    engine.Renderer := renderer; // engine 拥有 renderer 实例
    SetupEngine(engine, script, bridge, AInputFile, ATheme, AExtraCss);

    if AVerbose then
      WriteLn(Format('[信息] 正在排版与渲染: %s (%dx%d, 主题: %s)...', [AInputFile, AWidth, AHeight, ATheme]));

    engine.Draw(bmp.Canvas, Types.Rect(0, 0, AWidth, AHeight));

    // 保存输出为 PNG 格式
    png.Assign(bmp);
    png.SaveToFile(AOutputFile);
    WriteLn(Format('[成功] 已渲染导出至: %s (%dx%d)', [AOutputFile, AWidth, AHeight]));
    Result := True;
  except
    on E: Exception do
      WriteLn(Format('[错误] 渲染失败: %s', [E.Message]));
  end;
  png.Free;
  bmp.Free;
  if bridge <> nil then bridge.Free;
  script.Free;
  engine.Free;
end;

{ GUI 模式交互查看窗体 }
type
  TRenderViewerForm = class(TForm)
  private
    FHost: TXuiHost;
    FScript: TXuiScript;
    FBridge: TXuiDomBridge;
    FTheme: string;
    FInputFile: string;
    FExtraCss: string;
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
  // TXuiHost 自建并拥有 Engine/内部 Script/Bridge；viewer 另持有配套 Script/Bridge。
  // 销毁顺序：先桥/脚本（引用 host 引擎），再宿主（级联释放引擎）。
  if FBridge <> nil then FBridge.Free;
  FBridge := nil;
  if FScript <> nil then FScript.Free;
  FScript := nil;
  FreeAndNil(FHost);
end;

procedure TRenderViewerForm.InitHost;
begin
  if FHost = nil then
    FHost := TXuiHost.Create(Self);
  FHost.Align := alClient;

  if FScript = nil then
    FScript := TXuiScript.Create;

  SetupEngine(FHost.Engine, FScript, FBridge, FInputFile, FTheme, FExtraCss);
  FHost.Invalidate;
end;

procedure TRenderViewerForm.DoReload;
begin
  DestroyAll;          // 销毁重建：根治样式与组件库脚本的累积
  InitHost;
  FHost.Invalidate;
  WriteLn(Format('[热重载] 文件已更新并重新载入: %s', [TimeToStr(Now)]));
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
  currMTime := FileAge(FInputFile);
  if (currMTime <> -1) and (currMTime <> FLastMTime) then
  begin
    FLastMTime := currMTime;
    DoReload;
  end;
end;

{ 主执行流程 }
var
  viewer: TRenderViewerForm;
  lastAge, curAge: LongInt;

begin
  if not ParseCommandLine then
    Halt(1);

  if Opt.IsCliMode then
  begin
    // CLI 模式：离线渲染并输出图片
    if not RenderToImage(Opt.InputFile, Opt.OutputFile, Opt.Width, Opt.Height,
      Opt.Theme, Opt.ExtraCss, Opt.Verbose) then
      Halt(1);

    if Opt.Watch then
    begin
      WriteLn('[监听] 已开启文件监听模式，按 Ctrl+C 退出...');
      lastAge := FileAge(Opt.InputFile);
      while True do
      begin
        Sleep(300);
        curAge := FileAge(Opt.InputFile);
        if (curAge <> -1) and (curAge <> lastAge) then
        begin
          lastAge := curAge;
          WriteLn(Format('[变更检测] %s 发生改动，重新导出...', [Opt.InputFile]));
          RenderToImage(Opt.InputFile, Opt.OutputFile, Opt.Width, Opt.Height,
            Opt.Theme, Opt.ExtraCss, Opt.Verbose);
        end;
      end;
    end;
  end
  else
  begin
    // GUI 模式：窗口预览与交互
    Application.Initialize;
    viewer := TRenderViewerForm.CreateViewer(Opt.InputFile, Opt.Width, Opt.Height,
      Opt.Theme, Opt.ExtraCss, Opt.Watch);
    viewer.Show;
    Application.Run;
  end;
end.
