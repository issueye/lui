{ R8：断行缓存——键包含全部影响断行的输入，任何输入变化都必须重算 }

type
  // 与假测量器同接口但每字符 16px：用于验证「测量器实例」也是缓存键的一部分
  TWideMeasurer = class
  public
    function Measure(const AText: string; AStyle: TXuiStyle): TSize;
  end;

function TWideMeasurer.Measure(const AText: string; AStyle: TXuiStyle): TSize;
begin
  Result.cx := Utf8CharCount(AText) * 16;
  Result.cy := 20;
end;

procedure TestWrapCache;
var
  style: TXuiStyle;
  lines: TXuiLineArray;
  h1, h2: Single;
  wide: TWideMeasurer;
begin
  WriteLn('--- R8：断行缓存 ---');

  style := TXuiStyle.Create;
  wide := TWideMeasurer.Create;
  try
    InvalidateWrapCache;
    style.FontSize := 14;

    // 文本变化 → 必须重算（同一样式/宽度）
    h1 := WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 2, Format('首次断行为 2 行 [实际 %d]', [Length(lines)]));
    WrapText('中文', style, 40, @Measurer.Measure, lines);
    Check((Length(lines) = 1) and (lines[0] = '中文'), '更短文本重新计算为 1 行');
    WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check((Length(lines) = 2) and (lines[0] = '中文中文中'),
      Format('回到原文本仍为 2 行且内容正确 [实际 %d 行]', [Length(lines)]));

    // 大小写不同的文本不得串命中（缓存键精确比较）
    WrapText('abcd', style, 40, @Measurer.Measure, lines);
    WrapText('AbCd', style, 40, @Measurer.Measure, lines);
    Check((Length(lines) = 1) and (lines[0] = 'AbCd'),
      Format('大小写不同的文本各自命中 [实际 %s]', [lines[0]]));

    // 宽度变化 → 重算
    WrapText('中文中文中文', style, 80, @Measurer.Measure, lines);
    Check((Length(lines) = 1) and (lines[0] = '中文中文中文'), '可用宽度变大后为 1 行');
    WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 2, '宽度变回后仍为 2 行');

    // 字距影响断行 → 必须进入键
    InvalidateWrapCache;
    style.LetterSpacing := 0;
    WrapText('中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 1, '无字距时 4 个 CJK 字占 32px 为 1 行');
    style.LetterSpacing := 6;
    WrapText('中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 2, Format('字距 6px 后放不下 → 2 行 [实际 %d]', [Length(lines)]));
    style.LetterSpacing := 0;

    // 行高不进缓存：高度按调用时的 line-height 推导
    InvalidateWrapCache;
    style.LineHeight := 1;
    h1 := WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    style.LineHeight := 2;
    h2 := WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check((Round(h1) = 28) and (Round(h2) = 56),
      Format('同一文本在 line-height 1/2 下高度为 28/56 [实际 %d/%d]',
        [Round(h1), Round(h2)]));
    style.LineHeight := 1.4;

    // 测量器实例进入键：更宽的测量器必须重算
    InvalidateWrapCache;
    WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 2, '假测量器下为 2 行');
    WrapText('中文中文中文', style, 40, @wide.Measure, lines);
    Check(Length(lines) = 3,
      Format('更宽测量器下必须重算为 3 行 [实际 %d]', [Length(lines)]));

    // 显式失效后仍能正确计算
    InvalidateWrapCache;
    WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check(Length(lines) = 2, '失效缓存后结果不变');

    // 溢出策略变化同样重算
    InvalidateWrapCache;
    style.WhiteSpace := xwsNoWrap;
    style.TextOverflow := xtoEllipsis;
    WrapText('中文中文中文', style, 40, @Measurer.Measure, lines);
    Check((Length(lines) = 1) and (lines[0] = '中文中文…'),
      Format('nowrap + ellipsis 为 1 行并截断 [实际 %s]', [lines[0]]));
  finally
    wide.Free;
    style.Free;
  end;
end;
