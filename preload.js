const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
    onTerminalData: (callback) => ipcRenderer.on('terminal.incomingData', (_event, data) => callback(data)),
    sendKeystroke: (key) => ipcRenderer.send('terminal.keystroke', key),
    resizeTerminal: (cols, rows) => ipcRenderer.send('terminal.resize', { cols, rows }),
});
