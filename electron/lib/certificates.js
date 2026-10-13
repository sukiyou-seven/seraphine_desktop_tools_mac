const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const acme = require('acme-client');

function normalizeDomains(values, zone) {
  const domains = [...new Set(values.map((value) => String(value).trim().toLowerCase()).filter(Boolean))];
  if (!domains.length || domains.length > 20) throw new Error('请输入 1–20 个证书域名');
  const validHost = (host) => host.length <= 253 && host.split('.').length >= 2 &&
    host.split('.').every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label));
  for (const value of domains) {
    const base = value.replace(/^\*\./, '');
    if (!validHost(base) || (value.startsWith('*.') && value !== `*.${base}`) ||
        !(base === zone || base.endsWith(`.${zone}`)))
      throw new Error(`证书域名 ${value} 不属于当前解析域名 ${zone}`);
  }
  return domains;
}

function createCertificates(base, dns) {
  function directory(id) {
    const key = crypto.createHash('sha256').update(String(id || 'default')).digest('hex').slice(0, 16);
    return path.join(base, key);
  }
  function list(id) {
    const folder = directory(id);
    try { return JSON.parse(fs.readFileSync(path.join(folder, 'index.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }
  function saveIndex(id, entries) {
    const folder = directory(id);
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
    const temp = path.join(folder, `${crypto.randomUUID()}.tmp`);
    try {
      fs.writeFileSync(temp, JSON.stringify(entries, null, 2), { mode: 0o600, flag: 'wx' });
      fs.renameSync(temp, path.join(folder, 'index.json'));
    } finally { try { fs.unlinkSync(temp); } catch { /* renamed */ } }
  }
  async function accountKey(id) {
    const folder = directory(id);
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
    const file = path.join(folder, 'account.key');
    try { return fs.readFileSync(file); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const key = await acme.crypto.createPrivateKey();
    fs.writeFileSync(file, key, { mode: 0o600, flag: 'wx' });
    return key;
  }
  async function issue(id, input) {
    const zone = String(input.zone || '').trim().toLowerCase();
    const email = String(input.email || '').trim();
    const domains = normalizeDomains(input.domains || [], zone);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('请输入有效的联系人邮箱');
    const keyType = input.keyType === 'rsa2048' ? 'rsa2048' : 'ecc';
    const account = await accountKey(id);
    const client = new acme.Client({ directoryUrl: acme.directory.letsencrypt.production, accountKey: account });
    const privateKey = keyType === 'ecc'
      ? await acme.crypto.createPrivateEcdsaKey()
      : await acme.crypto.createPrivateRsaKey(2048);
    const [, csr] = await acme.crypto.createCsr({ altNames: domains }, privateKey);
    const challengeRecords = new Map();
    const remove = async (key) => {
      const recordId = challengeRecords.get(key);
      if (!recordId) return;
      await dns.call(id, 'DeleteDomainRecord', { RecordId: recordId });
      challengeRecords.delete(key);
    };
    try {
      const certificate = await client.auto({
        csr, email, termsOfServiceAgreed: true, challengePriority: ['dns-01'],
        skipChallengeVerification: true,
        challengeCreateFn: async (authorization, challenge, keyAuthorization) => {
          if (challenge.type !== 'dns-01') throw new Error('仅支持 DNS-01 证书验证');
          const baseDomain = authorization.identifier.value.replace(/^\*\./, '');
          const prefix = baseDomain === zone ? '' : baseDomain.slice(0, -(zone.length + 1));
          const rr = `_acme-challenge${prefix ? `.${prefix}` : ''}`;
          const result = await dns.call(id, 'AddDomainRecord', {
            DomainName: zone, RR: rr, Type: 'TXT', Value: keyAuthorization, TTL: 600
          });
          challengeRecords.set(challenge.token, result.RecordId);
          await new Promise((resolve) => setTimeout(resolve, 45000));
        },
        challengeRemoveFn: async (_authorization, challenge) => { await remove(challenge.token); }
      });
      const folder = directory(id);
      const name = `${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
      const output = path.join(folder, name);
      fs.mkdirSync(output, { recursive: true, mode: 0o700 });
      fs.writeFileSync(path.join(output, 'fullchain.pem'), certificate, { mode: 0o600, flag: 'wx' });
      fs.writeFileSync(path.join(output, 'privkey.pem'), privateKey, { mode: 0o600, flag: 'wx' });
      const details = acme.crypto.readCertificateInfo(certificate);
      const entry = { id: name, domains, email, keyType, createdAt: new Date().toISOString(),
        notAfter: details.notAfter, fullchainPath: path.join(output, 'fullchain.pem'),
        privateKeyPath: path.join(output, 'privkey.pem') };
      saveIndex(id, [entry, ...list(id)]);
      return entry;
    } finally {
      for (const key of [...challengeRecords.keys()]) {
        try { await remove(key); } catch { /* keep original ACME error */ }
      }
    }
  }
  function pair(id, certificateID) {
    const entry = list(id).find((item) => item.id === certificateID);
    if (!entry) throw new Error('证书不存在');
    const folder = fs.realpathSync(directory(id));
    for (const filename of [entry.fullchainPath, entry.privateKeyPath]) {
      if (!fs.realpathSync(filename).startsWith(folder + path.sep)) throw new Error('证书文件不在应用数据目录');
    }
    return { certificate: fs.readFileSync(entry.fullchainPath, 'utf8'), private_key: fs.readFileSync(entry.privateKeyPath, 'utf8') };
  }
  return { list, issue, pair };
}

module.exports = { createCertificates, normalizeDomains };
