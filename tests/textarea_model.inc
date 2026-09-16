{ R1：多行输入（textarea）—— 换行、软断行、行导航、滚动范围与 Enter 策略 }

procedure TestTextAreaBasics;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  ta: TXuiNode;
begin
  WriteLn('--- R1 多行输入：注册与基础编辑 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><textarea id="ta"/></window>');
    engine.LoadStyleSheetFromString(
      'textarea { width:200px; height:60px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);
    ta := engine.Document.FindElementById('ta');
    Check(ta <> nil, 'textarea 节点存在');
    Check(ta.Behavior is TXuiTextAreaBehavior, 'textarea 注册了多行输入行为');
    Check(TXuiBehavior(ta.Behavior).CanFocus, 'textarea 可获得焦点');
    Check(ta.SelfScrolls, 'textarea 标记为自绘滚动范围');

    ClickNode(engine, ta);
    Check(engine.FocusNode = ta, '点击 textarea 获得焦点');
    Check(engine.HandleTextInput('ab'), '文本输入被消费');
    Check(ta.Text = 'ab', '值写入节点 Text');

    Check(engine.HandleKeyDown(VK_RETURN, []), '默认策略下 Enter 被消费（换行）');
    Check(ta.Text = 'ab' + #10, 'Enter 插入换行');
    engine.HandleTextInput('cd');
    Check(ta.Text = 'ab' + #10 + 'cd', '换行后继续输入');

    engine.HandleTextInput('X' + #13#10 + 'Y');
    Check(Pos('X' + #10 + 'Y', ta.Text) > 0, '多行粘贴保留换行（CRLF 归一为 LF）');

    engine.SetDisabled(ta, True);
    Check(not engine.HandleTextInput('z'), '禁用 textarea 拒绝输入');
  finally
    engine.Free;
  end;
end;

procedure TestTextAreaEditAcrossLines;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  ta: TXuiNode;
begin
  WriteLn('--- R1 多行输入：跨行删除与行首/行尾语义 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><textarea id="ta"/></window>');
    engine.LoadStyleSheetFromString(
      'textarea { width:200px; height:60px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);
    ta := engine.Document.FindElementById('ta');
    ClickNode(engine, ta);
    engine.HandleTextInput('a');
    engine.HandleKeyDown(VK_RETURN, []);
    engine.HandleTextInput('b');
    Check(ta.Text = 'a' + #10 + 'b', '构造两行文本');

    engine.HandleKeyDown(VK_HOME, []);
    engine.HandleKeyDown(VK_BACK, []);
    Check(ta.Text = 'ab', '行首 Backspace 合并上一行（删除换行）');

    engine.SetText(ta, 'a' + #10 + 'b');
    ClickNode(engine, ta);
    engine.HandleKeyDown(VK_HOME, [xssCtrl]);
    engine.HandleKeyDown(VK_END, []);
    engine.HandleKeyDown(VK_DELETE, []);
    Check(ta.Text = 'ab', '行尾 Delete 删除换行即合并两行');

    engine.SetText(ta, 'ab');
    ClickNode(engine, ta);
    engine.HandleKeyDown(VK_HOME, []);
    engine.HandleKeyDown(VK_RETURN, []);
    Check(ta.Text = #10 + 'ab', '行首 Enter 在行前插入空行');

    engine.SetText(ta, 'x' + #10 + #10 + 'y');
    ClickNode(engine, ta);
    DrawEngine(engine);
    Check(Abs(ta.ContentHeight - 58.8) < 1,
      Format('连续换行产生空逻辑行（3 行 × 19.6）[实际 %.1f]', [ta.ContentHeight]));
  finally
    engine.Free;
  end;
end;

procedure TestTextAreaEnterPolicy;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  sink: TEventSink;
  ta: TXuiNode;
begin
  WriteLn('--- R1 多行输入：Enter 策略（onenter 提交语义）---');
  sink := TEventSink.Create;
  engine := NewTestEngine(fake);
  try
    engine.EventTarget := sink;
    engine.LoadFromString(
      '<window>' +
      '<textarea id="t1" onenter="EnterPressed"/>' +
      '<textarea id="t2" enterkey="submit" onenter="EnterPressed"/>' +
      '</window>');
    engine.LoadStyleSheetFromString(
      'textarea { width:160px; height:40px; padding:0; border-width:0; font-size:14px; }');
    DrawEngine(engine);

    ta := engine.Document.FindElementById('t1');
    ClickNode(engine, ta);
    engine.HandleKeyDown(VK_RETURN, []);
    DrawEngine(engine);
    Check(ta.Text = #10, '默认策略：Enter 换行');
    Check(sink.Enters = 0, '默认策略：Enter 不触发 onenter');
    engine.HandleKeyDown(VK_RETURN, [xssCtrl]);
    DrawEngine(engine);
    Check(sink.Enters = 1, '默认策略：Ctrl+Enter 触发 onenter（提交）');
    Check(ta.Text = #10, '默认策略：Ctrl+Enter 不插入换行');

    ta := engine.Document.FindElementById('t2');
    ClickNode(engine, ta);
    sink.Enters := 0;
    engine.HandleKeyDown(VK_RETURN, [xssShift]);
    DrawEngine(engine);
    Check((ta.Text = #10) and (sink.Enters = 0), 'submit 策略：Shift+Enter 换行');
    engine.HandleKeyDown(VK_RETURN, []);
    DrawEngine(engine);
    Check(sink.Enters = 1, 'submit 策略：Enter 触发 onenter（提交）');
    Check(ta.Text = #10, 'submit 策略：Enter 不插入换行');
  finally
    engine.Free;
    sink.Free;
  end;
end;

procedure TestTextAreaWrapAndNav;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  ta: TXuiNode;
begin
  WriteLn('--- R1 多行输入：软断行与行导航 ---');
  // 假测量器：每字符 8px；内容宽 50px → 每行 6 字符；空格处可断
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><textarea id="ta"/></window>');
    engine.LoadStyleSheetFromString(
      'textarea { width:50px; height:70px; padding:0; border-width:0; font-size:10px; line-height:1; }');
    DrawEngine(engine);
    ta := engine.Document.FindElementById('ta');
    ClickNode(engine, ta);
    engine.HandleTextInput('aaaaaa bbbbbb');
    DrawEngine(engine);
    Check(Abs(ta.ContentHeight - 20) < 0.5,
      Format('软断行：空格处断行 → 两行 × 10 [实际 %.1f]', [ta.ContentHeight]));
    Check(Abs(ta.ContentWidth - 50) < 0.5, '软断行不产生横向溢出');

    // End：停在当前视觉行行尾（不是文本末尾）
    engine.SetText(ta, 'aaaaaa bbbbbb');
    ClickNode(engine, ta);
    DrawEngine(engine);
    engine.HandleKeyDown(VK_HOME, [xssCtrl]);
    engine.HandleKeyDown(VK_END, []);
    engine.HandleTextInput('X');
    DrawEngine(engine);
    Check(Pos('aaaaaaX', ta.Text) = 1, 'End 停在当前视觉行行尾（不是文本末尾）');

    // Down：移到下一视觉行同一列（此处为第 2 行行首）
    engine.SetText(ta, 'aaaaaa bbbbbb');
    ClickNode(engine, ta);
    DrawEngine(engine);
    engine.HandleKeyDown(VK_HOME, [xssCtrl]);
    engine.HandleKeyDown(VK_DOWN, []);
    engine.HandleTextInput('Y');
    DrawEngine(engine);
    Check(Pos('aaaaaa ' + 'Ybbbbbb', ta.Text) = 1, 'Down 移到下一视觉行行首');

    // Up：按像素亲和回到上一行对应列
    engine.SetText(ta, 'aaaaaa bbbbbb');
    ClickNode(engine, ta);
    DrawEngine(engine);
    engine.HandleKeyDown(VK_HOME, [xssCtrl]);
    engine.HandleKeyDown(VK_DOWN, []);
    engine.HandleKeyDown(VK_HOME, []);
    engine.HandleTextInput('A');
    DrawEngine(engine);
    Check(Pos('aaaaaa ' + 'Abbbbbb', ta.Text) = 1, 'Home 停在当前视觉行行首');
    engine.HandleKeyDown(VK_UP, []);
    engine.HandleTextInput('B');
    DrawEngine(engine);
    Check(Pos('a' + 'B' + 'aaaaa ' + 'Abbbbbb', ta.Text) = 1,
      'Up 按像素亲和回到上一行对应列');

    // Ctrl+End：到达文本末尾
    engine.HandleKeyDown(VK_HOME, [xssCtrl]);
    engine.HandleKeyDown(VK_END, [xssCtrl]);
    engine.HandleTextInput('!');
    DrawEngine(engine);
    Check(Copy(ta.Text, Length(ta.Text), 1) = '!', 'Ctrl+End 到达文本末尾');

    // 连续换行产生空逻辑行（占位行），行数 = 3
    engine.SetText(ta, 'x' + #10 + #10 + 'y');
    ClickNode(engine, ta);
    DrawEngine(engine);
    Check(Abs(ta.ContentHeight - 30) < 0.5,
      Format('连续换行产生空逻辑行（3 行 × 10）[实际 %.1f]', [ta.ContentHeight]));
  finally
    engine.Free;
  end;
end;

procedure TestTextAreaScroll;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  ta: TXuiNode;
  bars: TXuiScrollBarLayout;
  topBefore: Single;
  fills, i: Integer;
begin
  WriteLn('--- R1 多行输入：滚动范围、滚动条与光标跟随 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><textarea id="ta"/></window>');
    engine.LoadStyleSheetFromString(
      'textarea { overflow:auto; width:80px; height:40px; padding:0; border-width:0; ' +
      'font-size:10px; line-height:1; }');
    DrawEngine(engine);
    ta := engine.Document.FindElementById('ta');
    ClickNode(engine, ta);
    engine.HandleTextInput('l1');
    for i := 2 to 7 do
    begin
      engine.HandleKeyDown(VK_RETURN, []);
      engine.HandleTextInput('l' + IntToStr(i));
    end;
    DrawEngine(engine);
    Check(Abs(ta.ContentHeight - 70) < 1,
      Format('7 行 × 10 = 内容高 70 [实际 %.1f]', [ta.ContentHeight]));
    Check(ta.ScrollTop > 0, '光标跟随：光标行被滚入可视区');

    bars := XuiScrollBarLayout(ta);
    Check(bars.ShowV, 'overflow:auto 且内容超出时显示纵向滚动条');
    Check(bars.VThumb.Top > bars.VTrack.Top, '滑块随滚动偏移下移');

    fake.Clear;
    DrawEngine(engine);
    fills := fake.CountOf('fill');
    Check(fills >= 2, Format('textarea 滚动条被绘制（fill=%d）', [fills]));

    topBefore := ta.ScrollTop;
    engine.HandleMouseWheel(10, 10, 120);
    DrawEngine(engine);
    Check(ta.ScrollTop < topBefore, '滚轮向上滚动生效（不被光标跟随拉回）');

    engine.SetText(ta, 'x');
    ClickNode(engine, ta);
    DrawEngine(engine);
    DrawEngine(engine);
    Check(Abs(ta.ContentHeight - 10) < 0.5, '单行内容高 = 一行行高');
    Check(ta.ScrollTop = 0, '内容变短后 ScrollTop 收敛为 0');
    Check(not XuiScrollBarLayout(ta).ShowV, '内容不溢出时不再显示滚动条');
  finally
    engine.Free;
  end;
end;

procedure TestTextAreaLongLine;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  ta: TXuiNode;
begin
  WriteLn('--- R1 多行输入：不可断长串按字符硬断 ---');
  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><textarea id="ta"/></window>');
    engine.LoadStyleSheetFromString(
      'textarea { overflow:auto; width:40px; height:20px; padding:0; border-width:0; ' +
      'font-size:10px; line-height:1; }');
    DrawEngine(engine);
    ta := engine.Document.FindElementById('ta');
    ClickNode(engine, ta);
    engine.HandleTextInput('abcdefghijklmnop');   // 16 字符 × 8px = 128 > 40
    DrawEngine(engine);
    Check(Abs(ta.ContentWidth - 40) < 0.5, '长串按字符硬断：不产生横向溢出');
    Check(not XuiScrollBarLayout(ta).ShowH, '长串用例不显示横向滚动条');
    Check(Abs(ta.ContentHeight - 40) < 0.5,
      Format('16 字符 / 每行 5 → 4 行 × 10 = 40 [实际 %.1f]', [ta.ContentHeight]));
    Check(XuiScrollBarLayout(ta).ShowV, '内容纵向溢出时显示纵向滚动条');

    // 断行后仍可正常编辑（光标在末行）
    engine.HandleKeyDown(VK_END, []);
    engine.HandleTextInput('Z');
    DrawEngine(engine);
    Check(Copy(ta.Text, Length(ta.Text), 1) = 'Z', '硬断后继续在末尾输入');
  finally
    engine.Free;
  end;
end;
