unit xui_anim;

{$mode objfpc}{$H+}

{ 属性过渡动画（M5）：纯逻辑、不依赖 LCL，时间由引擎注入（便于单元测试）。
  - 只处理白名单内的绘制类属性（opacity / 颜色 / 圆角），不触发布局
  - 引擎在样式重算前调用 Capture（记录显示值），重算后调用 Resolve（diff → 启动/重启）
    并立即 ApplyValues 写回插值；Tick 中调用 Advance 推进 }

interface

uses
  Classes, SysUtils, Contnrs, Math,
  xui_types, xui_style, xui_dom;

type
  TXuiAnimValueKind = (xavNone, xavNumber, xavColor);

  TXuiAnimValue = record
    Kind: TXuiAnimValueKind;
    Num: Single;
    Color: TXuiColor;
  end;

  TXuiPropAnim = record
    Active: Boolean;
    BaseV: TXuiAnimValue;   // 样式重算前的显示值（diff 基准）
    FromV: TXuiAnimValue;   // 本次动画起点
    ToV: TXuiAnimValue;     // 本次动画终点
    Delay: Single;          // 秒
    Duration: Single;       // 秒
    Timing: TXuiTimingFunction;
    StartMs: Int64;
  end;

  TXuiNodeAnim = class
  public
    Node: TXuiNode;                                  // 弱引用（DOM 变更前必须 Reset）
    Props: array[TXuiAnimProp] of TXuiPropAnim;
  end;

  TXuiTransitionSet = class
  private
    FItems: TObjectList;                             // TXuiNodeAnim
    function FindItem(ANode: TXuiNode): TXuiNodeAnim;
    function EnsureItem(ANode: TXuiNode): TXuiNodeAnim;
    procedure ApplyValues(ANowMs: Int64);
    procedure PurgeUnused(ADoc: TXuiDocument);
  public
    constructor Create;
    destructor Destroy; override;
    // DOM 发生增删（节点可能被释放）时必须重置
    procedure Reset;
    // 样式重算前：记录当前显示值（含动画中的插值）
    procedure Capture(ADoc: TXuiDocument);
    // 样式重算后：与新计算值 diff，启动/重启过渡；随后立即写回当前插值
    procedure Resolve(ADoc: TXuiDocument; ANowMs: Int64);
    function Advance(ANowMs: Int64): Boolean;        // 推进；返回是否有动画在运行
    function HasActive: Boolean;
  end;

function XuiAnimNumber(AValue: Single): TXuiAnimValue;
function XuiAnimColor(const AColor: TXuiColor): TXuiAnimValue;
function XuiAnimSame(const A, B: TXuiAnimValue): Boolean;
function XuiAnimLerp(const A, B: TXuiAnimValue; AT: Single): TXuiAnimValue;
function XuiAnimReadProp(AStyle: TXuiStyle; AProp: TXuiAnimProp): TXuiAnimValue;
procedure XuiAnimWriteProp(AStyle: TXuiStyle; AProp: TXuiAnimProp; const V: TXuiAnimValue);

implementation

function XuiAnimNumber(AValue: Single): TXuiAnimValue;
begin
  Result.Kind := xavNumber;
  Result.Num := AValue;
  Result.Color := XuiRGBA(0, 0, 0, 0);
end;

function XuiAnimColor(const AColor: TXuiColor): TXuiAnimValue;
begin
  Result.Kind := xavColor;
  Result.Num := 0;
  Result.Color := AColor;
end;

function XuiAnimSame(const A, B: TXuiAnimValue): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    xavNumber: Result := Abs(A.Num - B.Num) < 0.001;
    xavColor: Result := XuiSameColor(A.Color, B.Color);
  else
    Result := True;
  end;
end;

function XuiAnimLerp(const A, B: TXuiAnimValue; AT: Single): TXuiAnimValue;
begin
  if A.Kind <> B.Kind then
    Exit(B);
  case A.Kind of
    xavNumber:
      Result := XuiAnimNumber(A.Num + (B.Num - A.Num) * AT);
    xavColor:
      Result := XuiAnimColor(XuiMixColor(A.Color, B.Color, AT));
  else
    Result := B;
  end;
end;

function XuiAnimReadProp(AStyle: TXuiStyle; AProp: TXuiAnimProp): TXuiAnimValue;
begin
  Result := XuiAnimNumber(0);
  if AStyle = nil then
    Exit;
  case AProp of
    xapOpacity: Result := XuiAnimNumber(AStyle.Opacity);
    xapBgColor: Result := XuiAnimColor(AStyle.BgColor);
    xapTextColor: Result := XuiAnimColor(AStyle.TextColor);
    xapBorderColor: Result := XuiAnimColor(AStyle.BorderColor);
    xapBorderRadius: Result := XuiAnimNumber(AStyle.BorderRadius);
  end;
end;

procedure XuiAnimWriteProp(AStyle: TXuiStyle; AProp: TXuiAnimProp; const V: TXuiAnimValue);
begin
  if AStyle = nil then
    Exit;
  case AProp of
    xapOpacity: AStyle.Opacity := V.Num;
    xapBgColor: AStyle.BgColor := V.Color;
    xapTextColor: AStyle.TextColor := V.Color;
    xapBorderColor: AStyle.BorderColor := V.Color;
    xapBorderRadius: AStyle.BorderRadius := V.Num;
  end;
end;

{ TXuiTransitionSet }

constructor TXuiTransitionSet.Create;
begin
  inherited Create;
  FItems := TObjectList.Create(True);
end;

destructor TXuiTransitionSet.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TXuiTransitionSet.Reset;
begin
  FItems.Clear;
end;

function TXuiTransitionSet.FindItem(ANode: TXuiNode): TXuiNodeAnim;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    if TXuiNodeAnim(FItems[i]).Node = ANode then
      Exit(TXuiNodeAnim(FItems[i]));
  Result := nil;
end;

function TXuiTransitionSet.EnsureItem(ANode: TXuiNode): TXuiNodeAnim;
var
  p: TXuiAnimProp;
begin
  Result := FindItem(ANode);
  if Result <> nil then
    Exit;
  Result := TXuiNodeAnim.Create;
  Result.Node := ANode;
  for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
  begin
    Result.Props[p].Active := False;
    Result.Props[p].BaseV.Kind := xavNone;
    Result.Props[p].FromV.Kind := xavNone;
    Result.Props[p].ToV.Kind := xavNone;
  end;
  FItems.Add(Result);
end;

procedure TXuiTransitionSet.Capture(ADoc: TXuiDocument);
var
  i: Integer;
  item: TXuiNodeAnim;
  style: TXuiStyle;
  p: TXuiAnimProp;
begin
  for i := 0 to FItems.Count - 1 do
  begin
    item := TXuiNodeAnim(FItems[i]);
    style := item.Node.Style;
    if style = nil then
      Continue;
    for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
      if p in style.TransitionProps then
        item.Props[p].BaseV := XuiAnimReadProp(style, p);
  end;
end;

procedure TXuiTransitionSet.Resolve(ADoc: TXuiDocument; ANowMs: Int64);

  procedure Walk(ANode: TXuiNode);
  var
    style: TXuiStyle;
    item: TXuiNodeAnim;
    newV: TXuiAnimValue;
    i: Integer;
    p: TXuiAnimProp;
  begin
    style := ANode.Style;
    if (style <> nil) and (style.TransitionProps <> []) then
    begin
      item := EnsureItem(ANode);
      for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
        if p in style.TransitionProps then
        begin
          newV := XuiAnimReadProp(style, p);
          if item.Props[p].BaseV.Kind = xavNone then
            item.Props[p].BaseV := newV // 首次声明过渡：以当前值为基准，不产生动画
          else if not XuiAnimSame(item.Props[p].BaseV, newV) then
          begin
            // 值变化：从当前显示值过渡到新值（进行中的动画以当前插值为起点）
            item.Props[p].FromV := item.Props[p].BaseV;
            item.Props[p].ToV := newV;
            item.Props[p].Delay := style.TransitionDelay;
            item.Props[p].Duration := style.TransitionDuration;
            item.Props[p].Timing := style.TransitionTiming;
            item.Props[p].StartMs := ANowMs;
            item.Props[p].Active := style.TransitionDuration > 0;
            item.Props[p].BaseV := newV;
          end;
        end;
    end;
    for i := 0 to ANode.Count - 1 do
      Walk(ANode[i]);
  end;

begin
  if (ADoc = nil) or (ADoc.Root = nil) then
    Exit;
  Walk(ADoc.Root);
  PurgeUnused(ADoc);
  ApplyValues(ANowMs);
end;

procedure TXuiTransitionSet.ApplyValues(ANowMs: Int64);
var
  i: Integer;
  item: TXuiNodeAnim;
  p: TXuiAnimProp;
  elapsed, t: Single;
  v: TXuiAnimValue;
begin
  for i := 0 to FItems.Count - 1 do
  begin
    item := TXuiNodeAnim(FItems[i]);
    if item.Node.Style = nil then
      Continue;
    for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
    begin
      if not item.Props[p].Active then
        Continue;
      elapsed := (ANowMs - item.Props[p].StartMs) / 1000 - item.Props[p].Delay;
      if elapsed <= 0 then
        v := item.Props[p].FromV
      else if (item.Props[p].Duration <= 0) or (elapsed >= item.Props[p].Duration) then
      begin
        v := item.Props[p].ToV;
        item.Props[p].Active := False;
      end
      else
      begin
        t := XuiTimingEval(item.Props[p].Timing, elapsed / item.Props[p].Duration);
        v := XuiAnimLerp(item.Props[p].FromV, item.Props[p].ToV, t);
      end;
      XuiAnimWriteProp(item.Node.Style, p, v);
    end;
  end;
end;

procedure TXuiTransitionSet.PurgeUnused(ADoc: TXuiDocument);
var
  i: Integer;
  item: TXuiNodeAnim;
begin
  for i := FItems.Count - 1 downto 0 do
  begin
    item := TXuiNodeAnim(FItems[i]);
    if (item.Node.Root <> ADoc.Root) or (item.Node.Style = nil) or
       (item.Node.Style.TransitionProps = []) then
      FItems.Delete(i);
  end;
end;

function TXuiTransitionSet.Advance(ANowMs: Int64): Boolean;
begin
  Result := HasActive;
  if Result then
    ApplyValues(ANowMs);
end;

function TXuiTransitionSet.HasActive: Boolean;
var
  i: Integer;
  item: TXuiNodeAnim;
  p: TXuiAnimProp;
begin
  for i := 0 to FItems.Count - 1 do
  begin
    item := TXuiNodeAnim(FItems[i]);
    for p := Low(TXuiAnimProp) to High(TXuiAnimProp) do
      if item.Props[p].Active then
        Exit(True);
  end;
  Result := False;
end;

end.
