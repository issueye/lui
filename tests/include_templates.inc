{ M5：include 模板 }

procedure WriteTestFile(const APath, AContent: string);
var
  list: TStringList;
begin
  list := TStringList.Create;
  try
    list.Text := AContent;
    list.SaveToFile(APath);
  finally
    list.Free;
  end;
end;

// FileAge 只有 2 秒粒度；等待一个完整窗口，确保后续 mtime 变化可观测。
procedure WaitForMTimeTick;
begin
  Sleep(2200);
end;

procedure TestIncludeTemplates;
var
  dir, mainFile, itemFile, tmplFile, nestFile, cycA, cycB, badFile: string;
  engine: TXuiEngine;
  fake: TFakeRenderer;
  root, node: TXuiNode;
  raised: Boolean;
begin
  WriteLn('--- M5 include 模板 ---');

  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'lui_m5_tpl';
  ForceDirectories(dir);
  itemFile := dir + PathDelim + 'item.xml';
  tmplFile := dir + PathDelim + 'tmpl.xml';
  nestFile := dir + PathDelim + 'nest.xml';
  cycA := dir + PathDelim + 'cyc_a.xml';
  cycB := dir + PathDelim + 'cyc_b.xml';
  badFile := dir + PathDelim + 'bad.xml';
  mainFile := dir + PathDelim + 'main.xml';

  WriteTestFile(itemFile, '<panel class="item"><label class="t" text="item"/></panel>');
  WriteTestFile(tmplFile,
    '<template><label class="a" text="A"/><label class="b" text="B"/></template>');
  WriteTestFile(nestFile, '<panel class="nest"><include src="item.xml"/></panel>');
  WriteTestFile(cycA, '<window><include src="cyc_b.xml"/></window>');
  WriteTestFile(cycB, '<window><include src="cyc_a.xml"/></window>');
  WriteTestFile(badFile, '<window><include src="tmpl.xml" class="x"/></window>');
  WriteTestFile(mainFile,
    '<window title="tpl">' +
    '  <include src="item.xml"/>' +
    '  <include src="tmpl.xml"/>' +
    '  <include src="nest.xml"/>' +
    '  <include src="item.xml" class="extra" id="last"/>' +
    '</window>');

  engine := NewTestEngine(fake);
  try
    engine.LoadFromFile(mainFile);
    DrawEngine(engine);
    root := engine.Document.Root;
    Check(root.Count = 5, 'include 展开后节点数正确（1+2+1+1）');
    node := root[0];
    Check((node.Tag = 'panel') and node.HasClass('item'), '单根文件展开为根元素自身');
    Check((root[1].Tag = 'label') and (root[1].Text = 'A'), 'template 展开第一个子元素');
    Check((root[2].Tag = 'label') and (root[2].Text = 'B'), 'template 展开第二个子元素');
    Check(root[3].HasClass('nest') and (root[3].Count = 1), '嵌套 include 展开');
    Check(root[4].HasClass('item') and root[4].HasClass('extra'),
      'include 上的 class 合并到展开节点');
    Check(root[4].Id = 'last', 'include 上的 id 合并');
    Check(engine.Document.FindElementById('last') = root[4], '合并 id 后可被查找');
    Check(engine.Document.SourceFile <> '', '文档记录来源文件');
    Check(engine.Document.Dependencies.Count = 3, '依赖收集（item/tmpl/nest）');

    // 运行时片段里的 include（按文档目录解析）
    node := engine.AddElement(root, '<include src="item.xml"/>');
    DrawEngine(engine);
    Check((node <> nil) and node.HasClass('item'), '运行时片段中的 include 展开');

    // 多节点展开时不允许附加属性
    raised := False;
    try
      engine.LoadFromFile(badFile);
    except
      raised := True;
    end;
    Check(raised, 'template 多节点 + 附加属性 抛异常');

    // 循环 include
    raised := False;
    try
      engine.LoadFromFile(cycA);
    except
      raised := True;
    end;
    Check(raised, '循环 include 抛异常');
    Check(engine.Document <> nil, '加载失败保留原文档');

    DeleteFile(itemFile);
    DeleteFile(tmplFile);
    DeleteFile(nestFile);
    DeleteFile(cycA);
    DeleteFile(cycB);
    DeleteFile(badFile);
    DeleteFile(mainFile);
    RemoveDir(dir);
  finally
    engine.Free;
  end;
end;
