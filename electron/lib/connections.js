const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function createStore(file) {
  function read() {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (Array.isArray(parsed.entries)) return parsed;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    return { selectedID: '', entries: [] };
  }

  function write(document) {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    if (process.platform !== 'win32') fs.chmodSync(path.dirname(file), 0o700);
    const temporary = `${file}.${crypto.randomUUID()}.tmp`;
    try {
      fs.writeFileSync(temporary, JSON.stringify(document, null, 2), { mode: 0o600, flag: 'wx' });
      fs.renameSync(temporary, file);
      if (process.platform !== 'win32') fs.chmodSync(file, 0o600);
    } finally {
      try { fs.unlinkSync(temporary); } catch { /* renamed */ }
    }
  }

  function publicDocument() {
    const document = read();
    return {
      selectedID: document.selectedID,
      entries: document.entries.map(({ connection, token }) => ({ connection, hasToken: Boolean(token) }))
    };
  }

  function selected() {
    const document = read();
    const entry = document.entries.find(({ connection }) => connection.id === document.selectedID);
    if (!entry || !entry.token) throw new Error('请先保存服务器连接与 API 令牌');
    return entry;
  }

  function save(input) {
    if (!input || typeof input !== 'object') throw new Error('连接配置无效');
    const endpoint = String(input.endpoint || '').trim();
    const url = new URL(endpoint);
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash)
      throw new Error('请输入完整的 HTTPS 根地址，例如 https://1.2.3.4:27520');
    const fingerprint = String(input.fingerprint || '').replace(/[\s:]/g, '').toLowerCase();
    if (fingerprint && !/^[a-f0-9]{64}$/.test(fingerprint)) throw new Error('证书指纹须为 SHA-256 的 64 位十六进制字符');
    const document = read();
    const id = /^[a-f0-9-]{36}$/i.test(input.id || '') ? input.id : crypto.randomUUID();
    const previous = document.entries.find(({ connection }) => connection.id === id);
    const token = String(input.token || '').trim() || previous?.token || '';
    if (!token) throw new Error('请输入 API 令牌');
    const connection = { id, name: String(input.name || '').trim().slice(0, 80), endpoint: url.origin,
                         fingerprint };
    const next = { connection, token };
    const index = document.entries.findIndex(({ connection: item }) => item.id === id);
    if (index < 0) document.entries.push(next); else document.entries[index] = next;
    document.selectedID = id;
    write(document);
    return publicDocument();
  }

  function remove(id) {
    const document = read();
    document.entries = document.entries.filter(({ connection }) => connection.id !== id);
    if (document.selectedID === id) document.selectedID = document.entries[0]?.connection.id || '';
    write(document);
    return publicDocument();
  }

  function select(id) {
    const document = read();
    if (!document.entries.some(({ connection }) => connection.id === id)) throw new Error('服务器连接不存在');
    document.selectedID = id;
    write(document);
    return publicDocument();
  }

  return { read, publicDocument, selected, save, remove, select };
}

module.exports = { createStore };
