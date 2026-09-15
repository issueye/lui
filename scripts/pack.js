#!/usr/bin/env node
/**
 * lui 打包脚本 (M9-P3+)：把 lui-render / demo1 与其运行时资源组装为可分发包。
 *
 * 用法：
 *   node scripts/pack.js                # 构建渲染器 + demo1，组装 dist/lui/ 并压缩 zip
 *   node scripts/pack.js --no-zip      # 只组装目录，不压缩
 *   node scripts/pack.js --no-demo     # 不带 demo1.exe（仅 lui-render）
 *
 * 产物：
 *   dist/lui/                          可执行文件 + pages/（页面与 ui/ 运行时资源）
 *   dist/lui-<version>-win64.zip       上述目录的压缩包
 *
 * 布局说明：demo 页面放 pages/ 子目录（含 ui/ 运行时资源），
 * 用户 cd pages 后运行 ..\demo1.exe / ..\lui-render.exe 即可，
 * 相对引用（../ui/index.ts、nav-*.css）与 FindFile 查找链均成立。
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const noZip = process.argv.includes('--no-zip');
const withDemo = !process.argv.includes('--no-demo');

function findLazBuild() {
  if (process.env.LAZBUILD && fs.existsSync(process.env.LAZBUILD)) {
    return process.env.LAZBUILD;
  }
  const candidates = [
    'D:\\Programs\\lazarus\\lazbuild.exe',
    'C:\\lazarus\\lazbuild.exe',
    'C:\\Program Files\\lazarus\\lazbuild.exe'
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return 'lazbuild';
}

const lazbuild = findLazBuild();

function build(lpi) {
  const full = path.join(root, lpi);
  console.log(`[构建] ${lpi}`);
  const res = spawnSync(lazbuild, [full], { stdio: 'inherit', cwd: root });
  if (res.status !== 0) {
    console.error(`[错误] 构建失败: ${lpi}`);
    process.exit(1);
  }
}

function copy(src, dest) {
  fs.cpSync(path.join(root, src), path.join(dest, src), { recursive: true });
}

function main() {
  const stage = path.join(root, 'dist', 'lui');
  const pages = path.join(stage, 'pages');

  // 1. 构建
  build('tools/renderer/lui_render.lpi');
  if (withDemo) build('demo/demo1.lpi');

  // 2. 组装目录（先清空旧包）
  fs.rmSync(stage, { recursive: true, force: true });
  fs.mkdirSync(pages, { recursive: true });

  // 可执行文件
  const rendererExe = path.join(root, 'bin', 'lui-render.exe');
  if (!fs.existsSync(rendererExe)) {
    console.error('[错误] 未找到 bin/lui-render.exe（构建失败？）');
    process.exit(1);
  }
  fs.copyFileSync(rendererExe, path.join(stage, 'lui-render.exe'));
  if (withDemo) {
    const demoExe = path.join(root, 'demo', 'demo1.exe');
    if (!fs.existsSync(demoExe)) {
      console.error('[错误] 未找到 demo/demo1.exe（先构建 demo 目标）');
      process.exit(1);
    }
    fs.copyFileSync(demoExe, path.join(stage, 'demo1.exe'));
  }

  // ui/ 运行时资源（组件库 + 模板 + 主题）
  copy(path.join('ui', 'index.ts'), stage);
  copy(path.join('ui', 'components'), stage);
  copy(path.join('ui', 'templates'), stage);
  copy(path.join('ui', 'theme'), stage);

  // scaffold/ 项目模板（M11）：`lui-render --init` 从它生成工程骨架，
  // 与 ui/ 同级（脚手架把同级 ui/ 整树复制进新工程，故两者必须一起在包里）。
  copy(path.join('scaffold'), stage);

  // 演示页面（xml/css/ts + include 片段 + 资产），剔除截图与日志
  for (const f of fs.readdirSync(path.join(root, 'demo'))) {
    const ext = path.extname(f).toLowerCase();
    if (!['.xml', '.css', '.ts'].includes(ext)) continue;
    if (/shot|error|debug/i.test(f)) continue;
    fs.copyFileSync(path.join(root, 'demo', f), path.join(pages, f));
  }
  copy(path.join('demo', 'assets'), pages);

  // 说明文件
  fs.writeFileSync(path.join(stage, 'README.txt'), [
    'lui v' + version + ' — 轻量级声明式 UI 渲染引擎与组件库',
    '',
    '内容：',
    '  lui-render.exe  独立渲染器（CLI 出图 / GUI 预览）',
    withDemo ? '  demo1.exe       演示应用（登录 / 列表 / Todo / 脚本 / 组件库 / 浮层）' : '',
    '  pages\\          演示页面与 ui/ 运行时资源（组件库 + 主题）',
    '  ui\\             组件库运行时（新建工程时整树拷走）',
    '  scaffold\\       项目模板：lui-render --init <目录> 用它生成工程骨架',
    '',
    '用法（建议在 pages\\ 目录下运行，资源按相对路径解析）：',
    '  cd pages',
    withDemo ? '  ..\\demo1.exe login            # 演示应用' : '',
    '  ..\\lui-render.exe ui.xml -o ui.png -w 560 -H 980   # 页面出图',
    '  ..\\lui-render.exe --help      # 完整选项',
    '',
    '新建自己的工程：',
    '  ..\\lui-render.exe --init myapp -w 480 -H 560',
    '  cd myapp && run-dev.cmd       # 开发 / run-test.cmd 测试 / run-pack.cmd 交付',
    ''
  ].filter(Boolean).join('\r\n') + '\r\n');

  // 3. 冒烟验证：在 pages/ 工作目录运行打包内的渲染器（证明 exe 旁 ui/ 解析成立）
  const tmp = fs.mkdtempSync(path.join(root, 'dist', 'smoke-'));
  const smoke = spawnSync(
    path.join(stage, 'lui-render.exe'),
    ['ui_gallery.xml', '-o', path.join(tmp, 'smoke.png'), '-w', '420', '-H', '300', '-t', 'light'],
    { cwd: pages, encoding: 'utf-8' }
  );
  const smokePng = path.join(tmp, 'smoke.png');
  const smokeOk = smoke.status === 0 && fs.existsSync(smokePng);
  console.log(smokeOk
    ? '[冒烟] 打包内渲染器出图成功（pages/ 工作目录）'
    : '[警告] 打包内渲染器冒烟失败（status=' + smoke.status + '）');
  if (!smokeOk) {
    fs.rmSync(tmp, { recursive: true, force: true });
    console.error('[错误] 冒烟失败，中止打包');
    process.exit(1);
  }

  // 3b. 冒烟验证 --init：用打包内的模板生成工程，再渲染生成的起步页。
  //     这一步同时证明三件事：scaffold/ 随包分发、同级 ui/ 被整树复制、生成物能直接出图。
  const proj = path.join(tmp, 'myapp');
  const init = spawnSync(path.join(stage, 'lui-render.exe'),
    ['--init', proj, '-w', '420', '-H', '420'], { cwd: tmp, encoding: 'utf-8' });
  const genPage = path.join(proj, 'src', 'main.xml');
  const genCss = path.join(proj, 'src', 'main-light.css');
  const genUi = path.join(proj, 'ui', 'index.ts');
  const initOk = init.status === 0 && fs.existsSync(genPage) && fs.existsSync(genCss) &&
    fs.existsSync(genUi);
  if (!initOk) {
    console.error('[错误] --init 冒烟失败（status=' + init.status + '）:\n' +
      (init.stdout || '') + (init.stderr || ''));
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }
  // 生成的 run-*.cmd 里渲染器路径应指向包内 exe（不是构建机的仓库路径）
  const devCmd = fs.readFileSync(path.join(proj, 'run-dev.cmd'), 'utf-8');
  if (!devCmd.includes(path.join(stage, 'lui-render.exe'))) {
    console.error('[错误] 生成的 run-dev.cmd 未指向包内渲染器');
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }
  const genOut = path.join(proj, 'out', 'init.png');
  const genRender = spawnSync(path.join(stage, 'lui-render.exe'),
    [genPage, '-o', genOut, '-w', '420', '-H', '420', '-t', 'light'],
    { cwd: proj, encoding: 'utf-8' });
  const genOk = genRender.status === 0 && fs.existsSync(genOut) && fs.statSync(genOut).size > 1000;
  console.log(genOk
    ? '[冒烟] --init 生成工程并出图成功（模板 + ui/ 运行时齐备）'
    : '[警告] --init 生成的工程渲染失败（status=' + genRender.status + '）');
  if (!genOk) {
    console.error((genRender.stdout || '') + (genRender.stderr || ''));
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }

  // 3c. --json 契约：stdout 必须只含可解析的 JSON（日志走 stderr）。
  //     这条约定是 ADR 32 的核心，一旦有人把日志写回 stdout，脚本化调用就会断。
  const jsonRun = spawnSync(path.join(stage, 'lui-render.exe'),
    [genPage, '-O', path.join(proj, 'out'), '-t', 'both', '--json'],
    { cwd: proj, encoding: 'utf-8' });
  let jsonOk = false, jsonDetail = '';
  try {
    const parsed = JSON.parse(jsonRun.stdout);
    jsonOk = parsed.total === 2 && parsed.failed === 0 && parsed.items.length === 2;
    jsonDetail = `total=${parsed.total} items=${parsed.items.length}`;
  } catch (e) {
    jsonDetail = 'stdout 不是合法 JSON: ' + String(e.message).slice(0, 80);
  }
  console.log(jsonOk
    ? `[冒烟] --json 输出可解析（${jsonDetail}）`
    : `[警告] --json 契约被破坏（${jsonDetail}）`);
  if (!jsonOk) {
    console.error('stdout 实际内容:\n' + jsonRun.stdout);
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }

  // 3d. 参数健壮性：`--init --force` 曾把 --force 当目录名，真的建出过叫 "--force" 的目录
  const badArg = spawnSync(path.join(stage, 'lui-render.exe'), ['--init', '--force'],
    { cwd: tmp, encoding: 'utf-8' });
  const forceDir = path.join(tmp, '--force');
  const badArgOk = badArg.status === 2 && !fs.existsSync(forceDir);
  console.log(badArgOk
    ? '[冒烟] 选项缺值被正确拒绝（未把选项当成目录名）'
    : `[警告] 选项缺值处理异常（status=${badArg.status}, 建出了 --force 目录=${fs.existsSync(forceDir)}）`);
  if (!badArgOk) {
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }

  fs.rmSync(tmp, { recursive: true, force: true });

  // 4. 压缩
  if (!noZip) {
    const zip = path.join(root, 'dist', `lui-${version}-win64.zip`);
    fs.rmSync(zip, { force: true });
    const ps = [
      '-NoProfile', '-Command',
      `Compress-Archive -Path '${stage}\\*' -DestinationPath '${zip}' -Force`
    ];
    const res = spawnSync('powershell', ps, { stdio: 'inherit' });
    if (res.status !== 0) {
      console.error('[错误] 压缩失败');
      process.exit(1);
    }
    console.log(`[完成] ${zip}`);
  }

  console.log(`[完成] 分发目录: ${stage}`);
}

main();
