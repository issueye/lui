unit xui_xml;

{$mode objfpc}{$H+}

{ XML → 节点树。使用 LazUtils 自带的 laz2_XMLRead / laz2_DOM，零第三方依赖。

  规则：
  - 元素节点 → TXuiNode（tag 转小写），属性原样保留；
  - class 属性拆分进 ClassList；id 属性同时存入 Node.Id；
  - 文本子节点（去除首尾空白后）合并为节点 Text；若存在 text 属性则优先 text 属性；
  - <include src="xxx.xml"/> 在解析期展开（不产生节点，M5 模板复用）：
      被包含文件根为 <template> → 展开其子元素（可多节点）；否则展开根元素自身；
      src 相对包含者文件目录解析；循环包含抛异常；
      <include> 上的其他属性（class/id/text 等）仅在展开结果为单节点时合并到该节点；
  - 未知属性不解释，交由行为类（xui_widget）处理。 }

interface

uses
  Classes, SysUtils, StrUtils,
  xui_dom;

function LoadDocumentFromFile(const AFileName: string): TXuiDocument;
function LoadDocumentFromXML(const AXMLContent: string; const ABaseDir: string = ''): TXuiDocument;

implementation

uses
  laz2_dom, laz2_xmlread;

type
  // include 展开上下文：相对路径基准 + 循环检测 + 依赖收集（热重载用）
  TIncludeContext = class
  public
    BaseDir: string;
    Stack: TStringList;        // 正在展开的文件（ExpandFileName 规范化）
    Dependencies: TStringList; // 展开过的全部文件
    constructor Create(const ABaseDir: string; ADependencies: TStringList);
    destructor Destroy; override;
  end;

constructor TIncludeContext.Create(const ABaseDir: string; ADependencies: TStringList);
begin
  inherited Create;
  BaseDir := ABaseDir;
  Stack := TStringList.Create;
  Dependencies := ADependencies;
end;

destructor TIncludeContext.Destroy;
begin
  Stack.Free;
  inherited Destroy;
end;

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

// 绝对路径判定（Windows 盘符 / UNC；Unix 以 / 开头）
function PathIsAbsolute(const APath: string): Boolean;
begin
  if APath = '' then
    Exit(False);
  {$IFDEF UNIX}
  Result := APath[1] = '/';
  {$ELSE}
  Result := ((Length(APath) >= 2) and (APath[2] = ':')) or
    ((Length(APath) >= 2) and (APath[1] = PathDelim) and (APath[2] = PathDelim));
  {$ENDIF}
end;

// 读取单个属性（laz2_dom 未公开便捷 API，按现有代码风格遍历）
function AttrOf(AEl: TDOMElement; const AName: string): string;
var
  i: Integer;
  attr: TDOMNode;
begin
  Result := '';
  if not AEl.HasAttributes then
    Exit;
  for i := 0 to AEl.Attributes.Length - 1 do
  begin
    attr := AEl.Attributes.Item[i];
    if CompareText(attr.NodeName, AName) = 0 then
      Exit(attr.NodeValue);
  end;
end;

// 单个元素 → 节点（属性/类/文本；不含子元素）
function BuildNodeSelf(ADomElement: TDOMElement): TXuiNode;
var
  i: Integer;
  attr: TDOMNode;
  text: string;
begin
  Result := TXuiNode.Create(ADomElement.NodeName);
  if ADomElement.HasAttributes then
  begin
    for i := 0 to ADomElement.Attributes.Length - 1 do
    begin
      attr := ADomElement.Attributes.Item[i];
      Result.Attributes.Values[attr.NodeName] := attr.NodeValue;
    end;
  end;
  Result.Id := Result.AttributeValue('id');
  SplitClasses(Result.AttributeValue('class'), Result.ClassList);

  text := '';
  CollectTextChildren(ADomElement, text);
  Result.Text := text;
  if Result.HasAttribute('text') then
    Result.Text := Result.AttributeValue('text');
end;

procedure BuildInto(ADomElement: TDOMElement; AParent: TXuiNode;
  ACtx: TIncludeContext); forward;

// 展开 <include src="..."/>：被包含文件的根（template → 其子元素）替换 include 节点
procedure BuildInclude(AEl: TDOMElement; AParent: TXuiNode; ACtx: TIncludeContext);
var
  src, path: string;
  dom: TXMLDocument;
  root: TDOMElement;
  node: TXuiNode;
  i, count: Integer;
  child: TDOMNode;
  attrName: string;
begin
  src := Trim(AttrOf(AEl, 'src'));
  if src = '' then
    raise Exception.Create('<include> 缺少 src 属性');
  path := src;
  if not PathIsAbsolute(path) then
    path := ACtx.BaseDir + PathDelim + path;
  path := ExpandFileName(path);
  if not FileExists(path) then
    raise Exception.CreateFmt('<include> 文件不存在: %s', [path]);
  if ACtx.Stack.IndexOf(path) >= 0 then
    raise Exception.CreateFmt('include 循环引用: %s', [path]);
  if ACtx.Dependencies.IndexOf(path) < 0 then
    ACtx.Dependencies.Add(path);

  ReadXMLFile(dom, path);
  try
    root := dom.DocumentElement;
    if root = nil then
      raise Exception.CreateFmt('<include> 文件缺少根元素: %s', [path]);
    ACtx.Stack.Add(path);
    try
      count := 0;
      if CompareText(root.NodeName, 'template') = 0 then
      begin
        // 模板：展开其子元素（可多节点）
        child := root.FirstChild;
        while child <> nil do
        begin
          if child.NodeType = ELEMENT_NODE then
          begin
            BuildInto(TDOMElement(child), AParent, ACtx);
            Inc(count);
          end;
          child := child.NextSibling;
        end;
      end
      else
      begin
        BuildInto(root, AParent, ACtx);
        count := 1;
      end;

      // include 上的附加属性：仅在单节点结果时合并（class 追加）
      if AEl.HasAttributes then
      begin
        for i := 0 to AEl.Attributes.Length - 1 do
        begin
          attrName := LowerCase(AEl.Attributes.Item[i].NodeName);
          if attrName = 'src' then
            Continue;
          if count <> 1 then
            raise Exception.CreateFmt('<include> 展开为多个节点时不能带属性 "%s"（%s）',
              [attrName, path]);
          node := AParent[AParent.Count - 1];
          if attrName = 'class' then
          begin
            SplitClasses(node.AttributeValue('class') + ' ' +
              AEl.Attributes.Item[i].NodeValue, node.ClassList);
            node.Attributes.Values['class'] := AEl.Attributes.Item[i].NodeValue;
          end
          else
          begin
            node.Attributes.Values[AEl.Attributes.Item[i].NodeName] :=
              AEl.Attributes.Item[i].NodeValue;
            if attrName = 'id' then
              node.Id := AEl.Attributes.Item[i].NodeValue
            else if attrName = 'text' then
              node.Text := AEl.Attributes.Item[i].NodeValue;
          end;
        end;
      end;
    finally
      ACtx.Stack.Delete(ACtx.Stack.Count - 1);
    end;
  finally
    dom.Free;
  end;
end;

// 元素 → 节点并递归子元素（<include> 就地展开）
procedure BuildInto(ADomElement: TDOMElement; AParent: TXuiNode;
  ACtx: TIncludeContext);
var
  node: TXuiNode;
  child: TDOMNode;
begin
  if CompareText(ADomElement.NodeName, 'include') = 0 then
  begin
    BuildInclude(ADomElement, AParent, ACtx);
    Exit;
  end;
  node := BuildNodeSelf(ADomElement);
  AParent.AddChild(node);
  child := ADomElement.FirstChild;
  while child <> nil do
  begin
    if child.NodeType = ELEMENT_NODE then
      BuildInto(TDOMElement(child), node, ACtx);
    child := child.NextSibling;
  end;
end;

function BuildDocument(ADom: TXMLDocument; const ASourceFile, ABaseDir: string): TXuiDocument;
var
  rootEl: TDOMElement;
  child: TDOMNode;
  ctx: TIncludeContext;
begin
  Result := TXuiDocument.Create;
  try
    rootEl := ADom.DocumentElement;
    if rootEl = nil then
      raise Exception.Create('XML 缺少根元素');
    if CompareText(rootEl.NodeName, 'include') = 0 then
      raise Exception.Create('根元素不能是 <include>');
    Result.SourceFile := ASourceFile;
    ctx := TIncludeContext.Create(ABaseDir, Result.Dependencies);
    try
      Result.Root := BuildNodeSelf(rootEl);
      child := rootEl.FirstChild;
      while child <> nil do
      begin
        if child.NodeType = ELEMENT_NODE then
          BuildInto(TDOMElement(child), Result.Root, ctx);
        child := child.NextSibling;
      end;
    finally
      ctx.Free;
    end;
    Result.Title := Result.Root.AttributeValue('title');
  except
    Result.Free;
    raise;
  end;
end;

function LoadDocumentFromXML(const AXMLContent: string; const ABaseDir: string): TXuiDocument;
var
  stream: TStringStream;
  dom: TXMLDocument;
begin
  stream := TStringStream.Create(AXMLContent);
  try
    ReadXMLFile(dom, stream);
    try
      Result := BuildDocument(dom, '', ABaseDir);
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
  path: string;
begin
  path := ExpandFileName(AFileName);
  ReadXMLFile(dom, AFileName);
  try
    Result := BuildDocument(dom, path, ExtractFileDir(path));
  finally
    dom.Free;
  end;
end;

end.
