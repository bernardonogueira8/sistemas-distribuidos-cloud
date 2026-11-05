const { execFileSync } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');

async function checkRuntime(deployment, execute = execFileSync, pause = delay) {
  const targets = deployment.runtime_regions ?? [{
    region: deployment.region, mig: deployment.mig, instance_group: deployment.instance_group,
  }];
  if (!Array.isArray(targets) || targets.length === 0 || !deployment.project_id ||
      targets.some(target => !target.region || !target.mig || !target.instance_group) ||
      new Set(targets.map(target => target.region)).size !== targets.length ||
      (deployment.runtime_regions && !deployment.backend_service)) {
    throw new Error('Invalid runtime health contract');
  }
  for (const target of targets) {
    execute('gcloud', ['compute', 'instance-groups', 'managed', 'wait-until', target.mig, '--stable',
      `--project=${deployment.project_id}`, `--region=${target.region}`, '--timeout=900'], {
      encoding: 'utf8', stdio: 'pipe', timeout: 920000,
    });
  }
  if (!deployment.backend_service) return;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const health = JSON.parse(execute('gcloud', ['compute', 'backend-services', 'get-health',
      deployment.backend_service, '--global', `--project=${deployment.project_id}`, '--format=json'], {
      encoding: 'utf8', stdio: 'pipe', timeout: 60000,
    }));
    const normalize = value => value.replace(/^https:\/\/www.googleapis.com\/compute\/v1\//, '');
    const allHealthy = targets.every(target => health.some(backend =>
      typeof backend.backend === 'string' && normalize(backend.backend) === normalize(target.instance_group) &&
      backend.status?.healthStatus?.some(instance => instance.healthState === 'HEALTHY')));
    if (allHealthy) return;
    if (attempt < 29) await pause(10000);
  }
  throw new Error('No healthy load balancer backend in every runtime region');
}

if (require.main === module) {
  Promise.resolve().then(() => {
    const deployment = JSON.parse(execFileSync('terraform', ['-chdir=infra', 'output', '-json', 'deployment'], {
      encoding: 'utf8', stdio: 'pipe', timeout: 60000,
    }));
    return checkRuntime(deployment);
  }).then(() => console.log('Runtime healthy in every configured region')).catch(() => {
    console.error('Regional runtime health verification failed.');
    process.exitCode = 1;
  });
}

module.exports = { checkRuntime };