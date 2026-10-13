const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
}[character]));
const fmtBytes = (value) => {
  let n = Number(value || 0), unit = 0;
  while (n >= 1024 && unit < 4) { n /= 1024; unit++; }
  return `${n.toFixed(unit ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][unit]}`;
};
const joinRemote = (dir, name) => `${dir === '/' ? '' : dir}/${name}`;
const button = (label, action, extra = '', css = 'secondary') =>
  `<button class="${css} mini" data-action="${esc(action)}" ${extra}>${esc(label)}</button>`;
const empty = (text) => `<div class="empty">${esc(text)}</div>`;
const tag = (text, good = false) => `<span class="tag ${good ? 'good' : ''}">${esc(text)}</span>`;
const row = (left, right = '') => `<div class="row"><div class="grow">${left}</div><div class="actions">${right}</div></div>`;
const card = (title, body, actions = '') => `<section class="card"><div class="card-header"><h2>${esc(title)}</h2><div class="actions">${actions}</div></div>${body}</section>`;
const list = (data) => Array.isArray(data) ? data : (data?.items || []);

const groups = [
  ['概览', [['status', '服务器状态']]],
  ['站点与数据', [['files', '文件管理'], ['domains', '域名管理'], ['sites', '网站管理'], ['projects', '项目管理'], ['databases', '数据库管理']]],
  ['运行与安全', [['services', '软件管理'], ['environments', '环境管理'], ['firewall', '防火墙'], ['tasks', '计划任务'], ['store', '软件商店']]],
  ['部署', [['installer', '安装服务端']]]
];
const titles = Object.fromEntries(groups.flatMap(([group, items]) => items.map(([id, title]) => [id, [group, title]])));
const subtitles = {
  status: '查看服务器实时状态。桌面客户端通过 HTTPS API 通信。',
  files: '浏览服务器文件系统；默认位于 /www/seraphim。',
  domains: '管理域名解析与证书。',
  sites: '管理 Nginx、Apache 和 OpenResty 网站。',
  projects: '管理 Python、Node.js、Go 等常驻项目。',
  databases: '查看数据库实例并管理库、用户与权限。',
  services: '查看服务状态，控制运行与开机启动。',
  environments: '动态读取可安装版本，管理独立安装的运行环境。',
  firewall: '查看与修改 TCP/UDP 入站端口规则。',
  tasks: '创建每小时、每天或每周执行的计划任务。',
  store: '安装或卸载服务器软件；详细管理位于软件管理。',
  installer: '通过 SSH 自动安装，或导出安装文件在服务器命令行部署。'
};
const S = { section: 'status', doc: { entries: [], selectedID: '' }, data: null, filePath: '/www/seraphim',
  expanded: new Set(), versions: {}, selectedDatabase: '', catalog: null, acl: null, busy: false };
let modalRevision = 0;

function setNotice(message = '', error = false) {
  const notice = $('#notice');
  notice.textContent = message;
  notice.classList.toggle('error', error);
}
function selectedConnection() { return S.doc.entries.find((entry) => entry.connection.id === S.doc.selectedID); }
function renderChrome() {
  $('#navigation').innerHTML = groups.map(([group, sections]) => `<div class="nav-group"><div class="nav-group-label">${esc(group)}</div>${sections.map(([id, title]) =>
    `<button class="nav-button ${S.section === id ? 'active' : ''}" data-section="${id}">${esc(title)}</button>`).join('')}</div>`).join('');
  $('#connection-select').innerHTML = S.doc.entries.length
    ? S.doc.entries.map(({ connection }) => `<option value="${esc(connection.id)}" ${connection.id === S.doc.selectedID ? 'selected' : ''}>${esc(connection.name || connection.endpoint)}</option>`).join('')
    : '<option value="">添加服务器连接</option>';
  $('#section-group').textContent = titles[S.section][0];
  $('#section-title').textContent = titles[S.section][1];
  $('#section-subtitle').textContent = subtitles[S.section];
  $('#platform').textContent = ({ darwin: 'macOS', win32: 'Windows', linux: 'Linux' })[window.sera.platform] || window.sera.platform;
}

function modal(title, fields, submit, label = '保存') {
  const revision = ++modalRevision;
  $('#modal-content').innerHTML = `<div class="dialog-body"><h2>${esc(title)}</h2><div class="fields">${fields.map((field) => {
    const id = `field-${field.name}`;
    let control;
    if (field.type === 'select') control = `<select id="${id}" name="${esc(field.name)}">${field.options.map(([value, text]) =>
      `<option value="${esc(value)}" ${String(field.value ?? '') === String(value) ? 'selected' : ''}>${esc(text)}</option>`).join('')}</select>`;
    else if (field.type === 'textarea') control = `<textarea id="${id}" name="${esc(field.name)}" rows="${field.rows || 3}">${esc(field.value)}</textarea>`;
    else if (field.type === 'checkbox') control = `<input id="${id}" name="${esc(field.name)}" type="checkbox" ${field.value ? 'checked' : ''}>`;
    else control = `<input id="${id}" name="${esc(field.name)}" type="${field.type || 'text'}" value="${esc(field.value)}" placeholder="${esc(field.placeholder)}" ${field.required ? 'required' : ''} ${field.disabled ? 'disabled' : ''}>`;
    if (field.browse) control = `<div class="inline">${control}<button type="button" class="secondary" data-browse="${esc(field.browse)}">选择…</button></div>`;
    return `<div class="field ${field.full ? 'full' : ''}"><label for="${id}">${esc(field.label)}</label>${control}</div>`;
  }).join('')}</div><p class="help" id="modal-error"></p></div>`;
  $('#modal-submit').textContent = label;
  $('#modal-submit').hidden = !submit;
  const dialog = $('#modal');
  $('#modal-cancel').onclick = () => dialog.close();
  $('#modal-form').onsubmit = async (event) => {
    event.preventDefault();
    if (!submit) { dialog.close(); return; }
    const form = new FormData($('#modal-form'));
    const values = Object.fromEntries(fields.map((field) => [field.name, field.type === 'checkbox'
      ? form.has(field.name) : form.get(field.name)]));
    $('#modal-submit').disabled = true;
    $('#modal-cancel').disabled = true;
    try { await submit(values); if (revision === modalRevision) dialog.close(); }
    catch (error) { $('#modal-error').textContent = error.message; }
    finally { $('#modal-submit').disabled = false; $('#modal-cancel').disabled = false; }
  };
  dialog.showModal();
}
function info(title, content) {
  modalRevision++;
  if ($('#modal').open) $('#modal').close();
  $('#modal-content').innerHTML = `<div class="dialog-body"><h2>${esc(title)}</h2><div class="code">${esc(content)}</div></div>`;
  $('#modal-submit').hidden = true;
  $('#modal-cancel').onclick = () => $('#modal').close();
  $('#modal').showModal();
}
async function api(action, payload) { return window.sera.api(action, payload); }
async function run(task, success) {
  if (S.busy) return;
  S.busy = true;
  try {
    const result = await task();
    if (success) setNotice(success);
    return result;
  } catch (error) {
    setNotice(error.message || String(error), true);
    return undefined;
  } finally { S.busy = false; }
}
async function mutate(action, payload, message = '操作已完成') {
  const result = await run(() => api(action, payload), message);
  if (result !== undefined) await refresh(false);
  return result;
}
async function loadConnections() {
  S.doc = await window.sera.connections();
  renderChrome();
}
function editConnection(entry) {
  const current = entry?.connection || {};
  modal(entry ? '编辑服务器连接' : '添加服务器连接', [
    { name: 'name', label: '名称', value: current.name, placeholder: '生产服务器' },
    { name: 'endpoint', label: 'HTTPS 地址', value: current.endpoint, required: true, placeholder: 'https://1.2.3.4:27520', full: true },
    { name: 'token', label: entry?.hasToken ? 'API 令牌（留空保持原值）' : 'API 令牌', type: 'password', value: '', required: !entry?.hasToken, full: true },
    { name: 'fingerprint', label: '自签证书 SHA-256 指纹（正式可信证书可留空）', value: current.fingerprint, full: true }
  ], async (values) => {
    S.doc = await window.sera.saveConnection({ ...values, id: current.id });
    setNotice('服务器连接已保存');
    renderChrome();
    await refresh(false);
  });
}

let refreshRevision = 0;
async function refresh(clearNotice = true) {
  const revision = ++refreshRevision;
  const section = S.section;
  if (clearNotice) setNotice();
  renderChrome();
  if (!selectedConnection() && !['installer', 'domains'].includes(S.section)) {
    $('#page-actions').innerHTML = '';
    $('#content').innerHTML = empty('请先添加服务器连接');
    return;
  }
  $('#content').innerHTML = empty('正在读取…');
  try {
    const loader = loaders[section];
    await loader();
    if (revision !== refreshRevision || section !== S.section) return;
    renders[section]();
  } catch (error) {
    if (revision !== refreshRevision || section !== S.section) return;
    $('#content').innerHTML = empty('读取失败');
    setNotice(error.message || String(error), true);
  }
}

const loaders = {
  status: async () => { S.data = await api('status'); },
  files: async () => { S.data = await api('files.list', { path: S.filePath }); S.filePath = S.data.path; },
  sites: async () => { S.data = await api('sites.list'); },
  projects: async () => { S.data = await api('projects.list'); },
  environments: async () => { S.data = await api('environments.list'); },
  services: async () => { S.data = await Promise.all([api('software.list'), api('services.list')]); },
  store: async () => { S.data = await api('software.list'); },
  firewall: async () => { S.data = await api('firewall.get'); },
  tasks: async () => { S.data = await api('tasks.list'); },
  databases: async () => {
    S.data = await api('databases.list');
    if (S.selectedDatabase) await loadDatabaseDetail();
  },
  domains: async () => {
    S.dnsSettings = await window.sera.dnsSettings();
    S.certificates = await window.sera.certificates();
    S.dnsDomains = [];
    S.dnsRecords = [];
    if (S.dnsSettings.hasSecret) {
      const result = await window.sera.dnsCall('DescribeDomains', { PageNumber: 1, PageSize: S.dnsSettings.pageSize });
      const raw = result.Domains?.Domain || [];
      S.dnsDomains = Array.isArray(raw) ? raw : [raw];
      if (S.dnsSelected && S.dnsDomains.some((domain) => domain.DomainName === S.dnsSelected))
        await loadDNSRecords();
    }
  },
  installer: async () => { S.data = null; }
};
const renders = {};

renders.status = () => {
  $('#page-actions').innerHTML = '';
  const s = S.data;
  if (s.schema_version !== 1) throw new Error(`服务端状态协议版本 ${s.schema_version} 暂不支持`);
  const meter = (number) => `<div class="meter"><span style="width:${Math.min(100, Math.max(0, Number(number) || 0))}%"></span></div>`;
  $('#content').innerHTML = `<div class="grid">
    ${card('CPU', `<div class="metric">${esc(s.cpu.usage_percent.toFixed(1))}%</div>${meter(s.cpu.usage_percent)}<p class="help">${esc(s.cpu.logical_cores)} 核 · 负载 ${esc(s.cpu.load_1m)} / ${esc(s.cpu.load_5m)} / ${esc(s.cpu.load_15m)}</p>`)}
    ${card('内存', `<div class="metric">${fmtBytes(s.memory.used_bytes)} / ${fmtBytes(s.memory.total_bytes)}</div>${meter(s.memory.usage_percent)}<p class="help">可用 ${fmtBytes(s.memory.available_bytes)}</p>`)}
    ${card('交换空间', `<div class="metric">${fmtBytes(s.swap.used_bytes)} / ${fmtBytes(s.swap.total_bytes)}</div>${meter(s.swap.usage_percent)}`)}
    ${card('主机', `<dl class="kv"><dt>名称</dt><dd>${esc(s.host.hostname)}</dd><dt>系统</dt><dd>${esc(s.host.os)}</dd><dt>内核</dt><dd>${esc(s.host.kernel)}</dd><dt>架构</dt><dd>${esc(s.host.architecture)}</dd><dt>运行时间</dt><dd>${Math.floor(s.host.uptime_seconds / 3600)} 小时</dd></dl>`)}
  </div><div class="grid">${(s.disks || []).map((disk) => card(`磁盘 ${disk.mountpoint}`, `<div class="metric">${fmtBytes(disk.used_bytes)} / ${fmtBytes(disk.total_bytes)}</div>${meter(disk.usage_percent)}<p class="help">${esc(disk.device)} · ${esc(disk.filesystem)}</p>`)).join('')}
  ${card('网卡流量', (s.network || []).map((network) => row(`<strong>${esc(network.name)}</strong><div class="small muted">收 ${fmtBytes(network.rx_bytes_per_second)}/s · 发 ${fmtBytes(network.tx_bytes_per_second)}/s</div>`)).join('') || empty('没有网卡数据'))}</div>`;
};

renders.files = () => {
  $('#page-actions').innerHTML = '';
  const entries = S.data.entries || [];
  $('#content').innerHTML = `<div class="toolbar"><button class="secondary" data-action="files.up">上一级</button><input id="file-path" aria-label="服务器路径" value="${esc(S.filePath)}"><button class="secondary" data-action="files.go">前往</button><button data-action="files.mkdir">新建文件夹</button><button class="secondary" data-action="files.touch">新建文件</button><button class="secondary" data-action="files.upload-file">上传文件</button><button class="secondary" data-action="files.upload-folder">上传文件夹</button></div>
    <div class="file-drop-hint">也可以把文件或文件夹拖到这里上传，保留文件夹结构和空目录。</div>
    <section class="card"><table class="table"><thead><tr><th>名称</th><th>权限</th><th>大小</th><th>修改时间</th><th></th></tr></thead><tbody>${entries.map((file, index) => `<tr><td>${file.kind === 'directory' ? '📁' : '📄'} <button class="linklike mono" data-action="files.open" data-index="${index}">${esc(file.name)}</button></td><td class="mono">${esc(file.permissions || '—')}</td><td>${file.kind === 'directory' ? '—' : fmtBytes(file.size_bytes)}</td><td>${esc((file.modified_at || '').replace('T', ' ').slice(0, 16))}</td><td class="actions-cell"><div class="actions">${file.kind === 'directory' ? button('进入', 'files.open', `data-index="${index}"`) : button('下载', 'files.download', `data-index="${index}"`)}${button('重命名', 'files.rename', `data-index="${index}"`)}${button('权限', 'files.chmod', `data-index="${index}"`)}${button('删除', 'files.delete', `data-index="${index}"`, 'danger')}</div></td></tr>`).join('')}</tbody></table>${entries.length ? '' : empty('此目录为空')}</section>`;
};

async function beginFileUpload(chosen) {
  if (!chosen?.length || S.busy) return;
  const existing = chosen.filter((entry) => S.data.entries.some((item) => item.name === entry.name));
  const overwrite = existing.length > 0;
  if (overwrite && !confirm(`服务器上已有 ${existing.map((entry) => entry.name).join('、')}。覆盖同名文件并合并文件夹？`)) return;
  const directory = S.filePath;
  setNotice(`正在上传 ${chosen.length} 项…`);
  const result = await run(() => window.sera.upload(chosen.map((entry) => entry.id), directory, overwrite));
  if (result) {
    await refresh(false);
    setNotice(`上传完成：${result.files} 个文件、${result.directories} 个文件夹${result.skipped ? `；跳过 ${result.skipped} 个符号链接或特殊文件` : ''}`);
  }
}

async function fileAction(action, index) {
  const file = S.data.entries[index];
  if (action === 'files.go' || action === 'files.up' || action === 'files.open') {
    const path = action === 'files.go' ? $('#file-path').value.trim()
      : action === 'files.up' ? S.data.parent : file.path;
    if (action === 'files.open' && file.kind !== 'directory') return fileAction('files.download', index);
    S.filePath = path;
    await refresh();
  } else if (action === 'files.mkdir' || action === 'files.touch') {
    modal(action === 'files.mkdir' ? '新建文件夹' : '新建文件', [{ name: 'name', label: '名称', required: true }], async ({ name }) => {
      await api('files.command', { operation: action === 'files.mkdir' ? 'mkdir' : 'touch', path: joinRemote(S.filePath, name) });
      await refresh(false);
    }, '创建');
  } else if (action === 'files.upload-file' || action === 'files.upload-folder') {
    await beginFileUpload(await window.sera.chooseUpload(action === 'files.upload-folder' ? 'directory' : 'file'));
  } else if (action === 'files.download') {
    const saved = await run(() => window.sera.download(file.path));
    if (saved) setNotice(`已下载到 ${saved}`);
  } else if (action === 'files.rename') {
    modal('重命名', [{ name: 'name', label: '新名称', value: file.name, required: true }], async ({ name }) => {
      const destination = joinRemote(S.filePath, name);
      let overwrite = false;
      if (S.data.entries.some((item) => item.name === name && item.path !== file.path)) {
        if (!confirm('覆盖目标文件？')) return;
        overwrite = true;
      }
      await api('files.command', { operation: 'rename', path: file.path, destination, overwrite });
      await refresh(false);
    });
  } else if (action === 'files.chmod') {
    modal('修改权限', [{ name: 'permissions', label: '八进制权限', value: file.permissions || '0644', required: true }], async ({ permissions }) => {
      if (!/^0?[0-7]{3}$/.test(permissions)) throw new Error('请输入 0644 或 0755 等八进制权限');
      await api('files.command', { operation: 'chmod', path: file.path, permissions });
      await refresh(false);
    });
  } else if (action === 'files.delete') {
    if (confirm(`删除 ${file.path}${file.kind === 'directory' ? ' 及其中所有内容' : ''}？`))
      await mutate('files.delete', { path: file.path, recursive: file.kind === 'directory' }, '文件已删除');
  }
}

renders.sites = () => {
  $('#page-actions').innerHTML = '<button data-action="sites.new">新建网站</button>';
  const sites = list(S.data), providers = S.data.providers || [];
  $('#content').innerHTML = `${card('Web 服务', providers.map((provider) => row(`<strong>${esc(provider.name)}</strong> ${tag(provider.installed ? (provider.running ? '运行中' : '已停止') : '未安装', provider.running)} <span class="small muted">端口 ${esc(provider.port)}</span>`)).join('') || empty('没有可用的 Web 服务'))}
    ${sites.map((site, index) => card(site.domains?.[0] || site.id, `<div class="inline">${tag(site.provider)} ${tag(site.kind === 'proxy' ? '反向代理' : site.kind === 'php' ? `PHP ${site.php_version || ''}` : '静态网站')} ${tag(site.enabled ? '已启用' : '已停用', site.enabled)}</div><dl class="kv"><dt>域名</dt><dd>${esc((site.domains || []).join('、'))}</dd><dt>目录</dt><dd class="mono">${esc(site.root)}</dd>${site.kind === 'proxy' ? `<dt>上游</dt><dd class="mono">${esc(site.upstream)}</dd>` : ''}</dl>`, `${button('编辑', 'sites.edit', `data-index="${index}"`)}${button(site.enabled ? '停用' : '启用', 'sites.toggle', `data-index="${index}"`)}${site.kind !== 'proxy' ? button('文件', 'sites.files', `data-index="${index}"`) : ''}${button('删除', 'sites.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('尚无网站')}`;
};
function siteForm(site) {
  const installed = (S.data.providers || []).filter((provider) => provider.installed);
  const phpVersions = S.data.php_versions || [];
  modal(site ? '编辑网站' : '新建网站', [
    { name: 'provider', label: 'Web 服务', type: 'select', options: (site ? S.data.providers : installed).map((provider) => [provider.id, provider.name]), value: site?.provider },
    { name: 'kind', label: '网站类型', type: 'select', options: [['static', '静态网站'], ['php', 'PHP 网站'], ['proxy', '反向代理']], value: site?.kind || 'static' },
    { name: 'domains', label: '域名（逗号或换行分隔）', type: 'textarea', value: site?.domains?.join('\n') || '', required: true, full: true },
    { name: 'phpVersion', label: 'PHP 版本', type: 'select', options: phpVersions.length ? phpVersions.map((version) => [version, version]) : [['', '请先到环境管理安装 PHP']], value: site?.php_version || phpVersions[0] || '', full: true },
    { name: 'upstream', label: '反向代理地址（仅代理站点）', value: site?.upstream || '', placeholder: 'http://127.0.0.1:3000', full: true },
    { name: 'enabled', label: '启用网站', type: 'checkbox', value: site?.enabled ?? true }
  ], async (values) => {
    const payload = { provider: values.provider, kind: values.kind,
      domains: values.domains.split(/[\s,，]+/).filter(Boolean), upstream: values.upstream.trim(),
      php_version: values.kind === 'php' ? values.phpVersion : '', enabled: values.enabled };
    if (!payload.domains.length) throw new Error('至少输入一个域名');
    if (payload.kind === 'php' && !payload.php_version) throw new Error('请先到环境管理安装 PHP');
    await api(site ? 'sites.update' : 'sites.create', site
      ? { provider: site.provider, id: site.id, site: payload } : { site: payload });
    await refresh(false);
  });
  const updateFields = () => {
    const kind = $('#field-kind').value;
    $('#field-phpVersion').closest('.field').hidden = kind !== 'php';
    $('#field-upstream').closest('.field').hidden = kind !== 'proxy';
  };
  $('#field-kind').addEventListener('change', updateFields);
  updateFields();
}
async function siteAction(action, index) {
  const site = list(S.data)[index];
  if (action === 'sites.new') siteForm();
  else if (action === 'sites.edit') siteForm(site);
  else if (action === 'sites.toggle') await mutate('sites.update', { provider: site.provider, id: site.id,
    site: { provider: site.provider, domains: site.domains, kind: site.kind, upstream: site.upstream,
      php_version: site.php_version || '',
      enabled: !site.enabled } }, site.enabled ? '网站已停用' : '网站已启用');
  else if (action === 'sites.files') { S.filePath = site.root; S.section = 'files'; await refresh(); }
  else if (action === 'sites.delete' && confirm(`删除 ${site.domains?.[0] || site.id} 的网站配置？网站文件会保留。`))
    await mutate('sites.delete', { provider: site.provider, id: site.id }, '网站配置已删除');
}

const defaultEntries = { python: 'main.py', node: 'index.js', go: '.', openjdk: 'app.jar', dotnet: 'app.dll',
  ruby: 'app.rb', bun: 'index.ts', deno: 'main.ts' };
renders.projects = () => {
  $('#page-actions').innerHTML = '<button data-action="projects.new">新建项目</button>';
  const projects = list(S.data), runtimes = S.data.runtimes || [];
  $('#content').innerHTML = projects.map((project, index) => {
    const runtime = runtimes.find((item) => item.id === project.runtime);
    return card(project.name, `<div class="inline">${tag(project.active_state === 'active' ? '运行中' : project.active_state === 'failed' ? '启动失败' : '已停止', project.active_state === 'active')} ${tag(project.enabled ? '开机启动' : '不自启')} ${tag(`${runtime?.name || project.runtime} ${project.runtime_version || ''}`)} ${!project.runtime_ready ? tag('运行环境缺失') : ''} ${project.use_venv && !project.venv_ready ? tag('虚拟环境未就绪') : ''}</div><dl class="kv"><dt>工程目录</dt><dd class="mono">${esc(project.directory)}</dd><dt>入口</dt><dd class="mono">${esc(project.entry)}</dd><dt>端口</dt><dd>${esc(project.port || '未指定')}</dd></dl>`,
      `${button('编辑', 'projects.edit', `data-index="${index}"`)}${button('文件', 'projects.files', `data-index="${index}"`)}${button('日志', 'projects.log', `data-index="${index}"`)}${project.use_venv ? button(project.venv_ready ? '安装依赖' : '创建虚拟环境', 'projects.venv', `data-index="${index}"`) : ''}${button(project.active_state === 'active' ? '停止' : '启动', 'projects.toggle', `data-index="${index}"`)}${project.active_state === 'active' ? button('重启', 'projects.restart', `data-index="${index}"`) : ''}${button(project.enabled ? '取消自启' : '开机自启', 'projects.enable', `data-index="${index}"`)}${button('删除', 'projects.delete', `data-index="${index}"`, 'danger')}`);
  }).join('') || empty('尚无服务器项目；可先上传项目文件，再创建项目配置');
};
function projectForm(project) {
  const runtimes = S.data.runtimes || [];
  const first = project?.runtime || runtimes.find((item) => item.installed)?.id || runtimes[0]?.id || 'python';
  const selected = runtimes.find((item) => item.id === first);
  const runtimeChoices = runtimes.map((item) => [item.id, item.installed ? item.name : `${item.name}（未安装）`]);
  const versions = [...(selected?.legacy_installed ? [['', '原有版本']] : []),
    ...((selected?.versions || []).map((version) => [version, version]))];
  if (!versions.length) versions.push(['', '尚未安装']);
  modal(project ? '编辑服务器项目' : '新建服务器项目', [
    { name: 'id', label: '项目标识', value: project?.id || '', disabled: Boolean(project), required: true },
    { name: 'name', label: '名称', value: project?.name || '', required: true },
    { name: 'runtime', label: '运行环境', type: 'select', options: runtimeChoices, value: first },
    { name: 'runtime_version', label: '环境版本', type: 'select', options: versions, value: project?.runtime_version || versions[0][0] },
    { name: 'directory', label: '工程目录（服务器绝对路径，留空使用默认目录）', value: project?.directory || '', full: true, browse: 'directory' },
    { name: 'entry', label: '入口（相对于工程目录）', value: project?.entry || defaultEntries[first], required: true, full: true, browse: 'entry' },
    { name: 'port', label: 'PORT 环境变量', type: 'number', value: project?.port ?? 3000 },
    { name: 'use_venv', label: '使用 Python 虚拟环境', type: 'checkbox', value: project?.use_venv ?? first === 'python' }
  ], async (values) => {
    const payload = { id: project?.id || values.id.trim(), name: values.name.trim(), runtime: values.runtime,
      runtime_version: values.runtime_version, directory: values.directory.trim(), entry: values.entry.trim(),
      port: Number(values.port || 0), use_venv: values.runtime === 'python' && values.use_venv };
    await api(project ? 'projects.update' : 'projects.create', project
      ? { id: project.id, project: payload } : { project: payload });
    await refresh(false);
  });
  $('#field-runtime').addEventListener('change', (event) => {
    const runtime = runtimes.find((item) => item.id === event.target.value);
    const choices = [...(runtime?.legacy_installed ? [['', '原有版本']] : []),
      ...((runtime?.versions || []).map((version) => [version, version]))];
    $('#field-runtime_version').innerHTML = (choices.length ? choices : [['', '尚未安装']])
      .map(([value, label]) => `<option value="${esc(value)}">${esc(label)}</option>`).join('');
    if (!project) $('#field-entry').value = defaultEntries[event.target.value] || '';
    $('#field-use_venv').checked = event.target.value === 'python';
  });
}
async function projectAction(action, index) {
  const project = list(S.data)[index];
  if (action === 'projects.new') projectForm();
  else if (action === 'projects.edit') projectForm(project);
  else if (action === 'projects.files') { S.filePath = project.directory; S.section = 'files'; await refresh(); }
  else if (action === 'projects.log') info(`${project.name} · 日志`, await api('projects.log', { id: project.id }));
  else if (action === 'projects.toggle') await mutate('projects.action', { id: project.id,
    action: project.active_state === 'active' ? 'stop' : 'start' });
  else if (action === 'projects.restart') await mutate('projects.action', { id: project.id, action: 'restart' });
  else if (action === 'projects.enable') await mutate('projects.action', { id: project.id,
    action: project.enabled ? 'disable' : 'enable' });
  else if (action === 'projects.venv') await mutate('projects.venv', { id: project.id,
    action: project.venv_ready ? 'install_requirements' : 'create' });
  else if (action === 'projects.delete' && confirm(`删除 ${project.name} 项目服务？项目文件和日志将保留。`))
    await mutate('projects.delete', { id: project.id }, '项目服务已删除');
}

const P = { mode: '', path: '', listing: null, message: '' };
function pathBase() {
  const chosen = $('#field-directory')?.value.trim() || '';
  const id = $('#field-id')?.value.trim() || '';
  return chosen || (id ? `/www/seraphim/projects/${id}` : '/www/seraphim/projects');
}
async function openProjectPathPicker(mode) {
  P.mode = mode;
  P.path = mode === 'entry' ? pathBase() : ($('#field-directory')?.value.trim() || '/www/seraphim/projects');
  P.listing = null;
  P.message = '';
  $('#path-modal').showModal();
  await loadProjectPath(P.path, true);
}
async function loadProjectPath(path, fallback = false) {
  try {
    P.listing = await api('files.list', { path });
    P.path = P.listing.path;
    P.message = '';
  } catch (error) {
    P.message = error.message;
    if (fallback && path !== '/www/seraphim/projects') {
      await loadProjectPath('/www/seraphim/projects');
      P.message = '原目录尚不存在，已转到项目根目录';
    }
  }
  renderProjectPathPicker();
}
function renderProjectPathPicker() {
  const runtime = $('#field-runtime')?.value || 'python';
  const extensions = {
    python: ['py'], node: ['js', 'mjs', 'cjs'], go: ['go'], openjdk: ['jar'], dotnet: ['dll'],
    ruby: ['rb'], bun: ['js', 'mjs', 'ts', 'tsx'], deno: ['js', 'mjs', 'ts', 'tsx']
  }[runtime] || [];
  const entries = (P.listing?.entries || []).filter((item) => item.kind === 'directory' || (P.mode === 'entry' && item.kind === 'file'));
  entries.sort((a, b) => (a.kind === 'directory' ? 0 : 1) - (b.kind === 'directory' ? 0 : 1) || a.name.localeCompare(b.name));
  P.entries = entries;
  $('#path-content').innerHTML = `<h2>选择服务器${P.mode === 'directory' ? '工程目录' : '入口文件'}</h2><div class="toolbar"><button class="secondary" data-path-action="up">上一级</button><input id="picker-path" value="${esc(P.path)}" aria-label="服务器目录"><button class="secondary" data-path-action="go">前往</button></div>${P.message ? `<p class="help">${esc(P.message)}</p>` : ''}<div class="path-list">${entries.map((item, index) => row(`<span class="mono">${item.kind === 'directory' ? '📁' : '📄'} ${esc(item.name)}</span>`, item.kind === 'directory'
    ? `${button('进入', 'picker.enter', `data-index="${index}"`)}${P.mode === 'directory' ? button('选择', 'picker.choose', `data-index="${index}"`) : ''}`
    : button('选择', 'picker.choose', `data-index="${index}" ${extensions.includes(item.name.split('.').pop().toLowerCase()) ? '' : 'disabled'}`))).join('') || empty('此目录没有可选条目')}</div><div class="dialog-actions"><button class="secondary" data-path-action="close">取消</button>${P.mode === 'directory' ? '<button data-path-action="choose-current">选择此目录</button>' : runtime === 'go' ? '<button data-path-action="go-current">使用此目录作为 Go 入口</button>' : ''}</div>`;
}
function applyProjectPath(path, useGoDirectory = false) {
  if (P.mode === 'directory' || useGoDirectory) $('#field-directory').value = path;
  if (useGoDirectory) $('#field-entry').value = '.';
  else if (P.mode === 'entry') {
    const base = pathBase().replace(/\/$/, '');
    const hadBase = Boolean($('#field-directory').value.trim() || $('#field-id').value.trim());
    if (hadBase && path.startsWith(`${base}/`)) $('#field-entry').value = path.slice(base.length + 1);
    else {
      const slash = path.lastIndexOf('/');
      $('#field-directory').value = path.slice(0, slash) || '/';
      $('#field-entry').value = path.slice(slash + 1);
    }
  }
  $('#path-modal').close();
}

loaders.environments = async () => {
  S.data = await api('environments.list');
  const results = await Promise.allSettled(list(S.data).map((item) => api('environments.versions', { id: item.id })));
  results.forEach((result, index) => {
    if (result.status === 'fulfilled') S.versions[list(S.data)[index].id] = result.value.versions || [];
  });
};
renders.environments = () => {
  $('#page-actions').innerHTML = '';
  $('#content').innerHTML = list(S.data).map((item, index) => {
    const installations = item.installations || (item.state === 'installed' ? [{ path: item.install_path,
      version: item.installed_version || item.catalog_version, legacy: true, tools: item.tools || [] }] : []);
    const installed = new Set(installations.map((part) => part.version));
    const versions = S.versions[item.id] || item.available_versions || [];
    const choices = versions.map((version) => `<option value="${esc(version)}">${esc(version)}${installed.has(version) ? ' · 已安装' : ''}</option>`).join('');
    const versionRows = installations.map((part, partIndex) => {
      const key = `${item.id}:${part.path}`, expanded = S.expanded.has(key);
      return `<div class="version-row"><strong>${esc(part.version)}</strong>${part.legacy ? '<span class="small muted">旧版路径</span>' : ''}${item.id === 'php' ? tag(part.service_state === 'active' ? 'FPM 运行中' : 'FPM 已停止', part.service_state === 'active') : ''}<div class="grow"></div>${button('验证', 'environments.check', `data-index="${index}" data-part="${partIndex}"`)}${button(expanded ? '收起' : '详情', 'environments.details', `data-index="${index}" data-part="${partIndex}"`)}${item.id === 'php' && !part.legacy ? button(part.service_state === 'active' ? '停止 FPM' : '启动 FPM', 'environments.service', `data-index="${index}" data-part="${partIndex}"`) : ''}${button('卸载', 'environments.uninstall', `data-index="${index}" data-part="${partIndex}"`, 'danger')}</div>${expanded ? `<div class="version-details"><div class="mono small">${esc(part.path)}</div>${(part.tools || []).map((tool) => `<div class="row"><div class="grow"><strong>${esc(tool.name)}</strong> <span class="small muted">${esc(tool.version || (tool.available ? '可执行文件存在' : '文件缺失'))}</span><div class="mono small muted">${esc(tool.path)}</div>${tool.error ? `<div class="small">${esc(tool.error)}</div>` : ''}</div></div>`).join('')}</div>` : ''}`;
    }).join('');
    return card(item.name, `<div class="inline">${tag(item.state === 'installed' ? '已安装' : item.state === 'installing' ? '安装中' : item.state === 'failed' ? '安装失败' : '未安装', installations.length > 0)} <span class="small muted">已安装 ${installations.length} 个版本</span></div>${item.message && item.message !== '安装完成' ? `<p class="help">${esc(item.message)}</p>` : ''}<div class="toolbar" style="margin-top:12px"><select id="env-version-${index}" aria-label="${esc(item.name)} 安装版本">${choices || '<option value="">暂无发布版本</option>'}</select>${button('安装所选版本', 'environments.install', `data-index="${index}" ${!item.supported || !versions.length ? 'disabled' : ''}`)}${button('日志', 'environments.log', `data-index="${index}"`)}</div>${versionRows}`);
  }).join('') || empty('尚无运行环境数据');
};
async function environmentAction(action, index, partIndex) {
  const item = list(S.data)[index];
  const installations = item.installations || (item.state === 'installed' ? [{ path: item.install_path,
    version: item.installed_version || item.catalog_version, legacy: true, tools: item.tools || [] }] : []);
  const part = installations[partIndex];
  if (action === 'environments.install') {
    const version = $(`#env-version-${index}`).value;
    if (version && confirm(`安装 ${item.name} ${version}？`)) await mutate('environments.install', { id: item.id, version }, '安装任务已开始');
  } else if (action === 'environments.details') {
    const key = `${item.id}:${part.path}`;
    S.expanded.has(key) ? S.expanded.delete(key) : S.expanded.add(key);
    renders.environments();
  } else if (action === 'environments.check') {
    const result = await run(() => api('environments.check', { id: item.id, version: part.version, legacy: part.legacy }), '验证完成');
    if (result) {
      const tools = result.tools || [];
      part.tools = tools;
      S.expanded.add(`${item.id}:${part.path}`);
      renders.environments();
    }
  } else if (action === 'environments.uninstall') {
    const mode = confirm('卸载并备份原目录？\n确定：备份；取消：继续选择彻底删除。') ? 'backup'
      : (confirm(`彻底删除 ${item.name} ${part.version}？`) ? 'purge' : null);
    if (mode) await mutate(part.legacy ? 'software.uninstall' : 'environments.uninstall',
      part.legacy ? { id: item.id, mode } : { id: item.id, version: part.version, mode }, '卸载任务已开始');
  } else if (action === 'environments.service') await mutate('environments.service', { version: part.version,
    action: part.service_state === 'active' ? 'stop' : 'start' });
  else if (action === 'environments.log') info(`${item.name} · 安装日志`, await api('software.log', { id: item.id }));
}

renders.store = () => {
  $('#page-actions').innerHTML = '';
  const items = list(S.data), search = (S.searchStore || '').toLowerCase();
  $('#content').innerHTML = `<div class="toolbar"><input id="store-search" placeholder="搜索软件" value="${esc(S.searchStore || '')}"><span class="small muted">共 ${items.length} 款 · 已安装 ${items.filter((item) => item.state === 'installed' || item.state === 'multiple_versions').length} 款</span></div><section class="card"><table class="table"><thead><tr><th>软件</th><th>类别</th><th>版本</th><th>状态</th><th></th></tr></thead><tbody>${items.map((item, index) => ({ item, index })).filter(({ item }) => !search || `${item.name} ${item.category} ${item.description}`.toLowerCase().includes(search)).map(({ item, index }) => `<tr><td><strong>${esc(item.name)}</strong><div class="small muted">${esc(item.description)}</div></td><td>${esc(item.category || '其他')}</td><td>${esc(item.version)}</td><td>${tag(item.state === 'installed' ? '已安装' : item.state === 'installing' ? '安装中' : item.state === 'uninstalling' ? '卸载中' : item.state === 'multiple_versions' ? '多版本' : '未安装', item.state === 'installed')}</td><td class="actions-cell"><div class="actions">${item.state === 'installed' ? button('卸载', 'software.uninstall', `data-index="${index}"`, 'danger') : item.install_available !== false && item.supported && !['installing', 'uninstalling', 'multiple_versions'].includes(item.state) ? button('安装', 'software.install', `data-index="${index}"`) : ''}${button('日志', 'software.log', `data-index="${index}"`)}</div></td></tr>`).join('')}</tbody></table></section>`;
};
renders.services = () => {
  $('#page-actions').innerHTML = '';
  const [software, services] = S.data;
  const installed = list(software).filter((item) => item.state === 'installed' && item.service_available !== false);
  $('#content').innerHTML = `${card('防火墙服务', (services.services || []).map((service, index) => row(`<strong>${esc(service.description || service.name)}</strong> ${tag(service.active_state === 'active' ? '运行中' : '已停止', service.active_state === 'active')} ${tag(service.unit_state === 'enabled' ? '开机启动' : '不自启')}`, `${button(service.active_state === 'active' ? '停止' : '启动', 'services.firewall', `data-index="${index}" data-command="${service.active_state === 'active' ? 'stop' : 'start'}"`)}${button(service.unit_state === 'enabled' ? '取消自启' : '开机自启', 'services.firewall', `data-index="${index}" data-command="${service.unit_state === 'enabled' ? 'disable' : 'enable'}"`)}`)).join('') || empty('未检测到防火墙服务'))}
    ${installed.map((item, index) => card(item.name, `<div class="inline">${tag(item.service_state === 'active' ? '运行中' : '已停止', item.service_state === 'active')} ${tag(item.enabled ? '开机启动' : '不自启')} <span class="small muted mono">${esc(item.install_path)}</span></div>`, `${button(item.service_state === 'active' ? '停止' : '启动', 'services.software', `data-index="${index}" data-command="${item.service_state === 'active' ? 'stop' : 'start'}"`)}${button('重启', 'services.software', `data-index="${index}" data-command="restart"`)}${button(item.enabled ? '取消自启' : '开机自启', 'services.software', `data-index="${index}" data-command="${item.enabled ? 'disable' : 'enable'}"`)}${button('日志', 'services.log', `data-index="${index}"`)}`)).join('') || empty('尚无已安装的常驻服务')}`;
  S.installedServices = installed;
};
async function softwareAction(action, index, command) {
  if (action === 'services.firewall') {
    const service = S.data[1].services[index];
    if (confirm(`${command} ${service.name}？`)) await mutate('services.action', { name: service.name, action: command });
    return;
  }
  const item = action.startsWith('services.') ? S.installedServices[index] : list(S.data)[index];
  if (action === 'software.install' && confirm(`安装 ${item.name}？`)) await mutate('software.install', { id: item.id }, '安装任务已开始');
  else if (action === 'software.uninstall') {
    const mode = confirm(`卸载 ${item.name} 并备份目录？\n确定：备份；取消：继续选择彻底删除。`) ? 'backup'
      : (confirm(`彻底删除 ${item.name}？`) ? 'purge' : null);
    if (mode) await mutate('software.uninstall', { id: item.id, mode }, '卸载任务已开始');
  } else if (action === 'software.log' || action === 'services.log') info(`${item.name} · 日志`, await api('software.log', { id: item.id }));
  else if (action === 'services.software' && confirm(`${command} ${item.name}？`))
    await mutate('software.service', { id: item.id, action: command });
}

renders.firewall = () => {
  $('#page-actions').innerHTML = '<button data-action="firewall.add">添加规则</button>';
  const firewall = S.data;
  $('#content').innerHTML = `${card('当前防火墙', `<div class="inline">${tag(firewall.backend || '未启用', Boolean(firewall.backend))}<span class="muted">区域 ${esc(firewall.zone || '—')}</span></div>`)}${card('入站端口', (firewall.rules || []).map((rule, index) => row(`<strong>${esc(rule.port)}/${esc(rule.protocol)}</strong> <span class="muted small">${esc(rule.source || '全部来源')}</span>`, button('删除', 'firewall.remove', `data-index="${index}"`, 'danger'))).join('') || empty('没有简单端口规则'))}`;
};
async function firewallAction(action, index) {
  if (action === 'firewall.add') modal('添加入站端口', [
    { name: 'port', label: '端口', type: 'number', required: true },
    { name: 'protocol', label: '协议', type: 'select', options: [['tcp', 'TCP'], ['udp', 'UDP']] }
  ], async ({ port, protocol }) => {
    if (!(Number(port) >= 1 && Number(port) <= 65535)) throw new Error('端口须在 1–65535 之间');
    await api('firewall.change', { action: 'add', port: Number(port), protocol });
    await refresh(false);
  }, '添加');
  else if (action === 'firewall.remove') {
    const rule = S.data.rules[index];
    if (confirm(`删除 ${rule.port}/${rule.protocol} 入站规则？`))
      await mutate('firewall.change', { action: 'remove', port: rule.port, protocol: rule.protocol });
  }
}

renders.tasks = () => {
  $('#page-actions').innerHTML = '<button data-action="tasks.new">新建任务</button>';
  $('#content').innerHTML = list(S.data).map((task, index) => card(task.name, `<div class="inline">${tag(task.enabled ? '已启用' : '已停用', task.enabled)} <span class="muted">${esc(task.frequency)} · ${esc(task.weekday || '')} ${esc(task.time)}</span></div><dl class="kv"><dt>标识</dt><dd>${esc(task.id)}</dd><dt>程序</dt><dd class="mono">${esc(task.executable)}</dd><dt>工作目录</dt><dd class="mono">${esc(task.directory)}</dd><dt>上次运行</dt><dd>${esc(task.last_run || '—')} ${esc(task.last_result || '')}</dd></dl>`, `${button('编辑', 'tasks.edit', `data-index="${index}"`)}${button(task.enabled ? '停用' : '启用', 'tasks.toggle', `data-index="${index}"`)}${button('日志', 'tasks.log', `data-index="${index}"`)}${button('删除', 'tasks.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('尚无计划任务');
};
function taskForm(task) {
  modal(task ? '编辑计划任务' : '新建计划任务', [
    { name: 'id', label: '标识', value: task?.id || '', disabled: Boolean(task), required: true },
    { name: 'name', label: '名称', value: task?.name || '', required: true },
    { name: 'frequency', label: '频率', type: 'select', options: [['hourly', '每小时'], ['daily', '每天'], ['weekly', '每周']], value: task?.frequency || 'daily' },
    { name: 'time', label: '时间（每小时填 00–59，其他填 HH:MM）', value: task?.time || '03:00', required: true },
    { name: 'weekday', label: '星期（每周任务）', type: 'select', options: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => [day, day]), value: task?.weekday || 'Mon' },
    { name: 'enabled', label: '启用', type: 'checkbox', value: task?.enabled ?? true },
    { name: 'executable', label: '程序绝对路径', value: task?.executable || '', required: true, full: true },
    { name: 'directory', label: '工作目录', value: task?.directory || '/www/seraphim', required: true, full: true },
    { name: 'arguments', label: '参数（每行一个）', type: 'textarea', value: (task?.arguments || []).join('\n'), full: true }
  ], async (values) => {
    const payload = { id: task?.id || values.id.trim(), name: values.name.trim(), frequency: values.frequency,
      time: values.time.trim(), weekday: values.weekday, executable: values.executable.trim(),
      directory: values.directory.trim(), arguments: values.arguments.split('\n').filter((line) => line.length),
      enabled: values.enabled };
    await api(task ? 'tasks.update' : 'tasks.create', task ? { id: task.id, task: payload } : { task: payload });
    await refresh(false);
  });
}
async function taskAction(action, index) {
  const task = list(S.data)[index];
  if (action === 'tasks.new') taskForm();
  else if (action === 'tasks.edit') taskForm(task);
  else if (action === 'tasks.toggle') await mutate('tasks.update', { id: task.id, task: { ...task, enabled: !task.enabled } });
  else if (action === 'tasks.log') info(`${task.name} · 日志`, await api('tasks.log', { id: task.id }));
  else if (action === 'tasks.delete' && confirm(`删除任务 ${task.name}？日志会保留。`))
    await mutate('tasks.delete', { id: task.id }, '任务已删除');
}

async function loadDatabaseDetail() {
  const instance = list(S.data).find((item) => item.id === S.selectedDatabase);
  S.catalog = null; S.acl = null;
  if (!instance || !instance.installed) return;
  if (['mysql', 'mariadb', 'postgresql'].includes(instance.id))
    S.catalog = await api('databases.catalog', { engine: instance.id });
  if (['redis', 'valkey'].includes(instance.id))
    S.acl = await api('databases.acl', { engine: instance.id });
}
renders.databases = () => {
  $('#page-actions').innerHTML = '';
  const instances = list(S.data);
  const chosen = instances.find((item) => item.id === S.selectedDatabase);
  $('#content').innerHTML = `<div class="grid">${instances.map((instance) => `<button class="card" style="text-align:left;width:100%;color:inherit" data-action="databases.select" data-id="${esc(instance.id)}"><div class="card-header"><h2>${esc(instance.name)}</h2>${tag(instance.running ? '运行中' : instance.installed ? '已停止' : '未安装', instance.running)}</div><div class="small muted">${esc(instance.version || '')} · 端口 ${esc(instance.port || '—')} · ${esc(instance.auth_state || '')}</div></button>`).join('')}</div>${chosen ? renderDatabaseDetail(chosen) : ''}`;
};
function renderDatabaseDetail(instance) {
  const engine = instance.id;
  if (!instance.installed) return card(instance.name, empty('请先从软件商店安装此数据库'));
  if (S.catalog) {
    const databases = S.catalog.databases || [], users = S.catalog.users || [];
    return card(`${instance.name} · 数据库与账户`, `<div class="split"><div><h3>数据库</h3>${databases.map((name, index) => row(`<span class="mono">${esc(name)}</span>`, button('删除', 'databases.db.delete', `data-index="${index}"`, 'danger'))).join('') || empty('暂无数据库')}</div><div><h3>账户</h3>${users.map((user, index) => row(`<span class="mono">${esc(user.name)}${user.host ? `@${esc(user.host)}` : ''}</span>`, `${button('重置密码', 'databases.user.reset', `data-index="${index}"`)}${button('删除', 'databases.user.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('暂无账户')}</div></div>`, `${button('建库', 'databases.db.create')}${button('建用户', 'databases.user.create')}${button('授权', 'databases.grant')}${engine === 'mysql' ? button('设置管理密码', 'databases.mysql.password') : ''}${engine === 'postgresql' && instance.auth_state !== 'local_password' ? button('启用本机密码连接', 'databases.pg.access') : ''}`);
  }
  if (S.acl) {
    return card(`${instance.name} · ACL`, `<p class="help">${S.acl.persistent ? 'ACL 已持久化' : 'ACL 尚未持久化'}</p>${(S.acl.users || []).map((user, index) => row(`<span class="mono">${esc(user.name)}</span> ${tag(user.enabled ? '启用' : '停用', user.enabled)} ${tag(user.level === 'readwrite' ? '读写' : '只读')}`, `${button('重置密码', 'databases.acl.reset', `data-index="${index}"`)}${button(user.enabled ? '停用' : '启用', 'databases.acl.toggle', `data-index="${index}"`)}${button(user.level === 'readwrite' ? '设为只读' : '设为读写', 'databases.acl.level', `data-index="${index}"`)}${button('删除', 'databases.acl.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('暂无 ACL 用户')}`, `${!S.acl.persistent ? button('启用持久化 ACL', 'databases.acl.enable') : ''}${button('建用户', 'databases.acl.create')}${button('设置默认账户密码', 'databases.acl.credential')}`);
  }
  return card(`${instance.name} · 实例状态`, `<div class="inline">${tag(instance.running ? '运行中' : '已停止', instance.running)} ${tag(instance.auth_state || '状态未知')}</div><p class="help">此数据库当前提供实例状态总览。</p>`);
}
async function databaseAction(action, index, id) {
  if (action === 'databases.select') { S.selectedDatabase = id; await refresh(); return; }
  const engine = S.selectedDatabase;
  const dbs = S.catalog?.databases || [], users = S.catalog?.users || [], aclUsers = S.acl?.users || [];
  if (action === 'databases.db.create' || action === 'databases.user.create' || action === 'databases.acl.create') {
    const acl = action === 'databases.acl.create';
    modal(acl ? '创建 ACL 用户' : action === 'databases.db.create' ? '创建数据库' : '创建账户', [
      { name: 'name', label: acl ? '账户名称' : action === 'databases.db.create' ? '数据库名' : '账户名', required: true },
      ...(acl ? [{ name: 'level', label: '权限', type: 'select', options: [['readwrite', '读写'], ['read', '只读']] }] : [])
    ], async ({ name, level }) => {
      const result = await api(action === 'databases.db.create' ? 'databases.create' : acl ? 'databases.acl.create' : 'databases.user.create',
        { engine, name, level });
      if (result?.password) info('请保存新账户密码', `${result.user}\n${result.password}`);
      await refresh(false);
    }, '创建');
  } else if (action === 'databases.db.delete' && confirm(`删除数据库 ${dbs[index]} 及其中数据？`))
    await mutate('databases.delete', { engine, name: dbs[index] });
  else if (action === 'databases.user.delete' && confirm(`删除账户 ${users[index].name}？`))
    await mutate('databases.user.delete', { engine, name: users[index].name });
  else if (action === 'databases.user.reset' && confirm(`重置 ${users[index].name} 的密码？`)) {
    const result = await api('databases.user.reset', { engine, name: users[index].name });
    info('新密码（仅显示一次）', `${result.user}\n${result.password}`);
  } else if (action === 'databases.grant') modal('授权或撤销', [
    { name: 'database', label: '数据库', type: 'select', options: dbs.map((name) => [name, name]) },
    { name: 'user', label: '账户', type: 'select', options: users.map((user) => [user.name, `${user.name}${user.host ? '@' + user.host : ''}`]) },
    { name: 'level', label: '权限', type: 'select', options: [['readwrite', '读写'], ['read', '只读']] },
    { name: 'revoke', label: '撤销权限', type: 'checkbox', value: false }
  ], async (values) => { await api('databases.grant', { engine, ...values }); await refresh(false); });
  else if (action === 'databases.mysql.password') modal('保存 MySQL 管理密码', [
    { name: 'password', label: '已有管理密码（留空则尝试安装时的临时密码）', type: 'password' }
  ], async ({ password }) => {
    const result = password ? await api('databases.mysql.credential', { password }) : await api('databases.mysql.bootstrap');
    if (result?.password) info('新管理密码（仅显示一次）', result.password);
    await refresh(false);
  });
  else if (action === 'databases.pg.access' && confirm('为 PostgreSQL 启用本机密码连接并重启服务？'))
    await mutate('databases.postgresql.localAccess');
  else if (action === 'databases.acl.enable' && confirm('启用持久化 ACL 并重启服务？'))
    await mutate('databases.acl.enable', { engine });
  else if (action === 'databases.acl.credential') modal('保存默认账户密码', [
    { name: 'password', label: '现有密码', type: 'password', required: true }
  ], async ({ password }) => { await api('databases.acl.credential', { engine, password }); await refresh(false); });
  else if (action === 'databases.acl.reset' && confirm(`重置 ${aclUsers[index].name} 的密码？`)) {
    const result = await api('databases.acl.reset', { engine, name: aclUsers[index].name });
    info('新密码（仅显示一次）', `${result.user}\n${result.password}`);
  } else if (action === 'databases.acl.toggle' || action === 'databases.acl.level') {
    const user = aclUsers[index];
    await mutate('databases.acl.update', { engine, name: user.name,
      enabled: action === 'databases.acl.toggle' ? !user.enabled : user.enabled,
      level: action === 'databases.acl.level' ? (user.level === 'readwrite' ? 'read' : 'readwrite') : user.level });
  } else if (action === 'databases.acl.delete' && confirm(`删除 ACL 账户 ${aclUsers[index].name}？`))
    await mutate('databases.acl.delete', { engine, name: aclUsers[index].name });
}

renders.installer = () => {
  $('#page-actions').innerHTML = '';
  $('#content').innerHTML = `${card('通过 SSH 安装', '<p>输入服务器 SSH 信息，确认主机指纹后，应用会上传内置安装文件、执行安装并保存 HTTPS 连接。</p><button data-action="installer.ssh">填写 SSH 信息…</button><p class="help">SSH 仅用于安装；日常管理使用 HTTPS API。SSH 密码只用于本次安装，不保存。</p>')}
    ${card('通过命令行安装', `<div class="toolbar"><select id="installer-arch"><option value="amd64">x86_64 / amd64</option><option value="arm64">aarch64 / arm64</option></select><button data-action="installer.export">导出 sera 安装文件…</button></div><p class="help">在服务器上运行 uname -m 查看架构。将文件上传到 /tmp/sera-install，以 root 或 sudo 执行：</p><div class="code">chmod 755 /tmp/sera-install\nsudo /tmp/sera-install install -host 服务器地址</div><p class="help">安装器会打印 HTTPS 地址、API 令牌和证书指纹。请将三项填入「连接设置」，并放行 TCP 27520。</p>`)}
    ${card('绑定域名与证书', '<p>域名解析与正式证书可由管理员配置。服务端监听 27520，证书更新后需要重启 server-status 服务。</p>')}`;
};
function sshInstallForm() {
  modal('通过 SSH 安装服务端', [
    { name: 'host', label: 'SSH 主机 IP / 域名', required: true },
    { name: 'port', label: 'SSH 端口', type: 'number', value: 22, required: true },
    { name: 'username', label: 'SSH 用户', value: 'root', required: true },
    { name: 'address', label: 'HTTPS 连接地址 IP / 域名', placeholder: '默认与 SSH 主机相同' },
    { name: 'password', label: 'SSH 密码（使用私钥时留空）', type: 'password', full: true },
    { name: 'privateKeyPath', label: 'SSH 私钥文件（可选）', browse: 'ssh-key', full: true },
    { name: 'passphrase', label: '私钥口令（可选）', type: 'password' },
    { name: 'sudoPassword', label: 'sudo 密码（非 root 且需要时填写）', type: 'password' }
  ], async (input) => {
    const target = { ...input, host: input.host.trim(), address: input.address.trim() || input.host.trim() };
    setNotice('正在检查 SSH 主机密钥…');
    const key = await window.sera.probeSSH(target);
    const description = `${key.previousFingerprint ? `先前：${key.previousFingerprint}\n` : ''}当前：${key.fingerprint}\n\n请从服务器控制台核对当前指纹。确认后继续安装？`;
    if (!confirm(description)) { setNotice('已取消安装'); return; }
    setNotice('正在通过 SSH 安装服务端，可能需要几分钟…');
    let result;
    try { result = await window.sera.installSSH(target, key.fingerprint); }
    catch (error) { setNotice(error.message || String(error), true); throw error; }
    S.doc = await window.sera.saveConnection({ name: target.host, endpoint: result.endpoint,
      token: result.token, fingerprint: result.fingerprint });
    renderChrome();
    info('服务端已安装', `HTTPS：${result.endpoint}\nAPI 令牌：${result.token}\n证书指纹：${result.fingerprint}\n\n连接已保存，请放行 TCP 27520。`);
    await refresh(false);
  }, '检查指纹并安装');
}
async function loadDNSRecords() {
  const result = await window.sera.dnsCall('DescribeDomainRecords', { DomainName: S.dnsSelected,
    PageNumber: 1, PageSize: S.dnsSettings.pageSize });
  const raw = result.DomainRecords?.Record || [];
  S.dnsRecords = Array.isArray(raw) ? raw : [raw];
}
renders.domains = () => {
  $('#page-actions').innerHTML = `${button('阿里云配置', 'domains.settings')}${S.dnsSelected ? button('申请证书', 'domains.certificate') : ''}`;
  if (!S.dnsSettings.hasSecret) {
    $('#content').innerHTML = empty('先配置阿里云 AccessKey ID 与 Secret，再查看域名和解析记录');
    return;
  }
  $('#content').innerHTML = `${card('域名', `<div class="grid">${S.dnsDomains.map((domain, index) => `<button class="card" style="text-align:left;color:inherit" data-action="domains.select" data-index="${index}"><strong>${esc(domain.DomainName)}</strong><p class="small">${esc(domain.RecordCount || 0)} 条记录 · ${esc(domain.VersionName || '')}</p></button>`).join('') || empty('此账号没有域名')}</div>`)}
    ${S.dnsSelected ? card(`${S.dnsSelected} · 解析记录`, `<table class="table"><thead><tr><th>主机</th><th>类型</th><th>值</th><th>TTL</th><th>状态</th><th></th></tr></thead><tbody>${S.dnsRecords.map((record, index) => `<tr><td class="mono">${esc(record.RR)}</td><td>${esc(record.Type)}</td><td class="mono">${esc(record.Value)}</td><td>${esc(record.TTL)}</td><td>${tag(record.Status === 'ENABLE' ? '启用' : '停用', record.Status === 'ENABLE')}</td><td class="actions-cell">${button('编辑', 'domains.edit', `data-index="${index}"`)} ${button('删除', 'domains.delete', `data-index="${index}"`, 'danger')}</td></tr>`).join('')}</tbody></table>${S.dnsRecords.length ? '' : empty('没有解析记录')}`, button('新增记录', 'domains.add')) : ''}
    ${card('证书', `<p class="help">使用当前阿里云账号自动添加 DNS-01 TXT 记录，向 Let’s Encrypt 申请证书。续期可再次申请；证书文件存于本机应用数据目录，部署到服务器由管理员完成。</p>${(S.certificates || []).map((cert) => row(`<strong>${esc(cert.domains.join('、'))}</strong><div class="small muted">到期 ${esc(String(cert.notAfter || '').slice(0, 10))} · ${esc(cert.keyType)}</div><div class="mono small muted">${esc(cert.fullchainPath)}<br>${esc(cert.privateKeyPath)}</div>`, button('复制证书路径', 'domains.cert.copy', `data-cert="${esc(cert.id)}"`))).join('') || empty('尚未申请证书')}`)}`;
};
function dnsRecordForm(record) {
  modal(record ? '编辑解析记录' : '新增解析记录', [
    { name: 'rr', label: '主机记录（主域名填 @）', value: record?.RR || '', required: true },
    { name: 'type', label: '类型', type: 'select', options: ['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'NS', 'SRV', 'CAA'].map((type) => [type, type]), value: record?.Type || 'A' },
    { name: 'value', label: '记录值', value: record?.Value || '', required: true, full: true },
    { name: 'ttl', label: 'TTL（秒）', type: 'number', value: record?.TTL || S.dnsSettings.defaultTTL },
    { name: 'priority', label: '优先级（MX/SRV，1–50）', type: 'number', value: record?.Priority || '' }
  ], async (values) => {
    if (values.type === 'A' && !/^(?:\d{1,3}\.){3}\d{1,3}$/.test(values.value.trim())) throw new Error('A 记录需要 IPv4 地址');
    const params = { RR: values.rr.trim(), Type: values.type, Value: values.value.trim(),
      TTL: Math.max(60, Math.min(86400, Number(values.ttl) || 600)) };
    if (['MX', 'SRV'].includes(values.type)) {
      if (!(Number(values.priority) >= 1 && Number(values.priority) <= 50)) throw new Error('优先级须在 1–50 之间');
      params.Priority = Number(values.priority);
    }
    if (record) params.RecordId = record.RecordId;
    else params.DomainName = S.dnsSelected;
    await window.sera.dnsCall(record ? 'UpdateDomainRecord' : 'AddDomainRecord', params);
    await loadDNSRecords();
    renders.domains();
  });
}
async function domainAction(action, index, certId) {
  if (action === 'domains.settings') modal('阿里云解析配置', [
    { name: 'accessKeyId', label: 'AccessKey ID', value: S.dnsSettings.accessKeyId, required: true, full: true },
    { name: 'secret', label: S.dnsSettings.hasSecret ? 'AccessKey Secret（留空保持原值）' : 'AccessKey Secret', type: 'password', required: !S.dnsSettings.hasSecret, full: true },
    { name: 'pageSize', label: '每页记录数（10–100）', type: 'number', value: S.dnsSettings.pageSize || 50 },
    { name: 'defaultTTL', label: '默认 TTL', type: 'number', value: S.dnsSettings.defaultTTL || 600 }
  ], async (values) => {
    await window.sera.saveDNS(values);
    await refresh(false);
  });
  else if (action === 'domains.select') {
    S.dnsSelected = S.dnsDomains[index].DomainName;
    await loadDNSRecords();
    renders.domains();
  } else if (action === 'domains.add') dnsRecordForm();
  else if (action === 'domains.certificate') modal('申请 Let’s Encrypt 证书', [
    { name: 'domains', label: '证书域名（逗号或换行分隔，支持 *.example.com）', type: 'textarea',
      value: S.dnsSelected, required: true, full: true },
    { name: 'email', label: '联系人邮箱', type: 'email', required: true, full: true },
    { name: 'keyType', label: '密钥类型', type: 'select', options: [['ecc', 'ECC P-256'], ['rsa2048', 'RSA 2048']] }
  ], async (values) => {
    setNotice('正在申请证书；DNS 验证通常需要几分钟，请保持应用运行。');
    const result = await window.sera.issueCertificate({ zone: S.dnsSelected,
      domains: values.domains.split(/[\s,，]+/).filter(Boolean), email: values.email, keyType: values.keyType });
    S.certificates = await window.sera.certificates();
    renders.domains();
    info('证书申请成功', `全链：${result.fullchainPath}\n私钥：${result.privateKeyPath}`);
  }, '开始申请');
  else if (action === 'domains.cert.copy') {
    const cert = (S.certificates || []).find((entry) => entry.id === certId);
    if (cert) await window.sera.clipboardWrite(`${cert.fullchainPath}\n${cert.privateKeyPath}`);
    setNotice('证书路径已复制');
  }
  else if (action === 'domains.edit') dnsRecordForm(S.dnsRecords[index]);
  else if (action === 'domains.delete') {
    const record = S.dnsRecords[index];
    if (confirm(`删除 ${record.RR}.${S.dnsSelected} 的 ${record.Type} 记录？`)) {
      await window.sera.dnsCall('DeleteDomainRecord', { RecordId: record.RecordId });
      await loadDNSRecords();
      renders.domains();
    }
  }
}

document.addEventListener('click', async (event) => {
  const browse = event.target.closest('[data-browse]');
  if (browse) {
    if (browse.dataset.browse === 'ssh-key') {
      const file = await window.sera.chooseSSHKey();
      if (file) $('#field-privateKeyPath').value = file;
    } else await openProjectPathPicker(browse.dataset.browse);
    return;
  }
  const pathButton = event.target.closest('[data-path-action]');
  if (pathButton) {
    const action = pathButton.dataset.pathAction;
    if (action === 'close') $('#path-modal').close();
    else if (action === 'go') await loadProjectPath($('#picker-path').value.trim());
    else if (action === 'up') await loadProjectPath(P.listing?.parent || '/');
    else if (action === 'choose-current') applyProjectPath(P.path);
    else if (action === 'go-current') applyProjectPath(P.path, true);
    return;
  }
  const sectionButton = event.target.closest('[data-section]');
  if (sectionButton) { S.section = sectionButton.dataset.section; await refresh(); return; }
  const target = event.target.closest('[data-action]');
  if (!target) return;
  const action = target.dataset.action, index = Number(target.dataset.index || 0), part = Number(target.dataset.part || 0);
  try {
    if (action === 'picker.enter') await loadProjectPath(P.entries[index].path);
    else if (action === 'picker.choose') applyProjectPath(P.entries[index].path);
    else if (action.startsWith('files.')) await fileAction(action, index);
    else if (action.startsWith('sites.')) await siteAction(action, index);
    else if (action.startsWith('projects.')) await projectAction(action, index);
    else if (action.startsWith('environments.')) await environmentAction(action, index, part);
    else if (action.startsWith('software.') || action.startsWith('services.'))
      await softwareAction(action, index, target.dataset.command);
    else if (action.startsWith('firewall.')) await firewallAction(action, index);
    else if (action.startsWith('tasks.')) await taskAction(action, index);
    else if (action.startsWith('databases.')) await databaseAction(action, index, target.dataset.id);
    else if (action.startsWith('domains.')) await domainAction(action, index, target.dataset.cert);
    else if (action === 'installer.export') {
      const file = await window.sera.exportInstaller($('#installer-arch').value);
      if (file) setNotice(`已导出到 ${file}`);
    } else if (action === 'installer.ssh') sshInstallForm();
  } catch (error) { setNotice(error.message || String(error), true); }
});
document.addEventListener('keydown', (event) => {
  if (event.target.id === 'picker-path' && event.key === 'Enter') {
    event.preventDefault();
    loadProjectPath(event.target.value.trim());
  }
});
document.addEventListener('input', (event) => {
  if (event.target.id === 'store-search') {
    S.searchStore = event.target.value;
    const position = event.target.selectionStart;
    renders.store();
    $('#store-search').focus();
    $('#store-search').setSelectionRange(position, position);
  }
});
let fileDragDepth = 0;
const hasDroppedFiles = (event) => Array.from(event.dataTransfer?.types || []).includes('Files');
document.addEventListener('dragenter', (event) => {
  if (!hasDroppedFiles(event)) return;
  event.preventDefault();
  if (S.section === 'files') {
    fileDragDepth++;
    $('#content').classList.add('file-drop-active');
  }
});
document.addEventListener('dragover', (event) => {
  if (!hasDroppedFiles(event)) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = S.section === 'files' && !S.busy ? 'copy' : 'none';
});
document.addEventListener('dragleave', (event) => {
  if (!hasDroppedFiles(event)) return;
  fileDragDepth = Math.max(0, fileDragDepth - 1);
  if (!fileDragDepth) $('#content').classList.remove('file-drop-active');
});
document.addEventListener('drop', async (event) => {
  if (!hasDroppedFiles(event)) return;
  event.preventDefault();
  fileDragDepth = 0;
  $('#content').classList.remove('file-drop-active');
  if (S.section !== 'files' || S.busy || !event.target.closest('#content')) return;
  try { await beginFileUpload(await window.sera.registerDropped(event.dataTransfer.files)); }
  catch (error) { setNotice(error.message || String(error), true); }
});
window.sera.onUploadProgress(({ completed, total, name }) => {
  if (S.section === 'files') setNotice(`正在上传 ${completed}/${total}：${name}`);
});
$('#connection-select').addEventListener('change', async (event) => {
  try {
    S.doc = await window.sera.selectConnection(event.target.value);
    S.selectedDatabase = '';
    S.filePath = '/www/seraphim';
    await refresh();
  } catch (error) { setNotice(error.message, true); }
});
$('#connection-edit').addEventListener('click', () => {
  const entry = selectedConnection();
  if (entry) editConnection(entry);
});
$('#connection-add').addEventListener('click', () => editConnection());
$('#refresh').addEventListener('click', () => refresh());
let statusPolling = false;
setInterval(async () => {
  if (statusPolling || S.section !== 'status' || !selectedConnection() || S.busy || $('#modal').open || document.hidden) return;
  statusPolling = true;
  const connectionID = S.doc.selectedID;
  try {
    const snapshot = await api('status');
    if (S.section === 'status' && S.doc.selectedID === connectionID) {
      S.data = snapshot;
      renders.status();
    }
  } catch (error) { setNotice(error.message || String(error), true); }
  finally { statusPolling = false; }
}, 5000);
loadConnections().then(() => refresh()).catch((error) => setNotice(error.message, true));
