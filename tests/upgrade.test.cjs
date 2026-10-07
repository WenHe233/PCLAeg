const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { Manager } = require('../src/core.cjs');
const { parseReleaseUrl, associationValues, scanExecutables } = require('../src/platform.cjs');
const { satisfies, version } = require('../src/dependencies.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-upgrade-')); t.after(() => fs.rm(root, { recursive: true, force: true }));
  const manager = new Manager(path.join(root, 'library')); await manager.init();
  for (const name of ['Source', 'Target', 'Other']) await manager.create({ name, populate: dir => fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture') });
  const [source, target, other] = manager.state.instances;
  const dir = v => path.dirname(manager.appDir(v));
  return { root, manager, source, target, other, dir };
}
async function script(manager, v, file, body, relative = 'automation/autoload') {
  const root = path.dirname(manager.appDir(v)); await fs.mkdir(path.join(root, relative), { recursive: true }); await fs.writeFile(path.join(root, relative, file), body); await manager.scanPlugins(v.id);
}
test('theme, scan and ASS preferences persist and invalid values are rejected', async t => {
  const { manager, source } = await fixture(t);
  await manager.setPreference('theme', 'dark'); await manager.setPreference('autoScan', false); await manager.setPreference('defaultAss', source.id);
  const restored = new Manager(manager.root); await restored.init(); assert.equal(restored.state.preferences.theme, 'dark'); assert.equal(restored.state.preferences.autoScan, false); assert.equal(restored.state.preferences.defaultAss, source.id);
  await assert.rejects(manager.setPreference('theme', 'invalid')); await assert.rejects(manager.setPreference('defaultAss', 'missing'));
});
test('sync previews changes, copies selected profile paths, preserves programs and supports manual rollback', async t => {
  const { manager, source, target, dir } = await fixture(t);
  await script(manager, source, 'tool.lua', 'script_name="Source tool"');
  await script(manager, target, 'old.lua', 'script_name="Old tool"');
  const cfgFile = path.join(dir(source), 'config.json'), config = JSON.parse(await fs.readFile(cfgFile)); config.App.Language = 'ja_JP'; await fs.writeFile(cfgFile, JSON.stringify(config));
  await fs.writeFile(path.join(dir(source), 'hotkey.json'), '{"key":"new"}'); await fs.writeFile(path.join(dir(target), 'hotkey.json'), '{"key":"old"}');
  const oldConfig = await fs.readFile(path.join(dir(target), 'config.json'));
  const options = { sourceId: source.id, targetIds: [target.id], config: true, plugins: true, hotkeys: true, policy: 'keep' };
  const preview = await manager.previewSync(options); assert.ok(preview.items[0].changes.length >= 3);
  await manager.syncProfiles(options);
  assert.equal(JSON.parse(await fs.readFile(path.join(dir(target), 'config.json'))).App.Language, 'ja_JP');
  assert.ok(target.plugins.some(p => p.name === 'Source tool')); assert.equal(target.plugins.some(p => p.name === 'Old tool'), false);
  assert.equal(await fs.readFile(manager.appDir(target), 'utf8'), 'fixture');
  const point = manager.state.restorePoints[0]; await manager.restoreProfile(point.id);
  assert.ok((await fs.readFile(path.join(dir(target), 'config.json'))).equals(oldConfig)); assert.equal(await fs.readFile(path.join(dir(target), 'hotkey.json'), 'utf8'), '{"key":"old"}');
  assert.ok(target.plugins.some(p => p.name === 'Old tool')); assert.equal(target.plugins.some(p => p.name === 'Source tool'), false);
});
test('multi-target sync automatically restores every target after a mid-operation failure', async t => {
  const { manager, source, target, other, dir } = await fixture(t);
  await fs.writeFile(path.join(dir(source), 'hotkey.json'), 'new'); await fs.writeFile(path.join(dir(target), 'hotkey.json'), 'target'); await fs.writeFile(path.join(dir(other), 'hotkey.json'), 'other');
  const portable = manager.portable.bind(manager);
  manager.portable = async exe => { if (exe === manager.appDir(other)) throw new Error('disk write failed'); return portable(exe); };
  await assert.rejects(manager.syncProfiles({ sourceId: source.id, targetIds: [target.id, other.id], config: false, plugins: false, hotkeys: true }), /disk write/);
  assert.equal(await fs.readFile(path.join(dir(target), 'hotkey.json'), 'utf8'), 'target'); assert.equal(await fs.readFile(path.join(dir(other), 'hotkey.json'), 'utf8'), 'other');
  assert.equal(manager.state.restorePoints[0].status, 'auto-restored');
});
test('unfinished operations expose their persisted backup after restart', async t => {
  const { manager, source, dir } = await fixture(t);
  const point = await manager.createRestorePoint([source.id], 'Interrupted operation');
  await fs.writeFile(path.join(dir(source), 'hotkey.json'), 'half-written change');
  const restarted = new Manager(manager.root); await restarted.init();
  assert.equal(restarted.state.restorePoints.find(p => p.id === point.id).status, 'interrupted');
  await restarted.restoreProfile(point.id); await assert.rejects(fs.access(path.join(dir(source), 'hotkey.json')), { code: 'ENOENT' });
});
test('active consumers protect shared modules and conflicting duplicates are visible', async t => {
  const { manager, source } = await fixture(t);
  await script(manager, source, 'consumer.lua', 'script_name="Consumer"\nlocal x = require "test.Module"');
  await script(manager, source, 'Module.lua', 'local version="1.0.0"\nreturn {}', 'automation/include/test');
  let graph = await manager.dependencyGraph(source.id); assert.equal(graph.edges.find(e => e.namespace === 'test.Module').status, 'ready');
  const module = source.plugins.find(p => p.kind === 'include' && p.file === 'Module.lua');
  await assert.rejects(manager.removePlugin(source.id, module.id), /被 .* 使用/); await assert.rejects(manager.togglePlugin(source.id, module.id), /被 .* 使用/);
  await script(manager, source, 'Module.moon', 'version: "2.0.0"\nreturn {}', 'automation/launcher/include/test');
  graph = await manager.dependencyGraph(source.id); assert.ok(graph.conflicts.some(c => c.namespace === 'test.Module'));
  await manager.resolveModuleDuplicate(source.id, 'test.Module', module.relativePath); graph = await manager.dependencyGraph(source.id); assert.equal(graph.conflicts.length, 0);
});
test('DC dependency version ranges use minimum versions and semver intersections', () => {
  assert.equal(satisfies('1.4.0', '1.2.0'), true); assert.equal(satisfies('2.0.0', '^1.2.0'), false); assert.equal(satisfies('1.3.0', '>=1.2.0 <2'), true);
  assert.equal(version((1 << 16) + (2 << 8) + 3), '1.2.3'); assert.equal(version('1.2'), '1.2.0'); assert.equal(satisfies('1.2.5', '~>1.2.0'), true);
});
function dcFixture() {
  const data = new Map(), files = new Map();
  const sourceUrl = 'https://example.com/DC.json';
  const entry = (namespace, section, version, requiredModules = [], provides = []) => {
    const suffix = section === 'macros' ? namespace : namespace.replaceAll('.', '/'), bytes = Buffer.from(`script_name="${namespace}"\nscript_version="${version}"\nreturn {}`);
    const url = 'https://example.com/' + suffix + '.lua'; files.set(url, bytes);
    return { name: namespace, provides, channels: { stable: { default: true, version, requiredModules, files: [{ name: '.lua', url, sha1: crypto.createHash('sha1').update(bytes).digest('hex') }] } } };
  };
  data.set(sourceUrl, { dependencyControlFeedFormatVersion: '0.3.0', name: 'Test', macros: { 'test.Plugin': entry('test.Plugin', 'macros', '1.0.0', [{ moduleName: 'test.Module', version: '^1.0.0' }]) }, modules: { 'test.Module': entry('test.Module', 'modules', '1.2.0') } });
  return { data, files, sourceUrl, entry };
}
test('DC installation resolves, verifies and records a module before installing its consumer', async t => {
  const { manager, source, dir } = await fixture(t), dc = dcFixture();
  manager.fetcher = async url => dc.data.has(url) ? Response.json(dc.data.get(url)) : new Response(dc.files.get(url));
  await manager.addPluginFeed(dc.sourceUrl); const entry = manager.catalog().find(p => p.namespace === 'test.Plugin');
  await manager.addPlugin(source.id, { catalogId: entry.id });
  assert.equal(source.dependencyPackages['test.Module'].version, '1.2.0'); await fs.access(path.join(dir(source), 'automation/include/test/Module.lua'));
  const graph = await manager.dependencyGraph(source.id); assert.equal(graph.conflicts.length, 0); assert.equal(graph.missing.length, 0);
  const cfg = JSON.parse(await fs.readFile(path.join(dir(source), 'config/l0.DependencyControl.json'))); assert.equal(cfg.modules['test.Module'].userFeed, dc.sourceUrl);
});
test('incompatible consumers prevent dependency replacement and leave original files intact', async t => {
  const { manager, source, dir } = await fixture(t), dc = dcFixture();
  await script(manager, source, 'existing.lua', 'script_name="Existing"'); source.plugins.find(p => p.file === 'existing.lua').requiredModules = [{ moduleName: 'test.Module', version: '^2.0.0' }];
  manager.fetcher = async url => dc.data.has(url) ? Response.json(dc.data.get(url)) : new Response(dc.files.get(url));
  await manager.addPluginFeed(dc.sourceUrl); const entry = manager.catalog().find(p => p.namespace === 'test.Plugin');
  await assert.rejects(manager.addPlugin(source.id, { catalogId: entry.id }), /找不到兼容依赖|冲突/);
  assert.ok(source.plugins.some(p => p.file === 'existing.lua')); await assert.rejects(fs.access(path.join(dir(source), 'automation/autoload/test.Plugin.lua')), { code: 'ENOENT' });
});
test('missing native module aliases are provided by a compatible DC provider package', async t => {
  const { manager, source } = await fixture(t), dc = dcFixture(), manifest = dc.data.get(dc.sourceUrl);
  manifest.macros['test.Plugin'].channels.stable.requiredModules = [{ moduleName: 'test.Alias', version: '^1.0.0' }];
  manifest.modules = { 'test.Provider': dc.entry('test.Provider', 'modules', '3.0.0', [], [{ name: 'test.Alias', version: '^1.0.0' }]) };
  manager.fetcher = async url => dc.data.has(url) ? Response.json(dc.data.get(url)) : new Response(dc.files.get(url));
  await manager.addPluginFeed(dc.sourceUrl); await manager.addPlugin(source.id, { catalogId: manager.catalog().find(p => p.namespace === 'test.Plugin').id });
  assert.ok(source.dependencyPackages['test.Provider']); assert.equal((await manager.dependencyGraph(source.id)).conflicts.length, 0);
});
test('scan excludes managed directories, discovers sibling executable choices and imports the selected program', async t => {
  const { root, manager } = await fixture(t);
  const external = path.join(root, 'external'); await fs.mkdir(external); await fs.writeFile(path.join(external, 'aegisub.exe'), 'one'); await fs.writeFile(path.join(external, 'aegisub9820.exe'), 'two');
  const scan = await scanExecutables([root], [manager.root], async () => '1.0.0'); assert.equal(scan.candidates.length, 2);
  await manager.scanLocalVersions([external]); const choice = manager.localVersions.find(v => v.file.endsWith('aegisub9820.exe'));
  await manager.importLocalCandidate(choice.token, 'Detected'); const v = manager.instance(manager.state.selected);
  assert.equal(v.exe, 'aegisub9820.exe'); assert.equal(await fs.readFile(manager.appDir(v), 'utf8'), 'two'); assert.equal(await fs.readFile(path.join(external, 'aegisub.exe'), 'utf8'), 'one');
  await assert.rejects(manager.importLocalCandidate(choice.token, 'Duplicate'), /已经导入/);
});
test('GitHub Releases sources persist, deduplicate and keep built-in branches protected', async t => {
  const { manager } = await fixture(t); manager.fetcher = async () => Response.json({ full_name: 'user/Aegisub' });
  assert.equal(parseReleaseUrl('https://github.com/user/Aegisub/releases/tag/v1'), 'user/Aegisub'); assert.throws(() => parseReleaseUrl('https://example.com/user/repo/releases'));
  const result = await manager.addReleaseSource('https://github.com/user/Aegisub/releases'); await manager.addReleaseSource('https://github.com/user/Aegisub');
  assert.equal(Object.keys(manager.state.releaseSources).length, 1); assert.equal(manager.sources()[result.addedSource].repo, 'user/Aegisub');
  const restored = new Manager(manager.root); await restored.init(); assert.ok(restored.sources()[result.addedSource]);
  await assert.rejects(manager.removeReleaseSource('official'), /内置/);
});
test('ASS registration quotes paths and uses per-user capabilities without changing UserChoice', () => {
  const values = associationValues('D:\\My App\\Launcher.exe'); const command = values.find(([key]) => key.endsWith('shell\\open\\command'))[2];
  assert.equal(command, '"D:\\My App\\Launcher.exe" --open-ass "%1"'); assert.ok(values.every(([key]) => key.startsWith('HKCU\\'))); assert.equal(values.some(([key]) => key.includes('UserChoice')), false);
});
test('ASS file launch routes quoted paths as arguments and tracks multiple processes in one instance', async t => {
  const { root, manager, source } = await fixture(t), file = path.join(root, 'with spaces.ass'); await fs.writeFile(file, '[Script Info]');
  const launches = []; manager.spawnProcess = (exe, args) => { launches.push({ exe, args }); const child = new EventEmitter(); setImmediate(() => child.emit('spawn')); return child; };
  await manager.launch(source.id, [file]); const first = manager.running.get(source.id); await manager.launch(source.id, [file]); const second = manager.running.get(source.id);
  assert.deepEqual(launches[0].args, [file]); assert.equal(launches[0].exe, manager.appDir(source)); first.emit('exit'); assert.equal(manager.running.has(source.id), true); second.emit('exit'); assert.equal(manager.running.has(source.id), false);
});
