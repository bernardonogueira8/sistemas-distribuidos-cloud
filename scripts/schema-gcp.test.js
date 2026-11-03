const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const host = readFileSync(path.join(__dirname, 'apply-schema-gcp.sh'), 'utf8');
const startup = readFileSync(path.join(__dirname, 'schema-startup.sh.tftpl'), 'utf8');
const deployment = {
  project_id: 'example-project', region: 'us-central1',
  subnetwork: 'projects/example-project/regions/us-central1/subnetworks/app',
  schema_service_account: 'schema@example-project.iam.gserviceaccount.com',
  runtime_secret_id: 'runtime', db_host: '10.0.0.2', db_name: 'aula_pratica_db',
  registry: 'us-central1-docker.pkg.dev/example-project/api',
  zones: ['us-central1-a', 'us-central1-b']
};
const image = `${deployment.registry}/api@sha256:${'a'.repeat(64)}`;

function fixture(context) {
  const root = mkdtempSync(path.join(tmpdir(), 'schema-test-'));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'bin'));
  mkdirSync(path.join(root, 'scripts'));
  mkdirSync(path.join(root, 'infra'));
  writeFileSync(path.join(root, 'scripts/apply-schema-gcp.sh'), host);
  writeFileSync(path.join(root, 'scripts/schema-startup.sh.tftpl'), startup);
  const trace = path.join(root, 'trace');
  const env = {
    ...process.env, PATH: `${root}/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin`,
    TRACE: trace, DEPLOYMENT: JSON.stringify(deployment),
    SCHEMA_TIMEOUT_SECONDS: '1', SCHEMA_POLL_SECONDS: '1',
    MOCK_MODE: 'success', MOCK_DELETE_FAIL: '', MOCK_CREATE_FAIL: '', MOCK_FAILURE_STAGE: 'schema-apply', MOCK_TIMEOUT_STAGE: 'image-pull'
  };
  const executable = (name, body) => writeFileSync(path.join(root, 'bin', name),
    `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  const events = () => existsSync(trace)
    ? readFileSync(trace, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  return { root, env, executable, events };
}

function launch(context, options = {}) {
  const setup = fixture(context);
  setup.executable('terraform', `
    require('node:fs').appendFileSync(process.env.TRACE, JSON.stringify(process.argv.slice(2)) + '\\n');
    process.stdout.write(process.env.DEPLOYMENT);
  `);
  setup.executable('gcloud', `
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    fs.appendFileSync(process.env.TRACE, JSON.stringify(args) + '\\n');
    if (args.includes('create')) process.exit(process.env.MOCK_CREATE_FAIL ? 1 : 0);
    if (args.includes('delete')) process.exit(process.env.MOCK_DELETE_FAIL ? 1 : 0);
    if (process.env.MOCK_MODE === 'unavailable') process.exit(1);
    if (process.env.MOCK_MODE === 'malformed') { console.log('not json'); process.exit(0); }
    const failureStage = args.includes('--query-path=schema/failure-stage');
    const stage = args.includes('--query-path=schema/stage');
    console.log(JSON.stringify({queryValue: {items: process.env.MOCK_MODE === 'pending' && !stage ? [] :
      [{namespace: 'schema', key: failureStage ? 'failure-stage' : stage ? 'stage' : 'status',
        value: failureStage ? process.env.MOCK_FAILURE_STAGE : stage ? process.env.MOCK_TIMEOUT_STAGE : process.env.MOCK_MODE}]}}));
  `);
  Object.assign(setup.env, options.env);
  const result = spawnSync('/bin/bash', [path.join(setup.root, 'scripts/apply-schema-gcp.sh'),
    ...(options.args || [image])], { env: setup.env, encoding: 'utf8', timeout: 10000 });
  assert.ifError(result.error);
  return { ...setup, result };
}

test('maintenance scripts are valid Bash', () => {
  for (const script of [host, startup]) {
    const result = spawnSync('/bin/bash', ['-n'], { input: script, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
});

test('success creates private COS with schema identity and deletes it without SSH', context => {
  const { result, events, root } = launch(context);
  assert.equal(result.status, 0, result.stderr);
  const calls = events();
  assert.deepEqual(calls[0], [`-chdir=${root}/infra`, 'output', '-json', 'deployment']);
  const create = calls.find(args => args.includes('create'));
  for (const expected of ['--no-address', '--image-family=cos-stable', '--image-project=cos-cloud',
    `--subnet=${deployment.subnetwork}`, `--service-account=${deployment.schema_service_account}`,
    `--zone=${deployment.zones[0]}`]) assert.ok(create.includes(expected), expected);
  const metadata = create.find(arg => arg.startsWith('--metadata='));
  assert.ok(metadata.includes('enable-guest-attributes=TRUE'));
  assert.ok(metadata.includes(`schema-image=${image}`));
  assert.ok(metadata.includes('schema-secret=runtime'));
  assert.doesNotMatch(metadata, /DB_PASSWORD|DB_USER/);
  assert.ok(create.includes(`--metadata-from-file=startup-script=${root}/scripts/schema-startup.sh.tftpl`));
  const deletion = calls.find(args => args.includes('delete'));
  assert.equal(deletion[3], create[3]);
  assert.ok(!calls.flat().includes('ssh'));
});

for (const mode of ['failed', 'pending', 'unavailable', 'malformed', 'unexpected']) {
  test(`schema ${mode} exits nonzero and deletes the VM`, context => {
    const { result, events } = launch(context, { env: { MOCK_MODE: mode } });
    assert.notEqual(result.status, 0);
    assert.equal(events().filter(args => args.includes('delete')).length, 1);
    if (mode === 'failed') assert.match(result.stderr, /Schema task failed during schema-apply/);
    if (['pending', 'unavailable', 'malformed'].includes(mode)) assert.match(result.stderr, /Timed out waiting for schema task during (image-pull|unknown)/);
  });
}

test('partially failed creation still attempts deletion', context => {
  const { result, events } = launch(context, { env: { MOCK_CREATE_FAIL: '1' } });
  assert.notEqual(result.status, 0);
  assert.ok(events().some(args => args.includes('delete')));
  assert.ok(!events().some(args => args.includes('get-guest-attributes')));
});

test('cleanup failure fails the command and identifies the stranded VM', context => {
  const { result } = launch(context, { env: { MOCK_DELETE_FAIL: '1' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Cleanup failed; delete instance schema-/);
});

test('invalid images and deployment output never call gcloud', context => {
  for (const invalid of [`${deployment.registry}/api:latest`, `${image}:tag`,
    image.replace('/api/api@', '/other/api@'), image.replace('sha256:', 'sha512:')]) {
    const { result, events } = launch(context, { args: [invalid] });
    assert.notEqual(result.status, 0);
    assert.equal(events().length, 1);
  }
  for (const override of [{ zones: [] }, { zones: ['europe-west1-a'] }, { runtime_secret_id: 'bad,metadata=x' },
    { subnetwork: 'projects/other-project/regions/us-central1/subnetworks/app' },
    { schema_service_account: null }, { db_name: 'bad\nname' }]) {
    const { result, events } = launch(context, { env: { DEPLOYMENT: JSON.stringify({ ...deployment, ...override }) } });
    assert.notEqual(result.status, 0);
    assert.equal(events().length, 1);
  }
});

test('invalid timing settings and missing arguments fail before Terraform', context => {
  for (const options of [{ args: [] }, { env: { SCHEMA_TIMEOUT_SECONDS: '0' } },
    { env: { SCHEMA_POLL_SECONDS: 'invalid' } }]) {
    const { result, events } = launch(context, options);
    assert.equal(result.status, 2);
    assert.equal(events().length, 0);
  }
});

function boot(context, mode) {
  const setup = fixture(context);
  const work = path.join(setup.root, 'protected');
  const script = path.join(setup.root, 'boot.sh');
  writeFileSync(script, startup.replace('WORK=/run/schema-job', `WORK='${work}'`));
  setup.env.MOCK_MODE = mode;
  setup.executable('systemctl', 'process.exit(0);');
  setup.executable('sleep', 'process.exit(0);');
  setup.executable('curl', `
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    const url = args[args.length - 1];
    if (url.includes('guest-attributes')) {
      const key = url.split('/').pop();
      fs.appendFileSync(process.env.TRACE, JSON.stringify({[key]: args[args.indexOf('--data') + 1]}) + '\\n');
    } else if (url.endsWith('/token')) console.log('');
    else console.log('nonsecret-reference');
  `);
  setup.executable('docker', `
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    if (args[0] === 'login') { fs.readFileSync(0); process.exit(0); }
    if (args[0] === 'pull') process.exit(process.env.MOCK_MODE === 'pull-failed' ? 1 : 0);
    if (args.includes('--input-type=module')) {
      if (process.env.MOCK_MODE === 'credentials-failed') process.exit(1);
      console.log('DB_USER=schema\\nDB_PASSWORD=never-log-this');
    } else {
      const file = args[args.indexOf('--env-file') + 1];
      fs.appendFileSync(process.env.TRACE, JSON.stringify({
        args, mode: fs.statSync(file).mode & 0o777,
        directoryMode: fs.statSync(require('node:path').dirname(file)).mode & 0o777,
        protected: fs.readFileSync(file, 'utf8').includes('never-log-this')
      }) + '\\n');
      console.log('never-log-this');
      console.error('never-log-this');
      process.exit(process.env.MOCK_MODE === 'failed' ? 7 : 0);
    }
  `);
  const result = spawnSync('/bin/bash', [script], { env: setup.env, encoding: 'utf8', timeout: 10000 });
  assert.ifError(result.error);
  return { ...setup, result, work };
}

for (const mode of ['success', 'failed', 'pull-failed', 'credentials-failed']) {
  test(`COS ${mode} reports actual outcome and removes protected files`, context => {
    const { result, events, work } = boot(context, mode);
    assert.equal(result.status === 0, mode === 'success', result.stderr);
    assert.equal(events().at(-1).status, mode === 'success' ? 'success' : 'failed');
    const failureStage = { failed: 'schema-apply', 'pull-failed': 'image-pull', 'credentials-failed': 'secret-access' }[mode];
    if (failureStage) assert.ok(events().some(event => event.stage === failureStage));
    assert.equal(existsSync(work), false);
    assert.doesNotMatch(result.stdout + result.stderr, /never-log-this/);
    const container = events().find(event => event.args);
    if (['success', 'failed'].includes(mode)) {
      assert.equal(container.mode, 0o600);
      assert.equal(container.directoryMode, 0o700);
      assert.equal(container.protected, true);
      assert.ok(container.args.includes('--log-driver'));
      assert.deepEqual(container.args.slice(-3), ['node', 'nonsecret-reference', 'src/db/apply-schema.js']);
    } else assert.equal(container, undefined);
  });
}

const credentialScript = startup.split('--input-type=module -e \'\n')[1].split("\n  ' >")[0];
async function credentials(payload, denied = false) {
  const output = [];
  const errors = [];
  const requests = [];
  let exitCode = 0;
  await vm.runInNewContext(`(async () => {${credentialScript}})()`, {
    Buffer, AbortSignal, encodeURIComponent,
    console: { log: value => output.push(value), error: value => errors.push(value) },
    process: { env: { PROJECT_ID: 'example-project', SECRET_ID: 'runtime', DB_HOST: '10.0.0.2', DB_NAME: 'db' },
      exit: value => { exitCode = value; } },
    fetch: async (url, options) => {
      requests.push({ url, options });
      return { ok: !denied, json: async () => url.includes('secretmanager')
        ? { payload: { data: Buffer.from(JSON.stringify(payload)).toString('base64') } }
        : { access_token: 'short-lived-token' } };
    }
  });
  return { output, errors, requests, exitCode };
}

test('credential JSON uses metadata ADC and preserves special characters', async () => {
  const result = await credentials({ DB_USER: 'schema', DB_PASSWORD: 'spaces $and "quotes"' });
  assert.equal(result.exitCode, 0);
  assert.match(result.output[0], /DB_PASSWORD=spaces \$and "quotes"\nDB_HOST=10.0.0.2/);
  assert.equal(result.requests[0].options.headers['Metadata-Flavor'], 'Google');
  assert.equal(result.requests[1].options.headers.Authorization, 'Bearer short-lived-token');
  assert.match(result.requests[1].url, /projects\/example-project\/secrets\/runtime\/versions\/latest:access$/);
});

test('invalid credentials and denied access fail closed without leaking payloads', async () => {
  for (const payload of [null, {}, { DB_USER: '', DB_PASSWORD: 'private' },
    { DB_USER: 'schema', DB_PASSWORD: 42 }, { DB_USER: 'schema', DB_PASSWORD: 'private\nADMIN=true' },
    { DB_USER: 'schema', DB_PASSWORD: 'private\r' }, { DB_USER: 'schema', DB_PASSWORD: 'private\0' }]) {
    const result = await credentials(payload);
    assert.equal(result.exitCode, 1);
    assert.deepEqual(result.output, []);
    assert.deepEqual(result.errors, ['Schema credential initialization failed']);
  }
  const denied = await credentials({ DB_USER: 'schema', DB_PASSWORD: 'private' }, true);
  assert.equal(denied.exitCode, 1);
  assert.deepEqual(denied.output, []);
});