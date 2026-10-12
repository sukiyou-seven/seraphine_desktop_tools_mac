const fs = require('node:fs');
const path = require('node:path');

const MAX_ROOTS = 100;
const MAX_ITEMS = 20000;
const MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024;

function planUpload(paths) {
  if (!Array.isArray(paths) || paths.length === 0 || paths.length > MAX_ROOTS)
    throw new Error('一次最多上传 100 个文件或文件夹');
  const names = new Set();
  const items = [];
  let skipped = 0;

  function visit(localPath, parts) {
    const info = fs.lstatSync(localPath);
    if (info.isSymbolicLink() || (!info.isDirectory() && !info.isFile())) { skipped++; return; }
    if (items.length >= MAX_ITEMS) throw new Error('一次最多上传 20000 个文件和目录');
    if (info.isDirectory()) {
      items.push({ kind: 'directory', localPath, parts });
      for (const name of fs.readdirSync(localPath).sort()) visit(path.join(localPath, name), [...parts, name]);
    } else {
      if (info.size > MAX_FILE_BYTES) throw new Error(`${parts.join('/')} 超过单文件 2 GiB 限制`);
      items.push({ kind: 'file', localPath, parts });
    }
  }

  for (const localPath of paths) {
    if (typeof localPath !== 'string' || !path.isAbsolute(localPath)) throw new Error('本地路径无效');
    const name = path.basename(localPath);
    if (!name || name === '.' || name === '..' || names.has(name)) throw new Error(`上传项名称重复或无效：${name}`);
    names.add(name);
    visit(localPath, [name]);
  }
  if (!items.length) throw new Error('所选内容没有可上传的普通文件或目录');
  return { roots: [...names], items, skipped };
}

function remotePath(directory, parts) {
  if (typeof directory !== 'string' || !directory.startsWith('/') || directory.length > 4096 ||
      directory.split('/').includes('..') || directory.includes('\0')) throw new Error('服务器路径无效');
  if (parts.some((part) => !part || part === '.' || part === '..' || part.includes('/') || part.includes('\0')))
    throw new Error('上传文件名称无效');
  const result = path.posix.join(directory, ...parts);
  if (result.length > 4096) throw new Error('服务器路径过长');
  return result;
}

async function uploadPlan(plan, directory, overwrite, actions) {
  let files = 0, directories = 0, completed = 0;
  for (const item of plan.items) {
    const destination = remotePath(directory, item.parts);
    try {
      if (item.kind === 'directory') {
        try { await actions.mkdir(destination); }
        catch (error) {
          if (error.status !== 409 || !overwrite || !await actions.directoryExists(destination)) throw error;
        }
        directories++;
      } else {
        await actions.uploadFile(item.localPath, destination, overwrite);
        files++;
      }
    } catch (error) {
      throw new Error(`上传 ${item.parts.join('/')} 失败：${error.message}`, { cause: error });
    }
    completed++;
    actions.progress?.(completed, plan.items.length, item.parts.join('/'));
  }
  return { files, directories, skipped: plan.skipped };
}

module.exports = { planUpload, remotePath, uploadPlan };
