const { _electron: electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs/promises');
const assert = require('node:assert/strict');
const { Manager, findExecutables } = require('../src/core.cjs');
(async () => {
  if (!process.env.PCLAEG_IMPORT_SOURCE) throw new Error('Set PCLAEG_IMPORT_SOURCE to the directory containing both Aegisub executables');
  const source = process.env.PCLAEG_IMPORT_SOURCE;
  const root = path.join(__dirname, '..', '.test-data', 'version-selection-' + Date.now());
  const candidates = await findExecutables(source, 0, 0);
  assert.equal(candidates.find(c => path.basename(c.path) === 'aegisub9820.exe').version.startsWith('9820'), true);
  const manager = new Manager(root); await manager.init();
  manager.chooseExecutable = async choices => choices.find(c => c.version.startsWith('9820')).path;
  await manager.create({ name: '9820 版本选择验证', populate: async dest => {
    for (const candidate of candidates) await fs.copyFile(candidate.path, path.join(dest, path.basename(candidate.path)));
  } });
  assert.equal(manager.instance(manager.state.selected).exe, 'aegisub9820.exe');
  assert.match(manager.instance(manager.state.selected).version, /^9820/);
  const app = await electron.launch({ args: [path.join(__dirname, '..')], env: { ...process.env, PCLAEG_TEST_ROOT: root } });
  try {
    const page = await app.firstWindow();
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    await page.locator('nav button[data-page="versions"]').click();
    assert.match(await page.locator('.version-info').innerText(), /9820-cibuilds.*aegisub9820\.exe/s);
    await app.evaluate(({ dialog }) => {
      globalThis.versionChoices = [];
      dialog.showMessageBox = async (_parent, options) => {
        globalThis.versionChoices.push(options.buttons);
        const target = globalThis.versionChoices.length === 1 ? '9706' : '9820';
        return { response: options.buttons.findIndex(label => label.includes(target)), checkboxChecked: false };
      };
    });
    await page.getByRole('button', { name: '启动文件', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('.version-info').textContent.includes('9706-cibuilds'));
    await page.getByRole('button', { name: '启动文件', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('.version-info').textContent.includes('9820-cibuilds'));
    const choices = await app.evaluate(() => globalThis.versionChoices);
    assert.equal(choices.length, 2);
    assert.equal(choices.every(c => c.some(label => label.includes('9706')) && c.some(label => label.includes('9820'))), true);
    const state = await page.evaluate(async () => (await window.launcher.command('state')).data);
    assert.equal(state.instances[0].exe, 'aegisub9820.exe');
    assert.match(state.instances[0].version, /^9820/);
    console.log('Actual 9706/9820 metadata, selection UI, switching and persisted launch path passed.');
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
