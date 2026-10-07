const { _electron: electron } = require('playwright');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const execFileAsync = require('node:util').promisify(execFile);
(async () => {
  const root = path.resolve(__dirname, '..', 'dist', 'AegisubLauncher');
  const app = await electron.launch({ executablePath: path.join(root, 'Aegisub Launcher.exe'), args: [] });
  try {
    const page = await app.firstWindow();
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    const paths = await app.evaluate(({ app }) => ({ userData: app.getPath('userData'), sessionData: app.getPath('sessionData'), temp: app.getPath('temp'), crashDumps: app.getPath('crashDumps'), version: app.getVersion() }));
    assert.equal(paths.version, '0.1.3');
    for (const [name, target] of Object.entries(paths)) if (name !== 'version') assert.equal(path.relative(path.join(root, 'cache'), target).startsWith('..'), false);
    const state = await page.evaluate(async () => (await window.launcher.command('state')).data);
    assert.equal(state.root, root);
    assert.equal(state.instances.length, 2);
    assert.equal(state.instances.find(v => v.id === state.selected).version.startsWith('9820'), true);
    assert.deepEqual(state.instances.map(v => v.folder).sort(), ['9706', '9820']);
    await page.locator('nav button[data-page="versions"]').click();
    await page.getByRole('button', { name: '打开版本文件夹', exact: true }).waitFor();
    await page.locator('nav button[data-page="settings"]').click();
    assert.match(await page.locator('#content').innerText(), /版本文件夹.*versions.*缓存文件夹.*cache/s);
    const selected = state.instances.find(v => v.id === state.selected);
    const launched = await page.evaluate(id => window.launcher.command('launch', { id }), selected.id);
    assert.equal(launched.ok, true, launched.error);
    const executable = path.join(root, 'versions', selected.folder, selected.exe);
    const { stdout } = await execFileAsync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_Process -Filter "Name = \'aegisub9820.exe\'" | Where-Object { $_.ExecutablePath -eq $env:PCLAEG_LAUNCH_PATH } | Select-Object -ExpandProperty ProcessId'], { env: { ...process.env, PCLAEG_LAUNCH_PATH: executable }, windowsHide: true });
    const pid = Number(stdout.trim());
    assert.equal(Number.isInteger(pid) && pid > 0, true);
    try {
      await page.waitForTimeout(5000);
      const live = await page.evaluate(async () => (await window.launcher.command('state')).data);
      assert.equal(live.running.includes(selected.id), true);
    } finally { process.kill(pid); }
    console.log('Deployed version folders, cache paths, default 9820 selection and actual 9820 launch passed.');
    console.log(paths);
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
