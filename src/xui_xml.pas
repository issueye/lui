unit xui_xml;

{$mode objfpc}{$H+}

{ XML → 节点树。使用 LazUtils 自带的 laz2_XMLRead / laz2_DOM，零第三方依赖。

  规则：
  - 元素节点 → TXuiNode（tag 转小写），属性原样保留；
  - class 属性拆分进 ClassList；id 属性同时存入 Node.Id；
  - 文本子节点（去除首尾空白后）合并为节点 Text；若存在 text 属性则优先 text 属性；
  - 未知属性不解释，交由行为类（xui_widget）处理。 }

interface

uses
  Classes, SysUtils, StrUtils,
  xui_dom;

function LoadDocumentFromFile(const AFileName: string): TXuiDocument;
function LoadDocumentFromXML(const AXMLContent: string): TXuiDocument;

implementation

uses
  laz2_dom, laz2_xmlread;

procedure CollectTextChildren(ADomNode: TDOMNode; var AText: string);
var
  child: TDOMNode;
  s: string;
begin
  child := ADomNode.FirstChild;
  while child <> nil do
  begin
    if child.NodeType = TEXT_NODE then
    begin
      s := Trim(child.NodeValue);
      if s <> '' then
      begin
        if AText <> '' then
          AText := AText + ' ';
        AText := AText + s;
      end;
    end;
    child := child.NextSibling;
  end;
end;

procedure SplitClasses(const AClassAttr: string; AList: TStringList);
var
  part, name: string;
begin
  AList.Clear;
  for part in SplitString(Trim(AClassAttr), ' ') do
  begin
    name := Trim(part);
    if name <> '' then
      AList.Add(name);
  end;
end;

function BuildNode(ADomElement: TDOMElement): TXuiNode;
var
  i: Integer;
  attr: TDOMNode;
  child: TDOMNode;
  node, childNode: TXuiNode;
  text: string;
begin
  node := TXuiNode.Create(ADomElement.NodeName);

  // 属性
  if ADomElement.HasAttributes then
  begin
    for i := 0 to ADomElement.Attributes.Length - 1 do
    begin
      attr := ADomElement.Attributes.Item[i];
      node.Attributes.Values[attr.NodeName] := attr.NodeValue;
    end;
  end;
  node.Id := node.AttributeValue('id');
  SplitClasses(node.AttributeValue('class'), node.ClassList);

  // 直接文本子节点（元素子节点之外）
  text := '';
  CollectTextChildren(ADomElement, text);
  node.Text := text;
  // text 属性优先（引擎约定：text 属性与文本子节点等价）
  if node.HasAttribute('text') then
    node.Text := node.AttributeValue('text');

  // 递归子元素
  child := ADomElement.FirstChild;
  while child <> nil do
  begin
    if child.NodeType = ELEMENT_NODE then
    begin
      childNode := BuildNode(TDOMElement(child));
      node.AddChild(childNode);
    end;
    child := child.NextSibling;
  end;

  Result := node;
end;

function BuildDocument(ADom: TXMLDocument): TXuiDocument;
var
  rootEl: TDOMElement;
begin
  Result := TXuiDocument.Create;
  try
    rootEl := ADom.DocumentElement;
    if rootEl = nil then
      raise Exception.Create('XML 缺少根元素');
    Result.Root := BuildNode(rootEl);
    Result.Title := Result.Root.AttributeValue('title');
  except
    Result.Free;
    raise;
  end;
end;

function LoadDocumentFromXML(const AXMLContent: string): TXuiDocument;
var
  stream: TStringStream;
  dom: TXMLDocument;
begin
  stream := TStringStream.Create(AXMLContent);
  try
    ReadXMLFile(dom, stream);
    try
      Result := BuildDocument(dom);
    finally
      dom.Free;
    end;
  finally
    stream.Free;
  end;
end;

function LoadDocumentFromFile(const AFileName: string): TXuiDocument;
var
  dom: TXMLDocument;
begin
  ReadXMLFile(dom, AFileName);
  try
    Result := BuildDocument(dom);
  finally
    dom.Free;
  end;
end;

end.
