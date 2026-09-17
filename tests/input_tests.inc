{ M5：输入框、键盘、焦点、剪贴板与鼠标 }

var
  FakeClipboard: string;

function FakeClipboardGet: string;
begin
  Result := FakeClipboard;
end;

procedure FakeClipboardSet(const AText: string);
begin
  FakeClipboard := AText;
end;

procedure TestInputEditing;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  input: TXuiNode;
begin
  WriteLn('--- M5 输入框：编辑 ---');

  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><input id="name"/></window>');
    engine.LoadStyleSheetFromString(
      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);

    input := engine.Document.FindElementById('name');
    Check(input <> nil, '输入框节点存在');
    Check((input.Behavior is TXuiBehavior) and TXuiBehavior(input.Behavior).CanFocus,
      'input 标签注册了可聚焦行为');

    ClickNode(engine, input);
    Check(engine.FocusNode = input, '点击输入框获得焦点');
    Check(engine.HandleTextInput('ab'), '文本输入被消费');
    Check(input.Text = 'ab', '值写入节点 Text');
    Check(engine.HandleKeyDown(VK_BACK, []), 'Backspace 被消费');
    Check(input.Text = 'a', 'Backspace 删除一个字符');
    Check(engine.HandleKeyDown(VK_LEFT, []), '方向键被消费');
    engine.HandleTextInput('X');
    Check(input.Text = 'Xa', '光标处插入（非末尾）');

    Check(engine.HandleKeyDown(VK_END, []), 'End 被消费');
    Check(engine.HandleKeyDown(VK_HOME, [xssShift]), 'Shift+Home 被消费');
    engine.HandleTextInput('hi');
    Check(input.Text = 'hi', '输入替换选区内容');

    engine.SetDisabled(input, True);
    Check(not engine.HandleTextInput('x'), '禁用输入框拒绝文本输入');
    Check(input.Text = 'hi', '禁用时值保持不变');
    engine.SetDisabled(input, False);
    Check(engine.HandleTextInput('!'), '恢复后可输入');
    Check(input.Text = 'hi!', '恢复输入生效');

    // 中文（多字节）按码点编辑
    engine.SetDisabled(input, False);
    Check(engine.HandleTextInput('中文'), '中文输入被消费');
    Check(input.Text = 'hi!中文', '中文追加正确');
    engine.HandleKeyDown(VK_BACK, []);
    Check(input.Text = 'hi!中', 'Backspace 删除一个中文字（码点）');
  finally
    engine.Free;
  end;
end;

procedure TestInputRender;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  input: TXuiNode;
begin
  WriteLn('--- M5 输入框：掩码 / 占位符 / 长度限制 ---');

  engine := NewTestEngine(fake);
  try
    engine.LoadFromString(
      '<window>' +
      '  <input id="pwd" password="true"/>' +
      '  <input id="tip" placeholder="请输入用户名"/>' +
      '  <input id="lim" maxlength="3"/>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);

    input := engine.Document.FindElementById('pwd');
    ClickNode(engine, input);
    engine.HandleTextInput('abc');
    fake.Clear;
    DrawEngine(engine);
    Check(fake.TextDrawn('●●●'), '密码框以掩码绘制');
    Check(not fake.TextDrawn('abc'), '密码原文不绘制');

    fake.Clear;
    DrawEngine(engine);
    Check(fake.TextDrawn('请输入用户名'), '空值绘制占位符');

    input := engine.Document.FindElementById('lim');
    ClickNode(engine, input);
    engine.HandleTextInput('abcdef');
    Check(input.Text = 'abc', 'maxlength 截断到 3 个码点');
  finally
    engine.Free;
  end;
end;

procedure TestFocusTraversalAndEnter;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  sink: TEventSink;
  a, b, btn: TXuiNode;
begin
  WriteLn('--- M5 焦点遍历 / Enter 激活 / oninput ---');

  sink := TEventSink.Create;
  engine := NewTestEngine(fake);
  try
    engine.EventTarget := sink;
    engine.LoadFromString(
      '<window>' +
      '  <input id="a" oninput="InputChanged" onenter="EnterPressed"/>' +
      '  <input id="b"/>' +
      '  <button id="go" text="go" onclick="BtnClick"/>' +
      '  <button id="off" text="off" disabled="true" onclick="BtnClick"/>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      'input, button { width:120px; height:24px; padding:0; border-width:0; }');
    DrawEngine(engine);

    a := engine.Document.FindElementById('a');
    b := engine.Document.FindElementById('b');
    btn := engine.Document.FindElementById('go');
    Check(engine.HandleKeyDown(VK_TAB, []), '无焦点时 Tab 聚焦第一个可聚焦节点');
    Check(engine.FocusNode = a, '第一个 Tab 落到 a');
    engine.HandleKeyDown(VK_TAB, []);
    Check(engine.FocusNode = b, 'Tab 前进到 b');
    engine.HandleKeyDown(VK_TAB, []);
    Check(engine.FocusNode = btn, 'Tab 跳过 disabled 到按钮');
    engine.HandleKeyDown(VK_TAB, []);
    Check(engine.FocusNode = a, 'Tab 环绕回 a');
    engine.HandleKeyDown(VK_TAB, [xssShift]);
    Check(engine.FocusNode = btn, 'Shift+Tab 反向环绕到按钮');

    engine.HandleKeyDown(VK_RETURN, []);
    Check(sink.Clicks = 1, 'Enter 激活聚焦按钮（等价点击）');
    ClickNode(engine, a);
    engine.HandleTextInput('xy');
    Check(sink.Inputs = 1, 'oninput 绑定在值变化后触发');
    Check(sink.LastInputText = 'xy', 'oninput 处理器读到节点新值');
    engine.HandleKeyDown(VK_HOME, []);
    engine.HandleKeyDown(VK_DELETE, []);
    Check(sink.Inputs = 2, '删除操作同样触发 oninput');
    Check(a.Text = 'y', 'Delete 删除光标后的字符');

    sink.Enters := 0;
    engine.HandleKeyDown(VK_RETURN, []);
    Check(sink.Enters = 1, '输入框中按 Enter 触发 onenter（表单提交用）');
  finally
    engine.Free;
    sink.Free;
  end;
end;

procedure TestInputClipboardAndMouse;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  input: TXuiNode;
  cx, cy: Integer;
begin
  WriteLn('--- M5 输入框：剪贴板 / 鼠标定位与拖选 ---');

  XuiClipboardGet := @FakeClipboardGet;
  XuiClipboardSet := @FakeClipboardSet;
  FakeClipboard := '';
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><input id="t"/></window>');
    engine.LoadStyleSheetFromString(
      'input { width:200px; height:28px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);

    input := engine.Document.FindElementById('t');
    ClickNode(engine, input);
    engine.HandleTextInput('abc');
    engine.HandleKeyDown(Ord('A'), [xssCtrl]);
    engine.HandleKeyDown(Ord('C'), [xssCtrl]);
    Check(FakeClipboard = 'abc', 'Ctrl+A 全选后 Ctrl+C 复制');
    engine.HandleKeyDown(Ord('X'), [xssCtrl]);
    Check(input.Text = '', 'Ctrl+X 剪切清空');
    Check(FakeClipboard = 'abc', 'Ctrl+X 写入剪贴板');
    engine.HandleKeyDown(Ord('V'), [xssCtrl]);
    Check(input.Text = 'abc', 'Ctrl+V 粘贴回输入框');

    // 鼠标点按定位：点最右侧 → 光标到末尾；拖到左侧 → 选中
    cx := input.ContentBox.Left + 2;
    cy := (input.ContentBox.Top + input.ContentBox.Bottom) div 2;
    engine.HandleMouseDown(cx, cy);
    engine.HandleMouseUp(cx, cy);
    engine.HandleTextInput('Z');
    Check(input.Text = 'Zabc', '点按左侧后光标在行首');
    engine.HandleMouseDown(input.ContentBox.Left + 1, cy);
    engine.HandleMouseMove(input.ContentBox.Right - 1, cy);
    engine.HandleMouseUp(input.ContentBox.Right - 1, cy);
    engine.HandleTextInput('Q');
    Check(input.Text = 'Q', '拖选后输入替换选中文本');
  finally
    engine.Free;
    XuiClipboardGet := nil;
    XuiClipboardSet := nil;
  end;
end;
