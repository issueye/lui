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
    '',
    '用法（建议在 pages\\ 目录下运行，资源按相对路径解析）：',
    '  cd pages',
    withDemo ? '  ..\\demo1.exe login            # 演示应用' : '',
    '  ..\\lui-render.exe ui.xml -o ui.png -w 560 -H 980   # 页面出图',
    '  ..\\lui-render.exe --help      # 完整选项',
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
  fs.rmSync(tmp, { recursive: true, force: true });
  if (!smokeOk) {
    console.error('[错误] 冒烟失败，中止打包');
    process.exit(1);
  }

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
