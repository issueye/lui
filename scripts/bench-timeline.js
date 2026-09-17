#!/usr/bin/env node
/**
 * 时间线压力基准（R4 决策用）：生成不同消息数的页面，用渲染器 --bench 测量
 * “完整样式重算 / 仅布局 / 仅绘制”三档失效级别下的平均耗时，输出对照表。
 *
 * 用法：
 *   node scripts/bench-timeline.js                                  # 默认 20/50/100/200/400
 *   node scripts/bench-timeline.js --counts 50,100 --bench 30 --modes full,layout,paint
 *
 * 页面结构对齐 a_da 的会话时间线（x-for 渲染消息，每条 1 容器 + 3 文本节点），
 * 因此测的是同一条渲染路径。本脚本只做测量，不修改引擎。
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const renderer = path.join(root, 'bin', 'lui-render.exe');

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const counts = argValue('--counts', '20,50,100,200,400')
  .split(',')
  .map((s) => parseInt(s.trim(), 10))
  .filter((n) => Number.isFinite(n) && n > 0);
const bench = parseInt(argValue('--bench', '30'), 10);
const modes = argValue('--modes', 'full,layout,paint')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const width = parseInt(argValue('-w', '560'), 10);
const height = parseInt(argValue('-H', '900'), 10);
const theme = argValue('--theme', 'light');

if (!fs.existsSync(renderer)) {
  console.error('[基准] 未找到 bin/lui-render.exe，请先运行 npm run build:renderer');
  process.exit(1);
}

const outDir = path.join(root, 'dist', 'bench-timeline');
fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

const PAGE_CSS = [
  '#tl { overflow:auto; padding: 8px; }',
  '.msg { padding: 8px; border-bottom: 1px solid #eee; }',
  '.role { font-size: 12px; color: #666666; }',
  '.body { font-size: 13px; color: #222222; }',
  '.tool { font-size: 12px; color: #444444; background-color: #f5f7fa; padding: 4px; }'
].join('\n');

const BODY = '这条消息用于测量时间线渲染开销：包含中文文本换行、角色标签与工具步骤行，长度接近真实会话内容。';

function pageXml() {
  return `<?xml version="1.0" encoding="utf-8"?>
<window title="时间线压力测试" width="${width}" height="${height}">
<style>
${PAGE_CSS}
</style>
<script src="page.ts"/>
<panel id="tl" x-for="m in state.messages">
  <panel class="msg">
    <label class="role" x-text="m.role"/>
    <label class="body" x-text="m.body"/>
    <label class="tool" x-text="m.tool"/>
  </panel>
</panel>
</window>
`;
}

function pageTs(count) {
  return `const COUNT: number = ${count};
const BODY: string = '${BODY}';
const state = reactive({ messages: [] });

function Build(): void {
  const list = [];
  for (let i = 0; i < COUNT; i++) {
    list.push({
      role: i % 2 === 0 ? 'user' : 'assistant',
      body: BODY,
      tool: 'read src/file' + i + '.ts (120 行)'
    });
  }
  state.messages = list;
}

Build();
`;
}

function writeCase(count) {
  const dir = path.join(outDir, 'n' + count);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'page.xml'), pageXml());
  fs.writeFileSync(path.join(dir, 'page.ts'), pageTs(count));
  return dir;
}

function measure(count, mode) {
  const dir = writeCase(count);
  const out = path.join(dir, 'out-' + mode + '.png');
  const res = spawnSync(
    renderer,
    [path.join(dir, 'page.xml'), '-o', out, '-w', String(width), '-H', String(height),
     '-t', theme, '--bench', String(bench), '--bench-mode', mode],
    { cwd: root, encoding: 'utf8' }
  );
  const text = (res.stdout || '') + (res.stderr || '');
  // 解析“平均 X ms/次”：不依赖中文文案（渲染器输出跟随控制台码页）
  const m = text.match(/([\d.]+)\s*ms\//) || text.match(/ms[^\d]{0,12}([\d.]+)/);
  return {
    count,
    mode,
    ok: res.status === 0 && fs.existsSync(out),
    avg: m ? Number(m[1]) : null
  };
}

console.log(['消息数', ...modes.map((m) => m + '(ms)')].join('\t'));
for (const count of counts) {
  const results = modes.map((mode) => measure(count, mode));
  console.log([count, ...results.map((r) => (r.avg === null ? 'n/a' : r.avg.toFixed(2)))].join('\t'));
}
console.log('\n说明：full=整树样式重算+布局+绘制（最坏情况）；layout=仅布局+绘制；paint=仅绘制。');
console.log('参考：60fps 预算 16.7 ms/帧；主设计文档 N2 目标 ≤ 8 ms。');
console.log('页面目录：' + path.relative(root, outDir) +
  '（--bench ' + bench + '，' + width + 'x' + height + '，theme=' + theme + '）');
