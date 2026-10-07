const { app, net } = require('electron');
const { Manager } = require('../src/core.cjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
app.whenReady().then(async () => {
  const manager = new Manager(path.join(__dirname, '..', '.test-data', `depctrl-real-${Date.now()}`), () => {}, net.fetch.bind(net));
  try {
    await manager.init();
    await manager.importVersion(path.join(__dirname, '..', '.test-data/branch-fix/migration05-01.zip'), 'Migration feed test');
    const feedUrl = 'https://raw.githubusercontent.com/TypesettingTools/arch1t3cht-Aegisub-Scripts/main/DependencyControl.json';
    await manager.addPluginFeed(feedUrl);
    const entry = manager.catalog().find(p => p.namespace === 'arch.FocusLines'); assert.ok(entry);
    await manager.addPlugin(manager.state.selected, { catalogId: entry.id });
    const v = manager.instance(manager.state.selected), root = path.dirname(manager.appDir(v));
    await manager.launch(v.id);
    await new Promise(resolve => setTimeout(resolve, 10000));
    assert.ok(manager.running.has(v.id), 'Aegisub exited early');
    const config = JSON.parse(await fs.readFile(path.join(root, 'config/l0.DependencyControl.json')));
    assert.equal(config.macros['arch.FocusLines'].namespace, 'arch.FocusLines');
    assert.equal(config.macros['arch.FocusLines'].userFeed, feedUrl);
    console.log('Real DependencyControl feed, SHA-1 verification, macro installation and Aegisub registration passed.');
    console.log('Root:', root);
  } catch (e) { console.error(e); process.exitCode = 1; }
  finally { for (const child of manager.running.values()) child.kill(); app.exit(process.exitCode || 0); }
});
