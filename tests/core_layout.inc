{ M2 block-flow layout contract. }

procedure TestBlockLayout;
var
  doc: TXuiDocument;
  card, btn: TXuiNode;
  i: Integer;
  prevBottom: LongInt;
  ok: Boolean;
begin
  WriteLn('--- 块级布局 ---');
  doc := LoadDocumentFromXML(DemoXML);
  try
    LayoutDocument(doc, 360, 240, @Measurer.Measure);
    Check(doc.Root.BoxRect.Left = 0, '根节点贴左');
    Check(doc.Root.BoxRect.Right = 360, '根节点宽度 = 视口宽');
    Check(doc.Root.BoxRect.Bottom = 240, '根节点高度 = 视口高');
    card := doc.FindElementById('login-card');
    Check(card.BoxRect.Right = 360, '卡片宽度 = 视口宽（auto）');
    Check(card.BoxRect.Bottom > card.BoxRect.Top + 50, '卡片高度由内容撑开');
    prevBottom := card.BoxRect.Top;
    ok := True;
    for i := 0 to card.Count - 1 do
    begin
      if card[i].BoxRect.Top < prevBottom then
        ok := False;
      prevBottom := card[i].BoxRect.Bottom;
    end;
    Check(ok, '子节点按块级流自上而下');
    btn := doc.FindElementById('btn-ok');
    Check(btn.BoxRect.Bottom - btn.BoxRect.Top = 32, 'button 高度 32px');
  finally
    doc.Free;
  end;
end;
