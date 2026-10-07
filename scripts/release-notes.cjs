const fs = require('node:fs');
const { version } = require('../package.json');
const changelog = fs.readFileSync('CHANGELOG.md', 'utf8');
const start = changelog.indexOf(`## ${version}`);
if (start < 0) throw new Error('Missing changelog for this version');
const section = changelog.slice(start).split(/\n## /)[0];
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/release-notes.md', `${section}\n\n## 下载与升级\n\n下载 Windows-x64.zip，完整解压后运行 AegisubLauncher/Aegisub Launcher.exe。Source code 是源码，不能直接运行。SHA256SUMS.txt 提供校验值。\n\n0.2.1 开始支持设置中的“检查更新 / 一键更新”，保留实例、配置、插件与数据目录设置，退出后替换程序并重启，替换失败回滚。0.2.0 首次升级需要手动覆盖程序文件；请关闭启动器和 Aegisub，备份原目录并保留 versions、cache、state.json、launcher-paths.json。\n\n插件目录包含内置与在线条目；Aegisub 本体需下载或导入。第三方组件遵循各自许可。\n`);
