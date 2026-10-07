const fs = require('node:fs');
const path = require('node:path');

function resolveStorage({ packaged, executable, portableDir, testRoot, projectRoot }) {
  const launcherDir = path.resolve(packaged ? portableDir || path.dirname(executable) : projectRoot);
  const configFile = path.join(launcherDir, 'launcher-paths.json');
  if (!packaged && testRoot) return { root: path.resolve(testRoot), launcherDir, configFile };
  let root = launcherDir;
  if (fs.existsSync(configFile)) {
    const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
    if (typeof config.dataRoot !== 'string' || !config.dataRoot.trim()) throw new Error('launcher-paths.json 的 dataRoot 无效');
    root = path.resolve(launcherDir, config.dataRoot);
  }
  return { root, launcherDir, configFile };
}

function configureStorage(app, root) {
  const paths = {
    userData: path.join(root, 'cache', 'runtime'),
    sessionData: path.join(root, 'cache', 'browser'),
    crashDumps: path.join(root, 'cache', 'crashdumps'),
    temp: path.join(root, 'cache', 'temp')
  };
  for (const [name, dir] of Object.entries(paths)) { fs.mkdirSync(dir, { recursive: true }); app.setPath(name, dir); }
  app.commandLine.appendSwitch('disk-cache-dir', path.join(root, 'cache', 'browser', 'http'));
  process.env.TEMP = paths.temp;
  process.env.TMP = paths.temp;
}

async function migrateLibrary(root, legacyRoots) {
  const io = fs.promises;
  const target = path.join(root, 'state.json');
  if (fs.existsSync(target)) return;
  for (const legacy of legacyRoots) {
    if (path.resolve(legacy) === path.resolve(root) || !fs.existsSync(path.join(legacy, 'state.json'))) continue;
    const state = JSON.parse(await io.readFile(path.join(legacy, 'state.json'), 'utf8'));
    if (!state.instances?.length) continue;
    await io.mkdir(root, { recursive: true });
    for (const folder of ['instances', 'versions', 'trash']) {
      const from = path.join(legacy, folder);
      if (fs.existsSync(from)) await io.cp(from, path.join(root, folder), { recursive: true, errorOnExist: true, force: false });
    }
    await io.copyFile(path.join(legacy, 'state.json'), target, fs.constants.COPYFILE_EXCL);
    return;
  }
}
async function relocateLibrary(oldRoot, newRoot, configFile) {
  const io = fs.promises;
  oldRoot = path.resolve(oldRoot); newRoot = path.resolve(newRoot);
  if (oldRoot === newRoot) return false;
  const relative = path.relative(oldRoot, newRoot);
  if (!relative.startsWith('..') && !path.isAbsolute(relative)) throw new Error('新目录不能位于当前数据目录内部');
  if (fs.existsSync(path.join(newRoot, 'state.json'))) throw new Error('所选目录已有启动器数据，请选择其他目录');
  for (const name of ['versions', 'instances', 'trash']) {
    const dest = path.join(newRoot, name);
    if (fs.existsSync(dest) && (await io.readdir(dest)).length) throw new Error('目标版本目录不是空目录，请选择其他位置');
  }
  await migrateLibrary(newRoot, [oldRoot]);
  // Empty libraries still need an index at the new location.
  await io.mkdir(newRoot, { recursive: true });
  if (!fs.existsSync(path.join(newRoot, 'state.json'))) await io.copyFile(path.join(oldRoot, 'state.json'), path.join(newRoot, 'state.json'));
  const state = JSON.parse(await io.readFile(path.join(newRoot, 'state.json'), 'utf8'));
  for (const v of state.instances) await io.access(path.join(newRoot, 'versions', v.folder || v.id, v.exe));
  const temp = configFile + '.tmp';
  await io.writeFile(temp, JSON.stringify({ dataRoot: newRoot }, null, 2));
  await io.rename(temp, configFile);
  return true;
}
module.exports = { resolveStorage, configureStorage, migrateLibrary, relocateLibrary };
