/**
 * lui 回归基线校验。
 *
 * 测试数量必须来自实际测试程序的机器可读结果，不能由 README 或里程碑文档手工维护。
 * 复用已编译的 tests/runtests.exe，执行后再校验文档。
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const testExe = path.join(root, 'tests', 'runtests.exe');
const testSource = path.join(root, 'tests', 'runtests.lpr');

if (!fs.existsSync(testSource)) {
  console.error('[基线] 未找到 tests/runtests.lpr');
  process.exit(1);
}

const sourceText = fs.readFileSync(testSource, 'utf8');
const includeFiles = [...sourceText.matchAll(/\{\$I\s+([^}\s]+)\}/gi)]
  .map((match) => match[1])
  .filter((file) => file.toLowerCase().endsWith('.inc'));
const missingIncludes = includeFiles.filter(
  (file) => !fs.existsSync(path.join(root, 'tests', file))
);

if (missingIncludes.length > 0) {
  console.error('[基线] runtests.lpr 引用了不存在的 include：');
  for (const file of missingIncludes) {
    console.error(`  - tests/${file}`);
  }
  process.exit(1);
}

if (!fs.existsSync(testExe)) {
  console.error('[基线] 未找到 tests/runtests.exe，请先运行 npm run build:test');
  process.exit(1);
}

const result = spawnSync(testExe, [], {
  cwd: root,
  stdio: 'pipe',
  encoding: null
});

if (result.error) {
  console.error(`[基线] 无法启动测试程序：${result.error.message}`);
  process.exit(1);
}

// 保留原测试输出，避免 npm test 从“直接执行 exe”改成静默执行。
if (result.stdout && result.stdout.length > 0) {
  process.stdout.write(result.stdout);
}
if (result.stderr && result.stderr.length > 0) {
  process.stderr.write(result.stderr);
}

const output = Buffer.concat([
  result.stdout || Buffer.alloc(0),
  result.stderr || Buffer.alloc(0)
]).toString('latin1');
const match = output.match(/LUI_TEST_RESULT passed=(\d+) failed=(\d+)/);

if (!match) {
  console.error('[基线] 测试程序没有输出 LUI_TEST_RESULT 机器可读标记');
  process.exit(1);
}

const passed = Number(match[1]);
const failed = Number(match[2]);
const checks = [
  {
    file: 'README.md',
    pattern: /单元测试（`npm test` 运行，当前 (\d+) 项）/
  },
  {
    file: 'docs/M10-AI-Agent设计方案.md',
    pattern: /当前回归基线：M11（runtests (\d+) 项全绿）/
  },
  {
    file: 'docs/M10-AI-Agent设计方案.md',
    pattern: /自动化（runtests，当前 (\d+) 项全绿 \/ 0 失败）/
  },
  {
    file: 'docs/M6-异步设计.md',
    pattern: /当前完整回归入口（(\d+) 项通过，0 项失败）/
  }
];

const errors = [];
for (const check of checks) {
  const file = path.join(root, check.file);
  if (!fs.existsSync(file)) {
    errors.push(`${check.file}: 文件不存在`);
    continue;
  }
  const text = fs.readFileSync(file, 'utf8');
  const found = text.match(check.pattern);
  if (!found) {
    errors.push(`${check.file}: 未找到测试基线声明`);
    continue;
  }
  if (Number(found[1]) !== passed) {
    errors.push(`${check.file}: 声明 ${found[1]}，实际 ${passed}`);
  }
}

if (result.status !== 0 || failed !== 0) {
  console.error(`[基线] 测试失败：exit=${result.status} passed=${passed} failed=${failed}`);
  process.exit(result.status || 1);
}

if (errors.length > 0) {
  console.error('[基线] 文档与实际测试数量不一致：');
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}

console.log(`[基线] ${passed} 项通过，文档声明一致`);
