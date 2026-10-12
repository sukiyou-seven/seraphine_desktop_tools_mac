const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { createStore } = require('../lib/connections');
const { route } = require('../lib/routes');
const { request } = require('../lib/transport');
const { encode, canonical, stringToSign, signature } = require('../lib/dns');
const { normalizeDomains } = require('../lib/certificates');
const { validate: validateSSH, fingerprint: sshFingerprint } = require('../lib/ssh-installer');
const { planUpload, remotePath, uploadPlan } = require('../lib/file-upload');

test('folder upload keeps nested files and empty directories, merges only after confirmation', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sera-upload-'));
  try {
    const root = path.join(dir, 'website');
    fs.mkdirSync(path.join(root, 'assets'), { recursive: true });
    fs.mkdirSync(path.join(root, 'empty'));
    fs.writeFileSync(path.join(root, 'assets', '.hidden'), 'yes');
    fs.writeFileSync(path.join(root, 'index.html'), '<h1>ok</h1>');
    fs.symlinkSync(path.join(root, 'index.html'), path.join(root, 'shortcut'));
    const plan = planUpload([root]);
    assert.equal(plan.skipped, 1);
    assert.deepEqual(plan.items.map((item) => item.parts.join('/')),
      ['website', 'website/assets', 'website/assets/.hidden', 'website/empty', 'website/index.html']);
    const visited = [];
    const actions = {
      mkdir: async (destination) => {
        visited.push(`mkdir ${destination}`);
        if (destination.endsWith('/website')) throw Object.assign(new Error('exists'), { status: 409 });
      },
      directoryExists: async () => true,
      uploadFile: async (_local, destination, overwrite) => visited.push(`file ${destination} ${overwrite}`)
    };
    await assert.rejects(uploadPlan(plan, '/www/seraphim/web', false, actions), /website.*失败/);
    visited.length = 0;
    const result = await uploadPlan(plan, '/www/seraphim/web', true, actions);
    assert.deepEqual(result, { files: 2, directories: 3, skipped: 1 });
    assert.deepEqual(visited, [
      'mkdir /www/seraphim/web/website',
      'mkdir /www/seraphim/web/website/assets',
      'file /www/seraphim/web/website/assets/.hidden true',
      'mkdir /www/seraphim/web/website/empty',
      'file /www/seraphim/web/website/index.html true'
    ]);
    assert.throws(() => remotePath('/www/seraphim', ['..', 'etc']), /名称无效/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('connection storage keeps tokens out of public view and validates HTTPS', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sera-connections-'));
  try {
    const file = path.join(dir, 'connections.json');
    const store = createStore(file);
    const publicData = store.save({ name: '测试', endpoint: 'https://127.0.0.1:27520',
      token: 'private-token', fingerprint: 'a'.repeat(64) });
    assert.equal(publicData.entries[0].hasToken, true);
    assert.equal(JSON.stringify(publicData).includes('private-token'), false);
    assert.equal(store.selected().token, 'private-token');
    store.save({ id: publicData.selectedID, name: '测试2', endpoint: 'https://127.0.0.1:27520',
      token: '', fingerprint: 'a'.repeat(64) });
    assert.equal(store.selected().token, 'private-token');
    assert.throws(() => store.save({ endpoint: 'http://127.0.0.1:27520', token: 'x' }), /HTTPS/);
    assert.throws(() => store.save({ endpoint: 'https://evil.test/path', token: 'x' }), /HTTPS/);
    if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('server actions use fixed routes and encoded path segments', () => {
  assert.deepEqual(route('projects.action', { id: 'web-app', action: 'start' }),
    ['POST', '/v1/projects/web-app/action', { action: 'start' }]);
  assert.match(route('files.list', { path: '/www/seraphim/a b' })[1], /a\+b/);
  assert.throws(() => route('projects.action', { id: '../etc', action: 'start' }), /标识/);
  assert.throws(() => route('projects.action', { id: 'web', action: 'rm -rf /' }), /操作/);
  assert.throws(() => route('custom.endpoint', {}), /不支持/);
});

test('AliDNS signature matches independent documented vector', () => {
  const params = { Format: 'XML', AccessKeyId: 'testid', Action: 'DescribeDomainRecords',
    SignatureMethod: 'HMAC-SHA1', DomainName: 'example.com',
    SignatureNonce: 'f59ed6a9-83fc-473b-9cc6-99c95df3856e', SignatureVersion: '1.0',
    Version: '2015-01-09', Timestamp: '2016-03-24T16:41:54Z' };
  assert.equal(encode('a b~c/d'), 'a%20b~c%2Fd');
  assert.equal(canonical({ b: '2', a: '1' }), 'a=1&b=2');
  assert.match(stringToSign(params), /Timestamp%3D2016-03-24T16%253A41%253A54Z/);
  assert.equal(signature('testsecret', params), 'uRpHwaSEt3J+6KQD//svCh/x+pI=');
});

test('certificate domains stay inside the selected DNS zone', () => {
  assert.deepEqual(normalizeDomains(['example.com', '*.example.com', 'www.example.com'], 'example.com'),
    ['example.com', '*.example.com', 'www.example.com']);
  assert.throws(() => normalizeDomains(['example.com.evil.test'], 'example.com'), /不属于/);
  assert.throws(() => normalizeDomains(['../example.com'], 'example.com'), /不属于/);
});

test('SSH installer validates command arguments and computes the displayed host fingerprint', () => {
  assert.deepEqual(validateSSH({ host: 'server.example.com', username: 'root', password: 'temporary' }),
    { host: 'server.example.com', address: 'server.example.com', username: 'root', port: 22 });
  for (const host of ['server;reboot', 'server/other', '-danger', 'server..example.com'])
    assert.throws(() => validateSSH({ host, username: 'root', password: 'x' }));
  assert.throws(() => validateSSH({ host: 'example.com', username: 'root;id', password: 'x' }));
  assert.equal(sshFingerprint(Buffer.from('host-key')),
    `SHA256:${crypto.createHash('sha256').update('host-key').digest('base64').replace(/=+$/, '')}`);
});

test('pinned self-signed TLS accepts matching certificate before sending bearer token', async (t) => {
  if (spawnSync('openssl', ['version']).status !== 0) { t.skip('openssl unavailable'); return; }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sera-tls-'));
  const keyFile = path.join(dir, 'key.pem'), certFile = path.join(dir, 'cert.pem');
  const generated = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=localhost', '-keyout', keyFile, '-out', certFile], { stdio: 'ignore' });
  assert.equal(generated.status, 0);
  const cert = fs.readFileSync(certFile);
  const fingerprint = crypto.createHash('sha256').update(new crypto.X509Certificate(cert).raw).digest('hex');
  const seen = [];
  const server = https.createServer({ key: fs.readFileSync(keyFile), cert }, (req, res) => {
    seen.push(req.headers.authorization);
    res.setHeader('Content-Type', 'application/json');
    res.end('{"ok":true}');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const endpoint = `https://127.0.0.1:${server.address().port}`;
  try {
    const success = await request({ endpoint, fingerprint }, 'BearerSecret', 'GET', '/v1/status');
    assert.deepEqual(success.data, { ok: true });
    assert.deepEqual(seen, ['Bearer BearerSecret']);
    await assert.rejects(request({ endpoint, fingerprint: '0'.repeat(64) }, 'wrong', 'GET', '/v1/status'), /指纹不匹配/);
    assert.deepEqual(seen, ['Bearer BearerSecret']);
    await assert.rejects(request({ endpoint, fingerprint: '' }, 'wrong', 'GET', '/v1/status'), /certificate|self-signed/i);
    assert.deepEqual(seen, ['Bearer BearerSecret']);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
