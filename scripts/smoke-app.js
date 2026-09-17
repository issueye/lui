#!/usr/bin/env node
/**
 * M12 冒烟：应用生命周期端到端（init → check → build → 换目录运行 → pack）。
 *
 * 为什么单独一个脚本：`npm run pack` 也能验，但它要重新编译三个目标、组装 29 MB 的发布包
 * 并压缩，几十秒起步。日常改运行时后想确认"应用这条路还通"需要一个几十秒内能跑完的入口，
 * 所以把 M12 的验收点单独提出来。
 *
 * 每一步都是黑盒调用 bin/lui.exe，只断言外部可观察的结果（退出码 / 文件 / 图能出）：
 *   1. init   生成应用骨架（lui.json + src/ + 自带 ui/ + run-*.cmd）
 *   2. check  逐页自检通过（脚本无错误）
 *   3. build  产出单文件应用 dist/<name>.exe
 *   4. 离开应用目录运行该 exe：--check、-o（出图）、--list-bundle 都成立
 *      —— 这一步是 M12 的关键验收：旧版 --pack 必须 cd 进 pages/ 才跑得起来
 *   5. pack   交付目录（应用 exe + 预览图 + README.txt）
 *
 * 用法：
 *   node scripts/smoke-app.js             # 用 bin/lui.exe
 *   node scripts/smoke-app.js --keep      # 保留临时目录，便于人工查看产物
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..');
const keep = process.argv.includes('--keep');

function findRuntime() {
  const candidates = [
    path.join(root, 'bin', 'lui.exe'),
    path.join(root, 'bin', 'lui-render.exe'),
    path.join(root, 'bin', 'lui-render-single.exe')
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

const runtime = findRuntime();
if (!runtime) {
  console.error('[错误] 未找到 bin/lui.exe。先跑 npm run build:renderer。');
  process.exit(1);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lui-smoke-app-'));
const app = path.join(tmp, 'smokeapp');
let failures = 0;

function step(title, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${title}${detail ? '  — ' + detail : ''}`);
  if (!ok) failures++;
}

function run(exe, args, cwd) {
  return spawnSync(exe, args, { cwd, encoding: 'utf-8' });
}

function fail(res) {
  return ((res.stdout || '') + (res.stderr || '')).trim().split('\n').slice(-6).join('\n');
}

console.log(`[冒烟] 运行时 ${path.relative(root, runtime)}`);
console.log(`[冒烟] 工作目录 ${tmp}`);

try {
  // 1) init
  const init = run(runtime, ['init', app, '-w', '420', '-H', '560'], tmp);
  const manifest = path.join(app, 'lui.json');
  const uiIndex = path.join(app, 'ui', 'index.ts');
  step('init 生成应用（lui.json + src/main.xml + 自带 ui/）',
    init.status === 0 && fs.existsSync(manifest) && fs.existsSync(uiIndex) &&
    fs.existsSync(path.join(app, 'src', 'main.xml')) &&
    fs.existsSync(path.join(app, 'run-build.cmd')),
    init.status === 0 ? '' : fail(init));
  if (init.status !== 0) throw new Error('init 失败，后续步骤无意义');

  // 2) check：逐页脚本自检（退出码即门禁）
  const check = run(runtime, ['check', app], tmp);
  step('check 自检通过（脚本无错误，退出码 0）', check.status === 0, check.status === 0 ? '' : fail(check));

  // 3) build：单文件应用
  const build = run(runtime, ['build', app], tmp);
  const appExe = path.join(app, 'dist', 'smokeapp.exe');
  step('build 产出单文件应用 dist/smokeapp.exe',
    build.status === 0 && fs.existsSync(appExe),
    build.status === 0 ? '' : fail(build));
  if (!fs.existsSync(appExe)) throw new Error('build 失败，后续步骤无意义');

  // 4) 关键验收：换一个完全无关的工作目录运行应用 exe
  const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), 'lui-smoke-away-'));
  const bundleList = run(appExe, ['--list-bundle'], elsewhere);
  step('应用 exe 能列出自身载荷（--list-bundle）',
    bundleList.status === 0 && bundleList.stdout.includes('lui.json'),
    bundleList.status === 0 ? '' : fail(bundleList));

  const awayCheck = run(appExe, ['--check'], elsewhere);
  step('应用 exe 在应用目录之外自检通过（应用根锚定生效）',
    awayCheck.status === 0, awayCheck.status === 0 ? '' : fail(awayCheck));

  const png = path.join(elsewhere, 'shot.png');
  const awayRender = run(appExe, ['-o', png, '-t', 'dark'], elsewhere);
  step('应用 exe 在应用目录之外出图成功',
    awayRender.status === 0 && fs.existsSync(png) && fs.statSync(png).size > 1000,
    awayRender.status === 0 ? '' : fail(awayRender));
  fs.rmSync(elsewhere, { recursive: true, force: true });

  // 5) pack：交付目录
  const pack = run(runtime, ['pack', app, '-t', 'both'], tmp);
  const dist = path.join(app, 'dist');
  step('pack 产出交付目录（exe + 预览图 + README.txt）',
    pack.status === 0 &&
    fs.existsSync(path.join(dist, 'preview-light.png')) &&
    fs.existsSync(path.join(dist, 'preview-dark.png')) &&
    fs.existsSync(path.join(dist, 'README.txt')),
    pack.status === 0 ? '' : fail(pack));
} catch (e) {
  console.error('[错误] ' + e.message);
  failures++;
} finally {
  if (keep) {
    console.log(`[冒烟] 保留临时目录: ${tmp}`);
  } else {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

console.log(failures === 0 ? '\n[完成] M12 应用生命周期冒烟全部通过' : `\n[失败] ${failures} 项未通过`);
process.exit(failures === 0 ? 0 : 1);
