const { app, BrowserWindow, ipcMain, dialog, clipboard, session } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createStore } = require('./lib/connections');
const { createDNS } = require('./lib/dns');
const { createCertificates } = require('./lib/certificates');
const { request } = require('./lib/transport');
const { route, pathQuery } = require('./lib/routes');
const { createSSHInstaller } = require('./lib/ssh-installer');
const { planUpload, remotePath, uploadPlan } = require('./lib/file-upload');

let store;
let dns;
let certificates;
let sshInstaller;
let certificateJob = false;
let window;
const chosenUploads = new Map();
const chosenSSHKeys = new Set();
const appIcon = path.join(__dirname, 'assets', 'icon.png');

function connectionsFile() {
  // The macOS native client already owns this location; both clients can reuse saved servers.
  const base = process.platform === 'darwin' ? app.getPath('appData') : app.getPath('userData');
  return path.join(base, 'Seraphim', 'server-management', 'connections.json');
}

function createWindow() {
  window = new BrowserWindow({
    width: 1320, height: 880, minWidth: 980, minHeight: 650,
    title: 'Seraphim', backgroundColor: '#111827', icon: appIcon,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      webSecurity: true
    }
  });
  window.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  window.on('closed', () => { chosenUploads.clear(); chosenSSHKeys.clear(); window = null; });
}

function installerBinary(arch) {
  if (!['amd64', 'arm64'].includes(arch)) throw new Error('不支持的服务器架构');
  return app.isPackaged
    ? path.join(process.resourcesPath, 'server', `sera-linux-${arch}`)
    : path.join(__dirname, 'assets', `sera-linux-${arch}`);
}

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.dock.setIcon(appIcon);
  store = createStore(connectionsFile());
  dns = createDNS(path.join(path.dirname(connectionsFile()), 'dns.json'));
  certificates = createCertificates(path.join(path.dirname(connectionsFile()), 'certificates'), dns);
  sshInstaller = createSSHInstaller(path.join(path.dirname(connectionsFile()), 'ssh-hosts.json'), installerBinary);
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  ipcMain.handle('connections:list', () => store.publicDocument());
  ipcMain.handle('connections:save', (_event, entry) => store.save(entry));
  ipcMain.handle('connections:delete', (_event, id) => store.remove(id));
  ipcMain.handle('connections:select', (_event, id) => store.select(id));
  ipcMain.handle('dns:settings', () => dns.publicSettings(store.read().selectedID));
  ipcMain.handle('dns:save', (_event, settings) => dns.save(store.read().selectedID, settings));
  ipcMain.handle('dns:call', (_event, action, params) => dns.call(store.read().selectedID, action, params));
  ipcMain.handle('certificates:list', () => certificates.list(store.read().selectedID));
  ipcMain.handle('certificates:deploy', async (_event, certificateID, provider, siteID) => {
    const { connection, token } = store.selected();
    if (!/^(nginx|apache|openresty)$/.test(provider) || !/^[a-z0-9.-]{1,253}$/.test(siteID)) throw new Error('网站标识无效');
    const pair = certificates.pair(store.read().selectedID, certificateID);
    await request(connection, token, 'POST', `/v1/sites/${provider}/${siteID}/certificate`, { body: pair });
  });
  ipcMain.handle('certificates:issue', async (_event, input) => {
    if (certificateJob) throw new Error('另一个证书申请正在进行');
    certificateJob = true;
    try { return await certificates.issue(store.read().selectedID, input); }
    finally { certificateJob = false; }
  });
  ipcMain.handle('server:api', async (_event, action, payload) => {
    const { connection, token } = store.selected();
    // route() 的第 4 项可以带请求选项（例如装依赖要放宽超时）。
    const [method, endpoint, body, options] = route(action, payload);
    return (await request(connection, token, method, endpoint, { body, ...options })).data;
  });
  const registerUploads = (paths) => {
    if (!Array.isArray(paths) || !paths.length || paths.length > 100) throw new Error('一次最多上传 100 个文件或文件夹');
    const entries = paths.map((localPath) => {
      if (typeof localPath !== 'string' || !path.isAbsolute(localPath)) throw new Error('本地路径无效');
      const info = fs.lstatSync(localPath);
      if (!info.isFile() && !info.isDirectory()) throw new Error('无法上传符号链接或特殊文件');
      return { id: crypto.randomUUID(), name: path.basename(localPath), kind: info.isDirectory() ? 'directory' : 'file', localPath };
    });
    chosenUploads.clear();
    for (const entry of entries) chosenUploads.set(entry.id, entry.localPath);
    return entries.map(({ id, name, kind }) => ({ id, name, kind }));
  };
  ipcMain.handle('files:choose-upload', async (_event, kind) => {
    if (!['file', 'directory'].includes(kind)) throw new Error('上传类型无效');
    const result = await dialog.showOpenDialog(window, {
      properties: [kind === 'file' ? 'openFile' : 'openDirectory', 'multiSelections']
    });
    return result.canceled ? null : registerUploads(result.filePaths);
  });
  ipcMain.handle('files:register-drop', (_event, paths) => registerUploads(paths));
  ipcMain.handle('files:upload', async (event, { ids, remoteDir, overwrite }) => {
    if (!Array.isArray(ids) || !ids.length || ids.length > 100 || new Set(ids).size !== ids.length ||
        ids.some((id) => !chosenUploads.has(id))) throw new Error('请重新选择要上传的内容');
    const plan = planUpload(ids.map((id) => chosenUploads.get(id)));
    remotePath(remoteDir, plan.items[0].parts);
    const { connection, token } = store.selected();
    const listing = (await request(connection, token, 'GET', `/v1/files?${pathQuery(remoteDir)}`)).data;
    const conflicts = plan.roots.filter((name) => listing.entries.some((item) => item.name === name));
    if (conflicts.length && overwrite !== true) throw new Error(`服务器上已存在：${conflicts.join('、')}，请确认覆盖后重试`);
    const result = await uploadPlan(plan, remoteDir, overwrite === true, {
      mkdir: (destination) => request(connection, token, 'POST', '/v1/files', {
        body: { operation: 'mkdir', path: destination }
      }),
      directoryExists: async (destination) => {
        try {
          await request(connection, token, 'GET', `/v1/files?${pathQuery(destination)}`);
          return true;
        } catch (error) {
          if ([400, 404, 409].includes(error.status)) return false;
          throw error;
        }
      },
      uploadFile: (localPath, destination, allowOverwrite) => request(connection, token, 'PUT',
        `/v1/files/content?${pathQuery(destination)}&overwrite=${allowOverwrite}`, { input: localPath, timeout: 3600000 }),
      progress: (completed, total, name) => event.sender.send('files:upload-progress', { completed, total, name })
    });
    chosenUploads.clear();
    return result;
  });
  ipcMain.handle('files:download', async (_event, remotePath) => {
    const { connection, token } = store.selected();
    const name = path.posix.basename(remotePath);
    const result = await dialog.showSaveDialog(window, { defaultPath: name });
    if (result.canceled) return null;
    const temporary = `${result.filePath}.${crypto.randomUUID()}.tmp`;
    try {
      await request(connection, token, 'GET', `/v1/files/content?${pathQuery(remotePath)}`, {
        output: temporary, timeout: 3600000
      });
      fs.renameSync(temporary, result.filePath);
      return result.filePath;
    } finally {
      try { fs.unlinkSync(temporary); } catch { /* already renamed */ }
    }
  });
  ipcMain.handle('installer:export', async (_event, architecture) => {
    const source = installerBinary(architecture);
    if (!fs.existsSync(source)) throw new Error('安装文件尚未构建，请运行 npm run prepare:server');
    const result = await dialog.showSaveDialog(window, { defaultPath: `sera-linux-${architecture}` });
    if (result.canceled) return null;
    fs.copyFileSync(source, result.filePath);
    return result.filePath;
  });
  ipcMain.handle('installer:choose-key', async () => {
    const result = await dialog.showOpenDialog(window, { properties: ['openFile'] });
    if (result.canceled) return null;
    chosenSSHKeys.add(result.filePaths[0]);
    return result.filePaths[0];
  });
  const checkedInstallInput = (input) => {
    if (input?.privateKeyPath && !chosenSSHKeys.has(input.privateKeyPath))
      throw new Error('请通过文件选择窗口选择 SSH 私钥');
    return input;
  };
  ipcMain.handle('installer:probe', (_event, input) => sshInstaller.probe(checkedInstallInput(input)));
  ipcMain.handle('installer:ssh', (_event, input, fingerprint) => sshInstaller.install(checkedInstallInput(input), fingerprint));
  ipcMain.handle('clipboard:write', (_event, value) => {
    if (typeof value !== 'string' || value.length > 100000) throw new Error('无法复制此内容');
    clipboard.writeText(value);
    return true;
  });
  createWindow();
  app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
