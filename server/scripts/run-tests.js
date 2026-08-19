const { readdirSync } = require('node:fs');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');

const serverDir = join(__dirname, '..');
const testDir = join(serverDir, 'test');
const testFiles = readdirSync(testDir)
  .filter((name) => name.endsWith('.test.js'))
  .sort()
  .map((name) => join('test', name));

if (testFiles.length === 0) {
  console.error('No backend test files found.');
  process.exit(1);
}

const result = spawnSync(process.execPath, ['--test', ...testFiles], {
  cwd: serverDir,
  stdio: 'inherit',
});

if (result.error) throw result.error;
process.exit(result.status ?? 1);
