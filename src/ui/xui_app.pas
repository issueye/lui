unit xui_app;

{$mode objfpc}{$H+}

{ 应用装配门面（M9，ADR 30）：把"主题样式 + 组件库 + 关联 CSS + 文档加载"的装配规则
  收敛到一处，供独立渲染器 (lui-render) 与演示应用 (demo1) 共用，消除双份维护。

  两种模式：
  - CreateOwned：自建 Engine/Script/Bridge（独立工具用）
  - CreateAttached：附着到既有 Engine/Script（TXuiHost 已自建三件套并 Install 桥）

  装配顺序（ConfigureStyles）：复位样式表 → 组件库主题（浅色基底，深色叠加覆盖）
  → 执行 ui/index.ts 注册组件 → 页面关联 CSS（<同名>-<theme>.css / <同名>.css /
  nav-<theme>.css）→ 附加 CSS。
  每次调用都会复位样式表，可安全重复调用（热重载 / 切主题不累积）。 }

interface

uses
  Classes, SysUtils,
  xui_types, xui_dom, xui_engine, xui_script, xui_script_dom, xui_embed, xui_appspec;

type
  TXuiApp = class
  private
    FEngine: TXuiEngine;
    FScript: TXuiScript;
    FBridge: TXuiDomBridge;
    FOwned: Boolean;         // true = 自建三件套并负责释放
    FRoot: string;           // 应用根（包含组件库目录；空 = 未找到）
    FUiDir: string;          // 组件库目录名（清单可改，默认 'ui'）
    FTheme: string;
    procedure FindRepoRoot;
  public
    constructor CreateOwned;
    constructor CreateAttached(AEngine: TXuiEngine; AScript: TXuiScript);
    destructor Destroy; override;
    // 让 ui.storage 真的落盘：按应用名放到用户配置目录（没有应用身份时不启用）
    procedure SetupStorage;
    // 复位并装配样式：组件库主题 + ui/index.ts + 关联/附加 CSS
    procedure ConfigureStyles(const ATheme, AExtraCss, AInputFile: string);
    // 装配样式并加载文档（等价 ConfigureStyles + Engine.LoadFromFile）
    procedure Configure(const AXmlFile, ATheme, AExtraCss: string);
    procedure LoadDocument(const AXmlFile: string);
    property Engine: TXuiEngine read FEngine;
    property Script: TXuiScript read FScript;
    property Root: string read FRoot;
    property UiDir: string read FUiDir;
  end;

implementation

procedure TXuiApp.FindRepoRoot;
var
  dir: string;
  spec: TXuiAppSpec;

  { FRoot 是"包含组件库目录的那个目录"，FUiDir 才是目录名（默认 'ui'）。 }
  function LooksLikeRoot(const ADir, AUi: string): Boolean;
  begin
    Result := (ADir <> '') and
      FileExists(IncludeTrailingPathDelimiter(ADir) + AUi + PathDelim + 'index.ts');
  end;

  function TryAccept(const ADir: string): Boolean;
  begin
    Result := False;
    if (ADir = '') or (not DirectoryExists(ADir)) then
      Exit;
    if LooksLikeRoot(ADir, 'ui') then
    begin
      FRoot := ADir;
      FUiDir := 'ui';
      Exit(True);
    end;
    // 清单允许把组件库放在别处（"ui": "vendor/lui-ui"）
    if XuiAppSpecAuto(ADir, spec) then
    begin
      try
        if FileExists(spec.UiIndex) then
        begin
          FRoot := ADir;
          FUiDir := spec.UiDir;
          Exit(True);
        end;
      finally
        spec.Free;
      end;
    end;
  end;

begin
  FRoot := '';
  FUiDir := 'ui';

  // M12（ADR 49）：应用根优先——自包含 exe 的挂载根 / CLI 显式指定的根 / 清单所在目录。
  // 排在最前，是为了让"应用"跑起来时不依赖当前工作目录（旧版正因为隐式依赖 CWD，
  // 交付目录必须 cd 进 pages/ 才能跑通）。
  if TryAccept(XuiAppRootOverride) then
    Exit;
  if (FRoot = '') and (XuiAppRootOverride <> '') and DirectoryExists(XuiAppRootOverride) then
    FRoot := XuiAppRootOverride;   // 覆盖根里没有组件库：仍认它作为资源根，组件库回落到后几档

  dir := GetCurrentDir;
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if TryAccept(dir) then
      Exit;
    dir := ExtractFileDir(dir);
  end;
  dir := ExtractFilePath(ParamStr(0));
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if TryAccept(dir) then
      Exit;
    dir := ExtractFileDir(dir);
  end;

  // 单程序分发（M9-P4）：磁盘上找不到 ui/ 时，回落到 exe 内嵌资源解包目录。
  // 顺序保证"外部文件优先"——仓库内开发始终用工作区里的活文件。
  dir := XuiEmbedRoot;
  if TryAccept(dir) then
    Exit;
  if (FRoot = '') and (dir <> '') then
    FRoot := dir;
end;

constructor TXuiApp.CreateOwned;
begin
  inherited Create;
  FOwned := True;
  FEngine := TXuiEngine.Create;
  FScript := TXuiScript.Create;
  FBridge := TXuiDomBridge.Create(FEngine, FScript);
  FBridge.Install;
  FEngine.AttachScript(FScript);
  FindRepoRoot;
  SetupStorage;
end;

constructor TXuiApp.CreateAttached(AEngine: TXuiEngine; AScript: TXuiScript);
begin
  inherited Create;
  FOwned := False;
  FEngine := AEngine;
  FScript := AScript;
  FBridge := nil;   // 宿主（如 TXuiHost）已自建并 Install 桥
  FindRepoRoot;
  SetupStorage;
end;

{ ui.storage 的落盘位置：%APPDATA% 下按应用名分目录。
  在这之前运行时从不配置 StorageFile，于是 ui.storage 的"持久化"对应用是假的——
  页面以为存住了，重启就没了。应用名取清单 name，退而取应用根目录名。 }
procedure TXuiApp.SetupStorage;
var
  name, dir: string;
  spec: TXuiAppSpec;
begin
  if FScript = nil then
    Exit;
  name := '';
  if FRoot <> '' then
  begin
    spec := TXuiAppSpec.Create;
    try
      if spec.Load(FRoot) then
        name := spec.Name;
    finally
      spec.Free;
    end;
    if name = '' then
      name := ExtractFileName(ExcludeTrailingPathDelimiter(FRoot));
  end;
  if name = '' then
    Exit;   // 没有应用身份时不落盘（避免写到莫名其妙的目录）
  dir := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + name;
  FScript.IO.StorageFile := IncludeTrailingPathDelimiter(dir) + 'storage.ini';
end;

destructor TXuiApp.Destroy;
begin
  if FOwned then
  begin
    FBridge.Free;
    FScript.Free;
    FEngine.Free;
  end;
  inherited Destroy;
end;

// 复位并装配样式。AInputFile 用于发现同目录的关联样式（可传空）。
procedure TXuiApp.ConfigureStyles(const ATheme, AExtraCss, AInputFile: string);
var
  themePath: string;
  dark: Boolean;
  i: Integer;
  spec: TXuiAppSpec;
  Loaded: TStringList;
begin
  Loaded := TStringList.Create;
  try
  FTheme := LowerCase(ATheme);
  dark := (FTheme = 'dark');

  // 把当前主题暴露给脚本（ui.theme）：页面自己做"主题类切换"时必须知道运行时用的是哪一档，
  // 否则 CLI 的 -t dark / 清单里的 window.theme 会和页面自己的初始值各说一套（两份真相）。
  if FScript <> nil then
  begin
    if dark then
      FScript.RegisterValue('ui.theme', FScript.Str('dark'))
    else
      FScript.RegisterValue('ui.theme', FScript.Str('light'));
  end;

  // 复位：修复重复装配时样式表累积（M9-P2 修复项）
  FEngine.ClearStyleSheets;

  // 组件库主题：浅色基底 + 深色覆盖
  if FRoot <> '' then
  begin
    themePath := FRoot + PathDelim + FUiDir + PathDelim + 'theme' + PathDelim + 'lui-light.css';
    if FileExists(themePath) then
    begin
      FEngine.LoadStyleSheetFromFile(themePath);
      Loaded.Add(ExpandFileName(themePath));
    end;
    if dark then
    begin
      themePath := FRoot + PathDelim + FUiDir + PathDelim + 'theme' + PathDelim + 'lui-dark.css';
      if FileExists(themePath) then
      begin
        FEngine.LoadStyleSheetFromFile(themePath);
        Loaded.Add(ExpandFileName(themePath));
      end;
    end;

    // 组件库入口：注册全部 ui-* 组件
    themePath := FRoot + PathDelim + FUiDir + PathDelim + 'index.ts';
    if FileExists(themePath) then
    begin
      try
        FScript.RunFile(themePath);
      except
        on E: Exception do ;
      end;
    end;
  end;

  // 清单声明的附加样式（与主题无关，无条件加载；M12）：给"多页共用一份基础样式"
  // 一个显式的挂法，不必依赖 <页面名>.css 的同名约定。已按同名约定加载过的跳过，
  // 避免同一份样式进两次（规则重复虽不改结果，但会让级联调试多一层噪声）。
  if XuiAppRootOverride <> '' then
  begin
    spec := TXuiAppSpec.Create;
    try
      if spec.Load(XuiAppRootOverride) then
        for i := 0 to spec.Styles.Count - 1 do
        begin
          themePath := spec.PathOf(spec.Styles[i]);
          if FileExists(themePath) and (Loaded.IndexOf(ExpandFileName(themePath)) < 0) then
          begin
            FEngine.LoadStyleSheetFromFile(themePath);
            Loaded.Add(ExpandFileName(themePath));
          end;
        end;
    finally
      spec.Free;
    end;
  end;

  // 页面关联 CSS：<同名>-<theme>.css 优先，其次 <同名>.css，再 nav-<theme>.css
  if AInputFile <> '' then
  begin
    themePath := ChangeFileExt(AInputFile, '') + '-' + ATheme + '.css';
    if FileExists(themePath) then
    begin
      FEngine.LoadStyleSheetFromFile(themePath);
      Loaded.Add(ExpandFileName(themePath));
    end
    else
    begin
      themePath := ChangeFileExt(AInputFile, '') + '.css';
      if FileExists(themePath) then
      begin
        FEngine.LoadStyleSheetFromFile(themePath);
        Loaded.Add(ExpandFileName(themePath));
      end;
    end;
    themePath := ExtractFilePath(AInputFile) + 'nav-' + ATheme + '.css';
    if FileExists(themePath) then
    begin
      FEngine.LoadStyleSheetFromFile(themePath);
      Loaded.Add(ExpandFileName(themePath));
    end;
  end;

  // 附加 CSS（显式指定，最后加载）
  if (AExtraCss <> '') and FileExists(AExtraCss) then
    FEngine.LoadStyleSheetFromFile(AExtraCss);

  finally
    Loaded.Free;
  end;
end;

procedure TXuiApp.LoadDocument(const AXmlFile: string);
begin
  FEngine.LoadFromFile(AXmlFile);
end;

procedure TXuiApp.Configure(const AXmlFile, ATheme, AExtraCss: string);
begin
  ConfigureStyles(ATheme, AExtraCss, AXmlFile);
  LoadDocument(AXmlFile);
end;

end.
