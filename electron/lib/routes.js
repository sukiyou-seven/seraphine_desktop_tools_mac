const segment = (value) => {
  const text = String(value ?? '');
  if (!text || text.length > 240 || text === '.' || text === '..' || text.includes('/'))
    throw new Error('标识无效');
  return encodeURIComponent(text);
};
const choice = (value, allowed) => {
  if (!allowed.includes(value)) throw new Error('操作无效');
  return value;
};
const pathQuery = (path) => {
  if (typeof path !== 'string' || !path.startsWith('/') || path.length > 4096) throw new Error('服务器路径无效');
  return new URLSearchParams({ path }).toString();
};

function route(action, p = {}) {
  switch (action) {
  case 'status': return ['GET', '/v1/status'];
  case 'files.list': return ['GET', `/v1/files?${pathQuery(p.path)}`];
  case 'files.command':
    return ['POST', '/v1/files', {
      operation: choice(p.operation, ['mkdir', 'touch', 'rename', 'chmod']),
      path: p.path, destination: p.destination, overwrite: Boolean(p.overwrite), permissions: p.permissions
    }];
  case 'files.delete': return ['DELETE', `/v1/files?${pathQuery(p.path)}&recursive=${p.recursive === true}`];
  case 'services.list': return ['GET', '/v1/services'];
  case 'services.action': return ['POST', '/v1/services', { name: p.name,
    action: choice(p.action, ['start', 'stop', 'restart', 'enable', 'disable']) }];
  case 'software.list': return ['GET', '/v1/software'];
  case 'software.install': return ['POST', `/v1/software/${segment(p.id)}/install`, p.version ? { version: p.version } : {}];
  case 'software.uninstall': return ['POST', `/v1/software/${segment(p.id)}/uninstall`,
    { mode: choice(p.mode, ['backup', 'purge']) }];
  case 'software.service': return ['POST', `/v1/software/${segment(p.id)}/service`,
    { action: choice(p.action, ['start', 'stop', 'restart', 'enable', 'disable']) }];
  case 'software.log': return ['GET', `/v1/software/${segment(p.id)}/log`];
  case 'environments.list': return ['GET', '/v1/environments'];
  case 'environments.versions': return ['GET', `/v1/environments/${segment(p.id)}/versions`];
  case 'environments.install': return ['POST', `/v1/environments/${segment(p.id)}/install`, { version: p.version }];
  case 'environments.check': return ['POST', p.legacy
    ? `/v1/environments/${segment(p.id)}/check`
    : `/v1/environments/${segment(p.id)}/versions/${segment(p.version)}/check`];
  case 'environments.uninstall': return ['POST',
    `/v1/environments/${segment(p.id)}/versions/${segment(p.version)}/uninstall`,
    { mode: choice(p.mode, ['backup', 'purge']) }];
  case 'environments.service': return ['POST',
    `/v1/environments/php/versions/${segment(p.version)}/service`,
    { action: choice(p.action, ['start', 'stop']) }];
  case 'sites.list': return ['GET', '/v1/sites'];
  case 'sites.create': return ['POST', '/v1/sites', p.site];
  case 'sites.update': return ['PUT', `/v1/sites/${segment(p.provider)}/${segment(p.id)}`, p.site];
  case 'sites.delete': return ['DELETE', `/v1/sites/${segment(p.provider)}/${segment(p.id)}`];
  case 'projects.list': return ['GET', '/v1/projects'];
  case 'projects.create': return ['POST', '/v1/projects', p.project];
  case 'projects.update': return ['PUT', `/v1/projects/${segment(p.id)}`, p.project];
  case 'projects.delete': return ['DELETE', `/v1/projects/${segment(p.id)}`];
  case 'projects.action': return ['POST', `/v1/projects/${segment(p.id)}/action`,
    { action: choice(p.action, ['start', 'stop', 'restart', 'enable', 'disable']) }];
  case 'projects.venv': return ['POST', `/v1/projects/${segment(p.id)}/venv`,
    { action: choice(p.action, ['create', 'install_requirements']) }];
  case 'projects.log': return ['GET', `/v1/projects/${segment(p.id)}/log`];
  case 'databases.list': return ['GET', '/v1/databases'];
  case 'databases.catalog': return ['GET', `/v1/databases/${segment(p.engine)}/catalog`];
  case 'databases.create': return ['POST', `/v1/databases/${segment(p.engine)}/databases`, { name: p.name }];
  case 'databases.delete': return ['DELETE', `/v1/databases/${segment(p.engine)}/databases/${segment(p.name)}`];
  case 'databases.user.create': return ['POST', `/v1/databases/${segment(p.engine)}/users`, { name: p.name }];
  case 'databases.user.delete': return ['DELETE', `/v1/databases/${segment(p.engine)}/users/${segment(p.name)}`];
  case 'databases.user.reset': return ['POST', `/v1/databases/${segment(p.engine)}/users/${segment(p.name)}:reset`];
  case 'databases.grant': return [p.revoke ? 'DELETE' : 'POST', `/v1/databases/${segment(p.engine)}/grants`,
    { database: p.database, user: p.user, level: choice(p.level, ['read', 'readwrite']) }];
  case 'databases.mysql.bootstrap': return ['POST', '/v1/databases/mysql/bootstrap'];
  case 'databases.mysql.credential': return ['POST', '/v1/databases/mysql/credential', { password: p.password }];
  case 'databases.postgresql.localAccess': return ['POST', '/v1/databases/postgresql/local-access'];
  case 'databases.acl': return ['GET', `/v1/databases/${segment(p.engine)}/acl`];
  case 'databases.acl.enable': return ['POST', `/v1/databases/${segment(p.engine)}/acl/enable`];
  case 'databases.acl.credential': return ['POST', `/v1/databases/${segment(p.engine)}/acl/credential`, { password: p.password }];
  case 'databases.acl.create': return ['POST', `/v1/databases/${segment(p.engine)}/acl/users`,
    { name: p.name, level: choice(p.level, ['read', 'readwrite']) }];
  case 'databases.acl.update': return ['PUT', `/v1/databases/${segment(p.engine)}/acl/users/${segment(p.name)}`,
    { enabled: Boolean(p.enabled), level: choice(p.level, ['read', 'readwrite']) }];
  case 'databases.acl.reset': return ['POST', `/v1/databases/${segment(p.engine)}/acl/users/${segment(p.name)}:reset`];
  case 'databases.acl.delete': return ['DELETE', `/v1/databases/${segment(p.engine)}/acl/users/${segment(p.name)}`];
  case 'firewall.get': return ['GET', '/v1/firewall'];
  case 'firewall.change': return ['POST', '/v1/firewall', {
    action: choice(p.action, ['add', 'remove']), port: Number(p.port),
    protocol: choice(p.protocol, ['tcp', 'udp']) }];
  case 'tasks.list': return ['GET', '/v1/tasks'];
  case 'tasks.create': return ['POST', '/v1/tasks', p.task];
  case 'tasks.update': return ['PUT', `/v1/tasks/${segment(p.id)}`, p.task];
  case 'tasks.delete': return ['DELETE', `/v1/tasks/${segment(p.id)}`];
  case 'tasks.log': return ['GET', `/v1/tasks/${segment(p.id)}?view=log`];
  default: throw new Error('不支持的接口操作');
  }
}

module.exports = { route, segment, pathQuery };
