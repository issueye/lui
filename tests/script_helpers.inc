{ M6：脚本测试共享接收器 }

type
  // 脚本输出/错误接收器（回调是 of object 类型）
  TScriptSink = class
  public
    Log: TStringList;
    Unhandled: TStringList;
    LastError: string;
    LastErrorStage: TXuiScriptStage;
    Errors: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure HandleLog(const AText: string);
    procedure HandleError(const AFile, AMessage: string;
      ALine, ACol: Integer; AStage: TXuiScriptStage);
    procedure HandleUnhandled(const AMessage: string);
  end;

constructor TScriptSink.Create;
begin
  inherited Create;
  Log := TStringList.Create;
  Unhandled := TStringList.Create;
end;

destructor TScriptSink.Destroy;
begin
  Log.Free;
  Unhandled.Free;
  inherited Destroy;
end;

procedure TScriptSink.HandleLog(const AText: string);
begin
  Log.Add(AText);
end;

procedure TScriptSink.HandleError(const AFile, AMessage: string;
  ALine, ACol: Integer; AStage: TXuiScriptStage);
begin
  Inc(Errors);
  LastError := AMessage;
  LastErrorStage := AStage;
end;

procedure TScriptSink.HandleUnhandled(const AMessage: string);
begin
  Unhandled.Add(AMessage);
end;
