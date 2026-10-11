const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');

const encode = (value) => [...Buffer.from(String(value))].map((byte) => {
  const char = String.fromCharCode(byte);
  return /[A-Za-z0-9_.~-]/.test(char) ? char : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
}).join('');
const canonical = (params) => Object.keys(params).sort().map((key) => `${encode(key)}=${encode(params[key])}`).join('&');
const stringToSign = (params) => `GET&%2F&${encode(canonical(params))}`;
const signature = (secret, params) => crypto.createHmac('sha1', `${secret}&`).update(stringToSign(params)).digest('base64');

function createDNS(file) {
  function read() {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return {}; throw error; }
  }
  function write(value) {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const temp = `${file}.${crypto.randomUUID()}.tmp`;
    try {
      fs.writeFileSync(temp, JSON.stringify(value, null, 2), { mode: 0o600, flag: 'wx' });
      fs.renameSync(temp, file);
      if (process.platform !== 'win32') fs.chmodSync(file, 0o600);
    } finally { try { fs.unlinkSync(temp); } catch { /* renamed */ } }
  }
  const keyFor = (id) => id || 'default';
  function publicSettings(id) {
    const entry = read()[keyFor(id)] || {};
    return { accessKeyId: entry.accessKeyId || '', hasSecret: Boolean(entry.secret),
      pageSize: entry.pageSize || 50, defaultTTL: entry.defaultTTL || 600 };
  }
  function save(id, input) {
    const all = read(), key = keyFor(id), before = all[key] || {};
    const accessKeyId = String(input.accessKeyId || '').trim();
    const secret = String(input.secret || '').trim() || before.secret || '';
    if (!accessKeyId || !secret) throw new Error('请输入阿里云 AccessKey ID 和 Secret');
    all[key] = { accessKeyId, secret, pageSize: Math.max(10, Math.min(100, Number(input.pageSize) || 50)),
      defaultTTL: Math.max(60, Math.min(86400, Number(input.defaultTTL) || 600)) };
    write(all);
    return publicSettings(id);
  }
  async function call(id, action, params = {}) {
    if (!['DescribeDomains', 'DescribeDomainRecords', 'AddDomainRecord', 'UpdateDomainRecord', 'DeleteDomainRecord'].includes(action))
      throw new Error('不支持的域名解析操作');
    const config = read()[keyFor(id)];
    if (!config?.accessKeyId || !config?.secret) throw new Error('请先配置阿里云 AccessKey');
    const all = {
      Action: action, Format: 'JSON', Version: '2015-01-09', AccessKeyId: config.accessKeyId,
      SignatureMethod: 'HMAC-SHA1', SignatureVersion: '1.0', SignatureNonce: crypto.randomUUID(),
      Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    };
    for (const [key, value] of Object.entries(params)) {
      if (!['DomainName', 'PageNumber', 'PageSize', 'RecordId', 'RR', 'Type', 'Value', 'TTL', 'Priority'].includes(key))
        throw new Error('域名解析参数无效');
      all[key] = String(value);
    }
    all.Signature = signature(config.secret, all);
    const url = `https://alidns.aliyuncs.com/?${canonical(all)}`;
    return new Promise((resolve, reject) => {
      const req = https.get(url, { timeout: 30000 }, async (res) => {
        try {
          const chunks = [];
          let size = 0;
          for await (const chunk of res) {
            size += chunk.length;
            if (size > 2 * 1024 * 1024) throw new Error('阿里云响应过大');
            chunks.push(chunk);
          }
          const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (body.Code) throw new Error(`[${body.Code}] ${body.Message || '请求失败'}`);
          if (res.statusCode !== 200) throw new Error(`阿里云返回 HTTP ${res.statusCode}`);
          resolve(body);
        } catch (error) { reject(error); }
      });
      req.on('timeout', () => req.destroy(new Error('阿里云解析接口连接超时')));
      req.on('error', reject);
    });
  }
  return { publicSettings, save, call };
}

module.exports = { createDNS, encode, canonical, stringToSign, signature };
