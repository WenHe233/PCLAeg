const { _electron: electron } = require('playwright');
const { Manager } = require('../src/core.cjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
async function waitState(page, predicate, timeout = 45000) {
 const end=Date.now()+timeout;
 while(Date.now()<end){const state=await page.evaluate(async()=> (await window.launcher.command('state')).data);if(predicate(state))return state;await page.waitForTimeout(100);}
 throw new Error('State did not reach expected result');
}
(async () => {
  const root = path.join(__dirname, '..', '.test-data', `upgrade-ui-${Date.now()}`);
  const library = new Manager(root); await library.init();
  await library.create({ name: 'Source', populate: async dir => {
    await fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture');
    await fs.mkdir(path.join(dir, 'automation/autoload'), { recursive: true });
    await fs.mkdir(path.join(dir, 'automation/include/test'), { recursive: true });
    await fs.writeFile(path.join(dir, 'automation/autoload/consumer.lua'), 'script_name="Consumer"\nscript_namespace="test.Consumer"\nlocal x = require "test.Module"');
    await fs.writeFile(path.join(dir, 'automation/include/test/Module.lua'), 'local version="1.2.0"\nreturn {}');
  } });
  const source = library.instance(library.state.selected);
  source.plugins.find(p => p.kind === 'autoload').requiredModules = [{ moduleName: 'test.Module', version: '^1.0.0' }];
  const sourceConfig = path.join(path.dirname(library.appDir(source)), 'config.json');
  const cfg = JSON.parse(await fs.readFile(sourceConfig)); cfg.App.Language = 'ja_JP'; await fs.writeFile(sourceConfig, JSON.stringify(cfg));
  await library.create({ name: 'Target', populate: async dir => {
    await fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture'); await fs.mkdir(path.join(dir, 'automation/autoload'), { recursive: true });
    await fs.writeFile(path.join(dir, 'automation/autoload/old.lua'), 'script_name="Old plugin"');
  } });
  const target = library.instance(library.state.selected); await library.save();
  const external = path.join(__dirname, '..', '.test-data', `external-ui-${Date.now()}`); await fs.mkdir(external); await fs.writeFile(path.join(external, 'aegisub9820.exe'), 'detected fixture');
  const configFile = path.join(__dirname, '..', 'dist/win-unpacked/launcher-paths.json');
  let previous; try { previous = await fs.readFile(configFile); } catch {}
  await fs.writeFile(configFile, JSON.stringify({ dataRoot: root }));
  const app = await electron.launch({ executablePath: path.join(__dirname, '..', 'dist/win-unpacked/Aegisub Launcher.exe'), args: [], env: { ...process.env, PCLAEG_TEST_ROOT: root } });
  try {
    const page = await app.firstWindow(), errors = []; page.on('pageerror', e => errors.push(e.message));
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    await page.locator('nav button[data-page="settings"]').click();
    await page.getByRole('button', { name: '深色', exact: true }).click();
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
    await page.locator('#ass-instance').selectOption(source.id);
    await waitState(page,s=>s.preferences.defaultAss===source.id);
    await fs.mkdir(path.join(__dirname, '..', 'dist/screenshots'), { recursive: true });
    await page.screenshot({ path: path.join(__dirname, '..', 'dist/screenshots/settings-dark-0.2.0.png') });
    await page.getByRole('button', { name: '跨实例同步', exact: true }).click();
    await page.locator('#sync-source').selectOption(source.id);
    await page.locator(`[data-field="targetIds"][value="${target.id}"]`).check();
    await page.getByRole('button', { name: '查看预览', exact: true }).click();
    await page.getByRole('heading', { name: '同步预览', exact: true }).waitFor();
    await page.getByRole('button', { name: '备份并同步', exact: true }).click();
    await waitState(page,s=>s.restorePoints.some(p=>p.status==='ready'&&p.records.some(r=>r.instanceId===target.id))&&s.instances.find(v=>v.id===target.id).plugins.some(p=>p.name==='Consumer'));
    await page.locator('#task.hidden').waitFor({ state: 'attached' });
    assert.equal(JSON.parse(await fs.readFile(path.join(root, 'versions/Target/config.json'))).App.Language, 'ja_JP');
    await app.evaluate(({ dialog }) => { dialog.showMessageBox = async () => ({ response: 1 }); });
    await page.getByRole('button', { name: '回滚', exact: true }).first().click();
    await waitState(page,s=>s.instances.find(v=>v.id===target.id).plugins.some(p=>p.name==='Old plugin'));
    assert.equal(JSON.parse(await fs.readFile(path.join(root, 'versions/Target/config.json'))).App.Language, 'zh_CN');
    await page.locator('#instance-select').selectOption(source.id);
    await page.locator('nav button[data-page="plugins"]').click();
    await page.getByRole('button', { name: '依赖关系', exact: true }).click();
    await page.locator('#dependency-owner').waitFor();
    await page.locator('#dependency-owner').selectOption(source.plugins.find(p => p.kind === 'autoload').id);
    await page.locator('.dependency-diagram svg').waitFor();
    assert.match(await page.locator('.dependency-table').innerText(), /test.Module.*1.2.0.*已满足/s);
    await page.screenshot({ path: path.join(__dirname, '..', 'dist/screenshots/dependencies-dark-0.2.0.png') });
    await page.locator('nav button[data-page="versions"]').click();
    await app.evaluate(({ dialog }, folder) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [folder] }); }, external);
    await page.getByRole('button', { name: '扫描指定目录', exact: true }).click();
    await page.getByRole('button', { name: '导入此版本', exact: true }).waitFor();
    await page.getByRole('button', { name: '导入此版本', exact: true }).click();
    await page.locator('dialog[open]').waitFor(); await page.locator('#modal-input').fill('Detected');
    await page.locator('#modal-form button[type="submit"]').click();
    await waitState(page,s=>s.instances.length===3);
    await page.locator('#task.hidden').waitFor({state:'attached'});
    await page.locator('nav button[data-page="downloads"]').click();
    await page.getByRole('button', { name: '添加下载分支', exact: true }).click();
    await page.locator('#modal-input').fill('https://github.com/ArrowChrono/Aegisub/releases');
    await page.locator('#modal-form button[type="submit"]').click();
    await waitState(page,s=>Object.values(s.releaseSources||{}).some(r=>r.repo.toLowerCase()==='arrowchrono/aegisub'));
    await page.locator('#task.hidden').waitFor({state:'attached',timeout:45000});
    assert.deepEqual(errors, []);
    console.log('Packaged 0.2.0 UI: dark mode, ASS instance selection, sync preview/apply/rollback, dependency graph, local discovery/import and custom Releases source passed.');
  } finally { await app.close(); if (previous) await fs.writeFile(configFile, previous); else await fs.rm(configFile, { force: true }); }
})().catch(e => { console.error(e); process.exitCode = 1; });
