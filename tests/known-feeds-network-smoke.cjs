const { app, net } = require('electron');
const { Manager } = require('../src/core.cjs');
const path = require('node:path');
const assert = require('node:assert/strict');
app.whenReady().then(async () => {
  try {
    const manager = new Manager(path.join(__dirname, '..', '.test-data', `known-network-${Date.now()}`), p => { if (p.label?.startsWith('发现关联源')) console.log(p.label); }, net.fetch.bind(net));
    await manager.init();
    await manager.addPluginFeed('https://raw.githubusercontent.com/TypesettingTools/arch1t3cht-Aegisub-Scripts/main/DependencyControl.json');
    const initial = manager.state.discoveredFeeds.length; assert.ok(initial >= 3);
    await manager.discoverPluginFeeds();
    assert.equal(manager.state.pluginFeeds.length, 1);
    assert.ok(manager.state.discoveredFeeds.length > initial);
    console.log('Real knownFeeds discovery passed:', initial, 'direct references;', manager.state.discoveredFeeds.length, 'recursive candidates;', manager.state.feedDiscoveryStatus.requested, 'requests.');
  } catch (error) { console.error(error); process.exitCode = 1; }
  finally { app.exit(process.exitCode || 0); }
});
