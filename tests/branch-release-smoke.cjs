const { app, net } = require('electron');
const { Manager } = require('../src/core.cjs');
const path = require('node:path');
const assert = require('node:assert/strict');

app.whenReady().then(async () => {
  const manager = new Manager(path.join(__dirname, '..', '.test-data', `branch-online-${Date.now()}`), () => {}, net.fetch.bind(net));
  try {
    await manager.init();
    const releases = await manager.releases('arch');
    for (const tag of ['migration05-01', 'feature_12']) {
      const release = releases.find(r => r.tag === tag);
      assert.ok(release, `Missing release ${tag}`);
      await manager.installRelease('arch', tag, release.assets[0].name, tag);
      const id = manager.state.selected, v = manager.instance(id);
      assert.match(v.exe, /aegisub\.exe$/i);
      await manager.launch(id);
      await new Promise(resolve => setTimeout(resolve, 5000));
      assert.ok(manager.running.has(id), `${tag} exited early`);
      const child = manager.running.get(id);
      await new Promise(resolve => { child.once('exit', resolve); child.kill(); });
      console.log(`${tag}: real download, nested extraction, config and launch passed (${v.exe})`);
    }
  } catch (e) { console.error(e); process.exitCode = 1; }
  finally {
    for (const child of manager.running.values()) child.kill();
    app.exit(process.exitCode || 0);
  }
});
