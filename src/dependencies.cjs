const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const semver = require('semver');
const { parse } = require('jsonc-parser');
const { tree } = require('./profiles.cjs');
const BUILTINS = new Set(['ffi', 'bit', 'lpeg', 'lfs', 'math', 'string', 'table', 'io', 'os', 'debug', 'coroutine', 'package', 'utf8', 'unicode', 'moonscript', 'moonscript.base', 'moonscript.version']);
const PROVIDERS = { 'BM.BadMutex': '0.1.3', 'DM.DownloadManager': '0.3.1', 'PT.PreciseTimer': '0.1.6', json: '0.7.0', dkjson: '0.7.0' };
function version(value) {
  if (typeof value === 'number') return Number.isInteger(value) && value >= 0 && value <= 0xffffff ? `${Math.floor(value / 65536) % 256}.${Math.floor(value / 256) % 256}.${value % 256}` : null;
  if (typeof value !== 'string') return null;
  const text = value.replace(/^v/, '');
  return semver.valid(text) || (/^\d+(?:\.\d+){0,2}$/.test(text) ? semver.coerce(text)?.version : null);
}
function range(value) { if (!value) return '*'; const v = version(value); return v ? '>=' + v : typeof value === 'string' ? semver.validRange(value.replace(/~>/g, '~')) : null; }
function satisfies(v, required) { const r = range(required); return !!r && (r === '*' || !!version(v) && semver.satisfies(version(v), r, { includePrerelease: true })); }
function requirement(spec) { if (typeof spec === 'string') return { namespace: spec, version: null }; return { ...spec, namespace: spec.moduleName || spec.namespace || spec.name, version: spec.version || null }; }
function specList(value) { if (!value) return []; if (typeof value === 'string') return [value]; if (Array.isArray(value)) return value.flatMap(specList); if (typeof value === 'object') return value.moduleName || value.namespace || value.name ? [value] : Object.values(value).flatMap(specList); return []; }
function offers(pkg, name, specs) {
  if (pkg.namespace === name) return specs.every(d => satisfies(pkg.version, d.version));
  const provided = (pkg.provides || []).find(a => (typeof a === 'string' ? a : a.name || a.moduleName) === name);
  if (!provided) return false;
  const v = typeof provided === 'string' ? pkg.version : provided.version;
  return specs.every(d => version(v) ? satisfies(v, d.version) : !!semver.validRange(v) && !!range(d.version) && semver.intersects(semver.validRange(v), range(d.version)));
}
const builtin = name => BUILTINS.has(name) || /^aegisub(?:\.|$)/.test(name);
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function extend(Manager, { inside, exists, writeJSON, download, BUNDLED_ROOT }) {
  Manager.prototype.moduleInventory = async function(id) {
    const v = this.instance(id), root = path.dirname(this.appDir(v)), inventory = new Map();
    let config = {}; if (await exists(path.join(root, 'config/l0.DependencyControl.json'))) { const errors = []; config = parse(await fs.readFile(path.join(root, 'config/l0.DependencyControl.json'), 'utf8'), errors, { allowTrailingComma: true }) || {}; if (errors.length) throw new Error('DependencyControl 配置无法读取，请恢复或修复配置'); }
    for (const base of ['automation/include', 'automation/launcher/include']) for (const rel of await tree(root, base)) {
      if (!/\.(lua|moon|dll)$/i.test(rel)) continue;
      const sub = path.relative(base, rel).replace(/\\/g, '/');
      const namespace = sub.replace(/\.(lua|moon|dll)$/i, '').replace(/\/init$/i, '').replace(/\//g, '.');
      const bytes = await fs.readFile(inside(root, path.join(root, rel)));
      const body = /\.(lua|moon)$/i.test(rel) ? bytes.toString('utf8') : '';
      const declared = body.match(/\b(?:script_version\s*=|version\s*[:=])\s*["']([\d.]+(?:-[\w.-]+)?)["']/)?.[1];
      const managed = v.dependencyPackages?.[namespace], native = config.modules?.[namespace];
      const actual = version(declared) || version(managed?.version || native?.version);
      const metadata = version(native?.version) === actual && native ? native : managed || native;
      const requirements = specList(metadata?.requiredModules);
      const known = new Set(requirements.map(requirement).map(r => r.namespace));
      for (const m of body.matchAll(/\brequire\s*\(?\s*["']([\w.-]+)["']/g)) if (!known.has(m[1])) { known.add(m[1]); requirements.push({ moduleName: m[1], inferred: true }); }
      const entry = inventory.get(namespace) || { namespace, paths: [], version: actual, managed: !!managed, modified: false, requiredModules: requirements, provides: specList(metadata?.provides) };
      entry.modified ||= !!managed?.checksums?.[rel] && managed.checksums[rel] !== hash(bytes);
      entry.paths.push({ relative: rel, sha256: hash(bytes), script: !!body }); inventory.set(namespace, entry);
    }
    for (const [namespace, pkg] of Object.entries(v.dependencyPackages || {})) if (pkg.files?.some(file => file.endsWith('.exe')) && !inventory.has(namespace)) inventory.set(namespace, { ...pkg, namespace, managed: true, paths: [] });
    return { inventory, config };
  };
  Manager.prototype.dependencyGraph = async function(id, extra = null) {
    const v = this.instance(id), root = path.dirname(this.appDir(v)), { inventory, config } = await this.moduleInventory(id);
    const nodes = [], edges = [], conflicts = [], requirements = [];
    const active = v.plugins.filter(p => p.kind === 'autoload' && p.enabled && (!extra || p.namespace !== extra.namespace));
    for (const p of active) {
      const body = await fs.readFile(this.pluginPath(v, p), 'utf8');
      const namespace = p.namespace || body.match(/script_namespace\s*=\s*["']([^"']+)/)?.[1] || p.file.replace(/\.(lua|moon)$/i, '');
      const declared = specList(p.requiredModules || config.macros?.[namespace]?.requiredModules);
      const specs = declared.map(requirement).filter(d => d.namespace);
      const found = new Set(specs.map(d => d.namespace));
      for (const m of body.matchAll(/\brequire\s*\(?\s*["']([\w.-]+)["']/g)) if (!found.has(m[1])) { found.add(m[1]); specs.push({ namespace: m[1], version: null, inferred: true }); }
      nodes.push({ id: p.id, type: 'plugin', name: p.name, namespace, version: p.version, enabled: true });
      requirements.push(...specs.map(d => ({ ...d, owner: p.id, ownerName: p.name })));
    }
    if (extra) { nodes.push({ id: 'proposed', type: 'plugin', name: extra.name, namespace: extra.namespace, version: extra.version }); requirements.push(...specList(extra.requiredModules).map(requirement).map(d => ({ ...d, owner: 'proposed', ownerName: extra.name }))); }
    const seenModules = new Set();
    for (let i = 0; i < requirements.length && i < 500; i++) {
      const d = requirements[i]; if (!d.namespace) continue;
      let module = inventory.get(d.namespace), provided = null;
      if (!module) for (const candidate of inventory.values()) {
        const alias = candidate.provides.find(a => (typeof a === 'string' ? a : a.name || a.moduleName) === d.namespace);
        if (alias) { module = candidate; provided = typeof alias === 'string' ? null : alias.version; break; }
      }
      const runtimeProvider = PROVIDERS[d.namespace] && (inventory.has('l0.DependencyControl') || extra?.depctrl);
      const paths = module?.paths || [];
      const duplicate = paths.filter(p => p.script).length > 1 && new Set(paths.filter(p => p.script).map(p => p.sha256)).size > 1;
      const installedVersion = provided || module?.version || (runtimeProvider ? PROVIDERS[d.namespace] : null);
      let status = builtin(d.namespace) ? 'builtin' : runtimeProvider ? satisfies(installedVersion, d.version) ? 'builtin' : 'conflict' : !module ? d.optional ? 'optional' : 'missing' : duplicate ? 'conflict' : d.version && !installedVersion ? 'unknown' : d.version && !(provided && semver.validRange(provided) && semver.intersects(range(d.version) || '*', semver.validRange(provided)) || satisfies(installedVersion, d.version)) ? 'conflict' : 'ready';
      edges.push({ from: d.owner, to: 'module:' + d.namespace, ...d, installedVersion, status });
      if (!seenModules.has(d.namespace)) {
        seenModules.add(d.namespace); nodes.push({ id: 'module:' + d.namespace, type: 'module', name: d.namespace, namespace: d.namespace, version: installedVersion, status, paths, managed: !!module?.managed });
        if (module) requirements.push(...module.requiredModules.map(requirement).map(spec => ({ ...spec, owner: 'module:' + d.namespace, ownerName: d.namespace })));
      }
      if (status === 'conflict') conflicts.push({ namespace: d.namespace, owner: d.ownerName, message: duplicate ? `${d.namespace} 有不同内容的重复模块` : `${d.ownerName} 需要 ${d.namespace} ${d.version}，当前 ${installedVersion}` });
    }
    for (const node of nodes.filter(n => n.type === 'module')) {
      const related = edges.filter(e => e.to === node.id); node.consumers = related.map(e => e.ownerName);
      if (related.some(e => e.status === 'conflict')) node.status = 'conflict'; else if (related.some(e => e.status === 'missing')) node.status = 'missing';
    }
    return { id, nodes, edges, conflicts, requirements, modules: [...inventory.values()], missing: edges.filter(e => e.status === 'missing' && !e.inferred), unknown: edges.filter(e => e.status === 'unknown') };
  };
  Manager.prototype.planDependencies = async function(id, entry = null, replaceUnmanaged = false) {
    this.ensureStopped(id);
    const graph = await this.dependencyGraph(id, entry), { inventory } = await this.moduleInventory(id);
    const feeds = new Map((this.state.pluginFeeds || []).flatMap(f => [f.url, f.manifestUrl].filter(Boolean).map(url => [url, f])));
    const fetched = new Set(), chosen = new Map(), requested = graph.requirements.filter(d => !d.inferred && !d.optional);
    const lookup = async url => {
      if (!url || fetched.has(url)) return; fetched.add(url);
      if (fetched.size > 16) throw new Error('依赖源过多，请先添加相关订阅再安装');
      if (!feeds.has(url)) { const feed = await this.readPluginSource(url, 'auto', true); feeds.set(url, feed); }
    };
    if (entry?.feedUrl) await lookup(entry.feedUrl);
    for (let round = 0; round < 20; round++) {
      let changed = false;
      const groups = new Map(); for (const d of requested) if (d.namespace && !builtin(d.namespace) && !(PROVIDERS[d.namespace] && satisfies(PROVIDERS[d.namespace], d.version))) { const specs = groups.get(d.namespace) || []; specs.push(d); groups.set(d.namespace, specs); }
      for (const [name, specs] of groups) {
        if (!/^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$/u.test(name)) throw new Error(`依赖名称无效：${name}`);
        const installed = inventory.get(name) || [...inventory.values()].find(p => offers(p, name, specs));
        if (installed?.paths.filter(p => p.script).length > 1 && new Set(installed.paths.filter(p => p.script).map(p => p.sha256)).size > 1) throw new Error(`${name} 有重复模块，请先选择保留的文件`);
        if (installed && offers(installed, name, specs)) continue;
        if (installed?.modified && !replaceUnmanaged) throw new Error(`${name} 已被手动编辑，请先预览替换，不能自动覆盖`);
        if (installed && !installed.managed && !replaceUnmanaged) throw new Error(`${name} 的现有模块版本不满足要求或未知；请在依赖管理中预览替换，不能自动覆盖手动模块`);
        for (const d of specs) if (d.feed) await lookup(d.feed);
        let candidates = [...new Set(feeds.values())].flatMap(f => f.packages).filter(p => p.section === 'modules' && offers(p, name, specs));
        if (!candidates.length) {
          const references = [...new Set(feeds.values())].flatMap(f => f.knownFeeds || []).filter(f => !feeds.has(f.url));
          for (const ref of references.slice(0, Math.max(0, 16 - fetched.size))) { try { await lookup(ref.url); } catch (e) { if (this.abort?.signal.aborted) throw e; } }
          candidates = [...new Set(feeds.values())].flatMap(f => f.packages).filter(p => p.section === 'modules' && offers(p, name, specs));
        }
        candidates.sort((a, b) => semver.rcompare(version(a.version) || '0.0.0', version(b.version) || '0.0.0'));
        const preferred = specs.find(d => d.feed)?.feed;
        const candidate = candidates.find(p => p.feedUrl === preferred) || candidates[0];
        if (!candidate) throw new Error(`找不到兼容依赖：${name}（${specs.map(d => `${d.ownerName}: ${d.version || '*'}`).join('；')}）`);
        if (chosen.get(name)?.id === candidate.id && chosen.get(name)?.version === candidate.version) continue;
        chosen.set(name, candidate); changed = true;
        for (const spec of candidate.requiredModules || []) { const d = requirement(spec); if (!d.optional && !requested.some(x => x.ownerName === candidate.namespace && x.namespace === d.namespace && x.version === d.version)) requested.push({ ...d, owner: 'module:' + candidate.namespace, ownerName: candidate.namespace }); }
      }
      if (!changed) break;
      if (round === 19) throw new Error('依赖关系无法收敛，安装已停止');
    }
    // Recheck every chosen version against all consumers after transitive requirements were added.
    for (const [name, candidate] of chosen) if (!offers(candidate, name, requested.filter(d => d.namespace === name))) throw new Error(`${name} 的版本要求相互冲突`);
    const unique = new Map(); for (const pkg of chosen.values()) { if (unique.has(pkg.namespace) && unique.get(pkg.namespace).version !== pkg.version) throw new Error(`${pkg.namespace} 的提供者版本相互冲突`); unique.set(pkg.namespace, pkg); }
    return { id, modules: [...unique.values()], replacing: [...unique.keys()].filter(name => inventory.has(name)), requirements: requested, replaceUnmanaged };
  };
  Manager.prototype.applyDependencyPlan = async function(id, plan) {
    const v = this.instance(id), root = path.dirname(this.appDir(v));
    const staging = inside(path.join(this.root, 'cache/downloads'), path.join(this.root, 'cache/downloads', crypto.randomUUID())); await fs.mkdir(staging);
    try {
      const staged = [];
      for (const pkg of plan.modules) for (const file of pkg.files) {
        const temp = path.join(staging, String(staged.length));
        await download(file.url, temp, p => this.progress({ label: `安装依赖 ${pkg.namespace} ${pkg.version}`, ...p }), 20 * 1024 ** 2, this.fetcher, this.abort?.signal);
        const bytes = await fs.readFile(temp); if (file.sha1 && crypto.createHash('sha1').update(bytes).digest('hex') !== file.sha1) throw new Error(`依赖校验失败：${file.relative}`);
        if (/^\s*<!doctype|^\s*<html/i.test(bytes.toString('utf8', 0, 128))) throw new Error('依赖下载返回了网页');
        staged.push({ temp, pkg, file });
      }
      const { inventory } = await this.moduleInventory(id);
      const byPath = new Map();
      for (const item of staged) { const relative = path.join('automation/include', item.file.relative), bytes = await fs.readFile(item.temp), digest = hash(bytes); if (byPath.has(relative) && byPath.get(relative) !== digest) throw new Error(`依赖包对同一文件声明了不同内容：${relative}`); byPath.set(relative, digest); }
      for (const pkg of plan.modules) {
        const previous = [...(inventory.get(pkg.namespace)?.paths || []).map(p => p.relative), ...(v.dependencyPackages?.[pkg.namespace]?.files || [])];
        for (const file of new Set(previous)) {
          const otherOwner = Object.entries(v.dependencyPackages || {}).find(([name, record]) => name !== pkg.namespace && !plan.modules.some(p => p.namespace === name) && record.files?.includes(file));
          if (otherOwner && byPath.has(file) && await exists(path.join(root, file)) && hash(await fs.readFile(path.join(root, file))) !== byPath.get(file)) throw new Error(`${file} 还被 ${otherOwner[0]} 共用，不能覆盖`);
          if (!otherOwner) await fs.rm(inside(root, path.join(root, file)), { force: true });
        }
      }
      v.dependencyPackages ||= {};
      for (const { temp, pkg, file } of staged) { const dest = inside(root, path.join(root, 'automation/include', file.relative)); await fs.mkdir(path.dirname(dest), { recursive: true }); await fs.copyFile(temp, dest); }
      for (const pkg of plan.modules) { const checksums = {}; for (const f of pkg.files) { const relative = path.join('automation/include', f.relative); checksums[relative] = hash(await fs.readFile(path.join(root, relative))); } v.dependencyPackages[pkg.namespace] = { namespace: pkg.namespace, version: pkg.version, feed: pkg.feedUrl, channel: pkg.channel, provides: pkg.provides, requiredModules: pkg.requiredModules, checksums, files: pkg.files.map(f => path.join('automation/include', f.relative)) }; }
      const configFile = path.join(root, 'config/l0.DependencyControl.json');
      const errors = [];
      const cfg = await exists(configFile) ? parse(await fs.readFile(configFile, 'utf8'), errors, { allowTrailingComma: true }) || {} : {};
      if (errors.length) throw new Error('DependencyControl 配置无法读取，请恢复或修复配置');
      cfg.modules ||= {};
      for (const pkg of plan.modules) cfg.modules[pkg.namespace] = { ...cfg.modules[pkg.namespace], moduleName: pkg.namespace, name: pkg.name, version: pkg.version, feed: pkg.feedUrl, userFeed: pkg.feedUrl, activeChannel: pkg.channel, requiredModules: pkg.requiredModules, provides: pkg.provides, recordType: 'managed' };
      await writeJSON(configFile, cfg); await this.scanInstance(v); await this.save();
    } finally { await fs.rm(staging, { recursive: true, force: true }); }
  };
  Manager.prototype.repairDependencies = async function(id, replaceUnmanaged = false) {
    const plan = await this.planDependencies(id, null, replaceUnmanaged);
    return this.profileTransaction([id], '修复插件依赖', async () => { await this.applyDependencyPlan(id, plan); const graph = await this.dependencyGraph(id); if (graph.conflicts.length || graph.missing.length) throw new Error('依赖仍有冲突或缺失，修复已回滚'); });
  };
  Manager.prototype.resolveModuleDuplicate = async function(id, namespace, keepPath) {
    this.ensureStopped(id); const { inventory } = await this.moduleInventory(id), module = inventory.get(namespace);
    if (!module || !module.paths.some(p => p.relative === keepPath)) throw new Error('模块文件选择无效');
    return this.profileTransaction([id], `解决 ${namespace} 重复模块`, async () => {
      const root = path.dirname(this.appDir(this.instance(id)));
      for (const item of module.paths) if (item.relative !== keepPath) await fs.rm(inside(root, path.join(root, item.relative)), { force: true });
      await this.scanInstance(this.instance(id)); const graph = await this.dependencyGraph(id); if (graph.conflicts.some(c => c.namespace === namespace)) throw new Error('保留的模块不满足所有插件，操作已回滚'); await this.save();
    });
  };
  const install = Manager.prototype.installFeedPlugin;
  Manager.prototype.installFeedPlugin = async function(id, entry) {
    const plan = await this.planDependencies(id, entry);
    return this.profileTransaction([id], '安装 DC 插件与依赖', async () => { await this.applyDependencyPlan(id, plan); await install.call(this, id, entry); const graph = await this.dependencyGraph(id); if (graph.conflicts.length) throw new Error(`依赖冲突，安装已回滚：${graph.conflicts[0].message}`); });
  };
  for (const method of ['togglePlugin', 'removePlugin']) {
    const original = Manager.prototype[method];
    Manager.prototype[method] = async function(id, pluginId) {
      const v = this.instance(id), p = v.plugins.find(p => p.id === pluginId);
      if (p?.kind === 'include' && (method === 'removePlugin' || p.enabled)) {
        const graph = await this.dependencyGraph(id);
        const rel = path.relative(path.dirname(this.appDir(v)), this.pluginPath(v, p));
        const used = graph.nodes.find(n => n.type === 'module' && n.paths.some(file => file.relative === rel) && n.consumers?.length);
        if (used) throw new Error(`${used.namespace} 被 ${used.consumers.join('、')} 使用，请先禁用相关插件`);
      }
      return original.call(this, id, pluginId);
    };
  }
}
module.exports = { extend, version, range, satisfies };
