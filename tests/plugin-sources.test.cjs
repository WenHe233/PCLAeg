const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { loadSource, parseList } = require('../src/plugin-sources.cjs');
const { Manager } = require('../src/core.cjs');
const blobHash = body => crypto.createHash('sha1').update(`blob ${body.length}\0`).update(body).digest('hex');

test('generic source auto-detects Unicode raw scripts and GitHub file pages', async () => {
  const text = 'export script_name = "字幕工具"\nexport script_version = "2.0"';
  const raw = 'https://raw.githubusercontent.com/user/repo/main/%E5%AD%97%E5%B9%95.lua';
  let requested;
  const source = await loadSource('https://github.com/user/repo/blob/main/%E5%AD%97%E5%B9%95.lua', 'auto', async url => { requested = url; return text; });
  assert.equal(requested, raw); assert.equal(source.type, 'script');
  assert.equal(source.packages[0].name, '字幕工具'); assert.equal(source.packages[0].file, '字幕.lua');
  assert.equal(source.packages[0].version, '2.0');
});
test('JSON plugin lists accept relative and absolute links with stable identities and digest metadata', () => {
  const url = 'https://example.com/sources/plugins.json';
  const feed = parseList({ name: 'Custom', plugins: [{ name: 'Script', file: '字幕.moon', url: '../scripts/test.moon', sha256: 'a'.repeat(64) }] }, url);
  assert.equal(feed.name, 'Custom'); assert.equal(feed.packages[0].url, 'https://example.com/scripts/test.moon');
  assert.equal(feed.packages[0].sha256, 'a'.repeat(64));
  const first = parseList(['https://example.com/a.lua', 'https://example.com/b.lua'], url);
  const reverse = parseList(['https://example.com/b.lua', 'https://example.com/a.lua'], url);
  assert.equal(first.packages[0].id, reverse.packages[1].id);
  assert.throws(() => parseList([{ url: 'https://example.com/a.lua', file: '../a.lua' }], url), /文件名/);
  assert.throws(() => parseList([{ url: 'http://example.com/a.lua' }], url), /HTTPS/);
  assert.throws(() => parseList([{ name: 'Missing URL' }], url), /缺少/);
  assert.throws(() => parseList(['https://example.com/a.lua', 'https://other.com/a.lua'], url), /重复/);
});
test('GitHub repository sources use the real default branch, filter helpers and preserve download integrity data', async () => {
  const requests = [];
  const source = await loadSource('https://github.com/user/repo', 'auto', async url => {
    requests.push(url);
    if (url === 'https://api.github.com/repos/user/repo') return JSON.stringify({ default_branch: 'dev', html_url: 'https://github.com/user/repo' });
    assert.equal(url, 'https://api.github.com/repos/user/repo/git/trees/dev?recursive=1');
    return JSON.stringify({ tree: [
      { type: 'blob', path: 'macros/tool.lua', sha: 'a'.repeat(40), mode: '100644' },
      { type: 'blob', path: 'include/helper.lua', mode: '100644' },
      { type: 'blob', path: 'tests/test.lua', mode: '100644' },
      { type: 'blob', path: 'macros/link.lua', mode: '120000' },
      { type: 'blob', path: 'build.lua', mode: '100644' }
    ] });
  });
  assert.equal(requests.length, 2); assert.equal(source.type, 'github'); assert.equal(source.packages.length, 1);
  assert.equal(source.packages[0].url, 'https://raw.githubusercontent.com/user/repo/dev/macros/tool.lua');
  assert.equal(source.packages[0].gitBlobSha, 'a'.repeat(40));
});
test('GitHub directory resolves slash-containing refs and restricts scripts to that directory', async () => {
  const source = await loadSource('https://github.com/user/repo/tree/feature/tools/macros', 'github', async url => {
    if (url === 'https://api.github.com/repos/user/repo') return JSON.stringify({ default_branch: 'main' });
    if (url === 'https://api.github.com/repos/user/repo/git/trees/feature%2Ftools?recursive=1') return JSON.stringify({ tree: [
      { type: 'blob', path: 'macros/tool.moon', mode: '100644' },
      { type: 'blob', path: 'other/tool.lua', mode: '100644' }
    ] });
    const error = new Error('Missing ref'); error.status = 404; throw error;
  });
  assert.equal(source.packages.length, 1);
  assert.equal(source.packages[0].url, 'https://raw.githubusercontent.com/user/repo/feature%2Ftools/macros/tool.moon');
});
test('GitHub auto detection keeps DependencyControl origin for updates; explicit GitHub type lists scripts', async () => {
  const manifest = { dependencyControlFeedFormatVersion: '0.3.0', name: 'DC source', fileBaseUrl: 'https://example.com', macros: {
    'test.Tool': { channels: { stable: { default: true, version: '1.0.0', files: [{ name: '.lua', url: '@{fileBaseUrl}/test.Tool.lua' }] } } }
  } };
  const reader = async url => {
    if (url.endsWith('/user/repo')) return JSON.stringify({ default_branch: 'main' });
    if (url.includes('/git/trees/')) return JSON.stringify({ tree: [{ type: 'blob', path: 'DependencyControl.json' }, { type: 'blob', path: 'macros/test.Tool.lua' }] });
    return '\uFEFF' + JSON.stringify(manifest);
  };
  const source = await loadSource('https://github.com/user/repo', 'auto', reader);
  assert.equal(source.type, 'depctrl'); assert.equal(source.url, 'https://github.com/user/repo');
  assert.equal(source.packages[0].sourceUrl, source.url);
  assert.equal(source.packages[0].feedUrl, 'https://raw.githubusercontent.com/user/repo/main/DependencyControl.json');
  const plain = await loadSource('https://github.com/user/repo', 'github', reader);
  assert.equal(plain.type, 'github'); assert.equal(plain.packages.length, 1);
});
test('Gist sources discover Lua/MoonScript files and reject incomplete inventories', async () => {
  const source = await loadSource('https://gist.github.com/user/abc123', 'auto', async url => {
    assert.equal(url, 'https://api.github.com/gists/abc123');
    return JSON.stringify({ description: 'Tools', files: { 'tool.lua': { filename: 'tool.lua', raw_url: 'https://gist.githubusercontent.com/user/abc123/raw/tool.lua' }, 'readme.txt': { filename: 'readme.txt' } } });
  });
  assert.equal(source.name, 'Tools'); assert.equal(source.packages.length, 1);
  await assert.rejects(loadSource('https://gist.github.com/user/abc123', 'auto', async () => JSON.stringify({ truncated: true })), /不完整/);
});
test('unrecognized HTML and invalid source types explain the accepted inputs', async () => {
  await assert.rejects(loadSource('https://example.com/page', 'auto', async () => '<html>page</html>'), /网页/);
  await assert.rejects(loadSource('https://example.com/feed', 'unknown', async () => ''), /类型无效/);
});
test('generic source persistence, integrity, refresh, update and removal keep installed versions independent', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-sources-')); t.after(() => fs.rm(root, { recursive: true, force: true }));
  const body = Buffer.from('script_name="Tool"\nscript_version="1.0.0"\n-- 字幕');
  let url = 'https://example.com/v1/字幕.lua', corrupted = false;
  const feedUrl = 'https://example.com/plugins.json';
  const manager = new Manager(root, () => {}, async request => request === feedUrl
    ? Response.json({ name: 'Custom', plugins: [{ url, file: '字幕.lua', sha256: crypto.createHash('sha256').update(body).digest('hex') }] })
    : new Response(corrupted ? Buffer.from('bad') : body));
  await manager.init(); await manager.create({ name: 'Target', populate: dir => fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture') });
  await manager.addPluginFeed(feedUrl); const entry = manager.catalog().find(p => p.sourcePlugin), id = manager.state.selected;
  assert.equal(manager.state.pluginFeeds[0].type, 'json');
  await manager.addPlugin(id, { catalogId: entry.id });
  const plugin = manager.instance(id).plugins.find(p => p.file === '字幕.lua');
  assert.equal(plugin.feedUrl, feedUrl); assert.equal(plugin.sourcePlugin, true);
  assert.ok((await fs.readFile(manager.pluginPath(manager.instance(id), plugin))).equals(body));
  url = 'https://example.com/v2/字幕.lua'; await manager.addPluginFeed(feedUrl);
  assert.equal(manager.catalog().find(p => p.sourcePlugin).id, entry.id);
  await manager.addPlugin(id, { catalogId: entry.id });
  assert.equal(manager.instance(id).plugins.find(p => p.id === plugin.id).url, new URL(url).href);
  corrupted = true;
  await assert.rejects(manager.addPlugin(id, { catalogId: entry.id }), /SHA-256/);
  assert.ok((await fs.readFile(manager.pluginPath(manager.instance(id), plugin))).equals(body));
  const restored = new Manager(root); await restored.init(); assert.equal(restored.state.pluginFeeds[0].type, 'json');
  await manager.removePluginFeed(feedUrl); assert.equal(manager.catalog().length, 64);
  assert.ok(manager.instance(id).plugins.find(p => p.id === plugin.id));
});
test('GitHub blob hash verifies original bytes including non-UTF8 scripts before replacing files', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-blob-')); t.after(() => fs.rm(root, { recursive: true, force: true }));
  const body = Buffer.from([45, 45, 32, 0xff, 10]);
  const manager = new Manager(root, () => {}, async request => {
    if (request === 'https://api.github.com/repos/user/repo') return Response.json({ default_branch: 'main' });
    if (request.includes('/git/trees/')) return Response.json({ tree: [{ type: 'blob', path: 'test.lua', sha: blobHash(body) }] });
    return new Response(body);
  });
  await manager.init(); await manager.create({ name: 'Target', populate: dir => fs.writeFile(path.join(dir, 'aegisub.exe'), 'fixture') });
  await manager.addPluginFeed('https://github.com/user/repo');
  await manager.addPlugin(manager.state.selected, { catalogId: manager.catalog().find(p => p.sourcePlugin).id });
  const v = manager.instance(manager.state.selected); assert.ok((await fs.readFile(manager.pluginPath(v, v.plugins[0]))).equals(body));
});
