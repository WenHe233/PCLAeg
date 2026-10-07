const { _electron: electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs/promises');
const assert = require('node:assert/strict');
const { Manager } = require('../src/core.cjs');
(async () => {
  if (process.env.PCLAEG_UI_SEED === '1') {
    const library = new Manager(path.join(__dirname, '..', '.test-data', 'ui-library')); await library.init();
    if (!library.state.instances.length) {
      const seed = new Manager(path.join(__dirname, '..', '.test-data', 'network-library')); await seed.init();
      const v = seed.instance(seed.state.selected);
      await library.create({ name: '日常字幕 · 官方版', version: v.version, source: v.source, plugins: v.plugins, populate: dest => fs.cp(seed.dir(v), dest, { recursive: true }) });
    }
  }
  const app = await electron.launch({ args: [path.join(__dirname, '..')], env: { ...process.env, PCLAEG_TEST_ROOT: path.join(__dirname, '..', '.test-data', 'ui-library') } });
  try {
    const page = await app.firstWindow();
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    page.on('console', msg => console.log('Renderer:', msg.text()));
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    await fs.mkdir(path.join(__dirname, '..', 'dist', 'screenshots'), { recursive: true });
    await page.screenshot({ path: path.join(__dirname, '..', 'dist', 'screenshots', 'home.png') });
    await page.locator('nav button[data-page="versions"]').click();
    await page.getByRole('heading', { name: '版本管理', exact: true }).waitFor();
    await page.getByRole('button', { name: '导入本地', exact: true }).click();
    await page.locator('dialog[open]').waitFor();
    await page.locator('#modal-input').fill('字幕练习');
    await page.locator('#modal-cancel').click();
    await page.locator('nav button[data-page="downloads"]').click();
    await page.locator('.version-row').first().waitFor({ timeout: 45000 });
    const version = await page.locator('.version-info h3').first().innerText();
    console.log('Live releases loaded:', version);
    await page.screenshot({ path: path.join(__dirname, '..', 'dist', 'screenshots', 'downloads.png') });
    if (process.env.PCLAEG_NETWORK_INSTALL === '1') {
      const existing = await page.evaluate(async () => (await window.launcher.command('state')).data.instances.length);
      if (!existing) {
      await page.getByRole('button', { name: '下载并安装', exact: true }).first().click();
      await page.locator('#modal-input').fill('日常字幕 · 官方版');
      await page.locator('#modal-form button[type="submit"]').click();
      console.log('Install submitted');
      await page.waitForTimeout(1000);
      console.log('Task status', await page.locator('#task').getAttribute('class'), 'Toast', await page.locator('#toast').textContent());
      await page.locator('#task.hidden').waitFor({ state: 'attached', timeout: 300000 });
      assert.equal(await page.locator('#side-name').textContent(), '日常字幕 · 官方版', await page.locator('#toast').textContent());
      }
      await page.locator('nav button[data-page="plugins"]').click();
      const alreadyInstalled = await page.evaluate(async () => (await window.launcher.command('state')).data.instances[0].plugins.length);
      if (!alreadyInstalled) {
      await page.getByRole('button', { name: '安装到此实例' }).first().click();
      await page.locator('#task.hidden').waitFor({ state: 'attached', timeout: 60000 });
      }
      await page.getByRole('button', { name: /已安装 · 1/ }).click();
      await page.getByRole('button', { name: '禁用', exact: true }).click();
      await page.getByRole('button', { name: '启用', exact: true }).waitFor();
      await page.getByRole('button', { name: '启用', exact: true }).click();
      await page.getByRole('button', { name: '禁用', exact: true }).waitFor();
      await page.locator('[data-action="plugin-tab"][data-tab="browse"]').click();
      await page.locator('#plugin-search').fill('Blur');
      assert.equal(await page.locator('.plugin-card').count(), 1);
      await page.locator('#plugin-search').fill('');
      await page.screenshot({ path: path.join(__dirname, '..', 'dist', 'screenshots', 'plugins.png') });
      await page.locator('nav button[data-page="home"]').click();
      await page.screenshot({ path: path.join(__dirname, '..', 'dist', 'screenshots', 'home.png') });
      console.log('Real Aegisub instance; plugin disabled, re-enabled; search passed.');
    }
    await page.locator('nav button[data-page="settings"]').click();
    await page.getByRole('heading', { name: '设置', exact: true }).waitFor();
    assert.deepEqual(errors, []);
    console.log('UI smoke passed; no renderer errors.');
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
