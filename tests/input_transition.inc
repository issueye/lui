{ M5：过渡动画 }

procedure TestTransitionAnim;
var
  engine: TXuiEngine;
  fake: TFakeRenderer;
  box: TXuiNode;
  s: TXuiStyle;
  mid: Byte;
begin
  WriteLn('--- M5 过渡动画：解析与推进 ---');

  s := TXuiStyle.Create;
  try
    ApplyDeclaration(s, 'transition', 'background-color 200ms ease-out 50ms', 14);
    Check(xapBgColor in s.TransitionProps, 'transition 解析出属性');
    Check(not (xapOpacity in s.TransitionProps), '未声明的属性不参与过渡');
    Check(Abs(s.TransitionDuration - 0.2) < 0.001, 'ms 时长换算为秒');
    Check(Abs(s.TransitionDelay - 0.05) < 0.001, '延迟解析');
    Check(s.TransitionTiming = xtfEaseOut, '时间函数解析');

    ApplyDeclaration(s, 'transition', 'all 0.1s linear', 14);
    Check(s.TransitionProps = XuiAllAnimProps, 'all 展开为白名单全集');
    Check(s.TransitionTiming = xtfLinear, 'linear 解析');

    ApplyDeclaration(s, 'transition', 'opacity, border-radius 120ms', 14);
    Check((s.TransitionProps = [xapOpacity, xapBorderRadius]),
      '逗号列表（逗号后空格）解析');
  finally
    s.Free;
  end;

  engine := NewTestEngine(fake);
  try
    engine.LoadFromString('<window><panel id="box"/></window>');
    engine.LoadStyleSheetFromString(
      '#box { width:100px; height:100px; background-color:#000000; ' +
      '       transition: background-color 200ms linear; } ' +
      '#box:hover { background-color:#ffffff; }');
    engine.Tick(1000);
    DrawEngine(engine);
    box := engine.Document.FindElementById('box');
    Check(box.Style.BgColor.R = 0, '初始背景为黑');
    Check(not engine.NeedsTick, '无过渡时不需要 Tick');

    engine.HandleMouseMove(10, 10);
    DrawEngine(engine);
    Check(xpHover in box.Pseudos, 'hover 生效');
    Check(box.Style.BgColor.R = 0, '过渡启动：绘制值为起点（黑）');
    Check(engine.NeedsTick, '过渡激活时 NeedsTick 为真');

    engine.Tick(1100);
    mid := box.Style.BgColor.R;
    Check((mid > 100) and (mid < 160), '半程插值（线性约 128）');
    engine.Tick(1200);
    Check(box.Style.BgColor.R = 255, '到达目标值（白）');
    Check(not engine.NeedsTick, '过渡结束后不再需要 Tick');

    // 中途反向：离开 hover 时从当前值平滑回到黑
    engine.Tick(1250);
    DrawEngine(engine);
    engine.Tick(1500);
    DrawEngine(engine);
    Check(box.Style.BgColor.R = 255, 'hover 保持目标值');
    engine.HandleMouseLeave;
    engine.Tick(1500);
    DrawEngine(engine);
    Check(box.Style.BgColor.R = 255, '离开瞬间仍为当前值（白）');
    engine.Tick(1600);
    mid := box.Style.BgColor.R;
    Check((mid > 100) and (mid < 160), '反向过渡半程插值');
    engine.Tick(1800);
    Check(box.Style.BgColor.R = 0, '反向过渡回到黑色');

    // 未声明的属性立即变化（不参与过渡）
    engine.LoadStyleSheetFromString('#box { opacity:0.5; }');
    engine.Tick(2000);
    DrawEngine(engine);
    Check(Abs(box.Style.Opacity - 0.5) < 0.01, '未声明过渡的属性立即生效');
  finally
    engine.Free;
  end;
end;
