const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const vm = require('node:vm');
const path = require('node:path');

const template = readFileSync(path.join(__dirname, 'startup.sh.tftpl'), 'utf8');
const script = template.split('--input-type=module -e \'\n')[1].split("\n  ' >")[0];

async function credentials(payload, fail = false) {
  const output = [];
  const errors = [];
  const requests = [];
  let exitCode = 0;
  await vm.runInNewContext(`(async () => {${script}})()`, {
    Buffer, AbortSignal,
    console: { log: value => output.push(value), error: value => errors.push(value) },
    process: { exit: value => { exitCode = value; } },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (fail) return { ok: false, status: 403 };
      return {
        ok: true,
        json: async () => url.includes('secretmanager')
          ? { payload: { data: Buffer.from(JSON.stringify(payload)).toString('base64') } }
          : { access_token: 'test-token' },
        text: async () => '123456789'
      };
    }
  });
  return { output, errors, requests, exitCode };
}

test('startup is valid bash and keeps credentials out of metadata inputs', () => {
  const result = spawnSync('/bin/bash', ['-n'], { input: template, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(template, /chmod 600/);
  assert.match(template, /--password-stdin/);
  assert.match(template, /--restart always/);
  assert.doesNotMatch(template, /set -x|konlet|gce-container-declaration/);
});

test('credential bootstrap validates JSON and uses short-lived metadata ADC', async () => {
  const result = await credentials({ DB_USER: 'api_user', DB_PASSWORD: 'spaces and $quotes\" allowed' });
  assert.equal(result.exitCode, 0);
  assert.equal(result.output[0], 'DB_USER=api_user\nDB_PASSWORD=spaces and $quotes" allowed\nINSTANCE_ID=123456789');
  assert.equal(result.requests[0].options.headers['Metadata-Flavor'], 'Google');
  assert.equal(result.requests[1].options.headers.Authorization, 'Bearer test-token');
});

test('host firewall admits only GFE health traffic and is idempotent on startup', () => {
  const firewall = template.slice(template.indexOf('for source_range in '), template.indexOf('docker run -d --name cloud-api'));
  assert.match(firewall, /35\.191\.0\.0\/16 130\.211\.0\.0\/22/);
  assert.doesNotMatch(firewall, /0\.0\.0\.0\/0|--dport (?!3000)/);
  const mock = String.raw`
    inserted=""
    iptables() {
      if [[ "$2" == -C ]]; then
        [[ "$inserted" == *"$7"* ]]
      elif [[ "$2" == -I ]]; then
        [[ "$*" == "-w -I INPUT 1 -p tcp -s $8 --dport 3000 -j ACCEPT" ]] || return 9
        inserted="$inserted $8"
        printf 'INSERT %s\n' "$8"
      else return 8; fi
    }
  `;
  const result = spawnSync('/bin/bash', ['-eu', '-c', `${mock}${firewall}\n${firewall}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'INSERT 35.191.0.0/16\nINSERT 130.211.0.0/22\n');
});

test('invalid credentials cannot inject Docker environment entries or leak in logs', async () => {
  for (const payload of [{ DB_USER: 'api', DB_PASSWORD: 'secret\nADMIN=true' }, { DB_USER: '', DB_PASSWORD: 'secret' }, { DB_USER: 'api', DB_PASSWORD: 123 }, { DB_USER: 'api', DB_PASSWORD: 'secret\u0000' }]) {
    const result = await credentials(payload);
    assert.equal(result.exitCode, 1);
    assert.deepEqual(result.output, []);
    assert.deepEqual(result.errors, ['Runtime credential initialization failed']);
  }
});

test('denied secret access fails closed without dumping HTTP payloads', async () => {
  const result = await credentials({}, true);
  assert.equal(result.exitCode, 1);
  assert.deepEqual(result.output, []);
});