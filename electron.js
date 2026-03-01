const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const os = require('node:os');
const pty = require('node-pty');

let mainWindow;
let ptyProcess;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
        }
    });

    const isDev = !app.isPackaged;
    if (isDev) {
        mainWindow.loadURL('http://localhost:5173');
        mainWindow.webContents.openDevTools();
    } else {
        mainWindow.loadFile(path.join(__dirname, 'dist/index.html'));
    }

    // Initialize PTY
    const shell = process.env[os.platform() === 'win32' ? 'COMSPEC' : 'SHELL'] || (os.platform() === 'win32' ? 'cmd.exe' : 'bash');

    ptyProcess = pty.spawn(shell, [], {
        name: 'xterm-256color',
        cols: 80,
        rows: 24,
        cwd: process.env.HOME,
        env: process.env
    });

    ptyProcess.onData((data) => {
        mainWindow.webContents.send('terminal.incomingData', data);
    });

    ipcMain.on('terminal.keystroke', (event, key) => {
        ptyProcess.write(key);
    });

    ipcMain.on('terminal.resize', (event, { cols, rows }) => {
        try {
            ptyProcess.resize(cols, rows);
        } catch (e) {
            console.error('Resize error:', e);
        }
    });
}

app.whenReady().then(() => {
    createWindow();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
});
