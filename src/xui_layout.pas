unit xui_layout;

{$mode objfpc}{$H+}

{ M1 布局引擎：块级流（纵向堆叠）+ 盒模型（默认 border-box）。
  通过测量回调解耦画布（测试可注入假测量），M3 扩展 flex 子集与文本换行。

  坐标系：布局结果 BoxRect 为绝对像素坐标（根节点原点 = 宿主内容区左上角）。
  说明：M1 的百分比高度以视口高度为参照；auto 外边距按 0 处理（M3 再实现居中）。 }

interface

uses
  SysUtils, Types, Math,
  xui_types, xui_style, xui_dom;

type
  // 文本测量回调：由引擎绑定到渲染器（测试可注入假测量）
  TXuiMeasureFunc = function(const AText: string; AStyle: TXuiStyle): TSize of object;

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

// 布局单个节点：ALeft/ATop/AWidth 为 border-box 的位置与宽度；返回 border-box 高度
function LayoutNode(ANode: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AParentHeight: Single): Single; forward;

// 布局父节点的内容盒中的全部子节点；返回流结束的绝对 Y（含最后一个子节点的外边距）
procedure LayoutChildren(AParent: TXuiNode; const AContent: TRect;
  const ACtx: TLayoutContext; AParentHeight: Single; out AFlowBottom: Single);
var
  i: Integer;
  child: TXuiNode;
  y: Single;
  availW, mL, mR, mT, mB, childW, childH: Single;
begin
  y := AContent.Top;
  availW := AContent.Right - AContent.Left;

  for i := 0 to AParent.Count - 1 do
  begin
    child := AParent[i];
    if (child.Style = nil) or (child.Style.Display = xdispNone) then
      Continue;

    mL := child.Style.Margin.Left.Resolve(availW);
    mR := child.Style.Margin.Right.Resolve(availW);
    mT := child.Style.Margin.Top.Resolve(availW);
    mB := child.Style.Margin.Bottom.Resolve(availW);

    if child.Style.Width.IsAuto then
      childW := Max(0, availW - mL - mR)
    else
      childW := child.Style.Width.Resolve(availW);

    childH := LayoutNode(child, AContent.Left + mL, y + mT, childW,
      ACtx, AParentHeight);
    y := (y + mT) + childH + mB;
  end;

  AFlowBottom := y;
end;

// 布局单个节点：ALeft/ATop/AWidth 为 border-box 的位置与宽度；返回 border-box 高度
function LayoutNode(ANode: TXuiNode; ALeft, ATop, AWidth: Single;
  const ACtx: TLayoutContext; AParentHeight: Single): Single;
var
  style: TXuiStyle;
  bw: Single;
  padL, padT, padR, padB: Single;
  contentLeft, contentTop, contentW: Single;
  contentH, flowBottom, parentH: Single;
  sz: TSize;
  contentRect: TRect;
begin
  style := ANode.Style;
  if style = nil then
  begin
    ANode.BoxRect := Types.Rect(Round(ALeft), Round(ATop),
      Round(ALeft + AWidth), Round(ATop));
    Exit(0);
  end;

  bw := style.BorderWidth;
  padL := style.Padding.Left.Resolve(AWidth);
  padT := style.Padding.Top.Resolve(AWidth);
  padR := style.Padding.Right.Resolve(AWidth);
  padB := style.Padding.Bottom.Resolve(AWidth);

  contentLeft := ALeft + bw + padL;
  contentTop := ATop + bw + padT;
  contentW := Max(0, AWidth - 2 * bw - padL - padR);

  if ANode.Count > 0 then
  begin
    // 容器：按块级流排布子节点；Bottom 占大值（子节点定位不依赖父内容底边）
    contentRect := Types.Rect(Round(contentLeft), Round(contentTop),
      Round(contentLeft + contentW), High(Integer) div 4);
    // 子节点百分比高度的参照：本节点显式高度，否则视口高度
    if not style.Height.IsAuto then
      parentH := style.Height.Resolve(ACtx.ViewportHeight)
    else
      parentH := ACtx.ViewportHeight;
    LayoutChildren(ANode, contentRect, ACtx, parentH, flowBottom);
    contentH := flowBottom - contentTop;
  end
  else if ANode.Text <> '' then
  begin
    if ACtx.Measure <> nil then
    begin
      sz := ACtx.Measure(ANode.Text, style);
      contentH := Max(Single(sz.cy), style.FontSize * style.LineHeight);
    end
    else
      contentH := style.FontSize * style.LineHeight;
  end
  else
    contentH := 0;

  if not style.Height.IsAuto then
    Result := style.Height.Resolve(AParentHeight)
  else
    Result := contentH + padT + padB + 2 * bw;

  ANode.BoxRect := Types.Rect(Round(ALeft), Round(ATop),
    Round(ALeft + AWidth), Round(ATop + Result));
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

procedure LayoutDocument(ADoc: TXuiDocument;
  AViewportWidth, AViewportHeight: Single; AMeasure: TXuiMeasureFunc);
var
  ctx: TLayoutContext;
  root: TXuiNode;
  contentRect: TRect;
  flowBottom: Single;
begin
  if (ADoc = nil) or (ADoc.Root = nil) then
    Exit;

  ctx.Measure := AMeasure;
  ctx.ViewportWidth := AViewportWidth;
  ctx.ViewportHeight := AViewportHeight;

  root := ADoc.Root;
  EnsureStyles(root, nil);

  // 根元素铺满视口
  root.BoxRect := Types.Rect(0, 0, Round(AViewportWidth), Round(AViewportHeight));

  contentRect := root.ContentRect;
  LayoutChildren(root, contentRect, ctx, AViewportHeight, flowBottom);
end;

end.
