const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const test = require('node:test');

const script = readFileSync(path.join(__dirname, 'apply-schema-gcp.sh'), 'utf8');
const deployment = {
  project_id: 'example-project', region: 'us-central1', db_instance: 'distributed-cloud-mysql',
  db_connection_name: 'example-project:us-central1:distributed-cloud-mysql',
  runtime_secret_id: 'runtime', db_host: '10.0.0.2', db_name: 'aula_pratica_db',
  registry: 'us-central1-docker.pkg.dev/example-project/api'
};
const image = `${deployment.registry}/api@sha256:${'a'.repeat(64)}`;
const secretPayload = JSON.stringify({ DB_USER: 'api_user', DB_PASSWORD: 'neverlogthis' });

function fixture(context) {
  const root = mkdtempSync(path.join(tmpdir(), 'schema-proxy-test-'));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'bin'));
  mkdirSync(path.join(root, 'infra'));
  mkdirSync(path.join(root, 'scripts'));
  mkdirSync(path.join(root, 'runner-temp'));
  writeFileSync(path.join(root, 'scripts', 'apply-schema-gcp.sh'), script);
  const credentials = path.join(root, 'deployer-credentials.json');
  writeFileSync(credentials, '{}', { mode: 0o600 });
  const trace = path.join(root, 'trace');
  const state = path.join(root, 'state');
  const env = {
    ...process.env, PATH: `${root}/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin`,
    TRACE: trace, STATE: state, DEPLOYMENT: JSON.stringify(deployment),
    GOOGLE_APPLICATION_CREDENTIALS: credentials, RUNNER_TEMP: path.join(root, 'runner-temp'),
    SCHEMA_CONNECT_ATTEMPTS: '3', MOCK_SECRET: secretPayload,
    MOCK_SECRET_FAIL: '', MOCK_PROXY_FAIL: '', MOCK_SCHEMA_FAILS: '0'
  };
  const executable = (name, body) => writeFileSync(path.join(root, 'bin', name),
    `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  const events = () => existsSync(trace)
    ? readFileSync(trace, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
  executable('terraform', String.raw`
    require('node:fs').appendFileSync(process.env.TRACE, JSON.stringify({tool: 'terraform', args: process.argv.slice(2)}) + '\n');
    process.stdout.write(process.env.DEPLOYMENT);
  `);
  executable('gcloud', String.raw`
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    fs.appendFileSync(process.env.TRACE, JSON.stringify({tool: 'gcloud', args}) + '\n');
    if (process.env.MOCK_SECRET_FAIL) process.exit(1);
    process.stdout.write(process.env.MOCK_SECRET);
  `);
  executable('docker', String.raw`
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    const state = fs.existsSync(process.env.STATE) ? JSON.parse(fs.readFileSync(process.env.STATE, 'utf8')) : {schemaRuns: 0};
    const event = {tool: 'docker', args};
    if (args[0] === 'run' && args.includes('--env-file')) {
      state.schemaRuns += 1;
      fs.writeFileSync(process.env.STATE, JSON.stringify(state));
      const envPath = args[args.indexOf('--env-file') + 1];
      const contents = fs.readFileSync(envPath, 'utf8');
      event.schemaEnvMode = fs.statSync(envPath).mode & 0o777;
      event.hasPassword = contents.includes('neverlogthis');
      event.dbHost = contents.match(/^DB_HOST=(.*)$/m)?.[1];
    }
    fs.appendFileSync(process.env.TRACE, JSON.stringify(event) + '\n');
    if (args[0] === 'run' && args.some(arg => arg.includes('cloud-sql-proxy')) && process.env.MOCK_PROXY_FAIL) process.exit(1);
    if (args[0] === 'run' && args.includes('--env-file') && state.schemaRuns <= Number(process.env.MOCK_SCHEMA_FAILS)) process.exit(1);
  `);
  executable('sleep', 'process.exit(0);');
  return { root, env, events, state };
}

function launch(context, options = {}) {
  const setup = fixture(context);
  Object.assign(setup.env, options.env);
  const result = spawnSync('/bin/bash', [path.join(setup.root, 'scripts', 'apply-schema-gcp.sh'), ...(options.args || [image])], {
    cwd: setup.root, env: setup.env, encoding: 'utf8', timeout: 10000
  });
  assert.ifError(result.error);
  return { ...setup, result };
}

test('schema script is valid Bash', () => {
  const result = spawnSync('/bin/bash', ['-n'], { input: script, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('applies schema through private Docker network and Cloud SQL Auth Proxy without a VM', context => {
  const { result, events, root } = launch(context);
  assert.equal(result.status, 0, `${JSON.stringify(events())}\n${result.stderr}`);
  assert.match(result.stdout, /Schema applied successfully/);
  const calls = events();
  assert.ok(calls.some(event => event.tool === 'gcloud' && event.args[0] === 'secrets' && event.args.includes('access')));
  assert.ok(!calls.some(event => event.args.some(arg => arg === 'compute' || arg === 'instances')));
  const networkCreate = calls.find(event => event.tool === 'docker' && event.args[0] === 'network' && event.args[1] === 'create');
  const proxy = calls.find(event => event.tool === 'docker' && event.args[0] === 'run' && event.args.some(arg => arg.includes('cloud-sql-proxy')));
  const schema = calls.find(event => event.tool === 'docker' && event.args[0] === 'run' && event.args.includes('--env-file'));
  assert.ok(networkCreate);
  assert.ok(proxy);
  assert.ok(proxy.args.includes('gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.27.0'));
  assert.ok(proxy.args.includes(deployment.db_connection_name));
  assert.ok(proxy.args.some(arg => arg.includes(`src=${path.join(root, 'deployer-credentials.json')}`)));
  assert.ok(!proxy.args.some(arg => arg === '-p' || arg === '--publish'));
  assert.ok(schema.args.includes(image));
  assert.equal(schema.dbHost, 'cloud-sql-proxy');
  assert.equal(schema.schemaEnvMode, 0o600);
  assert.equal(schema.hasPassword, true);
  assert.doesNotMatch(result.stdout + result.stderr, /neverlogthis/);
  assert.deepEqual(readdirSync(path.join(root, 'runner-temp')), []);
  assert.ok(calls.some(event => event.tool === 'docker' && event.args[0] === 'rm' && event.args.includes('--force')));
  assert.ok(calls.some(event => event.tool === 'docker' && event.args[0] === 'network' && event.args[1] === 'rm'));
});

test('retries schema connection while proxy starts, then cleans up', context => {
  const { result, events, state } = launch(context, { env: { MOCK_SCHEMA_FAILS: '2' } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(readFileSync(state, 'utf8')).schemaRuns, 3);
  assert.equal(events().filter(event => event.tool === 'docker' && event.args.includes('--env-file')).length, 3);
});

test('secret access failure stops before starting Docker and never prints payload', context => {
  const { result, events } = launch(context, { env: { MOCK_SECRET_FAIL: '1' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /secret-fetch/);
  assert.ok(!events().some(event => event.tool === 'docker'));
  assert.doesNotMatch(result.stdout + result.stderr, /neverlogthis/);
});

test('proxy startup failure removes its container and private network', context => {
  const { result, events } = launch(context, { env: { MOCK_PROXY_FAIL: '1' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /proxy-start/);
  assert.ok(events().some(event => event.tool === 'docker' && event.args[0] === 'rm'));
  assert.ok(events().some(event => event.tool === 'docker' && event.args[0] === 'network' && event.args[1] === 'rm'));
  assert.doesNotMatch(result.stdout + result.stderr, /neverlogthis/);
});

test('schema failure retries only within bound, hides database output, and cleans up', context => {
  const { result, events, state } = launch(context, { env: { MOCK_SCHEMA_FAILS: '3' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /schema-apply/);
  assert.equal(JSON.parse(readFileSync(state, 'utf8')).schemaRuns, 3);
  assert.ok(events().some(event => event.tool === 'docker' && event.args[0] === 'rm'));
  assert.ok(events().some(event => event.tool === 'docker' && event.args[0] === 'network' && event.args[1] === 'rm'));
  assert.doesNotMatch(result.stdout + result.stderr, /never-log-this/);
});

test('invalid image, outputs, credentials and retry settings fail before cloud calls', context => {
  const invalidCases = [
    { args: [`${deployment.registry}/api:latest`] },
    { env: { DEPLOYMENT: JSON.stringify({ ...deployment, db_connection_name: null }) } },
    { env: { GOOGLE_APPLICATION_CREDENTIALS: '/missing/credentials.json' } },
    { env: { SCHEMA_CONNECT_ATTEMPTS: '0' } }
  ];
  for (const options of invalidCases) {
    const { result, events } = launch(context, options);
    assert.notEqual(result.status, 0);
    assert.equal(events().filter(event => event.tool === 'gcloud' || event.tool === 'docker').length, 0);
  }
});