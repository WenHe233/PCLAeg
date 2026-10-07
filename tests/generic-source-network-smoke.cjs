const { app, net } = require('electron');
const { Manager } = require('../src/core.cjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
app.whenReady().then(async () => {
  try {
    const manager = new Manager(path.join(__dirname, '..', '.test-data', `generic-network-${Date.now()}`), () => {}, net.fetch.bind(net));
    await manager.init();
    await manager.create({ name: 'Source test', populate: dir => fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture') });
    await manager.addPluginFeed('https://github.com/TypesettingTools/unanimated-Aegisub-Scripts', 'github');
    const feed = manager.state.pluginFeeds[0]; assert.equal(feed.type, 'github'); assert.ok(feed.packages.length > 10);
    const p = feed.packages.find(p => p.file === 'ua.ChangeCase.lua'); assert.ok(p);
    await manager.addPlugin(manager.state.selected, { catalogId: p.id });
    const v = manager.instance(manager.state.selected); assert.ok(v.plugins.find(x => x.sourcePlugin && x.file === p.file));
    await manager.addPluginFeed('https://github.com/TypesettingTools/unanimated-Aegisub-Scripts/blob/master/ua.ChangeCase.lua');
    assert.equal(manager.state.pluginFeeds[1].type, 'script');
    await manager.addPluginFeed('https://github.com/TypesettingTools/arch1t3cht-Aegisub-Scripts');
    assert.equal(manager.state.pluginFeeds[2].type, 'depctrl');
    assert.ok(manager.state.pluginFeeds[2].packages.some(p => p.namespace === 'arch.FocusLines'));
    console.log(`Real GitHub repository (${feed.packages.length} scripts), blob link, DependencyControl detection and content-verified installation passed.`);
  } catch (e) { console.error(e); process.exitCode = 1; }
  finally { app.exit(process.exitCode || 0); }
});
