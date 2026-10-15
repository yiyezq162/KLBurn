'use strict';
const releaseBase = 'https://github.com/yiyezq162/KLBurn/releases/';
const size = bytes => `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
function link(label, url, className = '') {
  const parsed = new URL(url);
  if (!parsed.href.startsWith(releaseBase) || parsed.origin !== 'https://github.com') throw new Error('发布链接不属于官方仓库');
  const node = document.createElement('a'); node.textContent = label; node.href = parsed.href; node.className = className; return node;
}
function asset(target, item, label, release) {
  if (!/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.bytes) || item.bytes <= 0) throw new Error('发布资产元数据无效');
  const root = document.getElementById(target); root.replaceChildren(link(label, item.url, 'button'));
  const meta = document.createElement('p'); meta.className = 'metadata'; meta.textContent = `${release.version} · ${release.date} · ${size(item.bytes)}`;
  const checksum = document.createElement('code'); checksum.className = 'checksum'; checksum.textContent = `SHA256 ${item.sha256}`;
  root.append(meta, checksum);
}
async function render() {
  try {
    const response = await fetch('releases.json'); if (!response.ok) throw new Error('版本数据读取失败');
    const data = await response.json();
    if (data.schema !== 1 || !Array.isArray(data.releases)) throw new Error('版本数据格式无效');
    if (!data.publication_ready || !data.releases.length) {
      document.getElementById('release-status').textContent = '公开发布审查尚未完成；这里不提供未经核验的下载。'; return;
    }
    const latest = data.releases[0];
    document.getElementById('release-status').textContent = `${latest.version} · ${latest.prerelease ? '预发布版，请先验证适用性' : '稳定版'} · ${latest.date}`;
    asset('full-download', latest.assets.full, '下载 full ISO', latest);
    asset('mem-download', latest.assets.mem, '下载 mem ISO', latest);
    const tools = document.getElementById('tool-downloads'); tools.replaceChildren();
    for (const platform of ['Windows', 'macOS', 'Linux']) tools.append(link(platform, latest.assets[platform].url));
    const history = document.getElementById('release-history'); history.replaceChildren();
    for (const release of data.releases) {
      const row = document.createElement('div'); row.className = 'release-row'; row.append(link(release.version, release.url));
      const note = document.createElement('span'); note.textContent = `${release.date} · ${release.prerelease ? '预发布版' : '稳定版'}`; row.append(note); history.append(row);
    }
  } catch (error) {
    document.getElementById('release-status').textContent = '无法验证版本数据，请查看 GitHub Releases。';
    console.error(error.message);
  }
}
render();
