const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Client } = require('ssh2');

function validate(input) {
  const host = String(input.host || '').trim();
  const address = String(input.address || host).trim();
  const username = String(input.username || 'root').trim();
  const port = Number(input.port || 22);
  const validHost = (value) => /^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/.test(value) && !value.includes('..') && !value.endsWith('.');
  if (!validHost(host) || !validHost(address)) throw new Error('SSH 主机和 HTTPS 地址须为 IP 或域名，不含端口');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('SSH 端口无效');
  if (!/^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(username)) throw new Error('SSH 用户名无效');
  if (!input.password && !input.privateKeyPath) throw new Error('请输入 SSH 密码或选择私钥');
  return { host, address, username, port };
}

function fingerprint(key) {
  return `SHA256:${crypto.createHash('sha256').update(key).digest('base64').replace(/=+$/, '')}`;
}

function readKnown(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return {}; throw error; }
}

function writeKnown(file, known) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temp, JSON.stringify(known), { mode: 0o600, flag: 'wx' });
    fs.renameSync(temp, file);
  } finally { try { fs.unlinkSync(temp); } catch {} }
}

function connect(input, acceptedFingerprint, probe = false) {
  const options = validate(input);
  let observed = '';
  const client = new Client();
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      if (error) reject(error); else resolve(result);
    };
    client.on('ready', () => finish(null, { client, fingerprint: observed }));
    client.on('error', (error) => {
      if (probe && observed) finish(null, { fingerprint: observed });
      else if (observed && observed !== acceptedFingerprint) finish(new Error(`SSH 主机密钥不匹配：${observed}`));
      else finish(error);
    });
    client.on('close', () => {
      if (probe && observed) finish(null, { fingerprint: observed });
      else finish(new Error('SSH 连接已关闭'));
    });
    const config = {
      host: options.host, port: options.port, username: options.username, readyTimeout: 20000,
      hostVerifier: (key) => {
        observed = fingerprint(key);
        return !probe && observed === acceptedFingerprint;
      }
    };
    if (input.privateKeyPath) {
      config.privateKey = fs.readFileSync(input.privateKeyPath);
      if (input.passphrase) config.passphrase = input.passphrase;
    } else {
      config.password = String(input.password);
      config.tryKeyboard = true;
      client.on('keyboard-interactive', (_name, _instructions, _lang, prompts, done) =>
        done(prompts.map(() => String(input.password))));
    }
    client.connect(config);
  });
}

function execute(client, command, input = '') {
  return new Promise((resolve, reject) => client.exec(command, (error, stream) => {
    if (error) return reject(error);
    let stdout = '', stderr = '';
    stream.on('data', (chunk) => { stdout += chunk.toString(); });
    stream.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    stream.on('close', (code) => code === 0 ? resolve(stdout) : reject(new Error((stderr || stdout || `命令退出码 ${code}`).trim())));
    if (input) stream.end(input); else stream.end();
  }));
}

function upload(client, local, remote) {
  return new Promise((resolve, reject) => client.sftp((error, sftp) => {
    if (error) return reject(error);
    sftp.fastPut(local, remote, { mode: 0o755 }, (putError) => putError ? reject(putError) : resolve());
  }));
}

function createSSHInstaller(knownFile, binaryForArch) {
  async function probe(input) {
    const { host, port } = validate(input);
    const { fingerprint: seen } = await connect(input, '', true);
    const key = `${host}:${port}`;
    return { fingerprint: seen, previousFingerprint: readKnown(knownFile)[key] || '', key };
  }

  async function install(input, approvedFingerprint) {
    const options = validate(input);
    const key = `${options.host}:${options.port}`;
    const seen = String(approvedFingerprint || '');
    if (!/^SHA256:[A-Za-z0-9+/]{43}$/.test(seen)) throw new Error('请先确认 SSH 主机指纹');
    const { client, fingerprint: actual } = await connect(input, seen);
    let remote = '';
    try {
      const rawArch = (await execute(client, 'uname -m')).trim().split(/\s+/).at(-1);
      const arch = { x86_64: 'amd64', amd64: 'amd64', aarch64: 'arm64', arm64: 'arm64' }[rawArch];
      if (!arch) throw new Error(`不支持的服务器架构：${rawArch}`);
      const binary = binaryForArch(arch);
      if (!fs.existsSync(binary)) throw new Error('找不到内置服务端安装文件');
      remote = `/tmp/sera-install-${crypto.randomBytes(12).toString('hex')}`;
      await upload(client, binary, remote);
      await execute(client, `chmod 755 ${remote}`);
      const sudo = options.username === 'root' ? '' : input.sudoPassword ? "sudo -S -p '' " : 'sudo -n ';
      const output = await execute(client, `${sudo}${remote} install -host ${options.address} -json`,
        options.username !== 'root' && input.sudoPassword ? `${input.sudoPassword}\n` : '');
      const line = output.split(/\r?\n/).reverse().find((part) => part.trim().startsWith('{'));
      if (!line) throw new Error('安装已执行，但没有返回连接信息；请在服务器检查服务状态');
      const result = JSON.parse(line);
      if (!result.endpoint || !result.token || !result.fingerprint) throw new Error('安装返回的连接信息不完整');
      const known = readKnown(knownFile);
      known[key] = actual;
      writeKnown(knownFile, known);
      return result;
    } finally {
      if (remote) { try { await execute(client, `rm -f ${remote}`); } catch {} }
      client.end();
    }
  }
  return { probe, install };
}

module.exports = { createSSHInstaller, validate, fingerprint };
