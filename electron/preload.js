const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('sera', Object.freeze({
  connections: () => ipcRenderer.invoke('connections:list'),
  saveConnection: (entry) => ipcRenderer.invoke('connections:save', entry),
  deleteConnection: (id) => ipcRenderer.invoke('connections:delete', id),
  selectConnection: (id) => ipcRenderer.invoke('connections:select', id),
  api: (action, payload = {}) => ipcRenderer.invoke('server:api', action, payload),
  dnsSettings: () => ipcRenderer.invoke('dns:settings'),
  saveDNS: (settings) => ipcRenderer.invoke('dns:save', settings),
  dnsCall: (action, params = {}) => ipcRenderer.invoke('dns:call', action, params),
  certificates: () => ipcRenderer.invoke('certificates:list'),
  issueCertificate: (input) => ipcRenderer.invoke('certificates:issue', input),
  chooseUpload: () => ipcRenderer.invoke('files:choose-upload'),
  upload: (localPath, remotePath, overwrite) => ipcRenderer.invoke('files:upload', { localPath, remotePath, overwrite }),
  download: (remotePath) => ipcRenderer.invoke('files:download', remotePath),
  exportInstaller: (architecture) => ipcRenderer.invoke('installer:export', architecture),
  chooseSSHKey: () => ipcRenderer.invoke('installer:choose-key'),
  probeSSH: (input) => ipcRenderer.invoke('installer:probe', input),
  installSSH: (input, fingerprint) => ipcRenderer.invoke('installer:ssh', input, fingerprint),
  clipboardWrite: (value) => ipcRenderer.invoke('clipboard:write', value),
  platform: process.platform
}));
