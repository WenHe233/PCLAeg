const { app, net } = require('electron');
const { Manager } = require('../src/core.cjs');
const path = require('node:path');
app.whenReady().then(async () => {
  try {
    let last = -1;
    const manager = new Manager(path.join(__dirname, '..', '.test-data', 'network-library'), p => { if (p.percent !== last) { console.log(p.label, p.percent); last = p.percent; } }, net.fetch.bind(net));
    await manager.init();
    const versions = await manager.releases('official');
    console.log('Release', versions[0].tag);
    if (!manager.state.instances.length) await manager.installRelease('official', versions[0].tag, versions[0].assets[0].name, '真实下载测试');
    const id = manager.state.selected;
    if (!manager.instance(id).plugins.length) await manager.addPlugin(id, { catalogId: 'blur' });
    console.log('Installed', manager.instance(id).version, manager.instance(id).plugins[0].version);
    await manager.launch(id);
    console.log('Launched', manager.running.get(id).pid);
    await new Promise(resolve => setTimeout(resolve, 5000));
    if (!manager.running.has(id)) throw new Error('Aegisub 在启动后提前退出');
    manager.running.get(id).kill();
    console.log('Actual Aegisub launch smoke passed');
  } catch (e) { console.error(e); process.exitCode = 1; }
  finally { app.exit(process.exitCode || 0); }
});
