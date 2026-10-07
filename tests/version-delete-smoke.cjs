const { _electron: electron } = require('playwright');
const { Manager } = require('../src/core.cjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const root = path.join(__dirname, '..', '.test-data', `version-delete-${Date.now()}`);
  const manager = new Manager(root); await manager.init();
  for (const name of ['Feature', 'Migration']) await manager.create({ name, populate: dest => fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture') });
  const first = manager.state.instances[0], selected = manager.state.selected;
  const launchOptions = process.env.PCLAEG_PACKAGED_EXE
    ? { executablePath: process.env.PCLAEG_PACKAGED_EXE, args: [] }
    : { args: [path.join(__dirname, '..')] };
  const configFile = process.env.PCLAEG_PACKAGED_EXE ? path.join(path.dirname(process.env.PCLAEG_PACKAGED_EXE), 'launcher-paths.json') : null;
  let originalConfig;
  if (configFile) { try { originalConfig = await fs.readFile(configFile); } catch {} await fs.writeFile(configFile, JSON.stringify({ dataRoot: root })); }
  const desktop = await electron.launch({ ...launchOptions, env: { ...process.env, PCLAEG_TEST_ROOT: root } });
  try {
    const page = await desktop.firstWindow(); const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    assert.equal(await page.getByRole('button', { name: '删除版本', exact: true }).count(), 2);
    await page.locator('nav button[data-page="versions"]').click();
    const target = page.locator(`[data-action="remove"][data-id="${selected}"]`);
    await target.waitFor();
    const box = await target.boundingBox(); assert.ok(box && box.x + box.width <= 1240);
    await desktop.evaluate(({ dialog }) => { dialog.showMessageBox = async () => ({ response: 0 }); });
    await target.click(); await page.locator('#task.hidden').waitFor({ state: 'attached' });
    assert.equal((await page.evaluate(async () => (await window.launcher.command('state')).data)).instances.length, 2);
    await desktop.evaluate(({ dialog }) => {
      dialog.showMessageBox = async (_win, options) => {
        if (!options.message.includes('删除版本') || options.buttons[1] !== '删除版本' || !options.detail.includes('无法恢复')) throw new Error('Incorrect confirmation');
        return { response: 1 };
      };
    });
    await target.click(); await page.locator('#task.hidden').waitFor({ state: 'attached' });
    const state = await page.evaluate(async () => (await window.launcher.command('state')).data);
    assert.equal(state.instances.length, 1); assert.equal(state.selected, first.id);
    assert.equal(await page.getByRole('button', { name: '删除版本', exact: true }).count(), 1);
    await assert.rejects(fs.access(path.join(root, 'versions', 'Migration')), { code: 'ENOENT' });
    await assert.rejects(fs.access(path.join(root, 'trash')), { code: 'ENOENT' });
    await page.locator('[data-action="remove"]').click(); await page.locator('#task.hidden').waitFor({ state: 'attached' });
    assert.equal((await page.evaluate(async () => (await window.launcher.command('state')).data)).selected, null);
    await page.getByRole('heading', { name: '还没有安装版本' }).waitFor();
    assert.deepEqual(errors, []);
    console.log('Delete button visibility, cancel, confirmation, selection fallback and empty state passed.');
  } finally { await desktop.close(); if (configFile) { if (originalConfig) await fs.writeFile(configFile, originalConfig); else await fs.rm(configFile, { force: true }); } }
})().catch(e => { console.error(e); process.exitCode = 1; });
