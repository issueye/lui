program demo1;

{$mode objfpc}{$H+}

{ lui M5 演示：XML + CSS 自绘界面的交互与产品化能力。

  demo1                  登录卡片（浅色；输入框可编辑，Enter 提交）
  demo1 dark             登录卡片（深色）
  demo1 list             列表页（浅色）
  demo1 list dark        列表页（深色）
  demo1 todo             Todo 小应用（浅色；输入框 + Enter 添加，条目来自 include 模板）
  demo1 todo dark        Todo 小应用（深色）
  demo1 watch            开启热重载：运行中修改 *.css / *.xml 自动生效
  demo1 shot [WxH]       渲染到 shot.png 后退出（布局/观感自动核对）
  demo1 todo demo shot   同上，但先模拟交互（输入 + Enter 添加 / 悬停 / 完成 / 删除 / 滚动）

  交互要点：
  - XML 的 onclick/onenter/oninput="MethodName" 通过 MethodAddress 绑定到 published 方法
  - 输入框：点击聚焦、中英文输入（IME 上屏走 LCL UTF8KeyPress）、Ctrl+A/C/X/V、拖选
  - 按钮/条目 hover 有属性过渡（transition），光标闪烁与过渡由宿主 Timer 驱动
  - include：todo.xml 的条目来自 todo-items.xml；新增条目用 item.xml 模板（AddElement）
  - 渲染后端默认 xbAuto：Windows 上走 GDI+（圆角抗锯齿、alpha），失败自动回退 GDI

  代码直接创建窗体，不使用 .lfm。 }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, Forms, SysUtils, Classes, Controls, Graphics, Math, LCLType,
  xui_types, xui_dom, xui_host, xui_engine, xui_render;

type
  TDemoForm = class(TForm)
  private
    FHost: TXuiHost;
    FBaseName: string;
    FDark: Boolean;
    FTodoSeq: Integer;
    procedure ApplyTheme;
    function FindItemTextNode(AItem: TXuiNode): TXuiNode;
  public
    constructor Create(AOwner: TComponent); override;
    procedure LoadUI(const ABaseName: string);
    procedure SetDark(AValue: Boolean);
    procedure ToggleTheme;
    procedure UpdateCount;
    // 自动化演示：模拟一次交互序列后截图（无鼠标环境下的观感核对）
    procedure SimulateInteraction;
    // 诊断：把未处理异常写入文件（GUI 程序无控制台，否则只会弹对话框）
    procedure LogError(const APrefix, AMessage: string);
    property Host: TXuiHost read FHost;
  published
    // XML on*="..." 绑定到这些 published 方法（需要方法 RTTI，故放 published）
    procedure BtnOkClick(Sender: TObject);
    procedure LoginSubmit(Sender: TObject);
    procedure LoginInput(Sender: TObject);
    procedure ThemeClick(Sender: TObject);
    procedure TodoToggleClick(Sender: TObject);
    procedure TodoDeleteClick(Sender: TObject);
    procedure AddTodoClick(Sender: TObject);
    procedure AddTodoSubmit(Sender: TObject);
    procedure ClearClick(Sender: TObject);
  end;

var
  Form: TDemoForm;

function FindFile(const AName: string): string;
begin
  Result := AName;
  if FileExists(Result) then Exit;
  Result := ExtractFilePath(ParamStr(0)) + AName;
  if FileExists(Result) then Exit;
  Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + AName;
end;

{ TDemoForm }

constructor TDemoForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBaseName := 'login';
  FDark := False;
  FTodoSeq := 4;
  Caption := 'lui demo1 - M5：输入框 / 过渡动画 / include 模板 / 热重载';
  Position := poScreenCenter;
  ClientWidth := 360;
  ClientHeight := 300;

  FHost := TXuiHost.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  // XML 绑定的宿主对象：其 published 方法可被 onclick="Name" 找到
  FHost.EventTarget := Self;
end;

procedure TDemoForm.LoadUI(const ABaseName: string);
begin
  FBaseName := ABaseName;
  FHost.LoadFromFile(FindFile(FBaseName + '.xml'));
  ApplyTheme;
  FHost.FitToDocumentDefaultSize;
end;

procedure TDemoForm.ApplyTheme;
begin
  FHost.Engine.ClearStyleSheets;
  if FDark then
    FHost.Engine.LoadStyleSheetFromFile(FindFile(FBaseName + '-dark.css'))
  else
    FHost.Engine.LoadStyleSheetFromFile(FindFile(FBaseName + '-light.css'));
  FHost.Invalidate;
end;

procedure TDemoForm.SetDark(AValue: Boolean);
begin
  if FDark = AValue then
    Exit;
  FDark := AValue;
  ApplyTheme;
end;

procedure TDemoForm.ToggleTheme;
begin
  FDark := not FDark;
  ApplyTheme;
end;

// 登录：点击按钮或（输入框聚焦时）按 Enter 都走这里
procedure TDemoForm.BtnOkClick(Sender: TObject);
var
  msg, user, pass: TXuiNode;
  userName: string;
begin
  msg := FHost.Engine.Document.FindElementById('msg');
  user := FHost.Engine.Document.FindElementById('username');
  pass := FHost.Engine.Document.FindElementById('password');
  if msg = nil then
    Exit;
  userName := '';
  if user <> nil then
    userName := Trim(user.Text);
  if userName = '' then
  begin
    FHost.Engine.SetText(msg, '请先点输入框输入用户名（支持中文输入法），再按 Enter 或点「登 录」提交');
    Exit;
  end;
  FHost.Engine.SetText(msg, '已提交：用户「' + userName + '」，密码 ' +
    IntToStr(Length(pass.Text)) + ' 位（Sender=' + TXuiNode(Sender).Id + '）');
end;

// 卡片上的 onenter：输入框里按 Enter 时冒泡到这里（表单提交心智）
procedure TDemoForm.LoginSubmit(Sender: TObject);
begin
  BtnOkClick(Sender);
end;

// 输入框内容变化（oninput）：实时提示
procedure TDemoForm.LoginInput(Sender: TObject);
var
  msg, user: TXuiNode;
begin
  msg := FHost.Engine.Document.FindElementById('msg');
  if msg = nil then
    Exit;
  if Sender is TXuiNode then
  begin
    user := TXuiNode(Sender);
    if Trim(user.Text) = '' then
      FHost.Engine.SetText(msg, '请输入用户名（占位符提示由输入框行为绘制）')
    else
      FHost.Engine.SetText(msg, '已输入 ' + IntToStr(Length(Trim(user.Text))) + ' 个字符，按 Enter 提交');
  end;
end;

procedure TDemoForm.ThemeClick(Sender: TObject);
begin
  ToggleTheme;
end;

procedure TDemoForm.TodoToggleClick(Sender: TObject);
var
  node: TXuiNode;
begin
  node := Sender as TXuiNode;
  if node.HasClass('done') then
    FHost.Engine.SetClass(node, 'item')
  else
    FHost.Engine.SetClass(node, 'item done');
end;

procedure TDemoForm.TodoDeleteClick(Sender: TObject);
var
  item: TXuiNode;
begin
  item := (Sender as TXuiNode).Parent; // × 的父节点是条目本身
  if item <> nil then
    FHost.Engine.RemoveElement(item);
  UpdateCount;
end;

function TDemoForm.FindItemTextNode(AItem: TXuiNode): TXuiNode;
var
  i: Integer;
begin
  Result := nil;
  if AItem = nil then
    Exit;
  for i := 0 to AItem.Count - 1 do
    if AItem[i].HasClass('text') then
      Exit(AItem[i]);
end;

// 添加一条：输入框有内容则用它，否则生成默认文案；结构来自 include 模板 item.xml
procedure TDemoForm.AddTodoClick(Sender: TObject);
var
  list, inputNode, item, textNode: TXuiNode;
  newText: string;
begin
  list := FHost.Engine.Document.FindElementById('list');
  if list = nil then
    Exit;
  inputNode := FHost.Engine.Document.FindElementById('new-todo');
  newText := '';
  if inputNode <> nil then
    newText := Trim(inputNode.Text);
  if newText = '' then
  begin
    Inc(FTodoSeq);
    newText := '新任务 #' + IntToStr(FTodoSeq);
  end;

  item := FHost.Engine.AddElement(list, '<include src="item.xml"/>');
  textNode := FindItemTextNode(item);
  if textNode <> nil then
    FHost.Engine.SetText(textNode, newText);
  if inputNode <> nil then
    FHost.Engine.SetText(inputNode, ''); // 清空输入框

  // 新增后滚到底部（下一轮布局由夹取逻辑收敛到 maxScroll）
  list.ScrollTop := 1e9;
  FHost.Engine.InvalidateLayout;
  FHost.Invalidate;
  UpdateCount;
end;

// 输入框上的 onenter：Enter 添加
procedure TDemoForm.AddTodoSubmit(Sender: TObject);
begin
  AddTodoClick(Sender);
end;

procedure TDemoForm.ClearClick(Sender: TObject);
var
  list: TXuiNode;
begin
  list := FHost.Engine.Document.FindElementById('list');
  if list <> nil then
    FHost.Engine.ClearChildren(list);
  UpdateCount;
end;

procedure TDemoForm.UpdateCount;
var
  list, count, clearBtn: TXuiNode;
begin
  list := FHost.Engine.Document.FindElementById('list');
  count := FHost.Engine.Document.FindElementById('count');
  clearBtn := FHost.Engine.Document.FindElementById('clear');
  if list = nil then
    Exit;
  if count <> nil then
    FHost.Engine.SetText(count, IntToStr(list.Count));
  // 空列表时禁用「清空」——演示 :disabled 与点击屏蔽
  if clearBtn <> nil then
    FHost.Engine.SetDisabled(clearBtn, list.Count = 0);
end;

procedure TDemoForm.LogError(const APrefix, AMessage: string);
begin
  with TStringList.Create do
  try
    Add(APrefix + ': ' + AMessage);
    SaveToFile(ExtractFilePath(ParamStr(0)) + 'shot-error.txt');
  finally
    Free;
  end;
end;

// 交互序列（无鼠标环境的自动化）：
// 登录页：聚焦用户名/密码依次输入 → Enter 提交；
// Todo 页：输入框输入 + Enter 添加（include 模板）→ 悬停第 2 条 → 第 1 条完成 → 删第 3 条 → 滚动
procedure TDemoForm.SimulateInteraction;
var
  engine: TXuiEngine;
  list, item, inputNode: TXuiNode;
  cx, cy: Integer;

  procedure ClickAt(ANode: TXuiNode);
  begin
    if ANode = nil then
      Exit;
    cx := (ANode.BoxRect.Left + ANode.BoxRect.Right) div 2;
    cy := (ANode.BoxRect.Top + ANode.BoxRect.Bottom) div 2;
    engine.HandleMouseMove(cx, cy);
    engine.HandleMouseDown(cx, cy);
    engine.HandleMouseUp(cx, cy);
  end;

begin
  engine := FHost.Engine;

  if FBaseName = 'login' then
  begin
    inputNode := engine.Document.FindElementById('username');
    ClickAt(inputNode);
    engine.HandleTextInput('alice');
    inputNode := engine.Document.FindElementById('password');
    ClickAt(inputNode);
    engine.HandleTextInput('123456');
    engine.HandleKeyDown(VK_RETURN, []); // Enter → 卡片 onenter → 提交
    Exit;
  end;

  if FBaseName = 'list' then
  begin
    item := engine.Document.FindElementById('list');
    if (item <> nil) and (item.Count > 0) then
      ClickAt(item[1]);
    Exit;
  end;

  // script 页：逻辑全在 script.ts（点击「添加一条」两次，再把按钮移出指针）
  if FBaseName = 'script' then
  begin
    item := engine.Document.FindElementById('btn-add');
    ClickAt(item);
    ClickAt(item);
    engine.HandleMouseMove(295, 195);
    Exit;
  end;

  // todo
  inputNode := engine.Document.FindElementById('new-todo');
  if inputNode <> nil then
  begin
    ClickAt(inputNode);
    engine.HandleTextInput('通过输入框新增的任务');
    engine.HandleKeyDown(VK_RETURN, []); // onenter → AddTodoSubmit
  end;

  list := engine.Document.FindElementById('list');
  if (list = nil) or (list.Count < 3) then
    Exit;

  ClickAt(list[1]);                      // 悬停第 2 条（:hover + 过渡）
  engine.SetClass(list[0], 'item done'); // 第 1 条 → 完成态
  engine.RemoveElement(list[2]);         // 删掉第 3 条
  list.ScrollTop := 20;                  // 轻微滚动
  engine.InvalidateLayout;
  UpdateCount;
end;

var
  i, sep: Integer;
  arg, page, shotFile: string;
  dark, shotMode, demoMode, watchMode: Boolean;
  shotW, shotH: Integer;
  bmp: TBitmap;

begin
  RequireDerivedFormResource := False;
  Application.Title := 'lui demo1';

  page := 'login';
  dark := False;
  shotMode := False;
  demoMode := False;
  watchMode := False;
  shotW := 0;
  shotH := 0;
  for i := 1 to ParamCount do
  begin
    arg := LowerCase(Trim(ParamStr(i)));
    if arg = 'dark' then
      dark := True
    else if arg = 'todo' then
      page := 'todo'
    else if arg = 'list' then
      page := 'list'
    else if arg = 'script' then
      page := 'script'
    else if arg = 'login' then
      page := 'login'
    else if arg = 'shot' then
      shotMode := True
    else if arg = 'demo' then
      demoMode := True
    else if arg = 'watch' then
      watchMode := True
    else
    begin
      sep := Pos('x', arg);
      if (sep > 1) and (sep < Length(arg)) then
      begin
        shotW := StrToIntDef(Copy(arg, 1, sep - 1), 0);
        shotH := StrToIntDef(Copy(arg, sep + 1, MaxInt), 0);
      end;
    end;
  end;

  Application.Initialize;
  Form := TDemoForm.Create(Application);
  try
    try
      Form.LoadUI(page);
      Form.SetDark(dark);
      if page = 'todo' then
        Form.UpdateCount;
      Form.Host.Engine.HotReload := watchMode; // 运行中改 XML/CSS 自动生效
      if (shotW > 0) and (shotH > 0) then
      begin
        Form.ClientWidth := shotW;
        Form.ClientHeight := shotH;
        Form.Host.Invalidate;
      end;

      Form.Show;
      Application.ProcessMessages;

      if demoMode then
      begin
        Form.SimulateInteraction;
        Application.ProcessMessages;
      end;

      if shotMode then
      begin
        // 让过渡动画推进到末态再截图（失焦后光标保持常亮，画面可复现）
        Form.Host.Engine.SetHostActive(False);
        Form.Host.Engine.Tick(GetTickCount64 + 5000);
        Form.Host.Invalidate;
        Application.ProcessMessages;

        bmp := TBitmap.Create;
        try
          bmp.SetSize(Form.Host.ClientWidth, Form.Host.ClientHeight);
          bmp.Canvas.Brush.Color := clWhite;
          bmp.Canvas.FillRect(0, 0, bmp.Width, bmp.Height);
          Form.Host.PaintTo(bmp.Canvas, 0, 0);
          shotFile := ExtractFilePath(ParamStr(0)) + 'shot.png';
          bmp.SaveToFile(shotFile);
        finally
          bmp.Free;
        end;
        Halt(0);
      end;

      Application.Run;
    except
      on E: Exception do
      begin
        Form.LogError('EXCEPTION', E.ClassName + ': ' + E.Message);
        Halt(2);
      end;
    end;
  finally
    Form.Free;
  end;
end.
