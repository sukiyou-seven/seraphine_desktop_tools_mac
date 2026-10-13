const { contextBridge, ipcRenderer, webUtils } = require('electron');

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
  deployCertificate: (certificateID, provider, siteID) => ipcRenderer.invoke('certificates:deploy', certificateID, provider, siteID),
  issueCertificate: (input) => ipcRenderer.invoke('certificates:issue', input),
  chooseUpload: (kind) => ipcRenderer.invoke('files:choose-upload', kind),
  registerDropped: (files) => ipcRenderer.invoke('files:register-drop', Array.from(files, (file) => webUtils.getPathForFile(file)).filter(Boolean)),
  upload: (ids, remoteDir, overwrite) => ipcRenderer.invoke('files:upload', { ids, remoteDir, overwrite }),
  onUploadProgress: (callback) => {
    const listener = (_event, progress) => callback(progress);
    ipcRenderer.on('files:upload-progress', listener);
    return () => ipcRenderer.removeListener('files:upload-progress', listener);
  },
  download: (remotePath) => ipcRenderer.invoke('files:download', remotePath),
  exportInstaller: (architecture) => ipcRenderer.invoke('installer:export', architecture),
  chooseSSHKey: () => ipcRenderer.invoke('installer:choose-key'),
  probeSSH: (input) => ipcRenderer.invoke('installer:probe', input),
  installSSH: (input, fingerprint) => ipcRenderer.invoke('installer:ssh', input, fingerprint),
  clipboardWrite: (value) => ipcRenderer.invoke('clipboard:write', value),
  platform: process.platform
}));
