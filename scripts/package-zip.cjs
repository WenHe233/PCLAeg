const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const AdmZip = require('adm-zip');
const root = path.resolve(__dirname, '..');
const version = require('../package.json').version;
const source = path.resolve(root, process.argv[2] || 'dist/win-unpacked');
if (!fs.existsSync(path.join(source, 'Aegisub Launcher.exe'))) throw new Error('Build the Windows directory first.');
const excluded = new Set(['cache', 'versions', 'instances', 'trash', 'state.json', 'state.json.tmp', 'launcher-paths.json']);
const zip = new AdmZip();
for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
  if (excluded.has(entry.name) || ['README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md', 'docs'].includes(entry.name)) continue;
  const file = path.join(source, entry.name);
  if (entry.isSymbolicLink()) throw new Error('Symlinks are not allowed in the package.');
  if (entry.isDirectory()) zip.addLocalFolder(file, `AegisubLauncher/${entry.name}`);
  else zip.addLocalFile(file, 'AegisubLauncher');
}
for (const file of ['README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md']) zip.addLocalFile(path.join(root, file), 'AegisubLauncher');
zip.addLocalFolder(path.join(root, 'docs'), 'AegisubLauncher/docs');
const forbidden = /^AegisubLauncher\/(?:versions|instances|cache|trash)(?:\/|$)|^AegisubLauncher\/(?:state\.json(?:\.tmp)?|launcher-paths\.json)$/;
if (zip.getEntries().some(entry => forbidden.test(entry.entryName))) throw new Error('User data found in package.');
const name = `Aegisub-Launcher-${version}-Windows-x64.zip`;
const output = path.join(root, 'dist', name);
zip.writeZip(output);
const hash = crypto.createHash('sha256').update(fs.readFileSync(output)).digest('hex');
fs.writeFileSync(path.join(root, 'dist', 'SHA256SUMS.txt'), `${hash}  ${name}\n`);
console.log(`${output}\nSHA-256: ${hash}\nEntries: ${zip.getEntries().length}`);
