'use strict';
const releaseBase = 'https://github.com/yiyezq162/KLBurn/releases/';
const size = bytes => `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
const status = text => { document.getElementById('release-status').textContent = text; };
function link(label, url, className = '') {
  const parsed = new URL(url);
  if (!parsed.href.startsWith(releaseBase) || parsed.origin !== 'https://github.com') throw new Error('发布链接不属于官方仓库');
  const node = document.createElement('a'); node.textContent = label; node.href = parsed.href; node.className = className; return node;
}
function copyButton(text) {
  const button = document.createElement('button'); button.type = 'button'; button.className = 'copy'; button.textContent = '复制';
  button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(text); button.textContent = '已复制'; } catch { button.textContent = '请手动复制'; }
    setTimeout(() => { button.textContent = '复制'; }, 1600);
  });
  return button;
}
function asset(target, item, label, release) {
  if (!/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.bytes) || item.bytes <= 0) throw new Error('发布资产元数据无效');
  const root = document.getElementById(target); root.replaceChildren(link(label, item.url, 'btn btn-primary'));
  const meta = document.createElement('p'); meta.className = 'metadata'; meta.textContent = `${release.version} · ${release.date} · ${size(item.bytes)}`;
  const row = document.createElement('div'); row.className = 'checksum-row';
  const checksum = document.createElement('code'); checksum.className = 'checksum'; checksum.textContent = `SHA256 ${item.sha256}`;
  row.append(checksum, copyButton(item.sha256));
  root.append(meta, row);
}
async function render() {
  try {
    const response = await fetch('releases.json', { cache: 'no-cache' }); if (!response.ok) throw new Error('版本数据读取失败');
    const data = await response.json();
    if (data.schema !== 1 || !Array.isArray(data.releases)) throw new Error('版本数据格式无效');
    if (!data.publication_ready || !data.releases.length) {
      status('目前只公开源码和官网，ISO 暂不提供下载。第三方组件的分发条件核验完成后，下载会出现在这里。'); return;
    }
    const latest = data.releases[0];
    status(`最新版本 ${latest.version}（${latest.prerelease ? '预发布版，请先验证是否适用' : '稳定版'}）· ${latest.date}`);
    document.querySelector('.status').classList.add('ready');
    asset('full-download', latest.assets.full, '下载整机测试版 ISO', latest);
    asset('mem-download', latest.assets.mem, '下载内存专用版 ISO', latest);
    const tools = document.getElementById('tool-downloads'); tools.replaceChildren();
    for (const platform of ['Windows', 'macOS', 'Linux']) tools.append(link(platform, latest.assets[platform].url));
    const history = document.getElementById('release-history'); history.replaceChildren();
    for (const release of data.releases) {
      const row = document.createElement('div'); row.className = 'release-row'; row.append(link(release.version, release.url));
      const note = document.createElement('span'); note.textContent = `${release.date} · ${release.prerelease ? '预发布版' : '稳定版'}`; row.append(note); history.append(row);
    }
  } catch (error) {
    status('无法读取版本数据，请到 GitHub Releases 查看。');
    console.error(error.message);
  }
}
render();
