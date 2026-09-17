unit xui_scroll;

{$mode objfpc}{$H+}

{ R2/R3：滚动容器策略与滚动条几何（纯逻辑，不依赖 LCL 与渲染后端）。

  overflow 语义（TXuiOverflow）：
  - visible：不裁剪、不滚动
  - hidden ：裁剪 + 可编程滚动，但**不绘制滚动条**（v1 既有行为，保持不变）
  - auto   ：裁剪 + 滚动 + 内容溢出时按需显示滚动条
  - scroll ：裁剪 + 滚动 + 常显滚动条

  滚动条以**覆盖**方式绘制在 padding box 内侧（不占用内容宽度），避免"出现滚动条→内容变窄→
  重新布局"的反馈环；代价是窄容器下滚动条会遮挡边缘内容（已写入不支持清单）。

  几何与命中测试共用本单元，保证"看到的"与"可点的"一致。 }

interface

uses
  Types, Math,
  xui_types, xui_style, xui_dom;

const
  // 滚动条厚度（px）；轨道/滑块颜色为引擎默认值（尚无对应 CSS 属性，见不支持清单）
  XuiScrollbarThickness = 8;
  XuiScrollbarMinThumb = 24;

// overflow 是否构成滚动容器（hidden/auto/scroll）
function XuiIsScrollContainer(AStyle: TXuiStyle): Boolean;
// 是否绘制滚动条（hidden 不绘制，保持 v1 语义）
function XuiDrawsScrollbars(AStyle: TXuiStyle): Boolean;
// 最大滚动量（内容不足时为 0）
function XuiMaxScrollTop(ANode: TXuiNode): Single;
function XuiMaxScrollLeft(ANode: TXuiNode): Single;

type
  TXuiScrollBarLayout = record
    ShowV, ShowH: Boolean;
    VTrack, VThumb: TRect;
    HTrack, HThumb: TRect;
  end;

// 滚动条几何（须在布局后调用）
function XuiScrollBarLayout(ANode: TXuiNode): TXuiScrollBarLayout;
// 子节点可用区：padding box 去掉已显示滚动条占用的条带，并与外部裁剪区求交
function XuiScrollContentClip(ANode: TXuiNode; const AClip: TRect): TRect;
// 轨道 / 滑块颜色（引擎默认；浅深主题下均为中性灰）
function XuiScrollbarTrackColor: TXuiColor;
function XuiScrollbarThumbColor: TXuiColor;

implementation

function XuiIsScrollContainer(AStyle: TXuiStyle): Boolean;
begin
  Result := (AStyle <> nil) and (AStyle.Overflow <> xovVisible);
end;

function XuiDrawsScrollbars(AStyle: TXuiStyle): Boolean;
begin
  Result := (AStyle <> nil) and (AStyle.Overflow in [xovAuto, xovScroll]);
end;

function XuiMaxScrollTop(ANode: TXuiNode): Single;
var
  boxH: Single;
begin
  if ANode.Style = nil then
    Exit(0);
  boxH := ANode.ContentBox.Bottom - ANode.ContentBox.Top;
  Result := Max(0, ANode.ContentHeight - boxH);
end;

function XuiMaxScrollLeft(ANode: TXuiNode): Single;
var
  boxW: Single;
begin
  if ANode.Style = nil then
    Exit(0);
  boxW := ANode.ContentBox.Right - ANode.ContentBox.Left;
  Result := Max(0, ANode.ContentWidth - boxW);
end;

function ThumbSpan(ATrackLen, AVisible, ATotal: Single): Integer;
var
  len: Single;
begin
  if (ATrackLen <= 0) or (ATotal <= 0) then
    Exit(0);
  len := ATrackLen * AVisible / ATotal;
  len := Max(len, XuiScrollbarMinThumb);
  Result := Round(Min(len, ATrackLen));
end;

function ThumbOffset(ATrackLen, AThumbLen: Integer; APos, AMax: Single): Integer;
begin
  if (AMax <= 0) or (ATrackLen - AThumbLen <= 0) then
    Exit(0);
  Result := Round((ATrackLen - AThumbLen) * Min(Max(APos, 0), AMax) / AMax);
end;

function XuiScrollBarLayout(ANode: TXuiNode): TXuiScrollBarLayout;
var
  pad: TRect;
  maxTop, maxLeft, vTrackLen, hTrackLen: Single;
  vLen, hLen, vOff, hOff: Integer;
begin
  Result.ShowV := False;
  Result.ShowH := False;
  Result.VTrack := Types.Rect(0, 0, 0, 0);
  Result.VThumb := Result.VTrack;
  Result.HTrack := Result.VTrack;
  Result.HThumb := Result.VTrack;
  if (ANode = nil) or (ANode.Style = nil) or
     (ANode.Style.Display = xdispNone) or (not XuiDrawsScrollbars(ANode.Style)) then
    Exit;
  // 自绘内容（如多行输入）没有子节点，但有滚动范围，同样需要滚动条
  if (ANode.ContentHeight <= 0) and (ANode.ContentWidth <= 0) then
    Exit;

  maxTop := XuiMaxScrollTop(ANode);
  maxLeft := XuiMaxScrollLeft(ANode);
  Result.ShowV := (ANode.Style.Overflow = xovScroll) or (maxTop > 0);
  Result.ShowH := (ANode.Style.Overflow = xovScroll) or (maxLeft > 0);
  if (not Result.ShowV) and (not Result.ShowH) then
    Exit;

  pad := ANode.PaddingBox;
  vTrackLen := (pad.Bottom - pad.Top) - IfThen(Result.ShowH, XuiScrollbarThickness, 0);
  hTrackLen := (pad.Right - pad.Left) - IfThen(Result.ShowV, XuiScrollbarThickness, 0);

  if Result.ShowV then
  begin
    Result.VTrack := Types.Rect(pad.Right - XuiScrollbarThickness, pad.Top,
      pad.Right, pad.Top + Round(Max(0, vTrackLen)));
    vLen := ThumbSpan(vTrackLen, pad.Bottom - pad.Top, ANode.ContentHeight);
    vOff := ThumbOffset(Round(vTrackLen), vLen, ANode.ScrollTop, maxTop);
    Result.VThumb := Types.Rect(Result.VTrack.Left, Result.VTrack.Top + vOff,
      Result.VTrack.Right, Result.VTrack.Top + vOff + vLen);
  end;

  if Result.ShowH then
  begin
    Result.HTrack := Types.Rect(pad.Left, pad.Bottom - XuiScrollbarThickness,
      pad.Left + Round(Max(0, hTrackLen)), pad.Bottom);
    hLen := ThumbSpan(hTrackLen, pad.Right - pad.Left, ANode.ContentWidth);
    hOff := ThumbOffset(Round(hTrackLen), hLen, ANode.ScrollLeft, maxLeft);
    Result.HThumb := Types.Rect(Result.HTrack.Left + hOff, Result.HTrack.Top,
      Result.HTrack.Left + hOff + hLen, Result.HTrack.Bottom);
  end;
end;

function XuiScrollContentClip(ANode: TXuiNode; const AClip: TRect): TRect;
var
  pad: TRect;
  bars: TXuiScrollBarLayout;
begin
  pad := ANode.PaddingBox;
  Result := Types.Rect(Max(pad.Left, AClip.Left), Max(pad.Top, AClip.Top),
    Min(pad.Right, AClip.Right), Min(pad.Bottom, AClip.Bottom));
  bars := XuiScrollBarLayout(ANode);
  if bars.ShowV then
    Result.Right := Max(Result.Left, Result.Right - XuiScrollbarThickness);
  if bars.ShowH then
    Result.Bottom := Max(Result.Top, Result.Bottom - XuiScrollbarThickness);
end;

function XuiScrollbarTrackColor: TXuiColor;
begin
  Result := XuiRGB($E9, $EC, $EF);
end;

function XuiScrollbarThumbColor: TXuiColor;
begin
  Result := XuiRGB($9A, $A0, $A6);
end;

end.
