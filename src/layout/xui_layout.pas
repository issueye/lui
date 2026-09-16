unit xui_layout;

{$mode objfpc}{$H+}

{ M3 布局引擎：盒模型（默认 border-box）+ 块级流 + flex 子集（row/column、justify/align、gap、grow）
  + 绝对/相对定位 + min-width/min-height + auto 外边距居中。

  测量与断行通过回调解耦画布（测试可注入假测量器）。
  坐标系：布局结果为绝对像素坐标（根节点原点 = 宿主内容区左上角）。

  已知边界（与文档"不支持清单"同步）：
  - flex 不支持 wrap / shrink / 基线对齐 / 负 margin / order；主轴空间不足时溢出（可被 overflow:hidden 裁剪）
  - auto 外边距仅块级流水平方向生效；纵向 auto 按 0
  - 百分比：宽度对父内容宽；高度对父确定高度（父高不定时回退视口）；relative 偏移的横向百分比对自身宽度近似 }

interface

uses
  SysUtils, Types, Math,
  xui_types, xui_style, xui_dom, xui_text;

// 对整棵树做布局；AViewportWidth/Height 为宿主内容区尺寸（像素）
procedure LayoutDocument(ADoc: TXuiDocument;
  AViewportWidth, AViewportHeight: Single; AMeasure: TXuiMeasureFunc);

implementation

type
  TLayoutContext = record
    Measure: TXuiMeasureFunc;
    ViewportWidth: Single;
    ViewportHeight: Single;
  end;

  TFlexItem = record
    Node: TXuiNode;
    Main: Single;   // 主轴 border-box 尺寸
    Cross: Single;  // 交叉轴 border-box 尺寸（排布后回填）
    ML, MT, MR, MB: Single;
    X, Y: Single;
  end;
  TFlexItems = array of TFlexItem;

function ArrangeNode(ANode: TXuiNode; AX, AY, AWidth: Single;
  const ACtx: TLayoutContext; AParentHeight: Single; AForcedHeight: Single): Single; forward;

function MeasureNode(ANode: TXuiNode; const ACtx: TLayoutContext): TSize; forward;

// 布局收尾：整棵树布局完成后统一处理绝对定位（此时包含块矩形已是最终值）
procedure ArrangeAbsolutesTree(ANode: TXuiNode; const ACtx: TLayoutContext); forward;

// ---------- 工具 ----------

function IsInFlow(ANode: TXuiNode): Boolean;
begin
  Result := (ANode.Style <> nil) and (ANode.Style.Display <> xdispNone) and
    (ANode.Style.Position <> xposAbsolute);
end;

function ClampMin(AValue: Single; const AMin: TXuiLength; ABase: Single): Single;
begin
  Result := AValue;
  if not AMin.IsAuto then
    Result := Max(Result, AMin.Resolve(ABase));
end;

procedure OffsetSubtree(ANode: TXuiNode; ADX, ADY: Integer);
var
  i: Integer;
begin
  if (ADX = 0) and (ADY = 0) then
    Exit;
  ANode.BoxRect := Types.Rect(ANode.BoxRect.Left + ADX, ANode.BoxRect.Top + ADY,
    ANode.BoxRect.Right + ADX, ANode.BoxRect.Bottom + ADY);
  for i := 0 to ANode.Count - 1 do
    OffsetSubtree(ANode[i], ADX, ADY);
end;

// 绝对定位包含块：最近的非 static 祖先；无则回退根节点
function ContainingBlockOf(ANode: TXuiNode): TXuiNode;
var
  p: TXuiNode;
begin
  p := ANode.Parent;
  while p <> nil do
  begin
    if (p.Style <> nil) and (p.Style.Position <> xposStatic) then
      Exit(p);
    p := p.Parent;
  end;
  Result := ANode.Root;
  if Result = ANode then
    Result := ANode.Parent;
end;

// 节点的 max-content 尺寸（border-box）；只用于 flex 主轴尺寸推导
function MeasureNode(ANode: TXuiNode; const ACtx: TLayoutContext): TSize;
var
  style: TXuiStyle;
  i: Integer;
  child: TXuiNode;
  bw, padL, padT, padR, padB, cw, ch, mL, mR, mT, mB, gap: Single;
  cs: TSize;
begin
  style := ANode.Style;
  if (style = nil) or (style.Display = xdispNone) then
  begin
    Result.cx := 0;
    Result.cy := 0;
    Exit;
  end;

  bw := style.BorderWidth;
  padL := style.Padding.Left.Resolve(0);
  padT := style.Padding.Top.Resolve(0);
  padR := style.Padding.Right.Resolve(0);
  padB := style.Padding.Bottom.Resolve(0);
  cw := 0;
  ch := 0;

  if ANode.Count > 0 then
  begin
    if (style.Display = xdispFlex) and (style.FlexDirection = xfdRow) then
    begin
      gap := style.ColumnGap.Resolve(ACtx.ViewportWidth);
      for i := 0 to ANode.Count - 1 do
      begin
        child := ANode[i];
        if not IsInFlow(child) then
          Continue;
        mL := child.Style.Margin.Left.Resolve(0);
        mR := child.Style.Margin.Right.Resolve(0);
        mT := child.Style.Margin.Top.Resolve(0);
        mB := child.Style.Margin.Bottom.Resolve(0);
        cs := MeasureNode(child, ACtx);
        if cw > 0 then
          cw := cw + gap;
        cw := cw + cs.cx + mL + mR;
        ch := Max(ch, cs.cy + mT + mB);
      end;
    end
    else
    begin
      gap := style.RowGap.Resolve(ACtx.ViewportHeight);
      for i := 0 to ANode.Count - 1 do
      begin
        child := ANode[i];
        if not IsInFlow(child) then
          Continue;
        mL := child.Style.Margin.Left.Resolve(0);
        mR := child.Style.Margin.Right.Resolve(0);
        mT := child.Style.Margin.Top.Resolve(0);
        mB := child.Style.Margin.Bottom.Resolve(0);
        cs := MeasureNode(child, ACtx);
        cw := Max(cw, cs.cx + mL + mR);
        if ch > 0 then
          ch := ch + gap;
        ch := ch + cs.cy + mT + mB;
      end;
    end;
  end
  else if ANode.Text <> '' then
  begin
    if ACtx.Measure <> nil then
      cs := ACtx.Measure(ANode.Text, style)
    else
    begin
      cs.cx := Round(Length(ANode.Text) * style.FontSize * 0.6);
      cs.cy := Round(LineHeightPx(style));
    end;
    cw := cs.cx;
    ch := LineHeightPx(style); // 不换行的单行高度
  end;

  if not style.Width.IsAuto then
    cw := style.Width.Resolve(ACtx.ViewportWidth);
  if not style.Height.IsAuto then
    ch := style.Height.Resolve(ACtx.ViewportHeight);
  cw := ClampMin(cw, style.MinWidth, ACtx.ViewportWidth);
  ch := ClampMin(ch, style.MinHeight, ACtx.ViewportHeight);

  Result.cx := Round(cw + padL + padR + 2 * bw);
  Result.cy := Round(ch + padT + padB + 2 * bw);
end;

// 块级流：子节点纵向堆叠，宽度 auto 填满；水平 auto 外边距居中
function ArrangeBlock(AParent: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AHeightBase: Single; ADefiniteContentH: Single): Single;
var
  i: Integer;
  child: TXuiNode;
  style: TXuiStyle;
  y, mL, mR, mT, mB, childW, free: Single;
begin
  y := ATop;
  for i := 0 to AParent.Count - 1 do
  begin
    child := AParent[i];
    if not IsInFlow(child) then
      Continue;
    style := child.Style;
    mL := style.Margin.Left.Resolve(AWidth);
    mR := style.Margin.Right.Resolve(AWidth);
    mT := style.Margin.Top.Resolve(AWidth);
    mB := style.Margin.Bottom.Resolve(AWidth);

    if not style.Width.IsAuto then
    begin
      childW := ClampMin(style.Width.Resolve(AWidth), style.MinWidth, AWidth);
      if style.Margin.Left.IsAuto or style.Margin.Right.IsAuto then
      begin
        free := Max(0, AWidth - childW - mL - mR);
        if style.Margin.Left.IsAuto and style.Margin.Right.IsAuto then
        begin
          mL := free / 2;
          mR := free / 2;
        end
        else if style.Margin.Left.IsAuto then
          mL := free
        else
          mR := free;
      end;
    end
    else
      childW := Max(0, AWidth - mL - mR);

    y := y + mT + ArrangeNode(child, ALeft + mL, y + mT, childW, ACtx, AHeightBase, -1) + mB;
  end;

  Result := y - ATop;
end;

// flex 主轴 = x
function ArrangeFlexRow(AParent: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AHeightBase: Single; ADefiniteContentH: Single): Single;
var
  items: TFlexItems;
  n, i: Integer;
  child: TXuiNode;
  style: TXuiStyle;
  gap, totalMain, growSum, free, extra, x, maxCross, containerH, dy: Single;
begin
  n := 0;
  SetLength(items, AParent.Count);
  gap := AParent.Style.ColumnGap.Resolve(AWidth);
  totalMain := 0;
  growSum := 0;

  for i := 0 to AParent.Count - 1 do
  begin
    child := AParent[i];
    if not IsInFlow(child) then
      Continue;
    style := child.Style;
    items[n].Node := child;
    items[n].ML := style.Margin.Left.Resolve(AWidth);
    items[n].MT := style.Margin.Top.Resolve(AWidth);
    items[n].MR := style.Margin.Right.Resolve(AWidth);
    items[n].MB := style.Margin.Bottom.Resolve(AWidth);

    // 主轴尺寸：flex-basis > width > max-content
    if not style.FlexBasis.IsAuto then
      items[n].Main := style.FlexBasis.Resolve(AWidth)
    else if not style.Width.IsAuto then
      items[n].Main := style.Width.Resolve(AWidth)
    else
      items[n].Main := MeasureNode(child, ACtx).cx;
    items[n].Main := ClampMin(items[n].Main, style.MinWidth, AWidth);

    totalMain := totalMain + items[n].Main + items[n].ML + items[n].MR;
    growSum := growSum + style.FlexGrow;
    Inc(n);
  end;
  SetLength(items, n);
  if n > 1 then
    totalMain := totalMain + gap * (n - 1);

  free := Max(0, AWidth - totalMain);
  if (free > 0) and (growSum > 0) then
  begin
    for i := 0 to n - 1 do
      if items[i].Node.Style.FlexGrow > 0 then
        items[i].Main := items[i].Main + free * items[i].Node.Style.FlexGrow / growSum;
    free := 0;
  end;

  case AParent.Style.JustifyContent of
    xjcCenter:
      begin x := ALeft + free / 2; extra := 0; end;
    xjcEnd:
      begin x := ALeft + free; extra := 0; end;
    xjcSpaceBetween:
      begin
        x := ALeft;
        if n > 1 then extra := free / (n - 1) else extra := 0;
      end;
    xjcSpaceAround:
      begin
        if n > 0 then
        begin
          x := ALeft + free / (2 * n);
          extra := free / n;
        end
        else
        begin
          x := ALeft;
          extra := 0;
        end;
      end;
  else
    x := ALeft;
    extra := 0;
  end;

  maxCross := 0;
  for i := 0 to n - 1 do
  begin
    x := x + items[i].ML;
    items[i].X := x;
    items[i].Cross := ArrangeNode(items[i].Node, x, ATop, items[i].Main, ACtx, AHeightBase, -1);
    maxCross := Max(maxCross, items[i].Cross + items[i].MT + items[i].MB);
    x := x + items[i].Main + items[i].MR + gap + extra;
  end;

  if ADefiniteContentH >= 0 then
    containerH := ADefiniteContentH
  else
    containerH := maxCross;

  for i := 0 to n - 1 do
  begin
    child := items[i].Node;
    dy := items[i].MT;
    case AParent.Style.AlignItems of
      xaiCenter:
        dy := items[i].MT + (containerH - (items[i].Cross + items[i].MT + items[i].MB)) / 2;
      xaiEnd:
        dy := containerH - items[i].Cross - items[i].MB;
      xaiStretch:
        if child.Style.Height.IsAuto and
           (containerH > items[i].Cross + items[i].MT + items[i].MB) then
        begin
          items[i].Cross := ArrangeNode(child, items[i].X, ATop, items[i].Main, ACtx,
            AHeightBase, Max(0, containerH - items[i].MT - items[i].MB));
          dy := items[i].MT;
        end;
    end;
    OffsetSubtree(child, 0, Round(dy));
  end;

  Result := containerH;
end;

// flex 主轴 = y
function ArrangeFlexColumn(AParent: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AHeightBase: Single; ADefiniteContentH: Single): Single;
var
  items: TFlexItems;
  n, i: Integer;
  child: TXuiNode;
  style: TXuiStyle;
  gap, totalMain, growSum, free, extra, y, h, dx, startOff: Single;
begin
  n := 0;
  SetLength(items, AParent.Count);
  gap := AParent.Style.RowGap.Resolve(AHeightBase);
  totalMain := 0;
  growSum := 0;

  for i := 0 to AParent.Count - 1 do
  begin
    child := AParent[i];
    if not IsInFlow(child) then
      Continue;
    style := child.Style;
    items[n].Node := child;
    items[n].ML := style.Margin.Left.Resolve(AWidth);
    items[n].MT := style.Margin.Top.Resolve(AWidth);
    items[n].MR := style.Margin.Right.Resolve(AWidth);
    items[n].MB := style.Margin.Bottom.Resolve(AWidth);

    // 交叉轴（宽）：显式 / stretch 填满 / max-content
    if not style.Width.IsAuto then
      items[n].Cross := ClampMin(style.Width.Resolve(AWidth), style.MinWidth, AWidth)
    else if AParent.Style.AlignItems = xaiStretch then
      items[n].Cross := Max(0, AWidth - items[n].ML - items[n].MR)
    else
    begin
      items[n].Cross := Min(MeasureNode(child, ACtx).cx,
        Max(0, AWidth - items[n].ML - items[n].MR));
      items[n].Cross := ClampMin(items[n].Cross, style.MinWidth, AWidth);
    end;

    // 主轴（高）：flex-basis > height > 内容（排布后回填）
    if not style.FlexBasis.IsAuto then
      items[n].Main := style.FlexBasis.Resolve(AHeightBase)
    else if not style.Height.IsAuto then
      items[n].Main := style.Height.Resolve(AHeightBase)
    else
      items[n].Main := -1;
    if items[n].Main >= 0 then
      items[n].Main := ClampMin(items[n].Main, style.MinHeight, AHeightBase);
    growSum := growSum + style.FlexGrow;
    Inc(n);
  end;
  SetLength(items, n);

  // 第一遍：确定各子项主轴尺寸
  y := ATop;
  for i := 0 to n - 1 do
  begin
    y := y + items[i].MT;
    h := ArrangeNode(items[i].Node, ALeft + items[i].ML, y, items[i].Cross, ACtx,
      AHeightBase, items[i].Main);
    if items[i].Main < 0 then
      items[i].Main := h;
    items[i].Y := y;
    y := y + items[i].Main + items[i].MB + gap;
  end;
  totalMain := y - ATop;
  if n > 0 then
    totalMain := totalMain - gap;

  if ADefiniteContentH >= 0 then
  begin
    free := Max(0, ADefiniteContentH - totalMain);
    if (free > 0) and (growSum > 0) then
    begin
      for i := 0 to n - 1 do
        if items[i].Node.Style.FlexGrow > 0 then
        begin
          items[i].Main := items[i].Main + free * items[i].Node.Style.FlexGrow / growSum;
          ArrangeNode(items[i].Node, ALeft + items[i].ML, items[i].Y, items[i].Cross, ACtx,
            AHeightBase, items[i].Main);
        end;
      y := ATop;
      for i := 0 to n - 1 do
      begin
        y := y + items[i].MT;
        items[i].Y := y;
        y := y + items[i].Main + items[i].MB + gap;
      end;
      totalMain := y - ATop;
      if n > 0 then
        totalMain := totalMain - gap;
      free := Max(0, ADefiniteContentH - totalMain);
    end;

    // justify-content（容器高度确定时才有效果）
    case AParent.Style.JustifyContent of
      xjcCenter:
        begin startOff := free / 2; extra := 0; end;
      xjcEnd:
        begin startOff := free; extra := 0; end;
      xjcSpaceBetween:
        begin
          startOff := 0;
          if n > 1 then extra := free / (n - 1) else extra := 0;
        end;
      xjcSpaceAround:
        begin
          if n > 0 then
          begin
            startOff := free / (2 * n);
            extra := free / n;
          end
          else
          begin
            startOff := 0;
            extra := 0;
          end;
        end;
    else
      startOff := 0;
      extra := 0;
    end;

    y := ATop + startOff;
    for i := 0 to n - 1 do
    begin
      y := y + items[i].MT;
      OffsetSubtree(items[i].Node, 0, Round(y - items[i].Y));
      items[i].Y := y;
      y := y + items[i].Main + items[i].MB + gap + extra;
    end;
  end;

  // 交叉轴对齐（水平偏移）
  for i := 0 to n - 1 do
  begin
    dx := items[i].ML;
    case AParent.Style.AlignItems of
      xaiCenter:
        dx := items[i].ML + (AWidth - items[i].Cross - items[i].ML - items[i].MR) / 2;
      xaiEnd:
        dx := AWidth - items[i].Cross - items[i].MR;
    end;
    OffsetSubtree(items[i].Node, Round(dx - items[i].ML), 0);
  end;

  if ADefiniteContentH >= 0 then
    Result := ADefiniteContentH
  else
    Result := totalMain;
end;

// 定位单个绝对定位节点：包含块 = 最近非 static 祖先的 padding box
procedure ArrangeOneAbsolute(child: TXuiNode; const ACtx: TLayoutContext);
var
  cb: TXuiNode;
  cbRect: TRect;
  cbW, cbH, mL, mR, mT, mB, w, h, x, dy: Single;
begin
  cb := ContainingBlockOf(child);
  if cb = nil then
    Exit;
  cbRect := cb.PaddingBox;
  cbW := cbRect.Right - cbRect.Left;
  cbH := cbRect.Bottom - cbRect.Top;
  mL := child.Style.Margin.Left.Resolve(cbW);
  mR := child.Style.Margin.Right.Resolve(cbW);
  mT := child.Style.Margin.Top.Resolve(cbW);
  mB := child.Style.Margin.Bottom.Resolve(cbW);

  if not child.Style.Width.IsAuto then
    w := ClampMin(child.Style.Width.Resolve(cbW), child.Style.MinWidth, cbW)
  else
  begin
    w := Min(MeasureNode(child, ACtx).cx, Max(0, cbW - mL - mR));
    w := ClampMin(w, child.Style.MinWidth, cbW);
  end;

  if not child.Style.Inset.Left.IsAuto then
    x := cbRect.Left + child.Style.Inset.Left.Resolve(cbW) + mL
  else if not child.Style.Inset.Right.IsAuto then
    x := cbRect.Right - child.Style.Inset.Right.Resolve(cbW) - w - mR
  else
    x := cbRect.Left + mL;

  h := ArrangeNode(child, x, cbRect.Top + mT, w, ACtx, cbH, -1);

  if not child.Style.Inset.Top.IsAuto then
    dy := child.Style.Inset.Top.Resolve(cbH) + mT
  else if not child.Style.Inset.Bottom.IsAuto then
    dy := cbH - child.Style.Inset.Bottom.Resolve(cbH) - h - mB
  else
    dy := mT;
  if Round(dy - mT) <> 0 then
    OffsetSubtree(child, 0, Round(dy - mT));

  ArrangeAbsolutesTree(child, ACtx);
end;

procedure ArrangeAbsolutesTree(ANode: TXuiNode; const ACtx: TLayoutContext);
var
  i: Integer;
  child: TXuiNode;
begin
  for i := 0 to ANode.Count - 1 do
  begin
    child := ANode[i];
    if (child.Style = nil) or (child.Style.Display = xdispNone) then
      Continue;
    if child.Style.Position = xposAbsolute then
      ArrangeOneAbsolute(child, ACtx)
    else
      ArrangeAbsolutesTree(child, ACtx);
  end;
end;

function ArrangeChildren(AParent: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AHeightBase: Single; ADefiniteContentH: Single): Single;
begin
  if AParent.Style.Display = xdispFlex then
  begin
    if AParent.Style.FlexDirection = xfdRow then
      Result := ArrangeFlexRow(AParent, ALeft, ATop, AWidth, ACtx, AHeightBase, ADefiniteContentH)
    else
      Result := ArrangeFlexColumn(AParent, ALeft, ATop, AWidth, ACtx, AHeightBase, ADefiniteContentH);
  end
  else
    Result := ArrangeBlock(AParent, ALeft, ATop, AWidth, ACtx, AHeightBase, ADefiniteContentH);
end;

// 排布单个节点：AX/AY/AWidth 为 border-box 位置与宽度；返回 border-box 高度（-1 的 AForcedHeight 表示高度 auto）
function ArrangeNode(ANode: TXuiNode; AX, AY, AWidth: Single;
  const ACtx: TLayoutContext; AParentHeight: Single; AForcedHeight: Single): Single;
var
  style: TXuiStyle;
  bw, padL, padT, padR, padB: Single;
  contentLeft, contentTop, contentW, contentH: Single;
  definiteH, heightBase, ownH, dx, dy: Single;
begin
  style := ANode.Style;
  if style = nil then
  begin
    ANode.BoxRect := Types.Rect(Round(AX), Round(AY), Round(AX + AWidth), Round(AY));
    Exit(0);
  end;

  bw := style.BorderWidth;
  padL := style.Padding.Left.Resolve(AWidth);
  padT := style.Padding.Top.Resolve(AWidth);
  padR := style.Padding.Right.Resolve(AWidth);
  padB := style.Padding.Bottom.Resolve(AWidth);
  contentLeft := AX + bw + padL;
  contentTop := AY + bw + padT;
  contentW := Max(0, AWidth - 2 * bw - padL - padR);

  if AForcedHeight >= 0 then
    definiteH := AForcedHeight
  else if not style.Height.IsAuto then
    definiteH := style.Height.Resolve(AParentHeight)
  else
    definiteH := -1;

  // 先写 BoxRect：绝对定位子节点在排布过程中会读取祖先 padding box
  ANode.BoxRect := Types.Rect(Round(AX), Round(AY), Round(AX + AWidth), Round(AY));

  if ANode.Count > 0 then
  begin
    SetLength(ANode.TextLines, 0);
    if definiteH >= 0 then
      heightBase := definiteH
    else
      heightBase := ACtx.ViewportHeight;
    // 滚动：子节点从内容盒左上减去 ScrollLeft/ScrollTop 处开始排布（返回的仍是自然内容高）
    contentH := ArrangeChildren(ANode, contentLeft - ANode.ScrollLeft, contentTop - ANode.ScrollTop, contentW,
      ACtx, heightBase,
      IfThen(definiteH >= 0, Max(0, definiteH - 2 * bw - padT - padB), -1));
    ANode.ContentHeight := contentH;
  end
  else if ANode.Text <> '' then
  begin
    if ANode.Tag = 'button' then
    begin
      SetLength(ANode.TextLines, 1);
      ANode.TextLines[0] := ANode.Text;
      contentH := LineHeightPx(style);
    end
    else
      contentH := WrapText(ANode.Text, style, contentW, ACtx.Measure, ANode.TextLines);

    // R1：自绘内容（多行输入）由行为在 RenderContent 里上报真实的多行滚动范围；
    // 布局不清零它，并在 auto 高度下沿用上一帧上报值（首帧退化为单行估算）。
    if ANode.SelfScrolls then
    begin
      ANode.ContentHeight := Max(ANode.ContentHeight, contentH);
      if style.Height.IsAuto then
        contentH := ANode.ContentHeight;
    end
    else
      ANode.ContentHeight := 0;
  end
  else
  begin
    SetLength(ANode.TextLines, 0);
    if ANode.SelfScrolls then
    begin
      if (style <> nil) and style.Height.IsAuto then
        contentH := ANode.ContentHeight
      else
        contentH := 0;
    end
    else
    begin
      ANode.ContentHeight := 0;
      contentH := 0;
    end;
  end;

  if definiteH >= 0 then
    ownH := definiteH
  else
    ownH := contentH + padT + padB + 2 * bw;
  ownH := ClampMin(ownH, style.MinHeight, AParentHeight);

  ANode.BoxRect := Types.Rect(Round(AX), Round(AY), Round(AX + AWidth), Round(AY + ownH));

  // 相对定位：布局后平移自身子树（不占流）
  if style.Position = xposRelative then
  begin
    dx := 0;
    dy := 0;
    if not style.Inset.Left.IsAuto then
      dx := style.Inset.Left.Resolve(AWidth)
    else if not style.Inset.Right.IsAuto then
      dx := -style.Inset.Right.Resolve(AWidth);
    if not style.Inset.Top.IsAuto then
      dy := style.Inset.Top.Resolve(AParentHeight)
    else if not style.Inset.Bottom.IsAuto then
      dy := -style.Inset.Bottom.Resolve(AParentHeight);
    if (dx <> 0) or (dy <> 0) then
      OffsetSubtree(ANode, Round(dx), Round(dy));
  end;

  Result := ownH;
end;

// 确保每个节点都有样式：未计算过的节点填充按标签的默认样式
procedure EnsureStyles(ANode: TXuiNode; AParentStyle: TXuiStyle);
var
  i: Integer;
begin
  if ANode.Style = nil then
    ANode.Style := DefaultStyleForTag(ANode.Tag, AParentStyle);
  for i := 0 to ANode.Count - 1 do
    EnsureStyles(ANode[i], ANode.Style);
end;

// 滚动范围收敛（R2/R3）：先记录自然内容宽，再把 ScrollTop/ScrollLeft 夹回合法范围。
// ContentHeight 仍由布局期记录；ContentWidth 在此按子节点在未滚动坐标系下的最大延伸求得，
// 且下界为内容盒宽度（子节点更窄时不产生横向滚动）。
function ClampScrollOffsets(ANode: TXuiNode): Boolean;
var
  i: Integer;
  content: TRect;
  boxW, boxH, maxTop, maxLeft, extentR: Single;
  child: TXuiNode;
begin
  Result := False;
  if ANode.Style <> nil then
  begin
    content := ANode.ContentBox;
    boxW := content.Right - content.Left;
    boxH := content.Bottom - content.Top;

    if ANode.Count > 0 then
    begin
      extentR := content.Left;
      for i := 0 to ANode.Count - 1 do
      begin
        child := ANode[i];
        if (child.Style = nil) or (child.Style.Display = xdispNone) or
           (child.Style.Position = xposAbsolute) then
          Continue;
        extentR := Max(extentR, child.BoxRect.Right + ANode.ScrollLeft);
      end;
      ANode.ContentWidth := Max(boxW, extentR - content.Left);
    end
    else
      // 只抬高：自绘内容（多行输入）在 RenderContent 里上报的自然宽必须保留
      ANode.ContentWidth := Max(ANode.ContentWidth, boxW);

    maxTop := Max(0, ANode.ContentHeight - boxH);
    if ANode.ScrollTop > maxTop then
    begin
      ANode.ScrollTop := maxTop;
      Result := True;
    end;
    if ANode.ScrollTop < 0 then
    begin
      ANode.ScrollTop := 0;
      Result := True;
    end;

    maxLeft := Max(0, ANode.ContentWidth - boxW);
    if ANode.ScrollLeft > maxLeft then
    begin
      ANode.ScrollLeft := maxLeft;
      Result := True;
    end;
    if ANode.ScrollLeft < 0 then
    begin
      ANode.ScrollLeft := 0;
      Result := True;
    end;
  end;
  for i := 0 to ANode.Count - 1 do
    if ClampScrollOffsets(ANode[i]) then
      Result := True;
end;

procedure LayoutDocument(ADoc: TXuiDocument;
  AViewportWidth, AViewportHeight: Single; AMeasure: TXuiMeasureFunc);
var
  ctx: TLayoutContext;
  root: TXuiNode;
begin
  if (ADoc = nil) or (ADoc.Root = nil) then
    Exit;

  ctx.Measure := AMeasure;
  ctx.ViewportWidth := AViewportWidth;
  ctx.ViewportHeight := AViewportHeight;

  root := ADoc.Root;
  EnsureStyles(root, nil);

  // 根元素铺满视口
  ArrangeNode(root, 0, 0, AViewportWidth, ctx, AViewportHeight, AViewportHeight);

  // 收尾 1：滚动范围与偏移收敛（必要时重排一次）
  if ClampScrollOffsets(root) then
    ArrangeNode(root, 0, 0, AViewportWidth, ctx, AViewportHeight, AViewportHeight);

  // 收尾 2：所有包含块矩形定稿后再定位绝对定位元素
  ArrangeAbsolutesTree(root, ctx);
end;

end.
