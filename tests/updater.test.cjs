const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const AdmZip = require('adm-zip');
const { Updater, selectRelease, stageArchive, hash } = require('../src/updater.cjs');
const version = '0.2.2';
const name = `Aegisub-Launcher-${version}-Windows-x64.zip`;
const base = 'https://github.com/xiaohaiji/PCLAeg/releases/download/v0.2.2/';
function archive(extra = {}, mutate = () => {}) {
  const files = { 'Aegisub Launcher.exe': Buffer.from('new exe'), 'resources/app.asar': Buffer.from('new runtime'), 'README.md': Buffer.from('new docs'), ...extra };
  const manifest = { schema: 1, version, files: Object.entries(files).map(([file, data]) => ({ path: file, sha256: hash(data) })) };
  mutate(manifest);
  const zip = new AdmZip(); for (const [file, data] of Object.entries(files)) zip.addFile('AegisubLauncher/' + file, data);
  zip.addFile('AegisubLauncher/update-manifest.json', Buffer.from(JSON.stringify(manifest))); return zip.toBuffer();
}
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pclaeg-update-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const target = path.join(root, 'launcher'); await fs.mkdir(target);
  await fs.writeFile(path.join(target, 'README.md'), 'old docs');
  await fs.writeFile(path.join(target, 'state.json'), 'user state');
  await fs.writeFile(path.join(target, 'launcher-paths.json'), 'custom data location');
  await fs.mkdir(path.join(target, 'versions')); await fs.writeFile(path.join(target, 'versions/plugin.lua'), 'personal plugin');
  return { root, target };
}
function release(body) { return { tag_name: 'v' + version, assets: [{ name, browser_download_url: base + name, digest: 'sha256:' + hash(body) }] }; }
test('only official stable newer releases with a Windows asset and checksum are accepted', () => {
  const r = release(archive());
  assert.equal(selectRelease(r, '0.2.1').available, true);
  assert.equal(selectRelease(r, version).available, false);
  assert.equal(selectRelease(r, '0.3.0').available, false);
  assert.throws(() => selectRelease({ ...r, prerelease: true }, '0.2.1'), /稳定/);
  assert.throws(() => selectRelease({ ...r, assets: [{ ...r.assets[0], browser_download_url: 'https://evil.test/package.zip' }] }, '0.2.1'), /官方/);
  assert.throws(() => selectRelease({ ...r, assets: [{ ...r.assets[0], digest: null }] }, '0.2.1'), /校验/);
});
for (const kind of ['user-data', 'manifest-version', 'file-hash', 'omitted-file', 'path-traversal']) {
  test(`archive rejects ${kind} before extraction`, async t => {
    const { root } = await fixture(t);
    const extra = kind === 'user-data' ? { 'versions/personal.lua': Buffer.from('no') } : {};
    const body = archive(extra, m => {
      if (kind === 'manifest-version') m.version = '9.0.0';
      if (kind === 'file-hash') m.files[0].sha256 = '0'.repeat(64);
      if (kind === 'omitted-file') m.files.pop();
      if (kind === 'path-traversal') m.files[0].path = '../outside.exe';
    });
    const file = path.join(root, 'update.zip'), stage = path.join(root, 'stage'); await fs.writeFile(file, body);
    await assert.rejects(stageArchive(file, stage, version));
    await assert.rejects(fs.stat(stage), { code: 'ENOENT' });
  });
}
test('prepare verifies digest, stages only program files and preserves separate data root', async t => {
  const { root, target } = await fixture(t), body = archive();
  const updater = new Updater({ current: '0.2.1', root: path.join(root, 'separate-data'), launcherDir: target, fetcher: async url => url.includes('api.github.com') ? Response.json(release(body)) : new Response(body) });
  const result = await updater.prepare();
  const plan = JSON.parse(await fs.readFile(result.planFile));
  assert.equal(plan.target, await fs.realpath(target));
  assert.ok(result.job.startsWith(path.join(root, 'separate-data')));
  assert.deepEqual(plan.names.sort(), ['Aegisub Launcher.exe', 'README.md', 'resources'].sort());
  assert.equal(await fs.readFile(path.join(target, 'state.json'), 'utf8'), 'user state');
  assert.equal(await fs.readFile(path.join(plan.stage, 'resources/app.asar'), 'utf8'), 'new runtime');
});
test('checksum fallback selects exact asset and corrupted downloads leave no staging job', async t => {
  const { root, target } = await fixture(t), body = archive(), r = release(body); r.assets[0].digest = null;
  r.assets.push({ name: 'SHA256SUMS.txt', browser_download_url: base + 'SHA256SUMS.txt' });
  const updater = new Updater({ current: '0.2.1', root, launcherDir: target, fetcher: async url => url.includes('api.github.com') ? Response.json(r) : url.endsWith('.txt') ? new Response(`${'0'.repeat(64)}  other.zip\n${hash(body)}  ${name}\n`) : new Response(body) });
  await updater.prepare();
  updater.fetcher = async url => url.includes('api.github.com') ? Response.json(release(body)) : new Response('corrupted');
  const jobs = await fs.readdir(path.join(root, 'cache/launcher-updates'));
  await assert.rejects(updater.prepare(), /SHA-256/);
  assert.deepEqual(await fs.readdir(path.join(root, 'cache/launcher-updates')), jobs);
});
for (const fail of [false, true]) test(`Windows update worker ${fail ? 'rolls back a partial replacement' : 'replaces runtime and retains backup'} without modifying instances`, { skip: process.platform !== 'win32' }, async t => {
  const { root, target } = await fixture(t);
  const job = path.join(root, 'job'), stage = path.join(job, 'stage'); await fs.mkdir(stage, { recursive: true });
  await fs.writeFile(path.join(stage, 'README.md'), 'new docs');
  const plan = { schema: 1, pid: 0, version, target, stage, backup: path.join(job, 'backup'), names: ['README.md', ...(fail ? ['missing.dll'] : [])], restart: false };
  const planFile = path.join(job, 'plan.json'); await fs.writeFile(planFile, JSON.stringify(plan));
  const code = await new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.resolve('src/apply-update.ps1'),'-PlanFile',planFile], { windowsHide: true, stdio: 'pipe' });
    let stderr = ''; child.stderr.on('data', s => stderr += s); child.once('error', reject); child.once('exit', code => stderr ? reject(new Error(stderr)) : resolve(code));
  });
  const result = JSON.parse((await fs.readFile(path.join(job, 'result.json'), 'utf8')).replace(/^\uFEFF/, ''));
  assert.equal(code, fail ? 1 : 0, JSON.stringify(result));
  assert.equal(result.status, fail ? 'rolled-back' : 'installed');
  if (fail) assert.match(result.error, /Missing staged runtime file/);
  assert.equal(await fs.readFile(path.join(target, 'README.md'), 'utf8'), fail ? 'old docs' : 'new docs');
  assert.equal(await fs.readFile(path.join(target, 'state.json'), 'utf8'), 'user state');
  assert.equal(await fs.readFile(path.join(target, 'versions/plugin.lua'), 'utf8'), 'personal plugin');
  assert.equal(await fs.readFile(path.join(target, 'launcher-paths.json'), 'utf8'), 'custom data location');
  if (!fail) assert.equal(await fs.readFile(path.join(job, 'backup/README.md'), 'utf8'), 'old docs');
});
