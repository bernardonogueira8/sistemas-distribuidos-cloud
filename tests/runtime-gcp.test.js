const test = require('node:test');
const assert = require('node:assert/strict');
const { checkRuntime } = require('../scripts/check-runtime-gcp');

const targets = [
  { region: 'us-central1', mig: 'api', instance_group: 'projects/demo/regions/us-central1/instanceGroups/api' },
  { region: 'europe-west3', mig: 'api-secondary', instance_group: 'projects/demo/regions/europe-west3/instanceGroups/api-secondary' },
];
const deployment = { project_id: 'demo', backend_service: 'api', runtime_regions: targets };
const healthy = targets.map(target => ({
  backend: `https://www.googleapis.com/compute/v1/${target.instance_group}`,
  status: { healthStatus: [{ healthState: 'HEALTHY' }] },
}));

test('health waits for both regional MIGs and verifies both backend groups', async () => {
  const calls = [];
  await checkRuntime(deployment, (command, args, options) => {
    calls.push(args);
    assert.equal(command, 'gcloud');
    assert.equal(options.stdio, 'pipe');
    return JSON.stringify(healthy);
  });
  assert.equal(calls.length, 3);
  assert.ok(calls[0].includes('--region=us-central1'));
  assert.ok(calls[1].includes('--region=europe-west3'));
  assert.ok(calls[2].includes('get-health'));
});

test('an unstable MIG in either region fails before backend checks', async () => {
  for (const failedRegion of ['us-central1', 'europe-west3']) {
    await assert.rejects(checkRuntime(deployment, (command, args) => {
      assert.ok(!args.includes('get-health'));
      if (args.includes(`--region=${failedRegion}`)) throw new Error('MIG unstable');
    }), /MIG unstable/);
  }
});

test('one healthy region never masks an unhealthy or missing regional backend', async () => {
  for (const missing of [0, 1]) {
    let queries = 0;
    let pauses = 0;
    await assert.rejects(checkRuntime(deployment, (command, args) => {
      if (args.includes('get-health')) queries += 1;
      return JSON.stringify(healthy.filter((backend, index) => index !== missing));
    }, async () => { pauses += 1; }), /every runtime region/);
    assert.equal(queries, 30);
    assert.equal(pauses, 29);
  }
});

test('health retries until both regional backends become healthy', async () => {
  let queries = 0;
  await checkRuntime(deployment, (command, args) => {
    if (args.includes('get-health')) queries += 1;
    return JSON.stringify(queries < 2 ? healthy.slice(0, 1) : healthy);
  }, async () => {});
  assert.equal(queries, 2);
});

test('legacy single-region outputs remain readable but new empty contracts fail closed', async () => {
  let waits = 0;
  await checkRuntime({ project_id: 'demo', ...targets[0] }, () => { waits += 1; });
  assert.equal(waits, 1);
  for (const invalid of [
    { ...deployment, runtime_regions: [] },
    { ...deployment, runtime_regions: [targets[0], targets[0]] },
    { ...deployment, backend_service: null },
    { ...deployment, runtime_regions: [{ region: 'us-central1' }] },
  ]) await assert.rejects(checkRuntime(invalid, () => assert.fail('must not call gcloud')), /Invalid runtime/);
});