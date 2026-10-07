const { _electron: electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs/promises');
const assert = require('node:assert/strict');
const AdmZip = require('adm-zip');
(async () => {
  const root = path.resolve(__dirname, '..', '.test-data', 'cursor-' + Date.now());
  const folder = path.join(root, 'original');
  await fs.mkdir(folder, { recursive: true });
  await fs.writeFile(path.join(folder, 'aegisub.exe'), 'fixture');
  const zipFile = path.join(root, 'aegisub.zip');
  const zip = new AdmZip(); zip.addFile('portable/aegisub.exe', Buffer.from('fixture')); zip.writeZip(zipFile);
  const app = await electron.launch({ args: [path.join(__dirname, '..')], env: { ...process.env, PCLAEG_TEST_ROOT: path.join(root, 'library') } });
  try {
    const page = await app.firstWindow();
    await page.locator('#instance-select').waitFor();
    await app.evaluate(({ dialog }, inputs) => {
      globalThis.pickerCalls = [];
      globalThis.cancelPicker = false;
      dialog.showOpenDialog = async (parent, options) => {
        const view = await parent.webContents.executeJavaScript('({ modal: document.querySelector("#modal").open, focusedInput: document.activeElement.tagName === "INPUT", nativeClass: document.documentElement.classList.contains("native-picker"), cursor: getComputedStyle(document.body).cursor })');
        if (view.modal || view.focusedInput || !view.nativeClass || view.cursor !== 'default') throw new Error('Native picker must open with neutral cursor and no name dialog');
        globalThis.pickerCalls.push(options);
        return globalThis.cancelPicker ? { canceled: true, filePaths: [] } : { canceled: false, filePaths: [options.properties.includes('openFile') ? inputs.zip : inputs.folder] };
      };
    }, { zip: zipFile, folder });
    await page.locator('nav button[data-page="versions"]').click();
    for (const [button, name] of [['安装本地 ZIP', 'ZIP instance'], ['导入本地', 'Folder instance']]) {
      await page.getByRole('button', { name: button, exact: true }).click();
      await page.locator('#modal[open]').waitFor();
      assert.equal(await page.evaluate(() => document.documentElement.classList.contains('native-picker')), false);
      const cursor = await page.locator('#modal-input').evaluate(async input => {
        const css = getComputedStyle(input), url = css.cursor.match(/url\("?([^"\)]+)"?\)/)[1];
        const image = new Image(); image.src = url; await image.decode();
        return { cursor: css.cursor, caret: css.caretColor, focused: document.activeElement === input, width: image.naturalWidth };
      });
      assert.match(cursor.cursor, /text-cursor\.svg/); assert.equal(cursor.caret, 'rgb(39, 53, 76)');
      assert.equal(cursor.focused, true); assert.equal(cursor.width, 32);
      await page.locator('#modal-input').fill(name);
      await page.locator('#modal-input').press('Enter');
      await page.locator('#task.hidden').waitFor({ state: 'attached' });
      await page.getByRole('heading', { name, exact: true }).waitFor();
    }
    await app.evaluate(() => { globalThis.cancelPicker = true; });
    await page.getByRole('button', { name: '安装本地 ZIP', exact: true }).click();
    await page.waitForFunction(() => !document.documentElement.classList.contains('native-picker'));
    assert.equal(await page.locator('#modal[open]').count(), 0);
    await app.evaluate(() => { globalThis.cancelPicker = false; });
    await page.getByRole('button', { name: '安装本地 ZIP', exact: true }).click();
    await page.locator('#modal[open]').waitFor();
    await page.locator('#modal-input').press('Escape');
    await page.locator('#modal:not([open])').waitFor({ state: 'attached' });
    const state = await page.evaluate(async () => (await window.launcher.command('state')).data);
    assert.equal(state.instances.length, 2);
    assert.equal(await page.locator('#toast.error').count(), 0);
    console.log('ZIP/folder picker precedes typing, resets cursor, restores input cursor, imports and cancels correctly.');
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
