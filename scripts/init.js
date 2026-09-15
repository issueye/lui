#!/usr/bin/env node
/**
 * lui 项目脚手架入口（M11）：`npm run init -- <目录> [选项]`
 *
 * 真正干活的是渲染器的 `--init`（src/ui/xui_scaffold.pas + scaffold/ 模板）——
 * 这里只做三件事：定位渲染器、给缺省参数、把渲染器的输出与退出码原样透出。
 * 之所以不在这里重新实现一遍模板逻辑：模板定位、占位符替换、ui/ 运行时整树复制
 * 是引擎侧能力，单程序版 lui-render-single.exe 也要用同一份（ADR 44）。
 *
 * 用法：
 *   npm run init -- myapp                     # 生成 ./myapp
 *   npm run init -- myapp -w 480 -H 560 -t both
 *   npm run init -- myapp --force             # 覆盖已存在文件
 *   npm run scaffold                          # 自检：生成到临时目录并出图后删除
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..');
const selfTest = process.argv.includes('--self-test');
const args = process.argv.slice(2).filter(a => a !== '--self-test');

function findRenderer() {
  const candidates = [
    path.join(root, 'bin', 'lui-render.exe'),
    path.join(root, 'bin', 'lui-render'),
    path.join(root, 'bin', 'lui-render-single.exe')
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

const renderer = findRenderer();
if (!renderer) {
  console.error('[错误] 未找到渲染器（bin/lui-render.exe）。先跑 npm run build:renderer。');
  process.exit(1);
}

// 自检：生成到临时目录 → 出图 → 清理。用于验证模板与脚手架实现是好的。
if (selfTest) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lui-scaffold-self-'));
  const proj = path.join(tmp, 'selfapp');
  console.log(`[自检] 渲染器 ${path.relative(root, renderer)}`);
  console.log(`[自检] 生成到 ${proj}`);

  const init = spawnSync(renderer, ['--init', proj, '-w', '420', '-H', '420'],
    { encoding: 'utf-8' });
  if (init.status !== 0) {
    console.error('[错误] --init 失败:\n' + (init.stdout || '') + (init.stderr || ''));
    process.exit(1);
  }
  const page = path.join(proj, 'src', 'main.xml');
  if (!fs.existsSync(page)) {
    console.error('[错误] 未生成 src/main.xml');
    process.exit(1);
  }

  const out = path.join(tmp, 'self.png');
  const r = spawnSync(renderer, [page, '-o', out, '-w', '420', '-H', '420', '-t', 'light'],
    { cwd: proj, encoding: 'utf-8' });
  const ok = r.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 1000;
  if (!ok) {
    console.error('[错误] 生成的工程渲染失败:\n' + (r.stdout || '') + (r.stderr || ''));
    process.exit(1);
  }
  console.log(`[自检] 生成物渲染成功（${(fs.statSync(out).size / 1024).toFixed(1)} KB）`);

  const chk = spawnSync(renderer, [page, '--check', '-w', '420', '-H', '420'],
    { cwd: proj, encoding: 'utf-8' });
  if (chk.status !== 0) {
    console.error('[错误] 生成物自检未通过:\n' + (chk.stdout || '') + (chk.stderr || ''));
    process.exit(1);
  }
  console.log('[自检] --check 通过');

  fs.rmSync(tmp, { recursive: true, force: true });
  console.log('[完成] 脚手架自检通过');
  process.exit(0);
}

if (args.length === 0 || args[0].startsWith('-')) {
  console.error('用法: npm run init -- <目录> [-w 宽] [-H 高] [-t light|dark|both] [--name 名] [--force]');
  process.exit(2);
}

// 缺省视口与起步页内容相称；未显式给出时由渲染器兜底，这里不重复设默认值
const res = spawnSync(renderer, ['--init', ...args], { cwd: process.cwd(), stdio: 'inherit' });
process.exit(res.status === null ? 1 : res.status);
