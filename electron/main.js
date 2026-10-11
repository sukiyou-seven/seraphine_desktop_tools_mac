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

let store;
let dns;
let certificates;
let sshInstaller;
let certificateJob = false;
let window;
const chosenUploads = new Set();
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
  ipcMain.handle('certificates:issue', async (_event, input) => {
    if (certificateJob) throw new Error('另一个证书申请正在进行');
    certificateJob = true;
    try { return await certificates.issue(store.read().selectedID, input); }
    finally { certificateJob = false; }
  });
  ipcMain.handle('server:api', async (_event, action, payload) => {
    const { connection, token } = store.selected();
    const [method, endpoint, body] = route(action, payload);
    return (await request(connection, token, method, endpoint, { body })).data;
  });
  ipcMain.handle('files:choose-upload', async () => {
    const result = await dialog.showOpenDialog(window, { properties: ['openFile'] });
    if (result.canceled) return null;
    const selected = result.filePaths[0];
    chosenUploads.add(selected);
    return { path: selected, name: path.basename(selected), size: fs.statSync(selected).size };
  });
  ipcMain.handle('files:upload', async (_event, { localPath, remotePath, overwrite }) => {
    if (!chosenUploads.has(localPath)) throw new Error('请先通过文件选择窗口选择本地文件');
    if (typeof remotePath !== 'string' || !remotePath.startsWith('/')) throw new Error('服务器路径无效');
    const { connection, token } = store.selected();
    const query = `${pathQuery(remotePath)}&overwrite=${overwrite === true}`;
    await request(connection, token, 'PUT', `/v1/files/content?${query}`, { input: localPath, timeout: 3600000 });
    return true;
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
