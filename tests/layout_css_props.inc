{ M3：CSS 属性解析 }

procedure TestM3CssProps;
var
  s: TXuiStyle;
begin
  WriteLn('--- M3 属性解析 ---');

  s := TXuiStyle.Create;
  try
    s.FontSize := 14;

    ApplyDeclaration(s, 'position', 'absolute', 14);
    Check(s.Position = xposAbsolute, 'position: absolute');

    ApplyDeclaration(s, 'top', '5px', 14);
    Check(s.Inset.Top.Value = 5, 'top: 5px');

    ApplyDeclaration(s, 'right', '10%', 14);
    Check(s.Inset.Right.Kind = xlkPercent, 'right: 10%');

    ApplyDeclaration(s, 'left', 'auto', 14);
    Check(s.Inset.Left.IsAuto, 'left: auto');

    ApplyDeclaration(s, 'z-index', '7', 14);
    Check(s.ZIndex = 7, 'z-index: 7');

    ApplyDeclaration(s, 'overflow', 'hidden', 14);
    Check(s.Overflow = xovHidden, 'overflow: hidden');

    ApplyDeclaration(s, 'visibility', 'hidden', 14);
    Check(s.Visibility = xvisHidden, 'visibility: hidden');

    ApplyDeclaration(s, 'min-width', '80px', 14);
    Check(s.MinWidth.Value = 80, 'min-width: 80px');

    ApplyDeclaration(s, 'min-height', '50%', 14);
    Check(s.MinHeight.Kind = xlkPercent, 'min-height: 50%');

    ApplyDeclaration(s, 'flex-direction', 'column', 14);
    Check(s.FlexDirection = xfdColumn, 'flex-direction: column');

    ApplyDeclaration(s, 'justify-content', 'space-between', 14);
    Check(s.JustifyContent = xjcSpaceBetween, 'justify-content: space-between');

    ApplyDeclaration(s, 'align-items', 'center', 14);
    Check(s.AlignItems = xaiCenter, 'align-items: center');

    ApplyDeclaration(s, 'gap', '6px 12px', 14);
    Check((s.RowGap.Value = 6) and (s.ColumnGap.Value = 12), 'gap: 6px 12px');

    ApplyDeclaration(s, 'flex-grow', '2', 14);
    Check(Abs(s.FlexGrow - 2) < 0.01, 'flex-grow: 2');

    ApplyDeclaration(s, 'flex', '3', 14);
    Check((Abs(s.FlexGrow - 3) < 0.01) and (s.FlexBasis.Value = 0),
      'flex: 3 简写（grow=3 + basis=0）');

    ApplyDeclaration(s, 'flex-basis', '40%', 14);
    Check(s.FlexBasis.Kind = xlkPercent, 'flex-basis: 40%');

    ApplyDeclaration(s, 'row-gap', '4px', 14);
    Check(s.RowGap.Value = 4, 'row-gap: 4px');
  finally
    s.Free;
  end;
end;
