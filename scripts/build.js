/**
 * lui 框架自动化工程构建脚本 (跨平台 Node.js 驱动)
 * 封装对 Free Pascal / Lazarus lazbuild 的调用，提供统一工程化构建体验。
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// 探测 lazbuild 路径
function findLazBuild() {
  if (process.env.LAZBUILD && fs.existsSync(process.env.LAZBUILD)) {
    return process.env.LAZBUILD;
  }
  const candidates = [
    'D:\\Programs\\lazarus\\lazbuild.exe',
    'C:\\lazarus\\lazbuild.exe',
    'C:\\Program Files\\lazarus\\lazbuild.exe',
    '/usr/bin/lazbuild',
    '/usr/local/bin/lazbuild'
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  // 尝试 PATH
  try {
    const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['lazbuild'], { encoding: 'utf-8' });
    if (probe.status === 0 && probe.stdout.trim()) {
      return probe.stdout.trim().split('\n')[0].trim();
    }
  } catch (e) {}

  return 'lazbuild';
}

const lazbuild = findLazBuild();
const target = process.argv[2] || 'all';

const projects = {
  test: { name: '单元测试', lpi: 'tests/runtests.lpi' },
  renderer: { name: '独立渲染器', lpi: 'tools/renderer/lui_render.lpi' },
  demo: { name: 'Demo 应用程序', lpi: 'demo/demo1.lpi' }
};

// 单程序版（M9-P4）：需先生成内嵌资源单元再编译，整体交给 scripts/embed.js 编排，
// 不走下面的通用 lazbuild 流程
if (target === 'single') {
  const res = spawnSync(process.execPath, [path.resolve(__dirname, 'embed.js')],
    { stdio: 'inherit', cwd: path.resolve(__dirname, '..') });
  process.exit(res.status || 0);
}

function buildTarget(key) {
  const p = projects[key];
  if (!p) {
    console.error(`[错误] 未知构建目标: ${key}`);
    process.exit(1);
  }
  const lpiPath = path.resolve(__dirname, '..', p.lpi);
  if (!fs.existsSync(lpiPath)) {
    console.error(`[错误] 未找到工程文件: ${p.lpi}`);
    process.exit(1);
  }

  console.log(`\n========================================`);
  console.log(`[构建开始] ${p.name} (${p.lpi})`);
  console.log(`[编译器]   ${lazbuild}`);
  console.log(`========================================`);

  const res = spawnSync(lazbuild, [p.lpi], {
    stdio: 'inherit',
    cwd: path.resolve(__dirname, '..')
  });

  if (res.status !== 0) {
    console.error(`\n[构建失败] ${p.name} 编译返回错误码 ${res.status}`);
    process.exit(res.status || 1);
  } else {
    console.log(`[构建成功] ${p.name} 编译完成！`);
  }
}

if (target === 'all') {
  buildTarget('renderer');
  buildTarget('test');
  buildTarget('demo');
} else {
  buildTarget(target);
}
