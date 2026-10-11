const https = require('node:https');
const tls = require('node:tls');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');

function agentFor(fingerprint) {
  if (!fingerprint) return new https.Agent({ keepAlive: false });
  const agent = new https.Agent({ keepAlive: false });
  agent.createConnection = (options, callback) => {
    let finished = false;
    const finish = (error, socket) => {
      if (finished) return;
      finished = true;
      callback(error, socket);
    };
    const socket = tls.connect({ ...options, rejectUnauthorized: false }, () => {
      const certificate = socket.getPeerCertificate(true);
      if (!certificate?.raw) {
        finish(new Error('无法读取服务器证书'));
        socket.destroy();
        return;
      }
      const actual = crypto.createHash('sha256').update(certificate.raw).digest('hex');
      if (actual !== fingerprint) {
        finish(new Error('服务器证书指纹不匹配，请核对连接地址与指纹'));
        socket.destroy();
      } else {
        finish(null, socket);
      }
    });
    socket.once('error', (error) => finish(error));
  };
  return agent;
}

function endpointURL(connection, path) {
  const base = new URL(connection.endpoint);
  if (base.protocol !== 'https:') throw new Error('仅支持 HTTPS 服务器连接');
  return new URL(path, base);
}

async function request(connection, token, method, path, { body, input, output, timeout = 120000 } = {}) {
  const url = endpointURL(connection, path);
  const agent = agentFor(connection.fingerprint);
  const json = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
  try {
    return await new Promise((resolve, reject) => {
      const headers = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
      if (json) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = String(json.length); }
      if (input) {
        headers['Content-Type'] = 'application/octet-stream';
        headers['Content-Length'] = String(fs.statSync(input).size);
      }
      const req = https.request(url, { method, agent, headers, timeout }, async (res) => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          const chunks = [];
          for await (const chunk of res) chunks.push(chunk);
          const detail = Buffer.concat(chunks).toString('utf8').trim();
          reject(new Error(detail || `服务器返回 HTTP ${res.statusCode}`));
          return;
        }
        try {
          if (output) {
            await pipeline(res, fs.createWriteStream(output, { flags: 'wx', mode: 0o600 }));
            resolve({ status: res.statusCode, data: null });
            return;
          }
          const chunks = [];
          let size = 0;
          for await (const chunk of res) {
            size += chunk.length;
            if (size > 8 * 1024 * 1024) throw new Error('服务器响应超过 8 MiB');
            chunks.push(chunk);
          }
          const raw = Buffer.concat(chunks).toString('utf8');
          let data = raw;
          if ((res.headers['content-type'] || '').includes('application/json') && raw) data = JSON.parse(raw);
          resolve({ status: res.statusCode, data });
        } catch (error) { reject(error); }
      });
      req.on('timeout', () => req.destroy(new Error('连接超时')));
      req.on('error', reject);
      if (json) req.end(json);
      else if (input) fs.createReadStream(input).on('error', reject).pipe(req);
      else req.end();
    });
  } finally {
    agent.destroy();
  }
}

module.exports = { request, endpointURL, agentFor };
