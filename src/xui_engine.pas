unit xui_engine;

{$mode objfpc}{$H+}

{ 引擎门面：加载 XML → 应用默认样式 → 布局 → 渲染。
  宿主控件（xui_host）在 Paint 时调用 Draw；尺寸变化时调 SetViewport 使布局失效。 }

interface

uses
  Classes, SysUtils, Types, Graphics, Contnrs,
  xui_types, xui_style, xui_dom, xui_xml, xui_render, xui_layout, xui_widget,
  xui_css_parser, xui_css_match;

type
  TXuiEngine = class
  private
    FDocument: TXuiDocument;
    FRenderer: TXuiCustomRenderer;
    FStyleSheets: TObjectList; // TCssStyleSheet，加载顺序即应用顺序
    FViewportWidth, FViewportHeight: Integer;
    FLayoutValid: Boolean;
    FDocumentDirty: Boolean;  // 文档/样式表变更：需重建行为与样式
    FNeedsLayout: Boolean;    // 尺寸变更：需重算布局
    function DoMeasure(const AText: string; AStyle: TXuiStyle): TSize;
    procedure ApplyBehaviorsRecursive(ANode: TXuiNode);
    procedure RenderNode(ANode: TXuiNode; ACanvas: TCanvas);
    procedure RenderChildren(ANode: TXuiNode; ACanvas: TCanvas);
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromFile(const AFileName: string);
    procedure LoadFromString(const AXMLContent: string);

    // 样式表：可叠加多张，后加载的胜出（同特异性时）
    procedure LoadStyleSheetFromFile(const AFileName: string);
    procedure LoadStyleSheetFromString(const AContent: string);
    procedure ClearStyleSheets;

    // 尺寸变化后布局失效，下次 Draw 时重新布局
    procedure SetViewport(AWidth, AHeight: Integer);
    procedure InvalidateLayout;

    // 在指定画布上完成（必要时）布局与绘制
    procedure Draw(ACanvas: TCanvas; const ABounds: TRect);

    property Document: TXuiDocument read FDocument;
    property Renderer: TXuiCustomRenderer read FRenderer write FRenderer;
  end;

implementation

{ TXuiEngine }

constructor TXuiEngine.Create;
begin
  inherited Create;
  FStyleSheets := TObjectList.Create(True);
  FViewportWidth := 0;
  FViewportHeight := 0;
  FLayoutValid := False;
  FDocumentDirty := False;
  FNeedsLayout := False;
end;

destructor TXuiEngine.Destroy;
begin
  FStyleSheets.Free;
  FRenderer.Free;
  FDocument.Free;
  inherited Destroy;
end;

procedure TXuiEngine.LoadFromFile(const AFileName: string);
begin
  FDocument.Free;
  FDocument := LoadDocumentFromFile(AFileName);
  if FDocument.Root <> nil then
    ApplyBehaviorsRecursive(FDocument.Root);
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.LoadFromString(const AXMLContent: string);
begin
  FDocument.Free;
  FDocument := LoadDocumentFromXML(AXMLContent);
  if FDocument.Root <> nil then
    ApplyBehaviorsRecursive(FDocument.Root);
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.SetViewport(AWidth, AHeight: Integer);
begin
  if (AWidth <> FViewportWidth) or (AHeight <> FViewportHeight) then
  begin
    FViewportWidth := AWidth;
    FViewportHeight := AHeight;
    FNeedsLayout := True;
  end;
end;

procedure TXuiEngine.InvalidateLayout;
begin
  FNeedsLayout := True;
end;

procedure TXuiEngine.LoadStyleSheetFromFile(const AFileName: string);
var
  list: TStringList;
  sheet: TCssStyleSheet;
begin
  list := TStringList.Create;
  try
    list.LoadFromFile(AFileName);
    sheet := TCssStyleSheet.Create;
    sheet.ParseStyleSheet(list.Text);
    FStyleSheets.Add(sheet);
  finally
    list.Free;
  end;
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.LoadStyleSheetFromString(const AContent: string);
var
  sheet: TCssStyleSheet;
begin
  sheet := TCssStyleSheet.Create;
  sheet.ParseStyleSheet(AContent);
  FStyleSheets.Add(sheet);
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.ClearStyleSheets;
begin
  FStyleSheets.Clear;
  FDocumentDirty := True;
  FNeedsLayout := True;
end;

procedure TXuiEngine.ApplyBehaviorsRecursive(ANode: TXuiNode);
var
  i, ai: Integer;
  behavior: TXuiBehavior;
begin
  if ANode.Behavior = nil then
  begin
    behavior := CreateBehavior(ANode.Tag, ANode); // 未注册的标签返回 nil
    if behavior <> nil then
      for ai := 0 to ANode.Attributes.Count - 1 do
        behavior.HandleAttribute(ANode.Attributes.Names[ai],
          ANode.Attributes.ValueFromIndex[ai]);
  end;
  for i := 0 to ANode.Count - 1 do
    ApplyBehaviorsRecursive(ANode[i]);
end;

function TXuiEngine.DoMeasure(const AText: string; AStyle: TXuiStyle): TSize;
begin
  if FRenderer <> nil then
    Result := FRenderer.MeasureText(AText, AStyle)
  else
  begin
    Result.cx := Round(Length(AText) * AStyle.FontSize * 0.6);
    Result.cy := Round(AStyle.FontSize * AStyle.LineHeight);
  end;
end;

procedure TXuiEngine.Draw(ACanvas: TCanvas; const ABounds: TRect);
begin
  if (FDocument = nil) or (FDocument.Root = nil) then
    Exit;
  if FRenderer = nil then
    FRenderer := TGdiRenderer.Create(ACanvas);
  TGdiRenderer(FRenderer).Canvas := ACanvas;

  SetViewport(ABounds.Right - ABounds.Left, ABounds.Bottom - ABounds.Top);

  if FDocumentDirty or (not FLayoutValid) then
  begin
    ComputeDocumentStyles(FDocument, FStyleSheets);
    FDocumentDirty := False;
    FLayoutValid := True;
    FNeedsLayout := True;
  end;
  if FNeedsLayout then
  begin
    LayoutDocument(FDocument, FViewportWidth, FViewportHeight, @DoMeasure);
    FNeedsLayout := False;
  end;

  RenderNode(FDocument.Root, ACanvas);
end;

procedure TXuiEngine.RenderNode(ANode: TXuiNode; ACanvas: TCanvas);
var
  style: TXuiStyle;
  contentRect: TRect;
begin
  if (ANode.Style = nil) or (ANode.Style.Display = xdispNone) then
    Exit;
  style := ANode.Style;

  if style.BgColor.A > 0 then
    FRenderer.FillRect(ANode.BoxRect, style.BgColor);
  if style.BorderWidth > 0 then
    FRenderer.FrameRect(ANode.BoxRect, style.BorderColor, style.BorderWidth);

  contentRect := ANode.ContentRect;
  if (ANode.Text <> '') and (ANode.Count = 0) then
    FRenderer.DrawText(contentRect, ANode.Text, style);

  RenderChildren(ANode, ACanvas);
end;

procedure TXuiEngine.RenderChildren(ANode: TXuiNode; ACanvas: TCanvas);
var
  i: Integer;
begin
  for i := 0 to ANode.Count - 1 do
    RenderNode(ANode[i], ACanvas);
end;

end.
