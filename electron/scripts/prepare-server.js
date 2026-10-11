const { mkdirSync, existsSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

const root = resolve(__dirname, '../..');
const assets = join(__dirname, '..', 'assets');
mkdirSync(assets, { recursive: true });
for (const arch of ['amd64', 'arm64']) {
  const target = join(assets, `sera-linux-${arch}`);
  if (process.env.SERA_USE_EXISTING_SERVER_BINARIES === '1' && existsSync(target)) continue;
  const result = spawnSync('go', ['build', '-trimpath', '-ldflags=-s -w', '-o', target, '.'], {
    cwd: join(root, 'server-status'),
    stdio: 'inherit',
    env: { ...process.env, CGO_ENABLED: '0', GOOS: 'linux', GOARCH: arch }
  });
  if (result.status !== 0) process.exit(result.status || 1);
}
