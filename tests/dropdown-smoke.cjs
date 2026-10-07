const { _electron: electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs/promises');
const assert = require('node:assert/strict');
const { Manager } = require('../src/core.cjs');
(async () => {
  const root = path.resolve(__dirname, '..', '.test-data', 'dropdown-' + Date.now());
  const manager = new Manager(root); await manager.init();
  await manager.create({ name: '9706', version: '9706', populate: dest => fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture') });
  const id9706 = manager.state.selected;
  await manager.create({ name: '9820', version: '9820', populate: dest => fs.writeFile(path.join(dest, 'aegisub9820.exe'), 'fixture') });
  const id9820 = manager.state.selected;
  const app = await electron.launch({ args: [path.resolve(__dirname, '..')], env: { ...process.env, PCLAEG_TEST_ROOT: root } });
  try {
    const page = await app.firstWindow();
    await page.locator('#side-name').filter({ hasText: '9820' }).waitFor();
    for (const [id, name] of [[id9706, '9706'], [id9820, '9820'], [id9706, '9706']]) {
      await page.locator('#instance-select').selectOption(id);
      await page.waitForFunction(name => document.querySelector('#side-name').textContent === name && !document.querySelector('#instance-select').disabled, name, { timeout: 2000 });
      const state = await page.evaluate(async () => (await window.launcher.command('state')).data);
      assert.equal(state.selected, id); assert.equal(await page.locator('#instance-select').inputValue(), id);
      const persisted = JSON.parse(await fs.readFile(path.join(root, 'state.json')));
      assert.equal(persisted.selected, id);
    }
    const restored = new Manager(root); await restored.init();
    assert.equal(restored.state.selected, id9706);
    assert.equal(path.basename(restored.appDir(restored.instance(id9706))), 'aegisub.exe');
    assert.equal(path.basename(restored.appDir(restored.instance(id9820))), 'aegisub9820.exe');
    console.log('Dropdown switches both ways, updates launch target and persists selection.');
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
