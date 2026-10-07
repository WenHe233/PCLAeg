const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const AdmZip = require('adm-zip');
const { Manager, safeEntry, inside, extractZip, download } = require('../src/core.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const original = path.join(root, 'original'); await fs.mkdir(original);
  await fs.writeFile(path.join(original, 'aegisub.exe'), 'test fixture, not executable');
  await fs.writeFile(path.join(original, 'config.json'), JSON.stringify({ App: { Language: 'zh_CN' }, Path: { Automation: { Autoload: 'C:/shared/plugins' } } }));
  const script = path.join(root, 'test.lua'); await fs.writeFile(script, 'script_name="Test"\nscript_version="1.2"');
  const manager = new Manager(path.join(root, 'data')); await manager.init();
  return { root, original, script, manager };
}
test('import copies files and enforces local config without changing original', async t => {
  const { original, manager } = await fixture(t);
  await manager.importVersion(original, '字幕项目');
  const v = manager.state.instances[0];
  const config = JSON.parse(await fs.readFile(path.join(path.dirname(manager.appDir(v)), 'config.json')));
  assert.equal(config.App['Local Config'], true);
  assert.equal(config.App.Language, 'zh_CN');
  assert.match(config.Path.Automation.Autoload, /^\?user\/automation\/launcher\/autoload/);
  assert.equal(config.Path.Auto.Save, '?user/autosave');
  assert.equal(JSON.parse(await fs.readFile(path.join(original, 'config.json'))).App['Local Config'], undefined);
  const restored = new Manager(manager.root); await restored.init();
  assert.equal(restored.state.selected, v.id);
});
test('plugins and cloned instances remain isolated, disabled modules restore to include', async t => {
  const { manager, original, script } = await fixture(t);
  await manager.importVersion(original, 'A'); const a = manager.state.selected;
  await manager.addPlugin(a, { file: script, kind: 'include' });
  await manager.clone(a, 'B'); const b = manager.state.selected;
  const va = manager.instance(a), vb = manager.instance(b), p = va.plugins[0];
  assert.notEqual(manager.dir(va), manager.dir(vb));
  await manager.togglePlugin(a, p.id);
  assert.equal(va.plugins[0].enabled, false);
  assert.equal(vb.plugins[0].enabled, true);
  assert.match(manager.pluginPath(va, p), /disabled/);
  assert.equal((await fs.readFile(manager.pluginPath(vb, vb.plugins[0]), 'utf8')).includes('1.2'), true);
  await manager.togglePlugin(a, p.id);
  assert.match(manager.pluginPath(va, p), /include/);
  await manager.removePlugin(a, p.id);
  assert.equal(va.plugins.length, 0); assert.equal(vb.plugins.length, 1);
});
test('version deletion removes all managed files and adjusts selection without changing original', async t => {
  const { manager, original } = await fixture(t);
  await manager.importVersion(original, 'A'); const id = manager.state.selected;
  const target = manager.dir(manager.instance(id));
  const backups = path.join(manager.root, 'cache/plugin-dependency-backups', id);
  await fs.mkdir(backups, { recursive: true }); await fs.writeFile(path.join(backups, 'backup.moon'), 'backup');
  await manager.remove(id);
  assert.equal(manager.state.instances.length, 0); assert.equal(manager.state.selected, null);
  await assert.rejects(fs.access(target), { code: 'ENOENT' });
  await assert.rejects(fs.access(backups), { code: 'ENOENT' });
  await assert.rejects(fs.access(path.join(manager.root, 'trash')), { code: 'ENOENT' });
  assert.equal(await fs.readFile(path.join(original, 'aegisub.exe'), 'utf8'), 'test fixture, not executable');
  const restored = new Manager(manager.root); await restored.init();
  assert.equal(restored.state.instances.length, 0); assert.equal(restored.state.selected, null);
});

test('version deletion rejects paths outside the managed versions directory', async t => {
  const { manager, original } = await fixture(t);
  await manager.importVersion(original, 'A'); const id = manager.state.selected;
  const v = manager.instance(id), folder = v.folder;
  for (const invalid of ['..', path.relative(path.join(manager.root, 'versions'), original)]) {
    v.folder = invalid;
    await assert.rejects(manager.remove(id), /路径必须位于管理目录内/);
    assert.equal(manager.state.selected, id);
    assert.equal(await fs.readFile(path.join(original, 'aegisub.exe'), 'utf8'), 'test fixture, not executable');
  }
  v.folder = folder;
});
test('invalid imports clean staging and cannot recursively import manager root', async t => {
  const { manager, root } = await fixture(t);
  const invalid = path.join(root, 'invalid'); await fs.mkdir(invalid);
  await assert.rejects(manager.importVersion(invalid, 'Missing'), /没有找到/);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), []);
  await assert.rejects(manager.importVersion(root, 'Recursive'), /不能导入/);
});
test('path traversal, device names and absolute ZIP paths are rejected', () => {
  for (const entry of ['../x', 'a/../../x', 'a\\..\\x', '/absolute', 'C:/x', 'NUL.txt', 'a/foo.']) assert.throws(() => safeEntry(entry));
  safeEntry('aegisub/automation/autoload/plugin.lua');
  assert.throws(() => inside('C:/root', 'C:/outside/file'));
});
test('ZIP imports discover nested executable and initialize portable config', async t => {
  const { manager, root } = await fixture(t);
  const zip = new AdmZip(); zip.addFile('Aegisub/aegisub64.exe', Buffer.from('fixture'));
  const file = path.join(root, 'portable.zip'); zip.writeZip(file);
  await manager.importVersion(file, 'ZIP');
  assert.match(manager.instance(manager.state.selected).exe, /aegisub64.exe$/);
  const hostile = new AdmZip(); hostile.addFile('C:/bad.txt', Buffer.from('bad'));
  const bad = path.join(root, 'bad.zip'); hostile.writeZip(bad);
  await assert.rejects(extractZip(bad, path.join(root, 'out')), /不安全/);
});
test('running instances reject clone, removal and plugin mutations', async t => {
  const { manager, original, script } = await fixture(t);
  await manager.importVersion(original, 'A'); const id = manager.state.selected;
  manager.running.set(id, {});
  await assert.rejects(manager.addPlugin(id, { file: script }), /请先关闭/);
  await assert.rejects(manager.clone(id, 'copy'), /请先关闭/);
  await assert.rejects(manager.remove(id), /请先关闭/);
});
test('multiple executables require explicit selection, recognize 9820 and preserve choice on clone', async t => {
  const { manager, original } = await fixture(t);
  await fs.writeFile(path.join(original, 'aegisub9820.exe'), '9820 fixture');
  await assert.rejects(manager.importVersion(original, 'Ambiguous'), /多个 Aegisub/);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), []);
  manager.chooseExecutable = async choices => {
    assert.equal(choices.length, 2);
    return choices.find(c => c.relative === 'aegisub9820.exe').path;
  };
  await manager.importVersion(original, '9820');
  const id = manager.state.selected;
  assert.equal(manager.instance(id).exe, 'aegisub9820.exe');
  manager.chooseExecutable = async () => { throw new Error('Clone must preserve selection'); };
  await manager.clone(id, '9820 copy');
  assert.equal(manager.instance(manager.state.selected).exe, 'aegisub9820.exe');
  const restored = new Manager(manager.root); await restored.init();
  assert.equal(restored.instance(id).exe, 'aegisub9820.exe');
});
test('existing instance can switch sibling launch executable without changing plugin folder', async t => {
  const { manager, original, script } = await fixture(t);
  await manager.importVersion(original, 'Original'); const id = manager.state.selected;
  await manager.addPlugin(id, { file: script });
  const v = manager.instance(id), oldPlugin = manager.pluginPath(v, v.plugins[0]);
  await fs.writeFile(path.join(path.dirname(manager.appDir(v)), 'aegisub9820.exe'), '9820 fixture');
  manager.chooseExecutable = async choices => choices.find(c => path.basename(c.path) === 'aegisub9820.exe').path;
  await manager.changeExecutable(id);
  assert.equal(v.exe, 'aegisub9820.exe');
  assert.equal(manager.pluginPath(v, v.plugins[0]), oldPlugin);
  assert.equal(await fs.readFile(oldPlugin, 'utf8'), 'script_name="Test"\nscript_version="1.2"');
  manager.running.set(id, {});
  await assert.rejects(manager.changeExecutable(id), /请先关闭/);
});
test('cancelled executable selection leaves no instance behind', async t => {
  const { manager, original } = await fixture(t);
  await fs.writeFile(path.join(original, 'aegisub9820.exe'), 'fixture');
  manager.chooseExecutable = async () => null;
  await assert.rejects(manager.importVersion(original, 'Cancelled'), /已取消版本选择/);
  assert.equal(manager.state.instances.length, 0);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), []);
});
test('CI artifact ZIP can contain a portable ZIP with trailing-comma config', async t => {
  const { manager, root } = await fixture(t);
  const inner = new AdmZip();
  inner.addFile('Aegisub.exe', Buffer.from('fixture'));
  inner.addFile('config.json', Buffer.from('{ // portable\n"App": { "Local Config": true, "Language": "en_US", }, }'));
  const outer = new AdmZip(); outer.addFile('aegisub-portable.zip', inner.toBuffer());
  const file = path.join(root, 'artifact.zip'); outer.writeZip(file);
  await manager.importVersion(file, 'Experimental');
  const v = manager.instance(manager.state.selected);
  assert.match(v.exe, /portable[\\/]Aegisub.exe$/);
  const config = JSON.parse(await fs.readFile(path.join(path.dirname(manager.appDir(v)), 'config.json')));
  assert.equal(config.App.Language, 'en_US'); assert.equal(config.App['Local Config'], true);
});
test('source ZIP is rejected with an actionable message and no fake installed version', async t => {
  const { manager, root } = await fixture(t);
  const zip = new AdmZip(); zip.addFile('Aegisub-exp/CMakeLists.txt', Buffer.from('source'));
  const file = path.join(root, 'source.zip'); zip.writeZip(file);
  await assert.rejects(manager.importVersion(file, 'Source'), /源码 ZIP/);
  assert.equal(manager.state.instances.length, 0);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), []);
});

for (const [tag, innerName] of [['feature_12', 'aegisub-portable-64.zip'], ['migration05-01', 'Aegisub-9936-migration05-ac80c87ff-x64-portable.zip']]) {
  test(`online ${tag} install unpacks the release wrapper and preserves isolated config`, async t => {
    const { manager } = await fixture(t);
    const inner = new AdmZip();
    inner.addFile('aegisub-portable/aegisub.exe', Buffer.from('branch fixture'));
    inner.addFile('aegisub-portable/config.json', Buffer.from('{"App":{"Language":"zh_CN",},}'));
    const outer = new AdmZip(); outer.addFile(innerName, inner.toBuffer());
    const body = outer.toBuffer();
    const digest = 'sha256:' + require('node:crypto').createHash('sha256').update(body).digest('hex');
    const asset = { name: 'Windows.MSVC.Release.-.portable.zip', browser_download_url: 'https://example.com/branch.zip', size: body.length, digest };
    manager.fetcher = async url => url.includes('api.github.com')
      ? Response.json([{ tag_name: tag, assets: [asset] }])
      : new Response(body, { headers: { 'content-length': String(body.length) } });
    await manager.installRelease('arch', tag, asset.name, tag);
    const v = manager.instance(manager.state.selected);
    assert.equal(v.source, 'arch'); assert.equal(v.version, tag);
    assert.equal(await fs.readFile(manager.appDir(v), 'utf8'), 'branch fixture');
    assert.match(v.exe, /portable[\\/]aegisub-portable[\\/]aegisub.exe$/);
    const config = JSON.parse(await fs.readFile(path.join(path.dirname(manager.appDir(v)), 'config.json')));
    assert.equal(config.App.Language, 'zh_CN'); assert.equal(config.App['Local Config'], true);
    assert.deepEqual(await fs.readdir(path.join(manager.root, 'cache/downloads')), []);
    const restored = new Manager(manager.root); await restored.init();
    assert.equal(restored.instance(v.id).exe, v.exe);
  });
}

test('online invalid nested release cleans download and staging without changing selected version', async t => {
  const { manager, original } = await fixture(t);
  await manager.importVersion(original, 'Existing'); const selected = manager.state.selected;
  const inner = new AdmZip(); inner.addFile('README.txt', Buffer.from('no executable'));
  const outer = new AdmZip(); outer.addFile('aegisub-portable.zip', inner.toBuffer());
  const body = outer.toBuffer();
  const asset = { name: 'Windows.MSVC.Release.-.portable.zip', browser_download_url: 'https://example.com/invalid.zip', size: body.length };
  manager.fetcher = async url => url.includes('api.github.com')
    ? Response.json([{ tag_name: 'invalid', assets: [asset] }])
    : new Response(body);
  await assert.rejects(manager.installRelease('arch', 'invalid', asset.name, 'Invalid'), /没有找到/);
  assert.equal(manager.state.selected, selected); assert.equal(manager.state.instances.length, 1);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), ['Existing']);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'cache/downloads')), []);
});
test('existing Lua/MoonScript plugins and nested dependencies are discovered and disabled in place', async t => {
  const { manager, original } = await fixture(t);
  await fs.mkdir(path.join(original, 'automation', 'autoload'), { recursive: true });
  await fs.mkdir(path.join(original, 'automation', 'include', 'lib'), { recursive: true });
  await fs.writeFile(path.join(original, 'automation', 'autoload', 'hydra.lua'), 'script_name="HYDRA"\nscript_version="2.0"\nscript_author="unanimated"');
  await fs.writeFile(path.join(original, 'automation', 'include', 'lib', 'helper.moon'), 'return {}');
  await manager.importVersion(original, 'With plugins');
  const v = manager.instance(manager.state.selected);
  assert.equal(v.plugins.length, 2);
  const plugin = v.plugins.find(p => p.name === 'HYDRA');
  assert.equal(plugin.version, '2.0'); assert.equal(plugin.imported, true);
  assert.match(manager.pluginPath(v, plugin), /automation[\\/]autoload[\\/]hydra.lua$/);
  const originalPath = manager.pluginPath(v, plugin);
  await manager.togglePlugin(v.id, plugin.id);
  assert.equal(plugin.enabled, false);
  await manager.scanPlugins(v.id); assert.equal(v.plugins.length, 2);
  await manager.togglePlugin(v.id, plugin.id);
  assert.equal(manager.pluginPath(v, plugin), originalPath);
  await manager.scanPlugins(v.id); assert.equal(v.plugins.length, 2);
  await manager.removePlugin(v.id, plugin.id);
  await manager.scanPlugins(v.id); assert.equal(v.plugins.length, 1);
});
test('unified catalog lists existing 9820 scripts and installs them with missing dependencies only', async t => {
  const { manager, original } = await fixture(t);
  await fs.mkdir(path.join(original, 'automation', 'autoload'), { recursive: true });
  await fs.mkdir(path.join(original, 'automation', 'include', 'lib'), { recursive: true });
  await fs.writeFile(path.join(original, 'automation', 'autoload', 'shapery.moon'), 'export script_name = "Shapery"\nexport script_version = "2.6"');
  await fs.writeFile(path.join(original, 'automation', 'include', 'lib', 'helper.lua'), 'source helper');
  await fs.writeFile(path.join(original, 'automation', 'include', 'lib', 'keep.lua'), 'source shared');
  await manager.importVersion(original, '9820'); const sourceId = manager.state.selected;
  const entry = manager.catalog().find(p => p.file === 'shapery.moon');
  assert.equal(entry.name, 'Shapery'); assert.equal(manager.catalog().length, 65);
  await manager.create({ name: 'Target', populate: async dest => {
    await fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture');
    await fs.mkdir(path.join(dest, 'automation', 'include', 'lib'), { recursive: true });
    await fs.writeFile(path.join(dest, 'automation', 'include', 'lib', 'keep.lua'), 'target shared');
  } });
  const targetId = manager.state.selected;
  await manager.addPlugin(targetId, { catalogId: entry.id });
  const target = manager.instance(targetId), dir = path.dirname(manager.appDir(target));
  assert.equal(await fs.readFile(path.join(dir, 'automation', 'include', 'lib', 'helper.lua'), 'utf8'), 'source helper');
  assert.equal(await fs.readFile(path.join(dir, 'automation', 'include', 'lib', 'keep.lua'), 'utf8'), 'target shared');
  assert.equal(target.plugins.filter(p => p.kind === 'autoload').length, 1);
  assert.equal(manager.instance(sourceId).plugins.filter(p => p.kind === 'autoload').length, 1);
  const local = target.plugins.find(p => p.kind === 'autoload');
  await manager.togglePlugin(targetId, local.id); await manager.togglePlugin(targetId, local.id);
  await assert.rejects(manager.addPlugin(targetId, { catalogId: entry.id }), /已安装/);
});
test('legacy local dependency copies migrate without shadowing updates or changing edited modules', async t => {
  const { manager, original } = await fixture(t);
  const sourceDir = path.join(original, 'automation', 'include');
  await fs.mkdir(sourceDir, { recursive: true });
  for (const [name, data] of [['updated.lua', 'old'], ['missing.lua', 'module'], ['edited.lua', 'original']]) await fs.writeFile(path.join(sourceDir, name), data);
  await manager.importVersion(original, '9820');
  await manager.create({ name: 'Target', populate: async dest => {
    await fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture');
    const managed = path.join(dest, 'automation', 'launcher', 'include');
    await fs.mkdir(managed, { recursive: true });
    for (const [name, data] of [['updated.lua', 'old'], ['missing.lua', 'module'], ['edited.lua', 'user edit']]) await fs.writeFile(path.join(managed, name), data);
    await fs.mkdir(path.join(dest, 'automation', 'include'), { recursive: true });
    await fs.writeFile(path.join(dest, 'automation', 'include', 'updated.lua'), 'new');
    await fs.mkdir(path.join(dest, 'automation', 'launcher', 'autoload'), { recursive: true });
    await fs.writeFile(path.join(dest, 'automation', 'launcher', 'autoload', 'macro.lua'), 'script_name = "Macro"');
  } });
  const v = manager.instance(manager.state.selected), root = path.dirname(manager.appDir(v));
  v.plugins.find(p => p.kind === 'autoload').copiedFrom = '9820';
  await manager.repairLocalDependencies(v);
  assert.equal(await fs.readFile(path.join(root, 'automation/include/updated.lua'), 'utf8'), 'new');
  assert.equal(await fs.readFile(path.join(root, 'automation/include/missing.lua'), 'utf8'), 'module');
  assert.equal(await fs.readFile(path.join(root, 'automation/launcher/include/edited.lua'), 'utf8'), 'user edit');
  await assert.rejects(fs.access(path.join(root, 'automation/launcher/include/updated.lua')));
  await manager.repairLocalDependencies(v);
  assert.equal(v.plugins.filter(p => p.kind === 'include').length, 3);
});

test('Motion literal pattern is compatible with modern MoonScript and backed up', async t => {
  const { manager, original } = await fixture(t);
  await fs.mkdir(path.join(original, 'automation/autoload'), { recursive: true });
  await fs.mkdir(path.join(original, 'automation/include/a-mo'), { recursive: true });
  await fs.writeFile(path.join(original, 'automation/autoload/a-mo.Aegisub-Motion.moon'), 'export script_name = "Motion"');
  const old = 'encodeString = .preCom .. @command\\gsub( "#{(.-)}", ( token ) -> @tokens[token] ) .. .postCom';
  await fs.writeFile(path.join(original, 'automation/include/a-mo/TrimHandler.moon'), old);
  await manager.importVersion(original, 'Motion');
  const v = manager.instance(manager.state.selected);
  await manager.repairMotionCompatibility(v);
  const fixed = await fs.readFile(path.join(path.dirname(manager.appDir(v)), 'automation/include/a-mo/TrimHandler.moon'), 'utf8');
  assert.equal(fixed, old.replace('"#{(.-)}"', "'#{(.-)}'"));
  assert.equal(await fs.readFile(path.join(original, 'automation/include/a-mo/TrimHandler.moon'), 'utf8'), old);
  const backups = await fs.readdir(path.join(manager.root, 'cache/plugin-dependency-backups', v.id));
  assert.equal(backups.length, 1);
  await manager.repairMotionCompatibility(v);
  assert.equal((await fs.readdir(path.join(manager.root, 'cache/plugin-dependency-backups', v.id))).length, 1);
});

test('interrupted downloads resume at exact byte offset', async t => {
  const { root } = await fixture(t);
  const full = Buffer.from('abcdef'); let calls = 0;
  const fetcher = async (_, opts) => {
    calls++;
    if (calls === 1) {
      let read = 0;
      return new Response(new ReadableStream({ pull(controller) { if (read++ === 0) controller.enqueue(full.subarray(0, 3)); else controller.error(new Error('connection interrupted')); } }), { headers: { 'content-length': '6' } });
    }
    assert.equal(opts.headers.Range, 'bytes=3-4194306');
    return new Response(full.subarray(3), { status: 206, headers: { 'content-length': '3', 'content-range': 'bytes 3-5/6' } });
  };
  const dest = path.join(root, 'download'); await download('https://example.com/test', dest, () => {}, 10, fetcher);
  assert.equal(await fs.readFile(dest, 'utf8'), 'abcdef'); assert.equal(calls, 2);
});
test('servers ignoring Range restart cleanly and cancellation stops retries', async t => {
  const { root } = await fixture(t); let calls = 0;
  const fetcher = async () => {
    if (++calls === 1) {
      let sent = false;
      return new Response(new ReadableStream({ pull(c) { if (!sent) { sent = true; c.enqueue(Buffer.from('old')); } else c.error(new Error('interrupted')); } }), { headers: { 'content-length': '6' } });
    }
    return new Response('fresh', { headers: { 'content-length': '5' } });
  };
  const dest = path.join(root, 'restart'); await download('https://example.com/test', dest, () => {}, 10, fetcher);
  assert.equal(await fs.readFile(dest, 'utf8'), 'fresh');
  const abort = new AbortController(); abort.abort();
  await assert.rejects(download('https://example.com/test', path.join(root, 'cancel'), () => {}, 10, fetcher, abort.signal), /下载已取消/);
});
