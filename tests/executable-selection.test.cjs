const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const AdmZip = require('adm-zip');
const { Manager, findExecutables } = require('../src/core.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-executable-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const manager = new Manager(path.join(root, 'library')); await manager.init();
  await manager.create({ name: 'Existing', populate: dest => fs.writeFile(path.join(dest, 'aegisub.exe'), 'fixture') });
  return { root, manager };
}

function release(manager, body) {
  const asset = { name: 'editor-windows-x64-portable.zip', browser_download_url: 'https://example.com/editor.zip', size: body.length };
  manager.fetcher = async url => url.includes('api.github.com')
    ? Response.json([{ tag_name: 'test', assets: [asset] }]) : new Response(body);
  return () => manager.installRelease('official', 'test', asset.name, 'Imported');
}

async function unchanged(manager, selected) {
  assert.equal(manager.state.selected, selected);
  assert.equal(manager.state.instances.length, 1);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), ['Existing']);
  assert.deepEqual(await fs.readdir(path.join(manager.root, 'cache/downloads')), []);
  const restored = new Manager(manager.root); await restored.init();
  assert.equal(restored.state.selected, selected);
  assert.equal(restored.state.instances.length, 1);
}

for (const mode of ['directory', 'zip', 'release', 'nested-release']) {
  test(`${mode}: unknown executable requires selection, persists, clones and launches with its own working directory`, async t => {
    const { root, manager } = await fixture(t);
    const files = { 'editor/Subtitle Studio.EXE': 'fixture', 'editor/meson.build': 'build file', 'editor/config.json': '{"App":{"Language":"en_US"}}' };
    let calls = 0;
    const relative = path.join(...(mode === 'nested-release' ? ['portable'] : []), 'editor', 'Subtitle Studio.EXE');
    manager.browseExecutable = async (dir, options) => {
      calls++;
      assert.equal(options.sameDirectory, false);
      assert.equal(path.dirname(dir), path.join(manager.root, 'versions'));
      assert.deepEqual(await findExecutables(dir), []);
      return path.join(dir, relative);
    };
    if (mode === 'directory') {
      const input = path.join(root, 'original');
      for (const [name, content] of Object.entries(files)) { const file = path.join(input, name); await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, content); }
      await manager.importVersion(input, 'Imported');
      assert.equal(JSON.parse(await fs.readFile(path.join(input, 'editor/config.json'))).App['Local Config'], undefined);
    } else {
      const zip = new AdmZip(); for (const [name, content] of Object.entries(files)) zip.addFile(name, Buffer.from(content));
      if (mode === 'zip') { const input = path.join(root, 'input.zip'); zip.writeZip(input); await manager.importVersion(input, 'Imported'); }
      else { const outer = new AdmZip(); outer.addFile('aegisub-portable.zip', zip.toBuffer()); await release(manager, mode === 'release' ? zip.toBuffer() : outer.toBuffer())(); }
    }
    assert.equal(calls, 1);
    const v = manager.instance(manager.state.selected);
    assert.equal(v.exe, relative);
    const config = JSON.parse(await fs.readFile(path.join(path.dirname(manager.appDir(v)), 'config.json')));
    assert.equal(config.App['Local Config'], true); assert.equal(config.App.Language, 'en_US');
    const restored = new Manager(manager.root); await restored.init(); assert.equal(restored.instance(v.id).exe, relative);
    manager.browseExecutable = async () => assert.fail('克隆不能再次要求选择程序');
    await manager.clone(v.id, 'Clone'); const clone = manager.instance(manager.state.selected);
    assert.equal(clone.exe, relative);
    let launch;
    manager.spawnProcess = (exe, args, options) => { launch = { exe, args, options }; const child = new EventEmitter(); setImmediate(() => child.emit('spawn')); return child; };
    await manager.launch(clone.id);
    assert.equal(launch.exe, manager.appDir(clone)); assert.equal(launch.options.cwd, path.dirname(manager.appDir(clone)));
    manager.running.get(clone.id).emit('exit');
    await fs.unlink(manager.appDir(v));
    await assert.rejects(manager.clone(v.id, 'Missing'), /原实例的启动文件不存在/);
    assert.deepEqual(await fs.readdir(path.join(manager.root, 'versions')), ['Clone', 'Existing', 'Imported']);
  });
}

test('recognized executables keep priority over unknown names and multiple recognized names still require selection', async t => {
  const { manager } = await fixture(t);
  manager.browseExecutable = async () => assert.fail('已识别程序不应打开文件选择器');
  await manager.create({ name: 'Known', populate: async dir => {
    for (const name of ['AEGISUB.EXE', 'custom-editor.exe', 'aegisub-server.exe']) await fs.writeFile(path.join(dir, name), 'fixture');
  } });
  assert.equal(manager.instance(manager.state.selected).exe, 'AEGISUB.EXE');
  manager.chooseExecutable = async choices => { assert.equal(choices.length, 2); return choices.find(c => c.relative === 'aegisub9820.exe').path; };
  await manager.create({ name: 'Multiple', populate: async dir => {
    for (const name of ['aegisub.exe', 'aegisub9820.exe', 'custom-editor.exe']) await fs.writeFile(path.join(dir, name), 'fixture');
  } });
  assert.equal(manager.instance(manager.state.selected).exe, 'aegisub9820.exe');
});

for (const kind of ['cancel', 'abort', 'missing', 'non-exe', 'directory', 'outside', 'junction']) {
  test(`release selection ${kind} rolls back without changing existing state`, async t => {
    const { root, manager } = await fixture(t), selected = manager.state.selected;
    const zip = new AdmZip(); zip.addFile('editor.exe', Buffer.from('fixture')); zip.addFile('notes.txt', Buffer.from('notes'));
    const external = path.join(root, 'external'); await fs.mkdir(external); await fs.writeFile(path.join(external, 'outside.exe'), 'untouched');
    manager.browseExecutable = async dir => {
      if (kind === 'cancel') return null;
      if (kind === 'abort') { manager.abort.abort(); return path.join(dir, 'editor.exe'); }
      if (kind === 'missing') return path.join(dir, 'missing.exe');
      if (kind === 'non-exe') return path.join(dir, 'notes.txt');
      if (kind === 'directory') { await fs.mkdir(path.join(dir, 'folder.exe')); return path.join(dir, 'folder.exe'); }
      if (kind === 'outside') return path.join(external, 'outside.exe');
      await fs.symlink(external, path.join(dir, 'linked'), 'junction'); return path.join(dir, 'linked/outside.exe');
    };
    const expected = { cancel: /已取消版本选择/, abort: /已取消版本选择/, missing: /不存在/, 'non-exe': /有效的 EXE/, directory: /普通 EXE/, outside: /管理目录内/, junction: /管理目录内/ };
    await assert.rejects(manager.mutate(release(manager, zip.toBuffer())), error => {
      assert.match(error.message, expected[kind]);
      if (kind === 'cancel' || kind === 'abort') assert.equal(error.code, 'EXECUTABLE_SELECTION_CANCELLED');
      return true;
    });
    assert.equal(manager.busy, false); assert.equal(manager.abort, null);
    await unchanged(manager, selected);
    assert.equal(await fs.readFile(path.join(external, 'outside.exe'), 'utf8'), 'untouched');
    assert.deepEqual(await fs.readdir(external), ['outside.exe']);
  });
}

test('manual selection supports multiple unknown files without guessing and switching stays in the same directory', async t => {
  const { manager } = await fixture(t);
  manager.browseExecutable = async dir => path.join(dir, 'custom.exe');
  await manager.create({ name: 'Manual', populate: async dir => {
    for (const name of ['custom.exe', 'alternative.exe']) await fs.writeFile(path.join(dir, name), 'fixture');
    await fs.mkdir(path.join(dir, 'sub')); await fs.writeFile(path.join(dir, 'sub/other.exe'), 'fixture');
  } });
  const v = manager.instance(manager.state.selected), dir = path.dirname(manager.appDir(v));
  manager.browseExecutable = async (root, options) => { assert.equal(root, dir); assert.equal(options.sameDirectory, true); return path.join(root, 'alternative.exe'); };
  await manager.changeExecutable(v.id); assert.equal(v.exe, 'alternative.exe');
  manager.browseExecutable = async root => path.join(root, 'sub/other.exe');
  await assert.rejects(manager.changeExecutable(v.id), /当前主程序所在目录/);
  assert.equal(v.exe, 'alternative.exe');
  manager.browseExecutable = async () => null;
  await assert.rejects(manager.changeExecutable(v.id), { code: 'EXECUTABLE_SELECTION_CANCELLED' });
  assert.equal(v.exe, 'alternative.exe');
});

test('failed persistence restores previous selection and removes the new instance', async t => {
  const { manager } = await fixture(t), selected = manager.state.selected;
  manager.browseExecutable = async dir => path.join(dir, 'custom.exe');
  manager.save = async () => { throw new Error('写入失败'); };
  await assert.rejects(manager.create({ name: 'Failed', populate: dir => fs.writeFile(path.join(dir, 'custom.exe'), 'fixture') }), /写入失败/);
  await unchanged(manager, selected);
});
