const { _electron: electron } = require('playwright');
const path = require('node:path');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
(async () => {
  const root = path.join(__dirname, '..', '.test-data', `package-clean-${Date.now()}`);
  const configFile = path.join(__dirname, '..', 'dist/win-unpacked/launcher-paths.json');
  const { Manager } = require('../src/core.cjs');
  const manager = new Manager(root); await manager.init();
  assert.equal(manager.catalog().length, 64);
  await manager.create({ name: 'Clean target', populate: dest => fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture') });
  let originalConfig; try { originalConfig = await fs.readFile(configFile); } catch {}
  await fs.writeFile(configFile, JSON.stringify({ dataRoot: root }));
  const app = await electron.launch({ executablePath: path.join(__dirname, '..', 'dist', 'win-unpacked', 'Aegisub Launcher.exe'), args: [], env: { ...process.env, PCLAEG_TEST_ROOT: root } });
  try {
    const page = await app.firstWindow();
    await page.getByRole('heading', { name: '开始新的创作' }).waitFor();
    const info = await app.evaluate(({ app }) => ({ packaged: app.isPackaged, version: app.getVersion(), name: app.getName() }));
    assert.equal(info.packaged, true); assert.equal(info.version, require('../package.json').version);
    const result = await page.evaluate(() => window.launcher.command('state'));
    assert.equal(result.ok, true); assert.equal(result.data.instances.length, 1); assert.equal(result.data.catalog.length, 64);
    const bundled = result.data.catalog.filter(p => p.bundled);
    assert.equal(bundled.length, 42);
    const entry = bundled.find(p => p.file === 'a-mo.Aegisub-Motion.moon');
    const pluginInstall = await page.evaluate(args => window.launcher.command('pluginInstall', args), { id: result.data.selected, catalogId: entry.id });
    assert.equal(pluginInstall.ok, true, pluginInstall.error);
    const v = pluginInstall.data.instances[0];
    const plugin = v.plugins.find(p => p.file === entry.file);
    const appRoot = path.dirname(path.join(root, 'versions', v.folder, v.exe));
    assert.ok((await fs.readFile(path.join(appRoot, plugin.relativePath || path.join('automation/launcher/autoload', plugin.file)), 'utf8')).includes('script_name'));
    assert.ok((await fs.readFile(path.join(appRoot, 'automation/include/a-mo/TrimHandler.moon'), 'utf8')).includes("'#{(.-)}'"));
    await page.locator('nav button[data-page="settings"]').click();
    await page.getByRole('heading', { name: '设置', exact: true }).waitFor();
    console.log('Clean packaged desktop: 64 catalog entries, bundled script/dependency installation and settings passed:', info);
  } finally { await app.close(); if (originalConfig) await fs.writeFile(configFile, originalConfig); else await fs.rm(configFile, { force: true }); }
})().catch(e => { console.error(e); process.exitCode = 1; });
