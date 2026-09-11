program demo1;

{$mode objfpc}{$H+}

{ lui M2 演示：加载 login.xml + CSS 主题，在 TXuiHost 上自绘登录卡片。
  点击窗口在浅色/深色主题间切换（同一 XML，仅换 CSS）。

  代码直接创建窗体，不使用 .lfm。 }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, Forms, SysUtils, Classes, Controls,
  xui_host;

type
  TDemoApp = class
  private
    FDark: Boolean;
    FBasePath: string;
    procedure HostClick(Sender: TObject);
  public
    constructor Create;
    property BasePath: string read FBasePath write FBasePath;
  end;

var
  Form: TForm;
  Host: TXuiHost;
  Demo: TDemoApp;

  function FindFile(const AName: string): string;
  begin
    Result := AName;
    if FileExists(Result) then Exit;
    Result := ExtractFilePath(ParamStr(0)) + AName;
    if FileExists(Result) then Exit;
    Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + AName;
  end;

{ TDemoApp }

constructor TDemoApp.Create;
begin
  inherited Create;
  FDark := False;
end;

procedure TDemoApp.HostClick(Sender: TObject);
begin
  FDark := not FDark;
  if FDark then
    Host.Engine.LoadStyleSheetFromFile(FindFile('login-dark.css'))
  else
    Host.Engine.LoadStyleSheetFromFile(FindFile('login-light.css'));
  Host.Invalidate;
end;

begin
  RequireDerivedFormResource := False;
  Application.Title := 'lui demo1';
  Application.Initialize;

  Demo := TDemoApp.Create;
  Demo.BasePath := ExtractFilePath(ParamStr(0));

  Form := TForm.Create(Application);
  Form.Caption := 'lui demo1 - M2：点击窗口换肤（浅/深主题）';
  Form.Position := poScreenCenter;
  Form.ClientWidth := 360;
  Form.ClientHeight := 240;

  Host := TXuiHost.Create(Form);
  Host.Parent := Form;
  Host.Align := alClient;
  Host.LoadFromFile(FindFile('login.xml'));
  if (ParamCount > 0) and (LowerCase(ParamStr(1)) = 'dark') then
    Host.Engine.LoadStyleSheetFromFile(FindFile('login-dark.css'))
  else
    Host.Engine.LoadStyleSheetFromFile(FindFile('login-light.css'));
  Host.OnClick := @Demo.HostClick;
  Host.FitToDocumentDefaultSize;

  Form.Show;
  Application.Run;
end.
