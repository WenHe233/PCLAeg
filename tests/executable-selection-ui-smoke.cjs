const { _electron: electron } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const AdmZip = require('adm-zip');
const { Manager } = require('../src/core.cjs');

(async () => {
  const root = path.resolve(__dirname, '..', '.test-data', 'executable-ui-' + Date.now());
  const source = path.join(root, 'source'), library = path.join(root, 'library');
  await fs.mkdir(path.join(source, 'bin'), { recursive: true });
  await fs.writeFile(path.join(source, 'bin/custom-editor.exe'), 'fixture');
  const zip = new AdmZip(); zip.addFile('bin/custom-editor.exe', Buffer.from('fixture'));
  const zipFile = path.join(root, 'portable.zip'); zip.writeZip(zipFile);
  const manager = new Manager(library); await manager.init();
  await manager.create({ name: 'Existing', populate: dir => fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture') });
  const app = await electron.launch({ args: [path.join(__dirname, '..')], env: { ...process.env, PCLAEG_TEST_ROOT: library } });
  try {
    const page = await app.firstWindow();
    await page.locator('#instance-select').waitFor();
    await page.locator('nav button[data-page="versions"]').click();
    await app.evaluate(({ dialog }, inputs) => {
      globalThis.executablePickerCalls = [];
      globalThis.selectionMode = 'select';
      dialog.showOpenDialog = async (parent, options) => {
        const selectingExe = options.filters?.[0]?.extensions.includes('exe');
        if (!selectingExe) return { canceled: false, filePaths: [options.properties.includes('openDirectory') ? inputs.source : inputs.zipFile] };
        const view = await parent.webContents.executeJavaScript('({ modal: document.querySelector("#modal").open, nativePicker: document.documentElement.classList.contains("native-picker"), cursor: getComputedStyle(document.body).cursor })');
        if (view.modal || !view.nativePicker || view.cursor !== 'default') throw new Error('文件选择器的界面状态不正确');
        globalThis.executablePickerCalls.push(options);
        if (globalThis.selectionMode === 'cancel') return { canceled: true, filePaths: [] };
        const file = globalThis.selectionMode === 'outside' ? inputs.source + '/bin/custom-editor.exe'
          : options.defaultPath + (options.defaultPath.endsWith('bin') ? '/custom-editor.exe' : '/bin/custom-editor.exe');
        return { canceled: false, filePaths: [file] };
      };
    }, { source, zipFile });
    const state = () => page.evaluate(async () => (await window.launcher.command('state')).data);
    const waitForPicker = count => app.evaluate(async (_electron, expected) => {
      for (let attempt = 0; attempt < 300; attempt++) {
        if (globalThis.executablePickerCalls.length >= expected) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw new Error('等待文件选择器超时');
    }, count);
    const importVersion = async (button, name) => {
      const count = await app.evaluate(() => globalThis.executablePickerCalls.length);
      await page.getByRole('button', { name: button, exact: true }).click();
      await page.locator('#modal[open]').waitFor();
      await page.locator('#modal-input').fill(name);
      await page.locator('#modal-input').press('Enter');
      await waitForPicker(count + 1);
      await page.locator('#task.hidden').waitFor({ state: 'attached' });
    };
    for (const [button, name] of [['安装本地 ZIP', 'ZIP manual'], ['导入本地', 'Folder manual']]) {
      await importVersion(button, name);
      await page.getByRole('heading', { name: new RegExp('^' + name), level: 3 }).waitFor();
      const current = await state(); assert.equal(current.instances.find(v => v.name === name).exe, path.join('bin', 'custom-editor.exe'));
      assert.equal(await page.evaluate(() => document.documentElement.classList.contains('native-picker')), false);
    }
    const before = await state();
    await app.evaluate(() => { globalThis.selectionMode = 'cancel'; });
    await importVersion('安装本地 ZIP', 'Cancelled');
    const cancelled = await state();
    assert.equal(cancelled.selected, before.selected); assert.deepEqual(cancelled.instances, before.instances);
    assert.equal(await page.locator('#toast.error').count(), 0);
    assert.deepEqual(await fs.readdir(path.join(library, 'versions')), ['Existing', 'Folder manual', 'ZIP manual']);
    await app.evaluate(() => { globalThis.selectionMode = 'outside'; });
    await importVersion('导入本地', 'Invalid');
    await page.locator('#toast.error').waitFor(); assert.match(await page.locator('#toast').innerText(), /管理目录内/);
    assert.deepEqual((await state()).instances, before.instances);
    assert.deepEqual(await fs.readdir(path.join(library, 'versions')), ['Existing', 'Folder manual', 'ZIP manual']);
    await app.evaluate(() => { globalThis.selectionMode = 'select'; });
    const row = page.locator('.version-row').filter({ has: page.getByRole('heading', { name: /^Folder manual/ }) });
    await row.getByRole('button', { name: '启动文件', exact: true }).click();
    await waitForPicker(5);
    await page.locator('#task.hidden').waitFor({ state: 'attached' });
    const calls = await app.evaluate(() => globalThis.executablePickerCalls);
    assert.equal(calls.length, 5);
    assert.ok(calls.slice(0, 4).every(call => path.dirname(call.defaultPath) === path.join(library, 'versions')));
    assert.equal(calls.at(-1).defaultPath, path.join(library, 'versions/Folder manual/bin'));
    assert.ok(calls.every(call => call.properties.length === 1 && call.properties[0] === 'openFile' && call.filters[0].extensions[0] === 'exe'));
    assert.deepEqual(await fs.readdir(path.join(library, 'cache/downloads')), []);
    console.log('手动选择的 ZIP / 目录导入、取消、路径校验、启动文件切换及原生选择器状态验证通过。');
  } finally { await app.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
