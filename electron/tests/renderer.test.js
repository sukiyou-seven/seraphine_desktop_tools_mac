// 渲染层冒烟测试。
//
// app.js 是浏览器脚本，没有 module.exports，改一个模板字符串写坏了只有打开面板才会
// 发现。这里用一个极简 DOM 替身把脚本跑起来，再直接调渲染函数检查产出的 HTML——
// 至少保证「项目管理」这一页的所有新渲染路径不会抛异常、且关键信息真的出现了。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// closest() 在渲染代码里只用于「把字段所在的那一行藏起来」，返回一个能写 hidden 的替身即可。
const rowStub = () => ({ hidden: false, classList: { toggle() {}, add() {}, remove() {} } });

function makeElement(id) {
  return {
    id, innerHTML: '', textContent: '', value: '', checked: false, hidden: false,
    disabled: false, open: false, dataset: {},
    onclick: null, onsubmit: null, onclose: null,
    classList: { toggle() {}, add() {}, remove() {} },
    closest: rowStub,
    showModal() { this.open = true; },
    close() { this.open = false; },
    addEventListener() {}, setSelectionRange() {}, focus() {}
  };
}

function loadRenderer() {
  const elements = new Map();
  const element = (selector) => {
    if (!elements.has(selector)) elements.set(selector, makeElement(selector));
    return elements.get(selector);
  };
  const document = {
    querySelector: element,
    querySelectorAll: () => [],
    addEventListener() {},
    hidden: false,
    activeElement: null
  };
  const sandbox = {
    document,
    // connections() 一直挂着：脚本底部的 refresh() 就不会跑，测试只关心渲染函数。
    // 其余 preload 暴露的方法给个空实现即可，模块加载期只有 onUploadProgress 会被调用。
    window: {
      sera: {
        platform: 'darwin',
        connections: () => new Promise(() => {}),
        api: async () => ({}),
        onUploadProgress() {}
      }
    },
    navigator: { clipboard: { writeText: async () => {} } },
    // 破坏性动作都会先问一句；测试里默认同意，需要拒绝的用例自己覆盖。
    confirm: () => true,
    setInterval: () => 0,
    clearInterval() {},
    setTimeout: () => 0,
    FormData: class { has() { return false; } get() { return ''; } },
    exports: {}
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  const source = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
  vm.runInContext(`${source}
exports.renders = renders; exports.S = S; exports.D = D;
exports.projectDetail = projectDetail; exports.projectAction = projectAction;
exports.projectDetailAction = projectDetailAction; exports.renderProjectDetail = renderProjectDetail;
  exports.closeProjectDetail = closeProjectDetail; exports.projectForm = projectForm;
  exports.variablesAction = variablesAction; exports.apiAction = apiAction;
  exports.helpers = { actionMenu, projectStartupText, projectServerLabel, projectStateLabel,
    projectFailureText, parseEnvText, formatEnvText, fmtUptime, dependencyText, dependencyCardText,
    checkActionLabel, copyText };`,
    sandbox, { filename: 'app.js' });
  return { ...sandbox.exports, element, window: sandbox.window, globals: sandbox };
}

const sampleProject = (overrides = {}) => ({
  id: 'wechats', name: 'WeChats', runtime: 'python', runtime_version: '3.11',
  directory: '/www/seraphim/projects/wechats', entry: 'main.py', port: 53200,
  use_venv: true, python_server: 'gunicorn', python_worker: 'uvicorn',
  python_callable: 'app', python_workers: 2, python_threads: 1,
  active_state: 'activating', sub_state: 'auto-restart', result: 'exit-code', exit_status: 1,
  restarts: 7, main_pid: 0, enabled: false, runtime_ready: true, venv_ready: true,
  server_ready: false, port_busy: false, env: { DATABASE_URL: 'postgres://127.0.0.1:5432/wechats' },
  env_file: true, ...overrides
});

test('renderer: project list marks restart loops and offers the diagnostics entry', () => {
  const app = loadRenderer();
  app.S.data = { items: [sampleProject()], runtimes: [{ id: 'python', name: 'Python', installed: true, versions: ['3.11'] }] };
  app.renders.projects();
  const html = app.element('#content').innerHTML;
  // 反复重启不能被显示成「运行中」。
  assert.match(html, /反复重启/);
  assert.doesNotMatch(html, />运行中</);
  assert.match(html, /进程反复退出/);
  assert.match(html, /已重启 7 次/);
  assert.match(html, /环境未就绪，直接启动会失败/);
  // 环境变量与 .env 都要落到卡片上。
  assert.match(html, /DATABASE_URL/);
  assert.match(html, /工程目录下的 \.env/);
  // 主操作走 data-index，其余收进「更多」，避免十个按钮糊成一片。
  assert.match(html, /data-action="projects\.detail" data-index="0"/);
  assert.match(html, /data-action="projects\.toggle" data-index="0"/);
  assert.match(html, /class="menu"/);
  for (const action of ['projects.edit', 'projects.files', 'projects.log', 'projects.deps',
    'projects.server', 'projects.enable', 'projects.clearlog', 'projects.delete', 'projects.proxy'])
    assert.match(html, new RegExp(`data-action="${action.replace('.', '\\.')}" data-index="0"`), action);
  assert.match(html, /安装 Gunicorn/);
  // 端口存在时不要出现「创建虚拟环境」（虚拟环境已就绪）。
  assert.doesNotMatch(html, /创建虚拟环境/);
});

test('renderer: project list hides the venv entry once the venv is ready and shows it when not', () => {
  const app = loadRenderer();
  app.S.data = { items: [sampleProject({ venv_ready: false, server_ready: false })], runtimes: [] };
  app.renders.projects();
  const html = app.element('#content').innerHTML;
  assert.match(html, /创建虚拟环境/);
  assert.doesNotMatch(html, /安装 Gunicorn/);
  assert.match(html, /虚拟环境未就绪/);
});

test('renderer: empty project list still renders a hint', () => {
  const app = loadRenderer();
  app.S.data = { items: [], runtimes: [] };
  app.renders.projects();
  assert.match(app.element('#content').innerHTML, /尚无服务器项目/);
});

test('renderer: detail panel shows the self-check list, runtime info, deps and journal', () => {
  const app = loadRenderer();
  const project = sampleProject({ active_state: 'active', sub_state: 'running', main_pid: 4711, memory_bytes: 84 * 1024 * 1024, uptime_seconds: 3661, server_ready: false });
  app.D.project = project;
  app.D.detail = {
    project,
    status: { active_state: 'active', sub_state: 'running', main_pid: 4711, memory_bytes: 84 * 1024 * 1024,
      restarts: 7, result: 'success', exit_status: 0, uptime_seconds: 3661 },
    checks: [
      { id: 'unit', label: '最近一次启动', level: 'error', detail: '启动后立即退出（退出码 1）',
        hint: '先看项目日志和系统日志', action: 'log' },
      { id: 'server', label: '启动器', level: 'warning', detail: 'Gunicorn 未安装', action: 'server' },
      { id: 'deps', label: '依赖', level: 'warning', detail: '尚未通过面板安装', action: 'deps' },
      { id: 'port', label: '端口', level: 'ok', detail: '127.0.0.1:53200 已在监听' }
    ],
    dependency: { manifest: 'requirements.txt', present: true, installed: false,
      command: 'python3 -m pip install -r requirements.txt', detail: '尚未通过面板安装' },
    log: 'Traceback (most recent call last):\nModuleNotFoundError',
    journal: 'systemd[1]: sera-project-wechats.service: Failed with result exit-code'
  };
  // renderProjectDetail 从 #project-detail 取容器，先让 document 认识它。
  app.element('#project-detail');
  app.renderProjectDetail();
  const html = app.element('#project-detail').innerHTML;
  assert.match(html, /启动自检/);
  assert.match(html, /最近一次启动/);
  assert.match(html, /启动后立即退出（退出码 1）/);
  // 自检项要带上一键修复入口，且「日志」这种只读项不给按钮。
  assert.match(html, /data-detail-action="server">安装 Gunicorn<\/button>/);
  assert.match(html, /data-detail-action="deps"/);
  assert.match(html, /安装依赖（python3 -m pip install -r requirements.txt）/);
  assert.doesNotMatch(html, /data-detail-action="log"/);
  // 运行信息里的重启次数哪怕为 0 也要显示。
  assert.match(html, /重启次数/);
  assert.match(html, /PID 4711|>4711</);
  assert.match(html, /84\.0 MiB/);
  assert.match(html, /1小时 1分钟/);
  assert.match(html, /127\.0\.0\.1:53200/);
  assert.match(html, /ModuleNotFoundError/);
  assert.match(html, /Failed with result exit-code/);
  assert.match(html, /data-detail-action="restart"/);
  assert.doesNotMatch(html, /data-detail-action="start"/);
});

test('renderer: project card names the dependency manifest the panel recognised', () => {
  const app = loadRenderer();
  app.S.data = {
    items: [
      sampleProject({ dependency: { manifest: 'pyproject.toml', present: true, installed: false,
        command: 'pip install .', level: 'warning', action: 'deps' } }),
      sampleProject({ id: 'plain', name: 'Plain',
        dependency: { manifest: 'requirements.txt', present: false, installed: false,
          level: 'warning', action: 'edit',
          detail: '工程里有 requirements.txt；项目没有启用虚拟环境，面板不会把依赖装进共享的 Python' } }),
      sampleProject({ id: 'svc', name: 'Svc', runtime: 'java',
        dependency: { present: false, installed: false, level: 'ok',
          detail: '该运行环境不需要在服务器上安装依赖' } })
    ],
    runtimes: []
  };
  app.renders.projects();
  const html = app.element('#content').innerHTML;
  // 识别到的清单名直接写在卡片上，不必先点进详情。
  assert.match(html, /pyproject\.toml · 尚未安装（pip install \.）/);
  assert.match(html, /requirements\.txt · 面板不会替它装，原因见详情/);
  // Java 的 jar 本来就不装依赖：卡片上不该多出这一行。
  assert.equal(html.match(/依赖清单/g).length, 2);
});

test('renderer: dependency card text covers installed, refused and nothing-to-do cases', () => {
  const { dependencyCardText } = loadRenderer().helpers;
  assert.equal(dependencyCardText({ manifest: 'requirements.txt', installed: true, level: 'ok' }),
    'requirements.txt · 已安装');
  assert.equal(dependencyCardText({ manifest: 'pyproject.toml', installed: false, command: 'pip install .',
    action: 'deps', level: 'warning' }), 'pyproject.toml · 尚未安装（pip install .）');
  // 面板不打算装（Python 没开虚拟环境）时，别挂一个点不动的「尚未安装」。
  assert.equal(dependencyCardText({ manifest: 'requirements.txt', installed: false, action: 'edit',
    level: 'warning' }), 'requirements.txt · 面板不会替它装，原因见详情');
  // 说不出清单名时原样转达服务端的结论；确实没事就不占这一行。
  assert.equal(dependencyCardText({ present: false, installed: false, level: 'warning',
    detail: '项目没有启用虚拟环境，面板不会把依赖装进共享的 Python' }),
  '项目没有启用虚拟环境，面板不会把依赖装进共享的 Python');
  assert.equal(dependencyCardText({ present: false, installed: false, level: 'ok',
    detail: '该运行环境不需要在服务器上安装依赖' }), '');
  assert.equal(dependencyCardText(undefined), '');
});

test('renderer: dependency card names the manifest the panel found', () => {
  const app = loadRenderer();
  const project = sampleProject();
  app.D.project = project;
  // Python 项目不一定有 requirements.txt：服务端会认出 pyproject.toml 并给出对应命令。
  app.D.detail = {
    project,
    status: { active_state: 'inactive', sub_state: 'dead', restarts: 0 },
    checks: [{ id: 'deps', label: '项目依赖', level: 'warning', detail: '尚未通过面板安装',
      hint: '点「安装依赖」执行 pip install .', action: 'deps' }],
    dependency: { manifest: 'pyproject.toml', present: true, installed: false, command: 'pip install .',
      level: 'warning', detail: '尚未通过面板安装', hint: '点「安装依赖」执行 pip install .', action: 'deps' },
    log: '', journal: ''
  };
  app.element('#project-detail');
  app.renderProjectDetail();
  const html = app.element('#project-detail').innerHTML;
  assert.match(html, /pyproject\.toml · 尚未通过面板安装/);
  assert.match(html, /安装依赖（pip install \.）/);
});

test('renderer: detail panel does not blame the project log when the process never started', () => {
  const app = loadRenderer();
  app.D.project = sampleProject({ active_state: 'inactive', sub_state: 'dead', restarts: 0 });
  app.D.detail = { project: sampleProject({ active_state: 'inactive', sub_state: 'dead', restarts: 0 }),
    status: { active_state: 'inactive', sub_state: 'dead', restarts: 0 }, checks: [],
    dependency: { manifest: '', present: false, installed: false, detail: '该运行环境不需要在服务器上安装依赖' },
    log: '', journal: '' };
  app.element('#project-detail');
  app.renderProjectDetail();
  const html = app.element('#project-detail').innerHTML;
  assert.match(html, /暂无日志/);
  assert.match(html, /该运行环境不需要在服务器上安装依赖/);
  assert.doesNotMatch(html, /进程还没起来就退出时/);
  assert.match(html, /data-detail-action="start"/);
  assert.doesNotMatch(html, /data-detail-action="restart"/);
});

test('renderer: project form exposes env pairs, .env switch and the free-port picker', () => {
  const app = loadRenderer();
  app.S.data = { runtimes: [{ id: 'python', name: 'Python', installed: true, versions: ['3.13.16'] },
    { id: 'node', name: 'Node.js', installed: true, versions: ['22'] }] };
  app.projectForm();
  const html = app.element('#modal-content').innerHTML;
  assert.match(html, /id="field-env"/);
  assert.match(html, /id="field-env_file"/);
  assert.match(html, /data-free-port>选择空闲端口<\/button>/);
  assert.match(html, /id="field-port"/);
  // 保存按钮要留着（详情窗口才隐藏它）。
  assert.equal(app.element('#modal-submit').hidden, false);
  // 编辑已有项目时要把环境变量回填成 KEY=VALUE 文本。
  app.projectForm(sampleProject());
  assert.match(app.element('#modal-content').innerHTML, /LOG_LEVEL|DATABASE_URL/);
});

test('renderer: environment variables page explains both ways to consume it', () => {
  const app = loadRenderer();
  app.S.data = { variables: [{ name: 'API_BASE', value: 'https://example.test' },
    { name: 'PROJECT_RUNTIME', value: 'dev' }], updated_at: '2026-10-14T03:00:00Z',
    file: '/www/seraphim/server/env' };
  app.S.section = 'variables';
  app.renders.variables();
  const html = app.element('#content').innerHTML;
  // 一行一个 KEY=VALUE，值的顺序跟服务端返回的一致。
  assert.match(html, /API_BASE=https:\/\/example\.test/);
  assert.match(html, /PROJECT_RUNTIME=dev/);
  assert.match(html, /data-action="variables\.save"/);
  assert.match(html, /共 2 项/);
  assert.match(html, /最后更新 2026-10-14 03:00/);
  // 两条取用路径都要写明白：项目勾选加载，或者代码直接读这个文件。
  assert.match(html, /\. \/www\/seraphim\/server\/env/);
  assert.match(html, /在项目里勾上「加载面板环境变量」/);
  // 空表也要能打开，而不是显示一个坏掉的文本框。
  app.S.data = { variables: [] };
  app.renders.variables();
  assert.match(app.element('#content').innerHTML, /共 0 项/);
});

test('renderer: saving variables reports which projects were synced', async () => {
  const app = loadRenderer();
  let sent = null;
  app.window.sera.api = async (action, payload) => {
    if (action === 'variables.save') { sent = payload; return { variables: payload.variables, applied: ['WeChats'] }; }
    return { variables: [{ name: 'PROJECT_RUNTIME', value: 'dev' }] };
  };
  app.S.section = 'variables';
  app.element('#variables-text').value = '# 注释\nPROJECT_RUNTIME=dev\n';
  await app.variablesAction('variables.save');
  // 注释行不进请求，空行也不进。
  assert.deepEqual([...sent.variables.map((item) => item.name)], ['PROJECT_RUNTIME']);
  assert.equal(sent.variables[0].value, 'dev');
  assert.match(app.S.variablesNotice, /已保存 1 项，并同步到 1 个项目：WeChats/);
  // 写坏一行时说清楚是哪儿坏了，别把半张表发上去。
  app.element('#variables-text').value = '没有等号';
  await app.variablesAction('variables.save');
  assert.match(app.element('#notice').textContent, /KEY=VALUE/);
});

test('renderer: only projects that opt in point at the shared variables', () => {
  const app = loadRenderer();
  app.S.data = { items: [sampleProject({ use_global_env: true }),
    sampleProject({ id: 'plain', name: 'Plain' })], runtimes: [] };
  app.renders.projects();
  const html = app.element('#content').innerHTML;
  assert.match(html, /已加载「环境变量管理」里的值/);
  assert.match(html, /data-action="variables\.goto"/);
  // 默认不加载的项目不该在卡片上多出一行。
  assert.equal(html.match(/面板环境变量/g).length, 1);
  // 模块是独立的一级菜单，项目管理页不再挂它自己的入口。
  assert.doesNotMatch(app.element('#page-actions').innerHTML, /variables\.goto/);
});

test('renderer: project form leaves the shared variables switch off by default', () => {
  const app = loadRenderer();
  app.S.globalVariables = [{ name: 'PROJECT_RUNTIME', value: 'dev' }];
  app.S.data = { runtimes: [{ id: 'python', name: 'Python', installed: true, versions: ['3.13.16'] }] };
  app.projectForm();
  let html = app.element('#modal-content').innerHTML;
  // 默认不加载：面板不替项目决定要不要读那份公用变量。
  assert.doesNotMatch(html, /id="field-use_global_env"[^>]*checked/);
  // 标签里点名当前有哪些变量，用户不用来回翻页。
  assert.match(html, /加载面板的公用环境变量（当前 1 项：PROJECT_RUNTIME）/);
  app.projectForm(sampleProject({ use_global_env: true }));
  html = app.element('#modal-content').innerHTML;
  assert.match(html, /id="field-use_global_env"[^>]*checked/);
});

test('renderer: detail panel separates shared and project variables', () => {
  const app = loadRenderer();
  const project = sampleProject({ use_global_env: true });
  app.D.project = project;
  app.D.detail = {
    project,
    status: { active_state: 'active', sub_state: 'running', main_pid: 1, restarts: 0 },
    checks: [{ id: 'variables', label: '面板环境变量', level: 'ok', detail: '已加载 2 项：PROJECT_RUNTIME',
      hint: '其中 DATABASE_URL 被项目自己的变量覆盖', action: 'variables' }],
    dependency: { manifest: '', present: false, installed: false },
    // 项目自己也定义了 DATABASE_URL，同名以项目为准。
    global_variables: [{ name: 'DATABASE_URL', value: 'global' }, { name: 'PROJECT_RUNTIME', value: 'dev' }],
    log: '', journal: ''
  };
  app.element('#project-detail');
  app.renderProjectDetail();
  const html = app.element('#project-detail').innerHTML;
  assert.match(html, /面板 · PROJECT_RUNTIME/);
  assert.match(html, /面板 · DATABASE_URL/);
  assert.match(html, /被项目变量覆盖/);
  assert.match(html, /项目 · DATABASE_URL/);
  // 自检里的按钮要能跳到变量模块。
  assert.match(html, /data-detail-action="variables"/);
  // 没加载的项目要说清楚，否则用户会一直找「变量怎么没生效」。
  const plain = sampleProject({ id: 'plain', name: 'Plain' });
  app.D.project = plain;
  app.D.detail = { ...app.D.detail, project: plain, global_variables: [] };
  app.renderProjectDetail();
  assert.match(app.element('#project-detail').innerHTML, /没有加载面板那份公用变量/);
});

test('renderer: project helpers keep the same wording as the macOS client', () => {
  const app = loadRenderer();
  const { projectStartupText, projectServerLabel, parseEnvText, formatEnvText, fmtUptime,
    projectFailureText, dependencyText, actionMenu, checkActionLabel } = app.helpers;
  assert.equal(projectServerLabel(sampleProject()), 'Gunicorn');
  assert.equal(projectServerLabel(sampleProject({ python_server: 'direct' })), '直接运行');
  assert.equal(projectStartupText(sampleProject()), 'Gunicorn · app · 2 进程 · uvicorn worker');
  assert.equal(projectStartupText(sampleProject({ runtime: 'node', entry: 'index.js' })), 'index.js');
  assert.equal(projectFailureText(sampleProject()), '进程反复退出，systemd 正在自动重启');
  assert.equal(projectFailureText(sampleProject({ sub_state: 'dead', result: 'start-limit-hit', exit_status: 0 })),
    '连续失败次数过多，已放弃重启');
  assert.equal(projectFailureText(sampleProject({ sub_state: 'dead', result: 'exit-code', exit_status: 3 })),
    '启动后立即退出（退出码 3）');
  assert.equal(fmtUptime(0), '');
  assert.equal(fmtUptime(3661), '1小时 1分钟');
  assert.equal(fmtUptime(90061), '1天 1小时');
  // vm 里的对象是另一个 realm 的，铺平再比，免得 deepEqual 计较原型。
  assert.deepEqual({ ...parseEnvText('# 注释\n\nA=1\nB=two=three') }, { A: '1', B: 'two=three' });
  assert.equal(formatEnvText({ A: '1', B: 'two=three' }), 'A=1\nB=two=three');
  assert.throws(() => parseEnvText('没有等号'), /KEY=VALUE/);
  assert.throws(() => parseEnvText('1A=1'), /不合法/);
  assert.equal(formatEnvText(undefined), '');
  assert.equal(dependencyText(undefined), '正在读取…');
  assert.equal(dependencyText({ manifest: '', detail: '该运行环境不需要在服务器上安装依赖' }),
    '该运行环境不需要在服务器上安装依赖');
  assert.match(actionMenu('更多', ['', null, '<b>x</b>']), /^<details class="menu"><summary>更多 ▾<\/summary>/);
  assert.doesNotMatch(actionMenu('更多', ['']), /null|<b>/);
  assert.equal(checkActionLabel({ action: 'log' }), '');
  assert.equal(checkActionLabel({ action: 'files' }), '打开目录');
});

// API 设置：接口列表 + 一把给脚本与 AI 用的 key。这把 key 与面板连服务器用的
// 凭据是两把，能重置；页面上能复制的东西必须指向真实存在的元素，否则点了没
// 反应——这类错没有测试就只能靠用户发现。
const sampleApiDoc = (overrides = {}) => ({
  version: '1',
  endpoint: 'https://192.168.0.103:27520',
  key: 'deadbeefdeadbeefdeadbeefdeadbeef',
  header: 'Authorization: Bearer deadbeefdeadbeefdeadbeefdeadbeef',
  sections: [
    { name: '接入', endpoints: [
      { method: 'GET', path: '/v1/api', summary: '本接口列表与当前的 API key' },
      { method: 'POST', path: '/v1/api/key', summary: '重置 API key' }
    ] },
    { name: '项目', endpoints: [
      { method: 'GET', path: '/v1/projects', summary: '项目列表' },
      { method: 'POST', path: '/v1/projects/import', summary: '上传压缩包并一步建好项目',
        example: 'curl -k --data-binary @demo.tar.gz' }
    ] },
    { name: '给 AI 用', endpoints: [
      { method: 'POST', path: '/v1/mcp', summary: 'MCP 端点' }
    ] }
  ],
  mcp: {
    url: 'https://192.168.0.103:27520/v1/mcp',
    tools: [{ name: 'list_projects', description: '列出所有托管项目' },
      { name: 'import_project', description: '一步建好项目' }]
  },
  ...overrides
});

test('renderer: API 设置页摊开接口列表、key 与 MCP 配置', () => {
  const app = loadRenderer();
  app.S.data = sampleApiDoc();
  app.renders.api();
  const html = app.element('#content').innerHTML;
  assert.match(html, /192\.168\.0\.103:27520/);
  assert.match(html, /deadbeefdeadbeefdeadbeefdeadbeef/);
  assert.match(html, /GET \/v1\/projects/);
  assert.match(html, /POST \/v1\/projects\/import/);
  assert.match(html, /上传压缩包并一步建好项目/);
  assert.match(html, /curl -k --data-binary @demo\.tar\.gz/);
  assert.match(html, /共 5 个接口/);
  // 这把 key 与面板凭据是两把，能重置——页面上要能看见这个动作，也要说清楚
  // 它不能自己填。
  assert.match(html, /data-action="api\.reset"/);
  assert.match(html, /只能重置，不能自己填/);
  assert.doesNotMatch(html, /<input/);
  // HTTP 传输的配置里要有端点地址；stdio 传输里要有两个环境变量与占位路径。
  assert.match(html, /v1\/mcp/);
  assert.match(html, /SERAPHIM_ENDPOINT/);
  assert.match(html, /SERAPHIM_TOKEN/);
  assert.match(html, /seraphim-mcp\.py/);
  assert.match(html, /data-action="api\.download"/);
  // 复制按钮指向的元素真的在页面上。
  for (const id of ['#api-key', '#api-curl', '#api-mcp-http', '#api-mcp-stdio'])
    assert.match(html, new RegExp(`data-copy="${id}"`), id);
  assert.equal((html.match(/id="(api-key|api-curl|api-mcp-http|api-mcp-stdio)"/g) || []).length, 4);
  // AI 能用的工具要列出来，用户才知道接上之后能干什么。
  assert.match(html, /list_projects/);
  assert.match(html, /AI 能用的 2 个工具/);
});

test('renderer: 重置 API key 会换掉页面上所有出现 key 的地方', async () => {
  const app = loadRenderer();
  const calls = [];
  app.window.sera.api = async (action) => {
    calls.push(action);
    if (action === 'api.reset')
      return sampleApiDoc({ key: 'cafebabecafebabecafebabecafebabe',
        header: 'Authorization: Bearer cafebabecafebabecafebabecafebabe' });
    throw new Error(`不该调用 ${action}`);
  };
  app.S.data = sampleApiDoc();
  app.renders.api();
  await app.apiAction('api.reset');
  assert.deepEqual(calls, ['api.reset']);
  const html = app.element('#content').innerHTML;
  // 旧 key 不能有任何残留：示例脚本、请求头、MCP 配置都得跟着换。
  assert.doesNotMatch(html, /deadbeef/);
  assert.match(html, /cafebabecafebabecafebabecafebabe/);
  assert.match(app.element('#notice').textContent, /已重置/);

  // 用户点了取消就什么都不该发生。
  app.globals.confirm = () => false;
  calls.length = 0;
  await app.apiAction('api.reset');
  assert.deepEqual(calls, []);
});

test('renderer: API 设置页在服务端只给了半份数据时也不崩', () => {
  const app = loadRenderer();
  app.S.data = {};
  app.renders.api();
  const html = app.element('#content').innerHTML;
  assert.match(html, /暂未获取到接口列表/);
  assert.match(html, /AI 能用的 0 个工具/);
});
