#!/usr/bin/env node
/**
 * lui 单程序打包（M9-P4，ADR 34）：把页面资源（xml/css/ts/svg）与 ui/ 运行时资源
 * 内嵌进 lui-render 可执行文件，产出一个不依赖外部文件的 `lui-render-single.exe`。
 *
 * 用法：
 *   node scripts/embed.js                     # 内嵌默认页面集 + ui/，构建单程序 exe 并冒烟
 *   node scripts/embed.js --pages demo/login.xml,demo/ui_gallery.xml
 *   node scripts/embed.js --no-build          # 只生成内嵌资源单元，不编译
 *   node scripts/embed.js --no-smoke          # 跳过冒烟验证
 *
 * 工作方式：
 *   1. 调 `bin/lui-render.exe --add-page <页>` 让渲染器自己解析每页的关联资源
 *      （同名 css/ts、nav-*.css、<include src>、<script src>）——资源发现规则与引擎
 *      同源，不会漂移；
 *   2. 连同 ui/ 运行时资源（组件库脚本 + 模板 + 主题）与 demo/assets 一并收集；
 *   3. 生成 tools/renderer/embedded/xui_embed_assets.pas（Base64 数据块 + 清单 + 指纹）；
 *   4. 编译 `lui_render_single.lpi`（-dLUI_EMBED）→ bin/lui-render-single.exe；
 *   5. 冒烟：把 exe 复制到仓库外的空目录运行，证明无 ui/、无 pages/ 也能出图。
 *
 * 产物：
 *   bin/lui-render-single.exe            单文件分发（内嵌全部所需资源）
 *   tools/renderer/embedded/*.pas        生成的内嵌资源单元（构建产物，不入库）
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const root = path.resolve(__dirname, '..');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const rendererExe = path.join(root, 'bin', 'lui-render.exe');
const embedDir = path.join(root, 'tools', 'renderer', 'embedded');
const assetsUnit = path.join(embedDir, 'xui_embed_assets.pas');

const noBuild = process.argv.includes('--no-build');
const noSmoke = process.argv.includes('--no-smoke');

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

// 默认页面集：demo 根目录下全部 .xml（含 include 片段页：既是页也可被 include）
function defaultPages() {
  return fs.readdirSync(path.join(root, 'demo'))
    .filter(f => f.toLowerCase().endsWith('.xml'))
    .map(f => 'demo/' + f)
    .sort();
}

const pages = (argValue('--pages', '') || '')
  .split(',').map(s => s.trim()).filter(Boolean);
const pageList = pages.length ? pages : defaultPages();

function findLazBuild() {
  if (process.env.LAZBUILD && fs.existsSync(process.env.LAZBUILD)) return process.env.LAZBUILD;
  for (const c of ['D:\\Programs\\lazarus\\lazbuild.exe', 'C:\\lazarus\\lazbuild.exe',
                   'C:\\Program Files\\lazarus\\lazbuild.exe', '/usr/bin/lazbuild',
                   '/usr/local/bin/lazbuild']) {
    if (fs.existsSync(c)) return c;
  }
  return 'lazbuild';
}

// 走渲染器自身的资源发现：BASEDIR<TAB>dir / FILE<TAB>rel
function collectPage(relPage) {
  const res = spawnSync(rendererExe, ['--add-page', relPage], { cwd: root, encoding: 'utf-8' });
  if (res.status !== 0) {
    throw new Error(`--add-page 失败（${relPage}）：${res.stdout || ''}${res.stderr || ''}`);
  }
  let basedir = '';
  const files = [];
  for (const line of res.stdout.split(/\r?\n/)) {
    const [tag, value] = line.split('\t');
    if (tag === 'BASEDIR') basedir = value;
    else if (tag === 'FILE') files.push(value);
  }
  if (!basedir) throw new Error(`--add-page 未返回 BASEDIR（${relPage}）`);
  return { basedir, files };
}

// 递归列出目录下的文件（返回相对 root 的 POSIX 路径）
function walk(dir, prefix) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? prefix + '/' + entry.name : entry.name;
    if (entry.isDirectory()) out.push(...walk(path.join(dir, entry.name), rel));
    else out.push(rel);
  }
  return out;
}

function main() {
  if (!fs.existsSync(rendererExe)) {
    console.error(`[错误] 未找到 ${path.relative(root, rendererExe)}；请先 npm run build:renderer`);
    process.exit(1);
  }

  // 1. 收集资源：内嵌路径 → 磁盘绝对路径
  const files = new Map();   // embedName -> absPath

  // ui/ 运行时资源（页面里的 <script src="../ui/index.ts"> 指向它）
  for (const rel of walk(path.join(root, 'ui'), '')) {
    files.set('ui/' + rel, path.join(root, 'ui', rel));
  }

  // 页面及其关联资源 → pages/
  let pageCount = 0;
  for (const relPage of pageList) {
    const abs = path.join(root, relPage);
    if (!fs.existsSync(abs)) {
      console.error(`[警告] 跳过不存在的页面：${relPage}`);
      continue;
    }
    const { basedir, files: rels } = collectPage(relPage);
    pageCount++;
    for (const rel of rels) {
      const absFile = path.join(basedir, rel);
      if (!fs.existsSync(absFile)) continue;
      files.set('pages/' + rel, absFile);
    }
  }
  if (pageCount === 0) {
    console.error('[错误] 没有可内嵌的页面');
    process.exit(1);
  }

  // 页面资产（<svg src="assets/x.svg"> 一类）→ pages/assets/
  for (const rel of walk(path.join(root, 'demo', 'assets'), '')) {
    files.set('pages/assets/' + rel, path.join(root, 'demo', 'assets', rel));
  }

  // 2. 拼接数据块 + 清单（按内嵌路径排序，保证可复现）
  const names = [...files.keys()].sort();
  const chunks = [];
  const sizes = [];
  let total = 0;
  for (const name of names) {
    const buf = fs.readFileSync(files.get(name));
    chunks.push(buf);
    sizes.push(buf.length);
    total += buf.length;
  }
  const blob = Buffer.concat(chunks);
  const cacheKey = crypto.createHash('sha1').update(blob).digest('hex').slice(0, 16);
  const b64 = blob.toString('base64');
  const nameSet = new Set(names);

  // 3. 生成内嵌资源单元：Base64 数据块按块切分，资源名/大小用并列数组
  //    （避免超长字面量与带控制字符的清单文本）
  fs.mkdirSync(embedDir, { recursive: true });
  const CHUNK = 2000;
  const strArrayConst = (ident, typeName, values, indent) => {
    const items = values.map(v => `${indent}  '${String(v).replace(/'/g, "''")}'`);
    return `  ${ident}: array[0..${values.length - 1}] of ${typeName} = (\n${items.join(',\n')}\n${indent});`;
  };
  const b64Chunks = [];
  for (let i = 0; i < b64.length; i += CHUNK) b64Chunks.push(b64.slice(i, i + CHUNK));

  const unit =
`unit xui_embed_assets;

{$mode objfpc}{$H+}

{ 由 scripts/embed.js 生成，请勿手工编辑。
  内嵌资源：ui/ 运行时资源 + ${pageCount} 个演示页面及其关联资源
  （共 ${names.length} 个文件，${total} 字节）。指纹：${cacheKey} }

interface

implementation

uses
  xui_embed;

const
${strArrayConst('AssetNames', 'string', names, '')}

  AssetSizes: array[0..${sizes.length - 1}] of Integer = (
${sizes.map(v => '    ' + v).join(',\n')});

  AssetBlobBase64: array[0..${b64Chunks.length - 1}] of string = (
${b64Chunks.map(v => `    '${v}'`).join(',\n')});

  AssetCacheKey = '${cacheKey}';

initialization
  XuiEmbedInstall(AssetBlobBase64, AssetNames, AssetSizes, AssetCacheKey);

end.
`;
  fs.writeFileSync(assetsUnit, unit);
  console.log(`[生成] ${path.relative(root, assetsUnit)}`);
  console.log(`[资源] ${names.length} 个文件（${pageCount} 页），共 ${(total / 1024).toFixed(1)} KB，指纹 ${cacheKey}`);

  // 4. 编译单程序版（-dLUI_EMBED）
  const exePath = path.join(root, 'bin', 'lui-render-single.exe');
  if (!noBuild) {
    const lazbuild = findLazBuild();
    console.log(`[构建] lui_render_single.lpi（${lazbuild}）`);
    const res = spawnSync(lazbuild, [path.join(root, 'tools', 'renderer', 'lui_render_single.lpi')],
      { stdio: 'inherit', cwd: root });
    if (res.status !== 0) {
      console.error('[错误] 单程序版构建失败');
      process.exit(1);
    }
    if (!fs.existsSync(exePath)) {
      console.error('[错误] 未生成 bin/lui-render-single.exe');
      process.exit(1);
    }
    console.log(`[构建] ${path.relative(root, exePath)}（${(fs.statSync(exePath).size / 1048576).toFixed(1)} MB）`);
  } else if (!fs.existsSync(exePath)) {
    console.error('[错误] --no-build 但 bin/lui-render-single.exe 不存在');
    process.exit(1);
  }

  // 5. 冒烟：仓库外的空目录（无 ui/、无 pages/）运行，证明资源全部来自 exe 内部
  if (noSmoke) return;
  const smoke = fs.mkdtempSync(path.join(require('os').tmpdir(), 'lui-single-'));
  const smokeExe = path.join(smoke, 'lui-render-single.exe');
  fs.copyFileSync(exePath, smokeExe);

  const list = spawnSync(smokeExe, ['--list-embedded'], { cwd: smoke, encoding: 'buffer' });
  // 与本地化文案无关：只比对 ASCII 资源名行（子进程控制台编码随系统变化，
  // 中文表头不可靠，资源路径本身是 ASCII 可稳定比对）
  const listedNames = list.stdout.toString('latin1').split(/\r?\n/)
    .map(s => s.replace(/^\s+/, '').trimEnd())
    .filter(s => nameSet.has(s));
  const missing = names.filter(n => !listedNames.includes(n));
  if (list.status !== 0 || missing.length > 0) {
    console.error(`[错误] --list-embedded 校验失败（列出 ${listedNames.length}/${names.length}，缺 ${missing.slice(0, 5).join(', ')}）`);
    process.exit(1);
  }
  console.log(`[冒烟] 空目录运行 --list-embedded：内嵌 ${listedNames.length} 项`);

  const renderPage = path.basename(pageList.find(p => p.endsWith('ui_gallery.xml')) || pageList[0]);
  const outPng = path.join(smoke, 'out.png');
  const r = spawnSync(smokeExe, [renderPage, '-o', outPng, '-w', '420', '-H', '300', '-t', 'light'],
    { cwd: smoke, encoding: 'utf-8' });
  if (r.status !== 0 || !fs.existsSync(outPng) || fs.statSync(outPng).size < 1000) {
    console.error(`[错误] 空目录渲染失败（${renderPage}, status=${r.status}）:\n${r.stdout || ''}${r.stderr || ''}`);
    process.exit(1);
  }
  console.log(`[冒烟] 空目录渲染 ${renderPage} → ${(fs.statSync(outPng).size / 1024).toFixed(1)} KB PNG`);

  fs.rmSync(smoke, { recursive: true, force: true });
  console.log(`[完成] 单程序版：${path.relative(root, exePath)}`);
}

main();
