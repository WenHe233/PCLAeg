const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const exec = require('node:util').promisify(execFile);
function parseReleaseUrl(input) {
  const url = new URL(input.trim());
  const parts = url.pathname.split('/').filter(Boolean);
  if (url.protocol !== 'https:' || url.hostname !== 'github.com' || parts.length < 2 || parts.length > 2 && parts[2] !== 'releases' || !parts.slice(0, 2).every(p => /^[\w.-]+$/.test(p))) throw new Error('请输入 GitHub 仓库或 Releases 页的 HTTPS 地址');
  return parts.slice(0, 2).join('/');
}
async function registryScan() {
  if (process.platform !== 'win32') return [];
  const code = String.raw`$result = @();
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
      Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Aegisub' } | ForEach-Object { if ($_.InstallLocation) { $result += $_.InstallLocation }; if ($_.DisplayIcon) { $result += ($_.DisplayIcon -replace ',[0-9]+$','').Trim('"') } }
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^aegisub[0-9]*\.exe$' } | ForEach-Object { if ($_.ExecutablePath) { $result += $_.ExecutablePath } }
    @($result | Select-Object -Unique) | ConvertTo-Json -Compress`;
  try { const { stdout } = await exec('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', code], { windowsHide: true, timeout: 10000 }); const result = stdout.trim() ? JSON.parse(stdout) : []; return Array.isArray(result) ? result : [result]; } catch { return []; }
}
async function scanExecutables(roots, excluded, getVersion, maxDirs = 12000) {
  const queue = roots.map(dir => ({ dir: path.resolve(dir), depth: 0 })), visited = new Set(), candidates = [];
  const start = Date.now(); let truncated = false;
  for (let i = 0; i < queue.length; i++) {
    if (visited.size >= maxDirs || Date.now() - start > 30000) { truncated = true; break; }
    const { dir, depth } = queue[i], key = dir.toLowerCase();
    if (visited.has(key) || excluded.some(root => key === root.toLowerCase() || key.startsWith(root.toLowerCase() + path.sep))) continue;
    visited.add(key);
    let entries; try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { continue; }
    for (const ent of entries) {
      if (ent.isSymbolicLink()) continue;
      const file = path.join(dir, ent.name);
      if (ent.isFile() && /^aegisub(?:\d+)?\.exe$/i.test(ent.name)) candidates.push({ file, directory: dir, version: await getVersion(file), name: path.basename(dir) });
      else if (depth < 5 && ent.isDirectory() && !/^(node_modules|\.git|\.test-data|cache|trash|windows|system32|winsxs|\$recycle.bin|system volume information)$/i.test(ent.name)) queue.push({ dir: file, depth: depth + 1 });
    }
  }
  return { candidates, scanned: visited.size, truncated };
}
function associationValues(executable, prefix = []) {
  const quoted = value => { if (typeof value !== 'string' || /["\x00\r\n]/.test(value)) throw new Error('应用路径无效'); return `"${value}"`; };
  const command = [quoted(executable), ...prefix.map(quoted), '--open-ass', '"%1"'].join(' ');
  return [
    ['HKCU\\Software\\Classes\\PCLAeg.ASS', '', 'ASS 字幕（Aegisub Launcher）'],
    ['HKCU\\Software\\Classes\\PCLAeg.ASS\\DefaultIcon', '', quoted(executable) + ',0'],
    ['HKCU\\Software\\Classes\\PCLAeg.ASS\\shell\\open\\command', '', command],
    ['HKCU\\Software\\Classes\\.ass\\OpenWithProgids', 'PCLAeg.ASS', ''],
    ['HKCU\\Software\\Classes\\.ssa\\OpenWithProgids', 'PCLAeg.ASS', ''],
    ['HKCU\\Software\\PCLAeg\\Capabilities', 'ApplicationName', 'Aegisub Launcher'],
    ['HKCU\\Software\\PCLAeg\\Capabilities', 'ApplicationDescription', '使用启动器中指定的 Aegisub 实例打开字幕'],
    ['HKCU\\Software\\PCLAeg\\Capabilities\\FileAssociations', '.ass', 'PCLAeg.ASS'],
    ['HKCU\\Software\\PCLAeg\\Capabilities\\FileAssociations', '.ssa', 'PCLAeg.ASS'],
    ['HKCU\\Software\\RegisteredApplications', 'Aegisub Launcher', 'Software\\PCLAeg\\Capabilities']
  ];
}
async function registerAssociation(executable, prefix = [], runner = exec) {
  if (process.platform !== 'win32') throw new Error('文件关联仅支持 Windows');
  for (const [key, name, value] of associationValues(executable, prefix)) await runner('reg.exe', ['add', key, name ? '/v' : '/ve', ...(name ? [name] : []), '/t', 'REG_SZ', '/d', value, '/f'], { windowsHide: true });
}
function extend(Manager, { inside, exists, writeJSON, executableVersion }) {
  Manager.prototype.addReleaseSource = async function(input) {
    const repo = parseReleaseUrl(input), key = 'github-' + crypto.createHash('sha256').update(repo.toLowerCase()).digest('hex').slice(0, 12);
    const response = await this.fetcher(`https://api.github.com/repos/${repo}`, { headers: { 'User-Agent': 'PCLAeg', Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`找不到或无法访问仓库：HTTP ${response.status}`);
    const metadata = await response.json();
    const existing = Object.entries(this.sources()).find(([, info]) => info.repo.toLowerCase() === repo.toLowerCase());
    if (existing) return { ...this.snapshot(), addedSource: existing[0] };
    this.state.releaseSources ||= {}; this.state.releaseSources[key] = { repo: metadata.full_name || repo, name: metadata.full_name || repo, url: `https://github.com/${repo}/releases`, custom: true };
    await this.save(); return { ...this.snapshot(), addedSource: key };
  };
  Manager.prototype.removeReleaseSource = async function(sourceId) { if (!this.state.releaseSources?.[sourceId]) throw new Error('内置发布源不能移除'); delete this.state.releaseSources[sourceId]; await this.save(); return this.snapshot(); };
  Manager.prototype.scanLocalVersions = async function(extraRoots = []) {
    if (this.localScanning) return this.localScanning;
    this.localScanning = (async () => {
      const roots = [...extraRoots, ...(extraRoots.length ? [] : await registryScan())];
      if (!extraRoots.length) {
        for (const env of ['ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'USERPROFILE']) if (process.env[env]) {
          const base = process.env[env];
          if (/USERPROFILE|LOCALAPPDATA/.test(env)) for (const sub of ['Programs', 'Desktop', 'Downloads', 'Documents']) roots.push(path.join(base, sub));
          else roots.push(base);
        }
        for (const dir of (process.env.PATH || '').split(path.delimiter)) if (/aegisub/i.test(dir)) roots.push(dir);
        if (process.platform === 'win32') for (const drive of ['C:', 'D:', 'E:', 'F:', 'G:']) {
          try { for (const ent of await fs.readdir(drive + path.sep, { withFileTypes: true })) if (ent.isDirectory() && /aegisub|字幕|tools|program|app|软件|^zi$/i.test(ent.name)) roots.push(path.join(drive + path.sep, ent.name)); } catch {}
        }
      }
      const valid = []; for (const root of roots) try { const stat = await fs.stat(root); valid.push(stat.isFile() ? path.dirname(root) : root); } catch {}
      const result = await scanExecutables([...new Set(valid)], [this.root, path.resolve(__dirname, '..', '.test-data')], executableVersion);
      this.localVersions = result.candidates.map(item => ({ ...item, token: crypto.randomUUID(), imported: this.state.instances.some(v => v.importOrigin?.toLowerCase() === item.file.toLowerCase()), possibleDuplicate: this.state.instances.some(v => item.version && v.executableVersion === item.version) }));
      this.localScan = { scanned: result.scanned, truncated: result.truncated, completed: new Date().toISOString() };
      this.progress({ label: `扫描完成，找到 ${this.localVersions.length} 个本机 Aegisub`, stateChanged: true }); return this.snapshot();
    })();
    try { return await this.localScanning; } finally { this.localScanning = null; }
  };
  Manager.prototype.importLocalCandidate = async function(token, name) {
    const candidate = this.localVersions?.find(c => c.token === token); if (!candidate) throw new Error('扫描结果已过期，请重新扫描');
    if (candidate.imported) throw new Error('此程序已经导入');
    const rel = path.relative(candidate.directory, this.root); if (!rel || !rel.startsWith('..') && !path.isAbsolute(rel)) throw new Error('不能导入包含启动器数据的目录');
    await this.create({ name: name || candidate.name, preferredExe: path.basename(candidate.file), populate: dest => fs.cp(candidate.directory, dest, { recursive: true, filter: async file => !(await fs.lstat(file)).isSymbolicLink() }) });
    this.instance(this.state.selected).importOrigin = candidate.file; candidate.imported = true; await this.save(); return this.snapshot();
  };
  const remove = Manager.prototype.remove;
  Manager.prototype.remove = async function(id) {
    await remove.call(this, id);
    if (this.state.preferences.defaultAss === id) this.state.preferences.defaultAss = null;
    for (const point of this.state.restorePoints) {
      const base = inside(path.join(this.root, 'cache/restore-points'), path.join(this.root, 'cache/restore-points', point.id));
      await fs.rm(inside(base, path.join(base, id)), { recursive: true, force: true }); point.records = point.records.filter(r => r.instanceId !== id);
      if (point.records.length) await writeJSON(path.join(base, 'point.json'), point); else await fs.rm(base, { recursive: true, force: true });
    }
    this.state.restorePoints = this.state.restorePoints.filter(p => p.records.length); await this.save(); return this.snapshot();
  };
}
module.exports = { extend, parseReleaseUrl, scanExecutables, associationValues, registerAssociation };
