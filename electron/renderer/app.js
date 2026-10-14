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
// 剪贴板在部分环境下会被拒绝，失败了不要静默，至少把内容告诉用户。
async function copyText(text, success) {
  if (!text) return '没有可复制的内容';
  try {
    await navigator.clipboard.writeText(text);
    return success;
  } catch {
    return `无法访问剪贴板，请手动复制：${text}`;
  }
}
// 属主列显示成「所有者:用户组」，两者相同时只显示所有者。
const ownerLabel = (file) => !file?.owner ? '—'
  : (file.group && file.group !== file.owner ? `${file.owner}:${file.group}` : file.owner);
// 证书里的域名是否覆盖某个主机名：精确匹配或单层通配（*.example.com）。
const hostMatches = (host, rule) => {
  const name = String(host || '').toLowerCase().replace(/^\.+|\.+$/g, '');
  const pattern = String(rule || '').toLowerCase().replace(/^\.+|\.+$/g, '');
  if (!name || !pattern) return false;
  if (name === pattern) return true;
  if (!pattern.startsWith('*.')) return false;
  const suffix = pattern.slice(1);
  if (!name.endsWith(suffix)) return false;
  const label = name.slice(0, -suffix.length);
  return label.length > 0 && !label.includes('.');
};

const groups = [
  ['概览', [['status', '服务器状态']]],
  ['站点与数据', [['files', '文件管理'], ['domains', '域名管理'], ['sites', '网站管理'], ['projects', '项目管理'], ['databases', '数据库管理']]],
  ['运行与安全', [['services', '软件管理'], ['environments', '环境管理'], ['variables', '环境变量管理'], ['store', '软件商店'], ['firewall', '防火墙'], ['tasks', '计划任务'], ['api', 'API 设置']]],
  ['部署', [['installer', '安装服务端']]]
];
const titles = Object.fromEntries(groups.flatMap(([group, items]) => items.map(([id, title]) => [id, [group, title]])));
const subtitles = {
  status: '查看服务器实时状态。桌面客户端通过 HTTPS API 通信。',
  files: '浏览服务器文件系统；默认位于 /www/seraphim，可查看并修改权限与所有者。',
  domains: '管理域名解析与证书。',
  sites: '管理 Nginx、Apache 和 OpenResty 网站；在本机申请的证书可就地部署到网站并启用 HTTPS。',
  projects: '管理 Python、Node.js、Go 等常驻项目；启动失败时给出自检清单、依赖状态与日志。',
  variables: '面板统一保管的一份公用变量；项目勾上才加载，代码也可以直接读服务器上导出的共用文件。',
  api: '面板的接口列表和一把能直接用的 key；脚本与 AI 客户端都从这里接进来。',
  databases: '查看数据库实例并管理库、用户与权限。',
  services: '只管理已安装软件：运行状态、开机启动、日志与卸载。',
  environments: '动态读取可安装版本，管理独立安装的运行环境。',
  firewall: '管理防火墙服务的启停与入站端口规则。',
  tasks: '创建每小时、每天或每周执行的计划任务。',
  store: '浏览软件目录并安装；装好后到软件管理操作。',
  installer: '通过 SSH 自动安装，或导出安装文件在服务器命令行部署。'
};
const S = { section: 'status', doc: { entries: [], selectedID: '' }, data: null, filePath: '/www/seraphim',
  expanded: new Set(), versions: {}, selectedDatabase: '', catalog: null, acl: null, busy: false,
  // globalVariables 只在项目管理页用到：编辑项目时要告诉用户会加载哪些值。
  globalVariables: [], searchServices: '', filterServices: 'all' };

// 这些运行时由「环境管理」按版本安装，软件商店只给入口，避免同一个运行时两处可装。
const RUNTIME_IDS = new Set(['python', 'go', 'node', 'openjdk', 'dotnet', 'ruby', 'bun', 'deno', 'php']);
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
    // 端口这类字段给一个「让服务器挑个没被占用的」按钮，省得自己去猜。
    if (field.port) control = `<div class="inline">${control}<button type="button" class="secondary" data-free-port>选择空闲端口</button></div>`;
    return `<div class="field ${field.full ? 'full' : ''}"><label for="${id}">${esc(field.label)}</label>${control}</div>`;
  }).join('')}</div><p class="help" id="modal-error"></p></div>`;
  $('#modal-submit').textContent = label;
  $('#modal-submit').hidden = !submit;
  const dialog = $('#modal');
  dialog.onclose = null;
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
  // 表单是 method="dialog"，残留的 onsubmit 会让回车键把窗口关掉。
  $('#modal-form').onsubmit = (event) => event.preventDefault();
  $('#modal').onclose = null;
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
  // 离开变量页就不再显示上一次的保存结果。
  if (section !== 'variables') S.variablesNotice = '';
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
  projects: async () => {
    // 变量表读失败不该让整个项目管理打不开，单独兜住。
    const [listing, variables] = await Promise.all([
      api('projects.list'),
      api('variables.get').catch(() => ({ variables: [] }))
    ]);
    S.data = listing;
    S.globalVariables = variables.variables || [];
  },
  variables: async () => { S.data = await api('variables.get'); },
  api: async () => { S.data = await api('api.doc'); },
  environments: async () => { S.data = await api('environments.list'); },
  services: async () => { S.data = await Promise.all([api('software.list'), api('software.jobs')]); },
  store: async () => { S.data = await Promise.all([api('software.list'), api('software.jobs')]); },
  firewall: async () => { S.data = await Promise.all([api('firewall.get'), api('services.list')]); },
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
    <section class="card"><table class="table"><thead><tr><th>名称</th><th>权限</th><th>所有者</th><th>大小</th><th>修改时间</th><th></th></tr></thead><tbody>${entries.map((file, index) => `<tr><td>${file.kind === 'directory' ? '📁' : '📄'} <button class="linklike mono" data-action="files.open" data-index="${index}">${esc(file.name)}</button></td><td class="mono">${esc(file.permissions || '—')}</td><td class="mono"><button class="linklike" data-action="files.owner" data-index="${index}">${esc(ownerLabel(file))}</button></td><td>${file.kind === 'directory' ? '—' : fmtBytes(file.size_bytes)}</td><td>${esc((file.modified_at || '').replace('T', ' ').slice(0, 16))}</td><td class="actions-cell"><div class="actions">${file.kind === 'directory' ? button('进入', 'files.open', `data-index="${index}"`) : button('下载', 'files.download', `data-index="${index}"`)}${button('重命名', 'files.rename', `data-index="${index}"`)}${button('权限', 'files.chmod', `data-index="${index}"`)}${button('属主', 'files.owner', `data-index="${index}"`)}${button('删除', 'files.delete', `data-index="${index}"`, 'danger')}</div></td></tr>`).join('')}</tbody></table>${entries.length ? '' : empty('此目录为空')}</section>`;
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
  } else if (action === 'files.owner') {
    const fields = [
      { name: 'owner', label: '所有者（账户名或 UID）', value: file.owner || '', placeholder: '留空表示不变' },
      { name: 'group', label: '用户组（组名或 GID）', value: file.group || '', placeholder: '留空表示不变' }
    ];
    if (file.kind === 'directory') fields.push({ name: 'recursive', label: '同时应用到目录内的全部内容', type: 'checkbox', value: true });
    modal('修改所有者', fields, async (values) => {
      const owner = (values.owner || '').trim(), group = (values.group || '').trim();
      if (!owner && !group) throw new Error('请填写所有者或用户组；空着的那一项保持不变');
      await api('files.command', { operation: 'chown', path: file.path, owner, group, recursive: !!values.recursive });
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
    ${sites.map((site, index) => card(site.domains?.[0] || site.id, `<div class="inline">${tag(site.provider)} ${tag(site.kind === 'proxy' ? '反向代理' : site.kind === 'php' ? `PHP ${site.php_version || ''}` : '静态网站')} ${tag(site.enabled ? '已启用' : '已停用', site.enabled)} ${site.tls ? tag(site.tls_expires_at ? `HTTPS 至 ${esc(String(site.tls_expires_at).slice(0, 10))}` : 'HTTPS 443', true) : tag('未部署证书')}</div><dl class="kv"><dt>域名</dt><dd>${esc((site.domains || []).join('、'))}</dd><dt>目录</dt><dd class="mono">${esc(site.root)}</dd>${site.kind === 'proxy' ? `<dt>上游</dt><dd class="mono">${esc(site.upstream)}</dd>` : ''}</dl>`, `${button(site.tls ? '更换证书' : '部署证书', 'sites.cert', `data-index="${index}"`)}${button('编辑', 'sites.edit', `data-index="${index}"`)}${button(site.enabled ? '停用' : '启用', 'sites.toggle', `data-index="${index}"`)}${site.kind !== 'proxy' ? button('文件', 'sites.files', `data-index="${index}"`) : ''}${button('删除', 'sites.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('尚无网站')}`;
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
  else if (action === 'sites.cert') {
    if (!site.enabled) throw new Error('网站已停用，请先启用再部署证书');
    const certificates = await window.sera.certificates();
    S.certificates = certificates;
    if (!certificates.length) throw new Error('本机还没有已签发的证书；请先到「域名管理」申请');
    const covering = certificates.filter((cert) =>
      (site.domains || []).every((domain) => (cert.domains || []).some((rule) => hostMatches(domain, rule))));
    const ordered = [...covering, ...certificates.filter((cert) => !covering.includes(cert))];
    modal(`部署证书到 ${site.domains?.[0] || site.id}`, [{ name: 'certificate', label: '本机已签发的证书', type: 'select',
      options: ordered.map((cert) => [cert.id, `${cert.domains.join('、')} · 续期 ${String(cert.notAfter || '').slice(0, 10)}`
        + (covering.includes(cert) ? '' : '（未覆盖本站域名）')]) }],
    async ({ certificate }) => {
      await window.sera.deployCertificate(certificate, site.provider, site.id);
      await refresh(false);
      setNotice('证书已部署，网站 HTTPS 已启用');
    }, '部署');
  }
  else if (action === 'sites.delete' && confirm(`删除 ${site.domains?.[0] || site.id} 的网站配置？网站文件会保留。`))
    await mutate('sites.delete', { provider: site.provider, id: site.id }, '网站配置已删除');
}

const defaultEntries = { python: 'main.py', node: 'index.js', go: '.', openjdk: 'app.jar', dotnet: 'app.dll',
  ruby: 'app.rb', bun: 'index.ts', deno: 'main.ts' };

// systemd 在「起了又崩」时 ActiveState 仍是 activating/active，只看它就等于把崩溃
// 显示成「运行中」。子状态与 Result 才是真相。
const projectStateLabel = (project) => project.sub_state === 'auto-restart' ? '反复重启'
  : ({ active: '运行中', inactive: '已停止', failed: '启动失败', activating: '启动中',
       deactivating: '停止中' }[project.active_state] || '状态未知');
const projectFailureText = (project) => {
  if (project.sub_state === 'auto-restart') return '进程反复退出，systemd 正在自动重启';
  const reason = { 'exit-code': '启动后立即退出', signal: '被信号终止', timeout: '启动超时',
    'start-limit-hit': '连续失败次数过多，已放弃重启' }[project.result];
  if (reason) return project.exit_status > 0 ? `${reason}（退出码 ${project.exit_status}）` : reason;
  return project.active_state === 'failed' ? '启动未成功' : '';
};
// Python 项目的启动方式：服务端用 python_server 区分 uvicorn / uwsgi / gunicorn / 直接跑。
// 取值要和 macOS 客户端的 serverLabel 保持一致。
const projectServerLabel = (project) => ({
  gunicorn: 'Gunicorn', uwsgi: 'uWSGI', uvicorn: 'Uvicorn'
}[project.python_server] || '直接运行');
const projectStartupText = (project) => {
  if (project.runtime !== 'python') return project.entry;
  const server = projectServerLabel(project);
  if (server === '直接运行') return `直接运行 ${project.entry}`;
  const worker = project.python_server === 'gunicorn'
    ? ` · ${project.python_worker || (project.python_threads > 1 ? 'gthread' : 'sync')} worker` : '';
  return `${server} · ${project.python_callable || 'app'} · ${project.python_workers || 2} 进程${worker}`;
};
const fmtUptime = (value) => {
  let seconds = Math.max(0, Math.floor(Number(value) || 0));
  if (!seconds) return '';
  const units = [[86400, '天'], [3600, '小时'], [60, '分钟'], [1, '秒']];
  const parts = [];
  for (const [size, label] of units) {
    if (parts.length === 2) break;
    if (seconds >= size) { parts.push(`${Math.floor(seconds / size)}${label}`); seconds %= size; }
  }
  return parts.join(' ');
};
// 卡片上的动作太多会糊成一片，主操作留在外面，其余收进「更多」浮层。
const actionMenu = (label, items) => `<details class="menu"><summary>${esc(label)} ▾</summary><div class="menu-body">${items.filter(Boolean).join('')}</div></details>`;
renders.projects = () => {
  $('#page-actions').innerHTML = '<button data-action="projects.new">新建项目</button>';
  const projects = list(S.data), runtimes = S.data.runtimes || [];
  $('#content').innerHTML = projects.map((project, index) => {
    const runtime = runtimes.find((item) => item.id === project.runtime);
    const failure = projectFailureText(project);
    const running = project.active_state === 'active';
    const startable = project.runtime_ready && (!project.use_venv || project.venv_ready) && project.server_ready !== false;
    const runtimeInfo = [
      project.main_pid > 0 ? `PID ${project.main_pid}` : '',
      project.memory_bytes > 0 ? `内存 ${fmtBytes(project.memory_bytes)}` : '',
      running && project.uptime_seconds > 0 ? `已运行 ${fmtUptime(project.uptime_seconds)}` : '',
      project.restarts > 0 ? `已重启 ${project.restarts} 次` : ''
    ].filter(Boolean).join(' · ');
    const envRows = Object.entries(project.env || {})
      .map(([key, value]) => `<dt>${esc(key)}</dt><dd class="mono">${esc(value)}</dd>`).join('')
      + (project.env_file ? '<dt>环境文件</dt><dd class="mono">工程目录下的 .env</dd>' : '');
    // 面板那份公用变量：默认不加载，勾上的项目才会读到；不加载就不占地方。
    const inheritedRow = project.use_global_env === true
      ? `<dt>面板环境变量</dt><dd class="muted">已加载「环境变量管理」里的值（同名以项目自己的为准） · <a href="#" data-action="variables.goto">打开环境变量管理</a></dd>`
      : '';
    const pythonDetail = project.runtime === 'python'
      ? `<dt>启动方式</dt><dd>${esc(projectStartupText(project))}</dd>` : '';
    const dependencyLine = dependencyCardText(project.dependency);
    const dependencyRow = dependencyLine
      ? `<dt>依赖清单</dt><dd>${esc(dependencyLine)}</dd>` : '';
    const actions = `${button('详情', 'projects.detail', `data-index="${index}"`)}${button(running ? '停止' : '启动', 'projects.toggle', `data-index="${index}"`)}${running ? button('重启', 'projects.restart', `data-index="${index}"`) : ''}${actionMenu('更多', [
      button('编辑配置', 'projects.edit', `data-index="${index}"`),
      button('打开工程目录', 'projects.files', `data-index="${index}"`),
      button('查看日志', 'projects.log', `data-index="${index}"`),
      button('安装依赖', 'projects.deps', `data-index="${index}"`),
      project.use_venv && !project.venv_ready ? button('创建虚拟环境', 'projects.venv', `data-index="${index}"`) : '',
      project.runtime === 'python' && project.python_server && project.python_server !== 'direct' && project.venv_ready && project.server_ready === false
        ? button(`安装 ${projectServerLabel(project)}`, 'projects.server', `data-index="${index}"`) : '',
      button(project.enabled ? '取消开机自启' : '开机自启', 'projects.enable', `data-index="${index}"`),
      project.port > 0 ? button('复制反向代理地址', 'projects.proxy', `data-index="${index}"`) : '',
      button('清空日志…', 'projects.clearlog', `data-index="${index}"`),
      button('删除', 'projects.delete', `data-index="${index}"`, 'danger')
    ])}`;
    return card(project.name, `<div class="inline">${tag(projectStateLabel(project), running && project.sub_state !== 'auto-restart')} ${tag(project.enabled ? '开机启动' : '不自启')} ${tag(`${runtime?.name || project.runtime} ${project.runtime_version || ''}`)} ${!project.runtime_ready ? tag('运行环境缺失') : ''} ${project.use_venv && !project.venv_ready ? tag('虚拟环境未就绪') : ''} ${project.server_ready === false ? tag('启动器未安装') : ''} ${project.port_busy ? tag('端口被占用') : ''} ${!running && !startable ? tag('环境未就绪，直接启动会失败') : ''}</div>${failure ? `<p class="help">${esc(failure)} · 点「详情」看启动自检和系统日志</p>` : ''}<dl class="kv"><dt>工程目录</dt><dd class="mono">${esc(project.directory)}</dd><dt>入口</dt><dd class="mono">${esc(project.entry)}</dd>${dependencyRow}${pythonDetail}<dt>端口</dt><dd>${esc(project.port || '未指定')}${project.port_busy ? '（已被其他进程占用）' : ''}</dd>${runtimeInfo ? `<dt>运行信息</dt><dd>${esc(runtimeInfo)}</dd>` : ''}${inheritedRow}${envRows}</dl>`, actions);
  }).join('') || empty('尚无服务器项目；可先上传项目文件，再创建项目配置');
};
// 环境变量管理：面板统一保管的一份公用变量。它不是某个项目的设置——面板只负责
// 存，谁读、读哪几个由使用方决定：项目可以勾上加载，也可以让代码直接读导出的文件。
renders.variables = () => {
  const variables = S.data?.variables || [];
  const file = S.data?.file || '';
  const text = variables.map((item) => `${item.name}=${item.value}`).join('\n');
  const updated = S.data?.updated_at ? S.data.updated_at.replace('T', ' ').slice(0, 16) : '';
  $('#page-actions').innerHTML = '';
  $('#content').innerHTML = `<section class="card">
    <div class="card-header"><h2>怎么取用</h2></div>
    <dl class="kv">
      <dt>项目读取</dt><dd>在项目里勾上「加载面板环境变量」，值会写进它的 systemd 单元；同名时以项目自己填的为准。不勾就完全不碰这个项目。</dd>
      <dt>代码读取</dt><dd class="mono">${file ? esc(file) : '（暂未获取到路径）'}</dd>
      ${file ? `<dt>用法</dt><dd class="mono">shell：. ${esc(file)}<br>代码：每行一个 KEY=VALUE，# 开头是注释</dd>` : ''}
      <dt>权限</dt><dd>文件属组 sera、权限 0640：项目进程与 Web 服务能读，其他本地用户读不到。</dd>
      <dt>计划任务</dt><dd>执行命令时会带上同一份值，脚本和常驻服务看到的东西一致。</dd>
    </dl>
    <p class="help">端口、PATH、虚拟环境这类由面板按项目分配，不能定义在这里。</p>
  </section>
  <section class="card" style="margin-top:12px">
    <div class="card-header"><h2>变量</h2><div class="actions">${button('保存', 'variables.save')}</div></div>
    ${S.variablesNotice ? `<p class="help">${esc(S.variablesNotice)}</p>` : ''}
    <div class="field full"><label for="variables-text">每行一个 KEY=VALUE，# 开头为注释</label>
    <textarea id="variables-text" class="mono" rows="14" spellcheck="false" placeholder="PROJECT_RUNTIME=dev&#10;API_BASE=https://example.test">${esc(text)}</textarea></div>
    <p class="help">共 ${variables.length} 项${updated ? ` · 最后更新 ${esc(updated)}` : ''}。保存会同时更新共用文件；勾了加载的项目会被同步并重启一次，没勾的项目不会被动到。</p>
  </section>`;
};
// API 设置：接口列表 + 一把给脚本与 AI 用的 key。
//
// 这把 key 是服务端单独存的一把（config/api-key），和面板连服务器用的凭据
// 不是同一个，所以这里能重置：脚本泄露就换掉它，已连上的面板不受影响。
// key 只由服务端生成，页面上没有填写框。
renders.api = () => {
  const doc = S.data || {};
  const sections = Array.isArray(doc.sections) ? doc.sections : [];
  const mcp = doc.mcp || {};
  const tools = Array.isArray(mcp.tools) ? mcp.tools : [];
  const total = sections.reduce((sum, section) => sum + (section.endpoints || []).length, 0);
  const endpoints = sections.map((section) => `
    <h3>${esc(section.name)}</h3>
    <dl class="kv">${(section.endpoints || []).map((endpoint) => `
      <dt class="mono">${esc(endpoint.method)} ${esc(endpoint.path)}</dt>
      <dd>${esc(endpoint.summary)}${endpoint.example
        ? `<pre class="code">${esc(endpoint.example)}</pre>` : ''}</dd>`).join('')}
    </dl>`).join('');
  const curl = `export SERAPHIM="${doc.endpoint || ''}"
export API_KEY="${doc.key || ''}"
curl -k -H "Authorization: Bearer $API_KEY" "$SERAPHIM/v1/projects"`;
  const httpConfig = JSON.stringify({ mcpServers: { seraphim: {
    type: 'http', url: mcp.url || '', headers: { Authorization: `Bearer ${doc.key || ''}` } } } }, null, 2);
  const stdioConfig = JSON.stringify({ mcpServers: { seraphim: {
    command: 'python3', args: ['<seraphim-mcp.py 的完整路径>'],
    env: { SERAPHIM_ENDPOINT: doc.endpoint || '', SERAPHIM_TOKEN: doc.key || '' } } } }, null, 2);
  $('#page-actions').innerHTML = '';
  $('#content').innerHTML = `
  <section class="card">
    <div class="card-header"><h2>连接信息</h2>
      <div class="actions">${button('复制 key', 'api.copy', 'data-copy="#api-key"')}
        ${button('重置 key', 'api.reset')}</div></div>
    <dl class="kv">
      <dt>服务地址</dt><dd class="mono">${esc(doc.endpoint || '—')}</dd>
      <dt>API key</dt><dd class="mono" id="api-key">${esc(doc.key || '—')}</dd>
      <dt>请求头</dt><dd class="mono">${esc(doc.header || '—')}</dd>
    </dl>
    <p class="help">这把 key 由服务端生成，与面板连服务器用的凭据是两把。脚本或 AI 客户端泄露时直接重置：旧 key 立刻失效，已经连上的面板不受影响。页面上只能重置，不能自己填。</p>
  </section>
  <section class="card" style="margin-top:12px">
    <div class="card-header"><h2>快速开始</h2>
      <div class="actions">${button('复制', 'api.copy', 'data-copy="#api-curl"')}</div></div>
    <p class="help">贴进终端就能列出服务器上的项目。常见的自动化：打包上传（POST /v1/projects/import）、启动（POST /v1/projects/{id}/action）、改公用变量（PUT /v1/variables）。重置 key 之后，这些脚本里的 key 也要换成新的。</p>
    <pre class="code" id="api-curl">${esc(curl)}</pre>
  </section>
  <section class="card" style="margin-top:12px">
    <div class="card-header"><h2>接口列表</h2></div>
    <p class="help">共 ${total} 个接口。带 {id} 的参数按实际项目标识替换。</p>
    ${endpoints || empty('暂未获取到接口列表')}
  </section>
  <section class="card" style="margin-top:12px">
    <div class="card-header"><h2>MCP（让 AI 直接管理）</h2>
      <div class="actions">${button('下载桥脚本', 'api.download')}</div></div>
    <p class="help">面板自带 MCP 端点，AI 客户端接上之后就能看项目、上传代码、启动服务、读自检。支持 HTTP 传输的用第一段配置；只支持 stdio 的（多数桌面客户端）先下载桥脚本，用它的完整路径替换第二段里的占位符。两段里填的都是上面这把 key，重置后要一起换。</p>
    <h3>HTTP 传输</h3>
    <div class="actions">${button('复制', 'api.copy', 'data-copy="#api-mcp-http"')}</div>
    <pre class="code" id="api-mcp-http">${esc(httpConfig)}</pre>
    <h3>stdio 传输</h3>
    <div class="actions">${button('复制', 'api.copy', 'data-copy="#api-mcp-stdio"')}</div>
    <pre class="code" id="api-mcp-stdio">${esc(stdioConfig)}</pre>
    <h3>AI 能用的 ${tools.length} 个工具</h3>
    <dl class="kv">${tools.map((tool) => `
      <dt class="mono">${esc(tool.name)}</dt><dd>${esc(tool.description)}</dd>`).join('')}</dl>
  </section>`;
};
async function apiAction(action, target) {
  if (action === 'api.copy') {
    const node = document.querySelector(target.dataset.copy || '');
    setNotice(await copyText(node ? node.textContent : '', '已复制'));
    return;
  }
  if (action === 'api.reset') {
    if (!confirm('重置 API key？\n服务端会生成新的一把，旧的立刻失效：正在用它的脚本和 AI 客户端都要换成新的。\n面板连服务器用的是另一份凭据，不会掉线。')) return;
    try {
      // 服务端把新的整份接入信息发回来，页面上的示例与 MCP 配置一起换掉。
      S.data = await api('api.reset');
      renders.api();
      setNotice('已重置：旧 key 立刻失效，脚本和 AI 客户端里的都要换成新的');
    } catch (error) { setNotice(error.message || String(error), true); }
    return;
  }
  if (action === 'api.download') {
    try {
      const text = await api('api.script');
      const url = URL.createObjectURL(new Blob([String(text)], { type: 'text/x-python' }));
      const link = document.createElement('a');
      link.href = url;
      link.download = 'seraphim-mcp.py';
      link.click();
      URL.revokeObjectURL(url);
      setNotice('桥脚本已下载；把它放到任意位置，用完整路径替换配置里的占位符');
    } catch (error) { setNotice(error.message || String(error), true); }
  }
}
async function variablesAction(action) {
  if (action === 'variables.goto') { S.section = 'variables'; await refresh(); return; }
  if (action !== 'variables.save' || S.busy) return;
  let items;
  try {
    items = Object.entries(parseEnvText($('#variables-text').value)).map(([name, value]) => ({ name, value }));
  } catch (error) { setNotice(error.message, true); return; }
  S.busy = true;
  try {
    const result = await api('variables.save', { variables: items });
    const applied = result.applied || [];
    const saved = (result.variables || []).length;
    S.variablesNotice = applied.length
      ? `已保存 ${saved} 项，并同步到 ${applied.length} 个项目：${applied.join('、')}`
      : (items.length
        ? `已保存 ${saved} 项，并写入共用文件；没有项目勾选加载，所以没有项目被同步`
        : '已清空，共用文件也同步清空了');
    setNotice(S.variablesNotice);
  } catch (error) { setNotice(error.message || String(error), true); }
  S.busy = false;
  await refresh(false);
}
// 环境变量在表单里按「每行一个 KEY=VALUE」编辑，空行与 # 注释忽略。
function parseEnvText(text) {
  const env = {};
  for (const line of String(text || '').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const index = trimmed.indexOf('=');
    if (index < 1) throw new Error(`环境变量要写成 KEY=VALUE：${trimmed}`);
    const name = trimmed.slice(0, index).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(name)) throw new Error(`环境变量名不合法：${name}`);
    env[name] = trimmed.slice(index + 1);
  }
  return env;
}
function formatEnvText(env) {
  return Object.entries(env || {}).map(([key, value]) => `${key}=${value}`).join('\n');
}
function projectForm(project) {
  const runtimes = S.data.runtimes || [];
  const first = project?.runtime || runtimes.find((item) => item.installed)?.id || runtimes[0]?.id || 'python';
  const selected = runtimes.find((item) => item.id === first);
  const runtimeChoices = runtimes.map((item) => [item.id, item.installed ? item.name : `${item.name}（未安装）`]);
  const versions = [...(selected?.legacy_installed ? [['', '原有版本']] : []),
    ...((selected?.versions || []).map((version) => [version, version]))];
  if (!versions.length) versions.push(['', '尚未安装']);
  const globalNames = (S.globalVariables || []).map((item) => item.name);
  const globalLabel = globalNames.length
    ? `加载面板的公用环境变量（当前 ${globalNames.length} 项：${globalNames.slice(0, 6).join('、')}${globalNames.length > 6 ? ' 等' : ''}）`
    : '加载面板的公用环境变量（「环境变量管理」里还没有定义变量）';
  modal(project ? '编辑服务器项目' : '新建服务器项目', [
    { name: 'id', label: '项目标识', value: project?.id || '', disabled: Boolean(project), required: true },
    { name: 'name', label: '名称', value: project?.name || '', required: true },
    { name: 'runtime', label: '运行环境', type: 'select', options: runtimeChoices, value: first },
    { name: 'runtime_version', label: '环境版本', type: 'select', options: versions, value: project?.runtime_version || versions[0][0] },
    { name: 'directory', label: '工程目录（服务器绝对路径，留空使用默认目录）', value: project?.directory || '', full: true, browse: 'directory' },
    { name: 'entry', label: '入口（相对于工程目录）', value: project?.entry || defaultEntries[first], required: true, full: true, browse: 'entry' },
    { name: 'port', label: 'PORT 环境变量', type: 'number', value: project?.port ?? 3000, port: true },
    { name: 'use_global_env', label: globalLabel, type: 'checkbox',
      value: project?.use_global_env === true, full: true },
    { name: 'env', label: '项目自己的环境变量（每行一个 KEY=VALUE，# 开头为注释；同名会盖住面板那份）', type: 'textarea', rows: 4,
      value: formatEnvText(project?.env), full: true },
    { name: 'env_file', label: '同时加载工程目录下的 .env 文件（最后加载，同名以它为准）', type: 'checkbox', value: project?.env_file === true, full: true },
    { name: 'use_venv', label: '使用 Python 虚拟环境', type: 'checkbox', value: project?.use_venv ?? first === 'python' },
    { name: 'python_server', label: 'Python 启动方式', type: 'select', options: [['gunicorn', 'Gunicorn'], ['uvicorn', 'Uvicorn（ASGI）'], ['uwsgi', 'uWSGI（WSGI）'], ['direct', '直接运行脚本']], value: project?.python_server || 'gunicorn' },
    { name: 'python_worker', label: 'Gunicorn worker class', type: 'select', options: [['sync', 'sync（WSGI）'], ['gthread', 'gthread（WSGI）'], ['uvicorn', 'uvicorn_worker.UvicornWorker（ASGI）']], value: project?.python_worker || (project?.python_threads > 1 ? 'gthread' : 'sync') },
    { name: 'python_callable', label: 'Python 应用对象（例如 app）', value: project?.python_callable || 'app' },
    { name: 'python_workers', label: '进程数（1–32）', type: 'number', value: project?.python_workers || 2 },
    { name: 'python_threads', label: '每进程线程数（1–64）', type: 'number', value: project?.python_threads || 1 }
  ], async (values) => {
    const hasServer = values.runtime === 'python' && values.python_server !== 'direct';
    if (hasServer && (!values.use_venv || Number(values.port) < 1)) throw new Error('Python 启动器需要虚拟环境和监听端口');
    if (hasServer && (!Number.isInteger(Number(values.python_workers)) || Number(values.python_workers) < 1 || Number(values.python_workers) > 32 ||
      !Number.isInteger(Number(values.python_threads)) || Number(values.python_threads) < 1 || Number(values.python_threads) > 64))
      throw new Error('进程数须为 1–32，线程数须为 1–64');
    const env = parseEnvText(values.env);
    const payload = { id: project?.id || values.id.trim(), name: values.name.trim(), runtime: values.runtime,
      runtime_version: values.runtime_version, directory: values.directory.trim(), entry: values.entry.trim(),
      port: Number(values.port || 0), env, env_file: values.env_file === true,
      use_global_env: values.use_global_env === true,
      use_venv: values.runtime === 'python' && values.use_venv,
      python_server: values.runtime === 'python' ? values.python_server : '',
      python_worker: values.runtime === 'python' && values.python_server === 'gunicorn' ? values.python_worker : '',
      python_callable: hasServer ? values.python_callable.trim() : '',
      python_workers: hasServer ? Number(values.python_workers) : 0,
      python_threads: hasServer ? Number(values.python_threads) : 0 };
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
    updatePythonFields();
  });
  $('#field-python_server').addEventListener('change', updatePythonFields);
  $('#field-python_worker').addEventListener('change', updatePythonFields);
  function updatePythonFields() {
    const python = $('#field-runtime').value === 'python';
    const hasServer = python && $('#field-python_server').value !== 'direct';
    const gunicorn = hasServer && $('#field-python_server').value === 'gunicorn';
    for (const name of ['use_venv', 'python_server']) $('#field-' + name).closest('.field').hidden = !python;
    for (const name of ['python_callable', 'python_workers']) $('#field-' + name).closest('.field').hidden = !hasServer;
    $('#field-python_worker').closest('.field').hidden = !gunicorn;
    $('#field-python_threads').closest('.field').hidden = !(hasServer &&
      ($('#field-python_server').value === 'uwsgi' || (gunicorn && $('#field-python_worker').value === 'gthread')));
    if (hasServer) $('#field-use_venv').checked = true;
  }
  updatePythonFields();
}
// ── 项目详情 ────────────────────────────────────────────────────────────────
// 服务端把启动自检、运行信息、依赖状态和日志一起算好，这里只负责铺开。
// 详情窗口 3 秒自刷一次：依赖安装、启动、重启都在这个窗口里做，状态要跟着动。
const D = { project: null, detail: null, timer: null, message: '', busy: false };

const checkMark = (level) => (level === 'ok' ? '✓' : level === 'error' ? '✕' : '!');
const checkClass = (level) => (level === 'ok' ? 'good' : level === 'error' ? 'bad' : 'warn');
const CHECK_ACTIONS = { deps: '安装依赖', venv: '创建虚拟环境', server: '安装启动器', edit: '编辑项目',
  files: '打开目录', runtime: '环境管理', variables: '环境变量管理' };

function dependencyText(dependency) {
  if (!dependency) return '正在读取…';
  return [dependency.manifest, dependency.detail].filter(Boolean).join(' · ') || '无需安装';
}
// 项目卡片上的一行：面板认的是哪份依赖清单、装了没有。识别结果以前只在详情窗口里，
// 扫一眼列表根本看不出面板支持 pyproject.toml / setup.py。
// 服务端说不出清单名、也没话要说时（Java 的 jar、.NET 的 dll）返回空串，不占这一行。
function dependencyCardText(dependency) {
  if (!dependency) return '';
  if (dependency.manifest) {
    if (dependency.installed) return `${dependency.manifest} · 已安装`;
    // 面板不打算装（例如 Python 没开虚拟环境）时，别挂一个点不动的「尚未安装」。
    if (dependency.action === 'deps' && dependency.command) {
      return `${dependency.manifest} · 尚未安装（${dependency.command}）`;
    }
    return `${dependency.manifest} · 面板不会替它装，原因见详情`;
  }
  return dependency.level === 'ok' ? '' : (dependency.detail || '');
}
function checkActionLabel(check, project) {
  if (!check.action || check.action === 'log') return '';
  // 「安装启动器」要说清楚装的是哪个：用户照着点才不会装错。
  if (check.action === 'server')
    return project?.python_server && project.python_server !== 'direct'
      ? `安装 ${projectServerLabel(project)}` : '安装启动器';
  return CHECK_ACTIONS[check.action] || '';
}
function projectDetail(project) {
  D.project = project;
  D.detail = null;
  D.message = '';
  D.busy = false;
  modalRevision++;
  if ($('#modal').open) $('#modal').close();
  $('#modal-content').innerHTML = `<div class="dialog-body" id="project-detail"><h2>${esc(project.name)} · 详情</h2><p class="muted">正在检查…</p></div>`;
  $('#modal-submit').hidden = true;
  // 详情窗口只读，回车不该提交；表单是 method="dialog"，不拦住就会直接关窗。
  $('#modal-form').onsubmit = (event) => event.preventDefault();
  $('#modal-cancel').onclick = () => closeProjectDetail();
  $('#modal').onclose = () => closeProjectDetail();
  $('#modal').showModal();
  loadProjectDetail();
  D.timer = setInterval(() => {
    if (!$('#modal').open) { closeProjectDetail(); return; }
    if (!D.busy) loadProjectDetail(true);
  }, 3000);
}
function closeProjectDetail() {
  if (D.timer) { clearInterval(D.timer); D.timer = null; }
  D.project = null;
  D.detail = null;
  D.busy = false;
  if ($('#modal').open) $('#modal').close();
}
async function loadProjectDetail(silent = false) {
  const id = D.project?.id;
  if (!id) return;
  try {
    D.detail = await api('projects.status', { id });
    if (!silent) D.message = '';
  } catch (error) {
    if (!silent) D.message = error.message || String(error);
    renderProjectDetail();
    return;
  }
  renderProjectDetail();
}
function renderProjectDetail() {
  const host = $('#project-detail');
  if (!host) return;
  const detail = D.detail;
  const current = detail?.project || D.project;
  if (!current) return;
  const status = detail?.status || {};
  const stateTag = tag(projectStateLabel(current), current.active_state === 'active' && current.sub_state !== 'auto-restart');
  const failure = projectFailureText(current);
  const checks = detail?.checks || [];
  const checkRows = checks.map((check) => {
    const label = checkActionLabel(check, current);
    return `<div class="row ${checkClass(check.level)}"><div class="grow"><strong>${checkMark(check.level)} ${esc(check.label)}</strong>${check.detail ? `<div class="small">${esc(check.detail)}</div>` : ''}${check.hint ? `<div class="small muted">${esc(check.hint)}</div>` : ''}</div><div class="actions">${label ? button(label, 'noop', `data-detail-action="${esc(check.action)}"`) : ''}</div></div>`;
  }).join('');
  const runtimeFields = [
    ['systemd 状态', `${status.active_state || current.active_state || ''}${status.sub_state && status.sub_state !== 'dead' ? ` · ${status.sub_state === 'auto-restart' ? '正在自动重启' : status.sub_state}` : ''}`],
    ['PID', status.main_pid > 0 ? String(status.main_pid) : ''],
    ['内存占用', status.memory_bytes > 0 ? fmtBytes(status.memory_bytes) : ''],
    ['已运行', current.active_state === 'active' && status.uptime_seconds > 0 ? fmtUptime(status.uptime_seconds) : ''],
    // 重启次数哪怕为 0 也要显示：用户就是想知道它到底重启过几次。
    ['重启次数', `重启 ${status.restarts ?? current.restarts ?? 0} 次`],
    ['上次结果', [status.result, status.exit_status > 0 ? `退出码 ${status.exit_status}` : ''].filter(Boolean).join(' · ')],
    ['监听端口', current.port > 0 ? `127.0.0.1:${current.port}${current.port_busy ? '（已被其他进程占用）' : ''}` : ''],
    ['工程目录', current.directory],
    ['启动命令', projectStartupText(current)]
  ];
  const runtimeRows = runtimeFields.filter(([, value]) => value)
    .map(([label, value]) => `<dt>${esc(label)}</dt><dd class="mono">${esc(value)}</dd>`).join('');
  const dependency = detail?.dependency;
  // 环境变量：把加载来的和项目自己填的分开列，同名的标出被覆盖，
  // 免得用户以为变量没生效而反复保存。
  const ownEnv = Object.entries(current.env || {}).sort(([a], [b]) => (a < b ? -1 : 1));
  const inherited = detail?.global_variables || [];
  const overridden = new Set(ownEnv.map(([name]) => name));
  const variableRows = [
    ...inherited.map((item) => [`面板 · ${item.name}`,
      `${item.value}${overridden.has(item.name) ? '　（被项目变量覆盖）' : ''}`]),
    ...ownEnv.map(([name, value]) => [`项目 · ${name}`, value])
  ];
  const envNote = current.env_file ? '工程目录下的 .env 会最后加载，同名以它为准。' : '';
  const variableSection = `<section class="card"><div class="card-header"><h2>环境变量</h2><div class="actions">${button('环境变量管理…', 'noop', 'data-detail-action="variables"')}</div></div>
    ${current.use_global_env === true ? '' : '<p class="help">这个项目没有加载面板那份公用变量（默认不加载），只用下面项目自己的值。代码也可以直接读服务器上的共用文件，不必改项目配置。</p>'}
    ${variableRows.length ? `<dl class="kv">${variableRows.map(([key, value]) => `<dt>${esc(key)}</dt><dd class="mono">${esc(value)}</dd>`).join('')}</dl>` : '<p class="muted">没有自定义环境变量。</p>'}
    ${current.port > 0 || envNote ? `<p class="help">${current.port > 0 ? `PORT=${esc(current.port)} 由面板按项目写入。` : ''}${esc(envNote)}</p>` : ''}
  </section>`;
  const log = detail?.log || '';
  const journal = detail?.journal || '';
  host.innerHTML = `<h2>${esc(current.name)} · 详情</h2>
    <div class="inline">${stateTag} ${current.enabled ? tag('开机启动') : tag('不自启')} ${tag(`${current.runtime} ${current.runtime_version || ''}`)}</div>
    ${failure ? `<p class="help">${esc(failure)}</p>` : ''}
    ${D.message ? `<p class="help">${esc(D.message)}</p>` : ''}
    <section class="card"><div class="card-header"><h2>启动自检</h2><div class="actions">${button('重新检查', 'noop', 'data-detail-action="refresh"')}${current.active_state === 'active' ? button('重启', 'noop', 'data-detail-action="restart"') : button('启动', 'noop', 'data-detail-action="start"')}${current.active_state === 'active' ? button('停止', 'noop', 'data-detail-action="stop"') : ''}</div></div>${checkRows || '<p class="muted">正在检查…</p>'}</section>
    <section class="card"><div class="card-header"><h2>运行信息</h2></div><dl class="kv">${runtimeRows}</dl></section>
    ${variableSection}
    <section class="card"><div class="card-header"><h2>项目依赖</h2><div class="actions">${dependency?.present && !dependency?.installed && dependency?.command ? button(`安装依赖（${dependency.command}）`, 'noop', 'data-detail-action="deps"') : ''}</div></div><p class="mono small">${esc(dependencyText(dependency))}</p>${dependency?.present && !dependency?.installed ? '<p class="small muted">安装依赖需要先停止项目。</p>' : ''}</section>
    <section class="card"><div class="card-header"><h2>项目日志</h2><div class="actions">${button('复制', 'noop', 'data-detail-action="copy-log"')}${button('清空…', 'noop', 'data-detail-action="clear-log"', 'danger')}</div></div><div class="code">${esc(log || '暂无日志')}</div>${journal ? `<p class="small muted">进程还没起来就退出时项目日志是空的，原因只在系统日志里。</p><div class="code">${esc(journal)}</div>` : ''}</section>`;
}
// 详情窗口里的按钮统一走 data-detail-action，避免和列表页的 data-index 混在一起。
async function projectDetailAction(action, element) {
  void element;
  const project = D.detail?.project || D.project;
  if (!project) return;
  if (action === 'refresh') { D.busy = true; await loadProjectDetail(); D.busy = false; return; }
  if (action === 'copy-log') {
    D.message = await copyText(D.detail?.log || '', '日志已复制');
    renderProjectDetail();
    return;
  }
  if (action === 'edit' || action === 'files' || action === 'runtime' || action === 'variables') {
    closeProjectDetail();
    if (action === 'files') { S.filePath = project.directory; S.section = 'files'; await refresh(); }
    else if (action === 'runtime') { S.section = 'environments'; await refresh(); }
    else if (action === 'variables') { S.section = 'variables'; await refresh(); }
    else projectForm(project);
    return;
  }
  // 安装依赖要跑几分钟，窗口不能自己刷新把按钮状态顶掉，所以先占住 busy。
  const perform = async (task, message) => {
    D.busy = true;
    try {
      await task();
      D.message = message;
    } catch (error) { D.message = error.message || String(error); }
    D.busy = false;
    await loadProjectDetail(true);
    await refresh(false);
  };
  if (action === 'deps') await perform(() => api('projects.deps', { id: project.id }), '依赖安装完成');
  else if (action === 'venv') await perform(() => api('projects.venv', { id: project.id, action: 'create' }), '虚拟环境已创建');
  else if (action === 'server') await perform(() => api('projects.venv', { id: project.id, action: 'install_server' }), '启动器已安装');
  else if (action === 'start' || action === 'stop' || action === 'restart')
    await perform(() => api('projects.action', { id: project.id, action }), '操作已下发');
  else if (action === 'clear-log') {
    if (!confirm(`清空 ${project.name} 的项目日志？`)) return;
    await perform(() => api('projects.log.clear', { id: project.id }), '日志已清空');
  }
}
async function projectAction(action, index) {
  const project = list(S.data)[index];
  if (!project) return;
  if (action === 'projects.new') projectForm();
  else if (action === 'projects.edit') projectForm(project);
  else if (action === 'projects.detail' || action === 'projects.log') projectDetail(project);
  else if (action === 'projects.files') { S.filePath = project.directory; S.section = 'files'; await refresh(); }
  else if (action === 'projects.proxy') {
    const address = `http://127.0.0.1:${project.port}`;
    setNotice(await copyText(address, `已复制反向代理地址 ${address}，可在网站管理中创建代理站点`));
  }
  else if (action === 'projects.clearlog') {
    if (confirm(`清空 ${project.name} 的项目日志？（systemd 的系统日志会保留）`))
      await mutate('projects.log.clear', { id: project.id }, '日志已清空');
  }
  else if (action === 'projects.deps' && confirm(`按依赖清单为 ${project.name} 安装依赖？安装期间项目必须处于停止状态。`))
    await mutate('projects.deps', { id: project.id }, '依赖安装完成');
  else if (action === 'projects.toggle') await mutate('projects.action', { id: project.id,
    action: project.active_state === 'active' ? 'stop' : 'start' });
  else if (action === 'projects.restart') await mutate('projects.action', { id: project.id, action: 'restart' });
  else if (action === 'projects.enable') await mutate('projects.action', { id: project.id,
    action: project.enabled ? 'disable' : 'enable' });
  else if (action === 'projects.venv') await mutate('projects.venv', { id: project.id,
    action: project.venv_ready ? 'install_requirements' : 'create' });
  else if (action === 'projects.server') await mutate('projects.venv', { id: project.id, action: 'install_server' });
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
  const items = list(S.data[0]), search = (S.searchStore || '').toLowerCase();
  const installJobs = list(S.data[1]).filter((job) => job.operation === 'install');
  const installedCount = items.filter((item) => ['installed', 'multiple_versions'].includes(item.state)).length;
  const visible = items.map((item, index) => ({ item, index }))
    .filter(({ item }) => !search || `${item.name} ${item.category} ${item.description}`.toLowerCase().includes(search));
  const rows = visible.map(({ item, index }) => {
    const isInstalled = ['installed', 'multiple_versions'].includes(item.state);
    const canInstall = item.install_available !== false && item.supported &&
      !['queued', 'installing', 'uninstalling', 'cancelling', 'multiple_versions', 'installed'].includes(item.state);
    const isRuntime = RUNTIME_IDS.has(item.id);
    const primary = isRuntime
      ? (isInstalled ? button('去管理', 'software.gotoManagement') : button('选择版本…', 'software.gotoEnvironments'))
      : (canInstall ? button('安装', 'software.install', `data-index="${index}"`)
        : (isInstalled ? button('去管理', 'software.gotoManagement') : ''));
    const stateText = { installed: '已安装', multiple_versions: '多版本已安装', installing: '安装中', uninstalling: '卸载中',
      queued: '排队中', cancelling: '停止中', cancelled: '已停止', failed: '安装失败', needs_attention: '需要处理' }[item.state] || '未安装';
    return `<tr><td><strong>${esc(item.name)}</strong><div class="small muted">${esc(item.description)}</div></td><td>${esc(item.category || '其他')}</td><td>${esc(item.version)}</td><td>${tag(stateText, item.state === 'installed')}</td><td class="actions-cell"><div class="actions">${primary}${button('日志', 'software.log', `data-index="${index}"`)}</div></td></tr>`;
  }).join('');
  $('#content').innerHTML = `<section class="card"><h3>安装任务</h3>${installJobs.length ? installJobs.map((job) => `<div class="inline"><strong>${esc(items.find((item) => item.id === job.id)?.name || job.id)}</strong> · ${esc(jobStateText(job.state))} · ${esc(job.message)} ${['queued', 'installing'].includes(job.state) ? button('停止任务', 'software.cancel', `data-id="${esc(job.id)}"`) : ''}</div>`).join('') : '<p class="muted">暂无安装任务</p>'}</section><div class="toolbar"><input id="store-search" placeholder="搜索软件" value="${esc(S.searchStore || '')}"><span class="small muted">共 ${items.length} 款 · 已安装 ${installedCount} 款</span></div><section class="card"><table class="table"><thead><tr><th>软件</th><th>类别</th><th>版本</th><th>状态</th><th></th></tr></thead><tbody>${rows}</tbody></table></section>`;
};
const jobStateText = (state) => ({ queued: '排队中', installing: '安装中', uninstalling: '卸载中', cancelling: '停止中',
  cancelled: '已停止', installed: '已完成', not_installed: '已完成', failed: '失败', needs_attention: '需处理' })[state] || state;

renders.services = () => {
  $('#page-actions').innerHTML = button('去软件商店安装', 'software.gotoStore');
  const [software, jobs] = S.data;
  const installed = list(software).filter((item) => item.state === 'installed' || item.state === 'multiple_versions');
  const uninstallJobs = list(jobs).filter((job) => job.operation === 'uninstall');
  const search = (S.searchServices || '').toLowerCase();
  const filter = S.filterServices || 'all';
  const visible = installed.filter((item) => {
    if (search && !`${item.name} ${item.version} ${item.install_path || ''}`.toLowerCase().includes(search)) return false;
    if (filter === 'running') return item.service_available !== false && item.service_state === 'active';
    if (filter === 'stopped') return item.service_available !== false && item.service_state !== 'active';
    if (filter === 'runtime') return RUNTIME_IDS.has(item.id);
    return true;
  });
  S.installedServices = visible;
  const filters = [['all', '全部'], ['running', '运行中'], ['stopped', '已停止'], ['runtime', '运行环境']];
  $('#content').innerHTML = `${uninstallJobs.length ? card('卸载任务', uninstallJobs.map((job) => row(
    `<strong>${esc(installed.find((item) => item.id === job.id)?.name || job.id)}</strong> ${esc(jobStateText(job.state))} <span class="small muted">${esc(job.message)}</span>`,
    ['queued', 'uninstalling'].includes(job.state) ? button('停止任务', 'software.cancel', `data-id="${esc(job.id)}"`) : '')).join('')) : ''}<div class="toolbar"><input id="services-search" placeholder="搜索已安装软件" value="${esc(S.searchServices || '')}"><select id="services-filter">${filters.map(([value, text]) => `<option value="${value}" ${filter === value ? 'selected' : ''}>${text}</option>`).join('')}</select><span class="small muted">已安装 ${installed.length} 款</span></div>${visible.map((item, index) => {
      const hasService = item.service_available !== false && item.state !== 'multiple_versions';
      const actions = `${hasService ? `${button(item.service_state === 'active' ? '停止' : '启动', 'services.software', `data-index="${index}" data-command="${item.service_state === 'active' ? 'stop' : 'start'}"`)}${button('重启', 'services.software', `data-index="${index}" data-command="restart"`)}${button(item.enabled ? '取消自启' : '开机自启', 'services.software', `data-index="${index}" data-command="${item.enabled ? 'disable' : 'enable'}"`)}` : ''}${button('日志', 'services.log', `data-index="${index}"`)}${RUNTIME_IDS.has(item.id) ? button('管理版本', 'software.gotoEnvironments') : ''}${button('卸载', 'software.uninstall', `data-index="${index}"`, 'danger')}`;
      const state = hasService
        ? `${tag(item.service_state === 'active' ? '运行中' : '已停止', item.service_state === 'active')} ${tag(item.enabled ? '开机启动' : '不自启')}`
        : '<span class="small muted">无常驻服务</span>';
      return card(`${item.name} · ${item.version}`, `<div class="inline">${state} <span class="small muted mono">${esc(item.install_path)}</span></div>`, actions);
    }).join('') || empty('这台服务器上还没有已安装的软件')}`;
};
async function softwareAction(action, index, command) {
  if (action === 'software.gotoStore') { S.section = 'store'; await refresh(); return; }
  if (action === 'software.gotoManagement') { S.section = 'services'; await refresh(); return; }
  if (action === 'software.gotoEnvironments') { S.section = 'environments'; await refresh(); return; }
  if (action === 'software.cancel') { await mutate('software.cancel', { id: command }, '已请求停止任务'); return; }
  const item = action.startsWith('services.') ? S.installedServices[index] : list(S.data[0])[index];
  if (!item) return;
  if (action === 'software.install' && confirm(`安装 ${item.name}？`)) await mutate('software.install', { id: item.id }, '安装任务已开始，进度见下方任务列表');
  else if (action === 'software.uninstall') {
    const mode = confirm(`卸载 ${item.name} 并备份目录？\n确定：备份；取消：继续选择彻底删除。`) ? 'backup'
      : (confirm(`彻底删除 ${item.name}？`) ? 'purge' : null);
    if (mode) await mutate('software.uninstall', { id: item.id, mode }, '卸载任务已开始，进度见本页上方「卸载任务」');
  } else if (action === 'software.log' || action === 'services.log') info(`${item.name} · 日志`, await api('software.log', { id: item.id }));
  else if (action === 'services.software' && confirm(`${command} ${item.name}？`))
    await mutate('software.service', { id: item.id, action: command });
}

renders.firewall = () => {
  $('#page-actions').innerHTML = '<button data-action="firewall.add">添加规则</button>';
  const [firewall, services] = S.data;
  const service = (services.services || [])[0];
  const serviceCard = service
    ? card('防火墙服务', `<div class="inline">${tag(service.active_state === 'active' ? '运行中' : '已停止', service.active_state === 'active')} ${tag(service.unit_state === 'enabled' ? '开机启动' : '不自启')} <span class="small muted mono">${esc(service.name)}</span></div>`,
      `${button(service.active_state === 'active' ? '停止' : '启动', 'services.firewall', `data-index="0" data-command="${service.active_state === 'active' ? 'stop' : 'start'}"`)}${button('重启', 'services.firewall', 'data-index="0" data-command="restart"')}${button(service.unit_state === 'enabled' ? '取消自启' : '开机自启', 'services.firewall', `data-index="0" data-command="${service.unit_state === 'enabled' ? 'disable' : 'enable'}"`)}`)
    : card('防火墙服务', empty('未检测到防火墙服务'));
  $('#content').innerHTML = `${serviceCard}${card('当前防火墙', `<div class="inline">${tag(firewall.backend || '未启用', Boolean(firewall.backend))}<span class="muted">区域 ${esc(firewall.zone || '—')}</span></div>`)}${card('入站端口', (firewall.rules || []).map((rule, index) => row(`<strong>${esc(rule.port)}/${esc(rule.protocol)}</strong> <span class="muted small">${esc(rule.source || '全部来源')}</span>`, button('删除', 'firewall.remove', `data-index="${index}"`, 'danger'))).join('') || empty('没有简单端口规则'))}`;
};
async function firewallAction(action, index, command) {
  if (action === 'services.firewall') {
    const service = (S.data[1].services || [])[index];
    if (!service) return;
    const warning = ['start', 'enable'].includes(command) ? '（注意：请先确保防火墙允许 TCP 27520，否则可能中断 Seraphim 连接）' : '';
    if (confirm(`${command} ${service.name}？${warning}`))
      await mutate('services.action', { name: service.name, action: command });
    return;
  }
  if (action === 'firewall.add') modal('添加入站端口', [
    { name: 'port', label: '端口', type: 'number', required: true },
    { name: 'protocol', label: '协议', type: 'select', options: [['tcp', 'TCP'], ['udp', 'UDP']] }
  ], async ({ port, protocol }) => {
    if (!(Number(port) >= 1 && Number(port) <= 65535)) throw new Error('端口须在 1–65535 之间');
    await api('firewall.change', { action: 'add', port: Number(port), protocol });
    await refresh(false);
  }, '添加');
  else if (action === 'firewall.remove') {
    const rule = S.data[0].rules[index];
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
    return card(`${instance.name} · 数据库与账户`, `<div class="split"><div><h3>数据库</h3>${databases.map((name, index) => row(`<span class="mono">${esc(name)}</span>`, button('删除', 'databases.db.delete', `data-index="${index}"`, 'danger'))).join('') || empty('暂无数据库')}</div><div><h3>账户</h3>${users.map((user, index) => row(`<span class="mono">${esc(user.name)}${user.host ? `@${esc(user.host)}` : ''}</span>`, `${button('查看密码', 'databases.user.password', `data-index="${index}"`)}${button('重置密码', 'databases.user.reset', `data-index="${index}"`)}${button('删除', 'databases.user.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('暂无账户')}</div></div>`, `${button('建库', 'databases.db.create')}${button('建用户', 'databases.user.create')}${button('授权', 'databases.grant')}${engine === 'mysql' ? button('设置管理密码', 'databases.mysql.password') + button('查看管理密码', 'databases.mysql.saved') + button('修改管理密码', 'databases.mysql.change') : ''}${engine === 'postgresql' && instance.auth_state !== 'local_password' ? button('启用本机密码连接', 'databases.pg.access') : ''}`);
  }
  if (S.acl) {
    return card(`${instance.name} · ACL`, `<p class="help">${S.acl.persistent ? 'ACL 已持久化' : 'ACL 尚未持久化'}</p>${(S.acl.users || []).map((user, index) => row(`<span class="mono">${esc(user.name)}</span> ${tag(user.enabled ? '启用' : '停用', user.enabled)} ${tag(user.level === 'readwrite' ? '读写' : '只读')}`, `${button('查看密码', 'databases.acl.password', `data-index="${index}"`)}${button('重置密码', 'databases.acl.reset', `data-index="${index}"`)}${button(user.enabled ? '停用' : '启用', 'databases.acl.toggle', `data-index="${index}"`)}${button(user.level === 'readwrite' ? '设为只读' : '设为读写', 'databases.acl.level', `data-index="${index}"`)}${button('删除', 'databases.acl.delete', `data-index="${index}"`, 'danger')}`)).join('') || empty('暂无 ACL 用户')}`, `${!S.acl.persistent ? button('启用持久化 ACL', 'databases.acl.enable') : ''}${button('建用户', 'databases.acl.create')}${button('设置默认账户密码', 'databases.acl.credential')}${button('查看默认账户密码', 'databases.acl.saved')}`);
  }
  return card(`${instance.name} · 实例状态`, `<div class="inline">${tag(instance.running ? '运行中' : '已停止', instance.running)} ${tag(instance.auth_state || '状态未知')}</div><p class="help">此数据库当前提供实例状态总览。</p>`);
}
async function databaseAction(action, index, id) {
  if (action === 'databases.select') { S.selectedDatabase = id; await refresh(); return; }
  const engine = S.selectedDatabase;
  const dbs = S.catalog?.databases || [], users = S.catalog?.users || [], aclUsers = S.acl?.users || [];
  if (action === 'databases.db.create' || action === 'databases.user.create' || action === 'databases.acl.create') {
    const acl = action === 'databases.acl.create';
    const db = action === 'databases.db.create';
    modal(acl ? '创建 ACL 用户' : db ? '创建数据库' : '创建账户', [
      { name: 'name', label: acl ? '账户名称' : db ? '数据库名' : '账户名', required: true },
      ...(db ? [{ name: 'createUser', label: '同时创建账户并授权（密码自动生成）', type: 'checkbox', value: true },
        { name: 'user', label: '账户名（留空则与数据库同名）' },
        { name: 'level', label: '账户权限', type: 'select', options: [['readwrite', '读写'], ['read', '只读']] }] : []),
      ...(acl ? [{ name: 'level', label: '权限', type: 'select', options: [['readwrite', '读写'], ['read', '只读']] }] : [])
    ], async ({ name, level, user, createUser }) => {
      if (db) {
        const account = createUser ? String(user || '').trim() || name : '';
        if (account && !/^[A-Za-z][A-Za-z0-9_]{0,31}$/.test(account))
          throw new Error('账户名须以字母开头，只能包含字母、数字和下划线，最长 32 位');
        const result = await api('databases.create', { engine, name, user: account, level: level || 'readwrite' });
        if (result?.password) info('请保存新账户密码', `${result.user}\n${result.password}`);
      } else {
        const result = await api(acl ? 'databases.acl.create' : 'databases.user.create', { engine, name, level });
        if (result?.password) info('请保存新账户密码', `${result.user}\n${result.password}`);
      }
      await refresh(false);
    }, '创建');
  } else if (action === 'databases.db.delete' && confirm(`删除数据库 ${dbs[index]} 及其中数据？`))
    await mutate('databases.delete', { engine, name: dbs[index] });
  else if (action === 'databases.user.delete' && confirm(`删除账户 ${users[index].name}？`))
    await mutate('databases.user.delete', { engine, name: users[index].name });
  else if (action === 'databases.user.password') {
    const result = await api('databases.user.password', { engine, name: users[index].name });
    info('已保存的密码', `${result.user}\n${result.password}`);
  }
  else if (action === 'databases.user.reset' && confirm(`重置 ${users[index].name} 的密码？`)) {
    const result = await api('databases.user.reset', { engine, name: users[index].name });
    info('新密码（仅显示一次）', `${result.user}\n${result.password}`);
  } else if (action === 'databases.grant') modal('授权或撤销', [
    { name: 'database', label: '数据库', type: 'select', options: dbs.map((name) => [name, name]) },
    { name: 'user', label: '账户', type: 'select', options: users.map((user) => [user.name, `${user.name}${user.host ? '@' + user.host : ''}`]) },
    { name: 'level', label: '权限', type: 'select', options: [['readwrite', '读写'], ['read', '只读']] },
    { name: 'revoke', label: '撤销权限', type: 'checkbox', value: false }
  ], async (values) => { await api('databases.grant', { engine, ...values }); await refresh(false); });
  else if (action === 'databases.mysql.change') modal('修改 MySQL 管理密码', [
    { name: 'current', label: '当前密码（服务端已保存时可留空）', type: 'password' },
    { name: 'next', label: '新密码（至少 8 位）', type: 'password', required: true }
  ], async ({ current, next }) => { await api('databases.mysql.change', { current, next }); await refresh(false); });
  else if (action === 'databases.mysql.saved') { const result = await api('databases.mysql.saved'); info('已保存的管理密码', result.password); }
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
  else if (action === 'databases.acl.saved') { const result = await api('databases.acl.saved', { engine }); info('已保存的默认账户密码', result.password); }
  else if (action === 'databases.acl.password') { const result = await api('databases.acl.password', { engine, name: aclUsers[index].name }); info('已保存的密码', `${result.user}\n${result.password}`); }
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
  $('#content').innerHTML = `${card('通过 SSH 安装或升级', '<p>输入服务器 SSH 信息，确认主机指纹后，应用会上传内置文件、安装或覆盖升级服务端并保存 HTTPS 连接。</p><button data-action="installer.ssh">填写 SSH 信息…</button><p class="help">覆盖升级保留令牌、证书、服务配置及业务数据。SSH 密码只用于本次操作，不保存。</p>')}
    ${card('通过命令行安装或升级', `<div class="toolbar"><select id="installer-arch"><option value="amd64">x86_64 / amd64</option><option value="arm64">aarch64 / arm64</option></select><button data-action="installer.export">导出 sera 安装文件…</button></div><p class="help">在服务器上运行 uname -m 查看架构。将文件上传到 /tmp/sera-install，以 root 或 sudo 执行：</p><div class="code">chmod 755 /tmp/sera-install\nsudo /tmp/sera-install install -host 服务器地址</div><p class="help">再次执行同一命令会覆盖升级。安装器打印 HTTPS 地址、API 令牌和证书指纹；升级沿用原值。</p>`)}
    ${card('绑定域名与证书', '<p>域名解析与正式证书可由管理员配置。服务端监听 27520，证书更新后需要重启 server-status 服务。</p>')}`;
};
function sshInstallForm() {
  modal('通过 SSH 安装或升级服务端', [
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
    const existing = S.doc.entries.find(({ connection }) => connection.endpoint === result.endpoint)?.connection;
    S.doc = await window.sera.saveConnection({ id: existing?.id, name: existing?.name || target.host, endpoint: result.endpoint,
      token: result.token, fingerprint: result.fingerprint });
    renderChrome();
    info('服务端已安装或升级', `HTTPS：${result.endpoint}\nAPI 令牌：${result.token}\n证书指纹：${result.fingerprint}\n\n连接已保存。`);
    await refresh(false);
  }, '检查指纹并安装或升级');
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
    ${card('证书', `<p class="help">使用当前阿里云账号自动添加 DNS-01 TXT 记录，向 Let’s Encrypt 申请证书。续期可再次申请；证书文件存于本机应用数据目录；部署后网站将启用 HTTPS 443。</p>${(S.certificates || []).map((cert) => row(`<strong>${esc(cert.domains.join('、'))}</strong><div class="small muted">到期 ${esc(String(cert.notAfter || '').slice(0, 10))} · ${esc(cert.keyType)}</div><div class="mono small muted">${esc(cert.fullchainPath)}<br>${esc(cert.privateKeyPath)}</div>`, `${button('部署到网站', 'domains.cert.deploy', `data-cert="${esc(cert.id)}"`)}${button('复制证书路径', 'domains.cert.copy', `data-cert="${esc(cert.id)}"`)}`)).join('') || empty('尚未申请证书')}`)}`;
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
  else if (action === 'domains.cert.deploy') {
    const sites = list(await api('sites.list')).filter((site) => site.enabled);
    if (!sites.length) throw new Error('请先在当前服务器创建并启用网站');
    modal('部署证书到网站', [{ name: 'site', label: '网站', type: 'select',
      options: sites.map((site) => [`${site.provider}/${site.id}`, `${(site.domains || []).join('、')} · ${site.provider}`]) }],
    async ({ site }) => { const selected = sites.find((item) => `${item.provider}/${item.id}` === site);
      if (!selected) throw new Error('请选择网站');
      await window.sera.deployCertificate(certId, selected.provider, selected.id);
      await refresh(false); setNotice('证书已部署，网站 HTTPS 已启用'); }, '部署');
  }
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

// 「更多」用的是 <details> 浮层：点了里面的按钮、或点了别处，都该收起来。
// 放在捕获阶段，先收起再让业务动作跑，元素本身还在 DOM 里，动作不受影响。
document.addEventListener('click', (event) => {
  const inside = event.target.closest('.menu');
  const clickedItem = event.target.closest('.menu-body button');
  for (const node of document.querySelectorAll('.menu[open]')) {
    if (clickedItem || node !== inside) node.removeAttribute('open');
  }
}, true);

document.addEventListener('click', async (event) => {
  const detailAction = event.target.closest('[data-detail-action]');
  if (detailAction) {
    await projectDetailAction(detailAction.dataset.detailAction, detailAction);
    return;
  }
  const freePort = event.target.closest('[data-free-port]');
  if (freePort) {
    freePort.disabled = true;
    try {
      const input = $('#field-port');
      const after = Math.max(0, Number(input?.value) - 1) || 3000;
      const result = await api('projects.ports', { after });
      const port = list(result)[0] ?? result?.ports?.[0];
      if (port && input) input.value = port;
      else setNotice('服务器没有返回可用的空闲端口', true);
    } catch (error) { setNotice(error.message || String(error), true); }
    finally { freePort.disabled = false; }
    return;
  }
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
    else if (action.startsWith('variables.')) await variablesAction(action);
    else if (action.startsWith('api.')) await apiAction(action, target);
    else if (action.startsWith('environments.')) await environmentAction(action, index, part);
    else if (action === 'services.firewall') await firewallAction(action, index, target.dataset.command);
    else if (action.startsWith('software.') || action.startsWith('services.'))
      await softwareAction(action, index, target.dataset.command || target.dataset.id);
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
  } else if (event.target.id === 'services-search') {
    S.searchServices = event.target.value;
    const position = event.target.selectionStart;
    renders.services();
    $('#services-search').focus();
    $('#services-search').setSelectionRange(position, position);
  }
});
document.addEventListener('change', (event) => {
  if (event.target.id === 'services-filter') {
    S.filterServices = event.target.value;
    renders.services();
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
let servicesPolling = false;
setInterval(async () => {
  if (servicesPolling || S.section !== 'services' || !selectedConnection() || S.busy || $('#modal').open || document.hidden) return;
  if (['services-search', 'services-filter'].includes(document.activeElement?.id)) return;
  // 只有确实有卸载任务在跑才轮询，避免空转重绘打断操作。
  const pending = list(S.data?.[1]).some((job) => ['queued', 'uninstalling'].includes(job.state));
  if (!pending) return;
  servicesPolling = true;
  const connectionID = S.doc.selectedID;
  try {
    const snapshot = await Promise.all([api('software.list'), api('software.jobs')]);
    if (S.section === 'services' && S.doc.selectedID === connectionID) {
      S.data = snapshot;
      renders.services();
    }
  } catch (error) { setNotice(error.message || String(error), true); }
  finally { servicesPolling = false; }
}, 5000);

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
let storePolling = false;
setInterval(async () => {
  if (storePolling || S.section !== 'store' || !selectedConnection() || S.busy || $('#modal').open || document.hidden || document.activeElement?.id === 'store-search') return;
  storePolling = true;
  const connectionID = S.doc.selectedID;
  try {
    const snapshot = await Promise.all([api('software.list'), api('software.jobs')]);
    if (S.section === 'store' && S.doc.selectedID === connectionID) {
      S.data = snapshot;
      renders.store();
    }
  } catch (error) { setNotice(error.message || String(error), true); }
  finally { storePolling = false; }
}, 5000);
loadConnections().then(() => refresh()).catch((error) => setNotice(error.message, true));
