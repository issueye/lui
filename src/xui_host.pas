unit xui_host;

{$mode objfpc}{$H+}

{ TXuiHost — 引擎在 Lazarus 窗体上的宿主控件（整个引擎唯一的原生控件入口）。
  负责：接收系统绘制/尺寸消息并转发给引擎；提供 XML 文件装载入口。 }

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms,
  xui_types, xui_style, xui_dom, xui_engine;

type
  TXuiHost = class(TCustomControl)
  private
    FEngine: TXuiEngine;
    procedure SetXmlFile(const AValue: string);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadFromFile(const AFileName: string);
    // 依据根元素 width/height 属性调整宿主尺寸（demo 用）
    procedure FitToDocumentDefaultSize;
    property Engine: TXuiEngine read FEngine;
  published
    property XmlFile: string write SetXmlFile;
    property Align;
    property Anchors;
    property Color;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnEnter;
    property OnExit;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

implementation

{ TXuiHost }

constructor TXuiHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 320;
  Height := 240;
  DoubleBuffered := True;
  // 引擎自绘全部像素，告诉 LCL 不要擦背景（避免闪烁）
  ControlStyle := ControlStyle + [csOpaque];
  Color := clWhite;
  FEngine := TXuiEngine.Create;
end;

destructor TXuiHost.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

procedure TXuiHost.Loaded;
begin
  inherited Loaded;
  // DFM 流加载完成后若指定了 XmlFile，此处已被 SetXmlFile 处理
end;

procedure TXuiHost.SetXmlFile(const AValue: string);
begin
  LoadFromFile(AValue);
end;

procedure TXuiHost.LoadFromFile(const AFileName: string);
begin
  FEngine.LoadFromFile(AFileName);
  Invalidate;
end;

procedure TXuiHost.FitToDocumentDefaultSize;
var
  root: TXuiNode;
  v: Integer;
begin
  root := FEngine.Document.Root;
  if root = nil then
    Exit;
  // 读取根元素 width/height 属性（引擎 M1 中样式为惰性计算，此处直接取属性）
  if TryStrToInt(Trim(root.AttributeValue('width')), v) then
    ClientWidth := v;
  if TryStrToInt(Trim(root.AttributeValue('height')), v) then
    ClientHeight := v;
end;

procedure TXuiHost.Paint;
begin
  if FEngine = nil then Exit;
  // 引擎自绘全部内容
  FEngine.Draw(Canvas, ClientRect);
end;

procedure TXuiHost.Resize;
begin
  inherited Resize;
  // 注意：构造函数中设置初始尺寸时引擎尚未创建
  if FEngine = nil then Exit;
  FEngine.SetViewport(ClientWidth, ClientHeight);
  Invalidate;
end;

end.
