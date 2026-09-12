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
  - 装配统一走 xui_app 装配门面（复位样式表，重载不累积） }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Controls, ExtCtrls, Graphics, LCLType,
  Classes, SysUtils, Types, Math, StrUtils,
  xui_types, xui_style, xui_dom, xui_xml, xui_layout, xui_render,
  xui_css_parser, xui_css_match, xui_engine, xui_events, xui_widget,
  xui_input, xui_svg, xui_script, xui_script_dom, xui_script_bind, xui_app,
  {$IFDEF WINDOWS}xui_render_gdiplus,{$ENDIF}
  xui_host;

const
  AppVersion = '0.9.0';

type
  { CLI / GUI 运行时配置参数 }
  TRenderOptions = record
    Inputs: TStringList;     // 输入文件（可多个 = 批量）
    OutDir: string;          // --outdir（批量模式）
    OutputFile: string;      // -o（单文件模式）
    Width: Integer;
    Height: Integer;
    Theme: string;           // 'light' / 'dark' / 'both'
    ExtraCss: string;
    Watch: Boolean;
    Verbose: Boolean;
    Bench: Integer;          // --bench N：渲染后重复 N 次完整重排（性能基准）
    JsonOut: Boolean;        // --json：结果以 JSON 输出到 stdout
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

procedure PrintUsage;
begin
  WriteLn('lui 渲染器程序 (lui-render) v' + AppVersion);
  WriteLn('用法: lui-render <输入.xml|svg> [更多输入...] [选项]');
  WriteLn;
  WriteLn('选项:');
  WriteLn('  -o, --output <文件.png>   单文件输出（CLI 模式；目录不存在会自动创建）');
  WriteLn('  -O, --outdir <目录>       批量输出目录（与多个输入搭配使用）');
  WriteLn('  -w, --width <像素>        视口宽度 (默认 800)');
  WriteLn('  -H, --height <像素>       视口高度 (默认 600)');
  WriteLn('  -t, --theme <light|dark|both>  主题（both = 双主题各出一张）');
  WriteLn('  -c, --css <样式文件>      附加加载的自定义 CSS 样式文件');
  WriteLn('  --watch                   监听输入文件变更并自动重跑');
  WriteLn('  --bench <次数>            渲染后重复 N 次完整重排并输出耗时（性能基准）');
  WriteLn('  --json                    结果以 JSON 输出到 stdout（日志走 stderr）');
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

  procedure AddInput(const AFile: string);
  begin
    if not FileExists(AFile) then
    begin
      WriteLn(Format('错误: 输入文件不存在: "%s"', [AFile]));
      Halt(1);
    end;
    Opt.Inputs.Add(AFile);
  end;

begin
  Result := True;
  Opt.Inputs := TStringList.Create;
  Opt.OutDir := '';
  Opt.OutputFile := '';
  Opt.Width := 800;
  Opt.Height := 600;
  Opt.Theme := 'light';
  Opt.ExtraCss := '';
  Opt.Watch := False;
  Opt.Verbose := False;
  Opt.Bench := 0;
  Opt.JsonOut := False;
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
    else if (arg = '-O') or (arg = '--outdir') then
      NeedValue('-O/--outdir', Opt.OutDir)
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
      if (Opt.Theme <> 'light') and (Opt.Theme <> 'dark') and (Opt.Theme <> 'both') then
        ParamError('主题只能是 light、dark 或 both: ' + arg);
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
    else if arg = '--json' then
      Opt.JsonOut := True
    else if (arg = '-v') or (arg = '--verbose') then
      Opt.Verbose := True
    else if (Copy(arg, 1, 1) = '-') and (arg <> '-') then
      ParamError('未知选项: ' + arg)
    else
      AddInput(arg);
    Inc(i);
  end;

  if Opt.Inputs.Count = 0 then
  begin
    WriteLn('错误: 未指定输入文件。');
    PrintUsage;
    Exit(False);
  end;

  if (Opt.OutputFile <> '') and (Opt.Inputs.Count > 1) then
    ParamError('-o 只能与单个输入搭配；多输入请使用 -O/--outdir');

  Opt.IsCliMode := (Opt.OutputFile <> '') or (Opt.OutDir <> '') or (Opt.Inputs.Count > 1);
end;

{ 寻找项目根目录 }
function FindRepoRoot: string;
var
  dir: string;

  function LooksLikeRoot(const ADir: string): Boolean;
  begin
    Result := DirectoryExists(ADir + PathDelim + 'ui') and
      FileExists(ADir + PathDelim + 'ui' + PathDelim + 'index.ts');
  end;

begin
  Result := '';
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

{ 单页渲染：xui_app 装配（复位样式表 → 组件库主题 → ui/index.ts → 关联 CSS →
  加载文档）→ 排版 → 绘制 → PNG；Opt.Bench > 0 时追加 N 次完整重排并计时 }
function RenderOne(const AInputFile, AOutputFile: string; AWidth, AHeight: Integer;
  const ATheme, AExtraCss: string; AVerbose: Boolean): Boolean;
var
  app: TXuiApp;
  bmp: TBitmap;
  png: TPortableNetworkGraphic;
  renderer: TXuiCustomRenderer;
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

    // Windows 平台优先使用高质量 GDI+ 抗锯齿渲染后端
    {$IFDEF WINDOWS}
    if GdiPlusAvailable then
      renderer := TGdiPlusRenderer.Create(bmp.Canvas)
    else
      renderer := TGdiRenderer.Create(bmp.Canvas);
    {$ELSE}
    renderer := TGdiRenderer.Create(bmp.Canvas);
    {$ENDIF}

    app.Engine.Renderer := renderer; // engine 拥有 renderer 实例

    if AVerbose then
      WriteLn(Format('[信息] 正在排版与渲染: %s (%dx%d, 主题: %s)...', [AInputFile, AWidth, AHeight, ATheme]));

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
        app.Engine.InvalidateStyles;
        app.Engine.Draw(bmp.Canvas, viewRect);
        t1 := GetTickCount64;
        total := total + (t1 - t0);
      end;
      WriteLn(Format('[基准] %d 次完整重排: %d ms（平均 %.2f ms/次）',
        [Opt.Bench, total, total / Opt.Bench]));
    end;

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
  app.Free;
end;

// 输出文件名推断（批量模式）：输出目录 + 输入主名 [-主题].png
function BatchOutputName(const AOutDir, AInputFile, ATheme: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AOutDir) +
    ChangeFileExt(ExtractFileName(AInputFile), '') + '-' + ATheme + '.png';
end;

function IIf(const ACond: Boolean; const ATrue, AFalse: string): string;
begin
  if ACond then
    Result := ATrue
  else
    Result := AFalse;
end;

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(S, '\\', '\\\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\\\"', [rfReplaceAll]);
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
      if RenderOne(inp, outName, Opt.Width, Opt.Height, themes[t],
        Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut)) then
      begin
        if Opt.JsonOut then
          itemsJson := itemsJson + Format(
            '  {"input": "%s", "output": "%s", "theme": "%s", "ok": true}%s',
            [JsonEscape(inp), JsonEscape(StringReplace(outName, '\', '/', [rfReplaceAll])),
             themes[t], iif(i < Opt.Inputs.Count - 1, ',', '')]) + LineEnding;
      end
      else
      begin
        Inc(fails);
        if Opt.JsonOut then
          itemsJson := itemsJson + Format(
            '  {"input": "%s", "theme": "%s", "ok": false}%s',
            [JsonEscape(inp), themes[t], iif(i < Opt.Inputs.Count - 1, ',', '')]) + LineEnding;
      end;
    end;
  end;

  if Opt.JsonOut then
    WriteLn('{"total": ' + IntToStr(total) + ', "failed": ' + IntToStr(fails) +
      ', "items": [' + LineEnding + itemsJson + ']}');

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
  // TXuiApp 以附着模式引用宿主引擎/脚本；先释放门面再释放宿主（级联释放引擎）
  FreeAndNil(FApp);
  FreeAndNil(FHost);
end;

procedure TRenderViewerForm.InitHost;
begin
  if FHost = nil then
    FHost := TXuiHost.Create(Self);   // TXuiHost 自建并拥有 Engine/Script/Bridge
  FHost.Align := alClient;

  if FApp = nil then
    FApp := TXuiApp.CreateAttached(FHost.Engine, FHost.Script);

  // M9：装配统一走门面（复位样式表 → 组件库主题 → ui/index.ts → 关联 CSS → 文档）
  FApp.Configure(FInputFile, FTheme, FExtraCss);
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
    if Opt.Watch then
    begin
      // --watch：先出一次图，再监听变更重跑
      if (Opt.Inputs.Count = 1) and (Opt.OutputFile <> '') then
        RenderOne(Opt.Inputs[0], Opt.OutputFile, Opt.Width, Opt.Height,
          Opt.Theme, Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut))
      else
        RunBatch;
      WriteLn('[监听] 已开启文件监听模式，按 Ctrl+C 退出...');
      lastAge := FileAge(Opt.Inputs[0]);
      while True do
      begin
        Sleep(300);
        curAge := FileAge(Opt.Inputs[0]);
        if (curAge <> -1) and (curAge <> lastAge) then
        begin
          lastAge := curAge;
          WriteLn(Format('[变更检测] %s 发生改动，重新导出...', [Opt.Inputs[0]]));
          if (Opt.Inputs.Count = 1) and (Opt.OutputFile <> '') then
            RenderOne(Opt.Inputs[0], Opt.OutputFile, Opt.Width, Opt.Height,
              Opt.Theme, Opt.ExtraCss, Opt.Verbose and (not Opt.JsonOut))
          else
            RunBatch;
        end;
      end;
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
    // GUI 模式：窗口预览与交互（单输入）
    Application.Initialize;
    viewer := TRenderViewerForm.CreateViewer(Opt.Inputs[0], Opt.Width, Opt.Height,
      Opt.Theme, Opt.ExtraCss, Opt.Watch);
    viewer.Show;
    Application.Run;
  end;
end.
