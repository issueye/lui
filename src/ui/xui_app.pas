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
  xui_types, xui_dom, xui_engine, xui_script, xui_script_dom, xui_embed;

type
  TXuiApp = class
  private
    FEngine: TXuiEngine;
    FScript: TXuiScript;
    FBridge: TXuiDomBridge;
    FOwned: Boolean;         // true = 自建三件套并负责释放
    FRoot: string;           // 仓库根（ui/ 所在目录；空 = 未找到）
    FTheme: string;
    procedure FindRepoRoot;
  public
    constructor CreateOwned;
    constructor CreateAttached(AEngine: TXuiEngine; AScript: TXuiScript);
    destructor Destroy; override;
    // 复位并装配样式：组件库主题 + ui/index.ts + 关联/附加 CSS
    procedure ConfigureStyles(const ATheme, AExtraCss, AInputFile: string);
    // 装配样式并加载文档（等价 ConfigureStyles + Engine.LoadFromFile）
    procedure Configure(const AXmlFile, ATheme, AExtraCss: string);
    procedure LoadDocument(const AXmlFile: string);
    property Engine: TXuiEngine read FEngine;
    property Script: TXuiScript read FScript;
    property Root: string read FRoot;
  end;

implementation

procedure TXuiApp.FindRepoRoot;
var
  dir: string;

  function LooksLikeRoot(const ADir: string): Boolean;
  begin
    Result := DirectoryExists(ADir + PathDelim + 'ui') and
      FileExists(ADir + PathDelim + 'ui' + PathDelim + 'index.ts');
  end;

begin
  FRoot := '';
  dir := GetCurrentDir;
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if LooksLikeRoot(dir) then
    begin
      FRoot := dir;
      Exit;
    end;
    dir := ExtractFileDir(dir);
  end;
  dir := ExtractFilePath(ParamStr(0));
  while (dir <> '') and (Length(dir) > 3) do
  begin
    if LooksLikeRoot(dir) then
    begin
      FRoot := dir;
      Exit;
    end;
    dir := ExtractFileDir(dir);
  end;

  // 单程序分发（M9-P4）：磁盘上找不到 ui/ 时，回落到 exe 内嵌资源解包目录。
  // 顺序保证"外部文件优先"——仓库内开发始终用工作区里的活文件。
  dir := XuiEmbedRoot;
  if (dir <> '') and LooksLikeRoot(dir) then
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
end;

constructor TXuiApp.CreateAttached(AEngine: TXuiEngine; AScript: TXuiScript);
begin
  inherited Create;
  FOwned := False;
  FEngine := AEngine;
  FScript := AScript;
  FBridge := nil;   // 宿主（如 TXuiHost）已自建并 Install 桥
  FindRepoRoot;
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
begin
  FTheme := LowerCase(ATheme);
  dark := (FTheme = 'dark');

  // 复位：修复重复装配时样式表累积（M9-P2 修复项）
  FEngine.ClearStyleSheets;

  // 组件库主题：浅色基底 + 深色覆盖
  if FRoot <> '' then
  begin
    themePath := FRoot + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-light.css';
    if FileExists(themePath) then
      FEngine.LoadStyleSheetFromFile(themePath);
    if dark then
    begin
      themePath := FRoot + PathDelim + 'ui' + PathDelim + 'theme' + PathDelim + 'lui-dark.css';
      if FileExists(themePath) then
        FEngine.LoadStyleSheetFromFile(themePath);
    end;

    // 组件库入口：注册全部 ui-* 组件
    themePath := FRoot + PathDelim + 'ui' + PathDelim + 'index.ts';
    if FileExists(themePath) then
    begin
      try
        FScript.RunFile(themePath);
      except
        on E: Exception do ;
      end;
    end;
  end;

  // 页面关联 CSS：<同名>-<theme>.css 优先，其次 <同名>.css，再 nav-<theme>.css
  if AInputFile <> '' then
  begin
    themePath := ChangeFileExt(AInputFile, '') + '-' + ATheme + '.css';
    if FileExists(themePath) then
      FEngine.LoadStyleSheetFromFile(themePath)
    else
    begin
      themePath := ChangeFileExt(AInputFile, '') + '.css';
      if FileExists(themePath) then
        FEngine.LoadStyleSheetFromFile(themePath);
    end;
    themePath := ExtractFilePath(AInputFile) + 'nav-' + ATheme + '.css';
    if FileExists(themePath) then
      FEngine.LoadStyleSheetFromFile(themePath);
  end;

  // 附加 CSS（显式指定，最后加载）
  if (AExtraCss <> '') and FileExists(AExtraCss) then
    FEngine.LoadStyleSheetFromFile(AExtraCss);
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
