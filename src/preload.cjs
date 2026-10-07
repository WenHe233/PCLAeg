const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('launcher', {
  command: (name, args) => ipcRenderer.invoke('command', name, args),
  onProgress: cb => ipcRenderer.on('progress', (_, event) => cb(event))
});
