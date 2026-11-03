const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const YAML = require('yaml');

const root = path.resolve(__dirname, '..');
function workflow(name) {
  return YAML.parse(fs.readFileSync(path.join(root, '.github/workflows', `${name}.yml`), 'utf8'));
}

test('release supports the first image from provisioned base infrastructure', () => {
  const release = workflow('release');
  assert.ok(Object.hasOwn(release.on, 'workflow_dispatch'));
  const steps = release.jobs.release.steps;
  const deployment = steps.find((step) => step.id === 'deployment');
  assert.doesNotMatch(deployment.run, /\.enable_runtime == true/);
  const guard = deployment.run.split('\n').find((line) => line.trim().startsWith('jq -e '));
  const result = spawnSync('bash', ['-eu', '-o', 'pipefail', '-c', guard], {
    env: { ...process.env, deployment: JSON.stringify({
      enable_runtime: false,
      image_repository: 'us-central1-docker.pkg.dev/demo-project/demo/api',
      registry_host: 'us-central1-docker.pkg.dev',
      db_connection_name: 'demo-project:us-central1:demo-mysql',
      runtime_secret_id: 'demo-runtime',
    }) },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  const invalid = spawnSync('bash', ['-eu', '-o', 'pipefail', '-c', guard], {
    env: { ...process.env, deployment: '{}' }, encoding: 'utf8',
  });
  assert.notEqual(invalid.status, 0);
  const schemaIndex = steps.findIndex((step) => step.run?.includes('bash scripts/apply-schema-gcp.sh'));
  const planIndex = steps.findIndex((step) => step.id !== 'base-plan' && step.run?.includes('terraform -chdir=infra plan'));
  assert.ok(schemaIndex >= 0 && planIndex > schemaIndex);
  assert.match(steps[planIndex].run, /enable_runtime = true/);
  assert.match(steps[planIndex].run, /image =/);
});

function runScript(script, options = {}) {
  return spawnSync('bash', ['-eu', '-o', 'pipefail', '-c', script], {
    encoding: 'utf8', ...options,
    env: { ...process.env, ...options.env },
  });
}

test('release updates infrastructure before publishing, schema and the image rollout', () => {
  const steps = workflow('release').jobs.release.steps;
  const ids = ['base-plan', 'base-apply', 'deployment', 'publisher', 'image'];
  const positions = ids.map((id) => steps.findIndex((step) => step.id === id));
  const schemaIndex = steps.findIndex((step) => step.run?.includes('bash scripts/apply-schema-gcp.sh'));
  const rolloutIndex = steps.findIndex((step) => step.id !== 'base-plan' && step.run?.includes('terraform -chdir=infra plan'));
  assert.ok(positions.every((position, index) => position >= 0 && (index === 0 || position > positions[index - 1])));
  assert.ok(schemaIndex > positions.at(-1) && rolloutIndex > schemaIndex);
  assert.doesNotMatch(steps.find((step) => step.id === 'deployment').run, /schema_service_account/);
});

test('release base plan preserves runtime, supports first deployment and fails closed before publishing', () => {
  const steps = workflow('release').jobs.release.steps;
  const basePlan = steps.find((step) => step.id === 'base-plan');
  const baseApply = steps.find((step) => step.id === 'base-apply');
  const deployment = steps.find((step) => step.id === 'deployment');
  const image = `us-central1-docker.pkg.dev/demo-project/demo/api@sha256:${'a'.repeat(64)}`;
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-base-'));
  try {
    fs.mkdirSync(path.join(temporary, 'infra'));
    fs.mkdirSync(path.join(temporary, 'gcp-deployment'));
    const mock = String.raw`terraform() {
      printf '%s\n' "$2" >> "$TRACE"
      case "$2" in
        output)
          if [[ "$#" -eq 4 && "$4" == deployment ]]; then
            test -f "$RUNNER_TEMP/applied" || return 90
            printf '%s' "$UPDATED"
          else
            if [[ "$FAIL_STAGE" == output ]]; then return 7; fi
            printf '%s' "$CURRENT"
          fi
          ;;
        state)
          if [[ "$FAIL_STAGE" == state ]]; then return 7; fi
          printf '%s' "$RESOURCES"
          ;;
        plan)
          test "$(cat infra/release.auto.tfvars)" = "$(printf 'enable_runtime = %s\nimage = "%s"\n' "$EXPECTED_ENABLED" "$EXPECTED_IMAGE")" || return 91
          test "$5" = "-out=$RUNNER_TEMP/gcp-deployment/base.tfplan" || return 92
          printf 'private base binary' > "$RUNNER_TEMP/gcp-deployment/base.tfplan"
          printf 'sensitive plan diagnostic\n' >&2
          if [[ "$FAIL_STAGE" == plan ]]; then return 8; fi
          ;;
        apply)
          test "$#" -eq 5 || return 93
          test "$5" = "$RUNNER_TEMP/gcp-deployment/base.tfplan" || return 94
          test "$(cat "$5")" = 'private base binary' || return 95
          printf 'sensitive apply diagnostic\n' >&2
          if [[ "$FAIL_STAGE" == apply ]]; then return 9; fi
          touch "$RUNNER_TEMP/applied"
          ;;
        *) return 99 ;;
      esac
    }
`;
    const active = { enable_runtime: true, image };
    const disabled = { enable_runtime: false, image: '' };
    const cases = [
      { current: active, enabled: 'true', image, success: true },
      { current: disabled, enabled: 'false', image: '', success: true },
      { current: null, enabled: 'false', image: '', success: true },
      { current: null, resources: 'module.database.google_sql_database.app' },
      { current: disabled, resources: 'module.compute[0].google_compute_region_instance_group_manager.app' },
      { current: { enable_runtime: true, image: 'invalid' } },
      { current: {}, resources: 'module.database.google_sql_database.app' },
      { current: active, failStage: 'output' },
      { current: null, failStage: 'state' },
      { current: active, enabled: 'true', image, failStage: 'plan' },
      { current: active, enabled: 'true', image, failStage: 'apply' },
    ];
    for (const scenario of cases) {
      const trace = path.join(temporary, 'trace');
      fs.writeFileSync(trace, '');
      fs.rmSync(path.join(temporary, 'applied'), { force: true });
      fs.writeFileSync(path.join(temporary, 'infra/terraform.tfvars'), 'enable_runtime = true\nimage = "invalid-stale-value"\n');
      const result = runScript(`${mock}${basePlan.run}\n${baseApply.run}\n${deployment.run}\nprintf 'READY_TO_PUBLISH'`, {
        cwd: temporary,
        env: {
          RUNNER_TEMP: temporary, TRACE: trace, GITHUB_OUTPUT: path.join(temporary, 'github-output'),
          CURRENT: JSON.stringify(scenario.current === null ? {} : { deployment: { value: scenario.current } }),
          RESOURCES: scenario.resources || '', FAIL_STAGE: scenario.failStage || '',
          EXPECTED_ENABLED: scenario.enabled || '', EXPECTED_IMAGE: scenario.image || '',
          UPDATED: JSON.stringify({
            image_repository: 'us-central1-docker.pkg.dev/demo-project/demo/api',
            registry_host: 'us-central1-docker.pkg.dev',
            db_connection_name: 'demo-project:us-central1:demo-mysql', runtime_secret_id: 'demo-runtime',
          }),
        },
      });
      assert.equal(result.status === 0, Boolean(scenario.success), `${JSON.stringify(scenario)}: ${result.stderr}`);
      assert.doesNotMatch(result.stdout + result.stderr, /sensitive|private base binary/);
      assert.equal(result.stdout.includes('READY_TO_PUBLISH'), Boolean(scenario.success));
      const calls = fs.readFileSync(trace, 'utf8').trim().split('\n');
      if (scenario.success) assert.deepEqual(calls, scenario.enabled === 'true' ? ['output', 'plan', 'apply', 'output'] : ['output', 'state', 'plan', 'apply', 'output']);
      else if (scenario.failStage === 'apply') assert.deepEqual(calls, ['output', 'plan', 'apply']);
      else assert.ok(!calls.includes('apply'));
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

for (const name of ['release', 'infrastructure']) {
  test(`${name} requires main, explicit authorization and the existing prod environment before credentials`, () => {
    const config = workflow(name);
    assert.deepEqual(Object.keys(config.on), ['workflow_dispatch']);
    const inputs = config.on.workflow_dispatch.inputs;
    assert.deepEqual(Object.keys(inputs), ['confirmation']);
    assert.equal(inputs.confirmation.type, 'string');
    assert.equal(inputs.confirmation.required, true);
    assert.match(inputs.confirmation.description, /DEPLOY TO PROD/);
    assert.equal(Object.keys(config.jobs).length, 1);
    const job = Object.values(config.jobs)[0];
    assert.equal(job.if, "github.ref == 'refs/heads/main' && inputs.confirmation == 'DEPLOY TO PROD'");
    assert.equal(job.environment, "${{ vars.GCP_GITHUB_ENVIRONMENT || 'prod' }}");
    assert.equal(config.concurrency.group, 'application-gcp-state');
    assert.equal(config.concurrency['cancel-in-progress'], false);
    assert.equal(job.permissions['id-token'], 'write');
    assert.equal(job.permissions.actions, undefined);
    assert.doesNotMatch(JSON.stringify(job.env), /\$\{\{\s*runner\./);
    for (const step of job.steps.filter((step) => step.uses?.startsWith('google-github-actions/auth@'))) {
      assert.equal(step.with.workload_identity_provider, '${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}');
      assert.equal(step.with.credentials_json, undefined);
    }
    const deployer = job.steps.find((step) => step.id === 'deployer');
    assert.equal(deployer.with.service_account, '${{ vars.GCP_APPLY_SERVICE_ACCOUNT }}');
    assert.equal(deployer.with.cleanup_credentials, true);
  });

  test(`${name} keeps the exact plan and both output streams private in the same runner`, () => {
    const config = workflow(name);
    const steps = Object.values(config.jobs)[0].steps;
    const serialized = JSON.stringify(config);
    assert.doesNotMatch(serialized, /actions\/(?:upload|download)-artifact|plan_run_id|sha256sum|terraform[^\n]* show |PRIVATE_REPOSITORY|repository\.private/);
    const planIndex = steps.findIndex((step) => step.id !== 'base-plan' && /terraform -chdir=infra plan /.test(step.run));
    const applyIndex = steps.findIndex((step) => step.id !== 'base-apply' && /terraform -chdir=infra apply /.test(step.run));
    assert.ok(planIndex >= 0 && applyIndex > planIndex);
    for (const step of steps.slice(planIndex, applyIndex + 1)) assert.equal(step.if, undefined);
    for (const step of steps) assert.notEqual(step['continue-on-error'], true);
    const plan = steps[planIndex].run;
    const apply = steps[applyIndex].run;
    const planPath = plan.match(/-out="([^"]+)"/)[1];
    assert.equal(planPath, '$RUNNER_TEMP/gcp-deployment/deployment.tfplan');
    assert.ok(apply.includes(`"${planPath}"`));
    for (const [command, script] of [['plan', plan], ['apply', apply]]) {
      assert.match(script, new RegExp(`> "\\$RUNNER_TEMP/gcp-deployment/${command}\\.stdout\\.log" 2> "\\$RUNNER_TEMP/gcp-deployment/${command}\\.stderr\\.log"`));
      assert.match(script, /umask 077/);
      assert.doesNotMatch(script, /\b(?:tee|cat|tail|show)\b/);
    }
    const cleanup = steps.at(-1);
    assert.equal(cleanup.if, 'always()');
    assert.match(cleanup.run, /rm -rf -- "\$RUNNER_TEMP\/gcp-deployment" infra\/\.terraform/);
    assert.match(cleanup.run, /rm -f -- infra\/backend\.hcl infra\/terraform\.tfvars infra\/release\.auto\.tfvars/);
    assert.match(cleanup.run, /rm -f -- "\$ORIGINAL_CREDENTIALS"/);
    const health = steps.find((step) => step.name?.startsWith('Wait for the MIG'));
    assert.ok(steps.indexOf(health) > applyIndex);
    assert.match(health.run, /managed wait-until[\s\S]*--stable/);
    assert.match(health.run, /curl --fail[\s\S]*SMOKE_ALLOW_HTTP=true node tests\/smoke\/api\.js/);
    for (const step of steps.filter((step) => step.run)) {
      const syntax = spawnSync('bash', ['-n'], { input: step.run, encoding: 'utf8' });
      assert.equal(syntax.status, 0, `${step.name}: ${syntax.stderr}`);
    }
  });
}

test('release tests before OIDC and isolates build-only tokens from deployer credentials', () => {
  const steps = workflow('release').jobs.release.steps;
  const testIndex = steps.findIndex((step) => step.run?.includes('npm run lint && npm test'));
  const authIndex = steps.findIndex((step) => step.id === 'deployer');
  const isolationIndex = steps.findIndex((step) => step.run?.includes('mv "$GOOGLE_GHA_CREDS_PATH"'));
  const buildIndex = steps.findIndex((step) => step.id === 'image');
  assert.ok(testIndex >= 0 && testIndex < authIndex && authIndex < isolationIndex && isolationIndex < buildIndex);
  assert.match(steps[isolationIndex].run, /destination="\$RUNNER_TEMP\/gcp-deployment\/deployer-credentials\.json"/);
  const publisher = steps.find((step) => step.id === 'publisher');
  assert.equal(publisher.with.service_account, '${{ vars.GCP_BUILD_SERVICE_ACCOUNT || vars.GCP_RELEASE_PLAN_SERVICE_ACCOUNT }}');
  assert.equal(publisher.with.token_format, 'access_token');
  assert.equal(publisher.with.create_credentials_file, false);
  assert.equal(publisher.with.export_environment_variables, false);
  assert.equal(steps[buildIndex].env.ACCESS_TOKEN, '${{ steps.publisher.outputs.access_token }}');
  assert.match(steps[buildIndex].run, /--platform linux\/amd64 --push --provenance=mode=max --sbom=true/);
  assert.match(steps[buildIndex].run, /sha256:\[a-f0-9\]\{64\}/);
  assert.match(steps[0].run, /DOCKER_CONFIG=%s\/docker\\nCLOUDSDK_CONFIG=%s\/gcloud/);
  assert.match(steps[0].run, /"\$RUNNER_TEMP\/gcp-deployment".*>> "\$GITHUB_ENV"/);
});

test('schema and private initialization failures stop execution without printing details', () => {
  const steps = workflow('release').jobs.release.steps;
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-failure-'));
  try {
    const privateDir = path.join(temporary, 'gcp-deployment');
    fs.mkdirSync(privateDir);
    fs.mkdirSync(path.join(temporary, 'infra'));
    const schema = steps.find((step) => step.run?.includes('bash scripts/apply-schema-gcp.sh'));
    const schemaResult = runScript(`bash() { printf 'sensitive schema diagnostic\\n' >&2; return 7; }\n${schema.run}\nprintf 'UNREACHABLE'`, {
      env: { RUNNER_TEMP: temporary, IMAGE: 'unused' },
    });
    assert.notEqual(schemaResult.status, 0);
    assert.doesNotMatch(schemaResult.stdout + schemaResult.stderr, /sensitive|UNREACHABLE/);
    assert.match(schemaResult.stderr, /Schema operation failed/);
    const stagedSchemaFailure = runScript(`bash() { printf 'Schema task failed during schema-apply.\\nsensitive schema diagnostic\\n' >&2; return 7; }\n${schema.run}`, {
      env: { RUNNER_TEMP: temporary, IMAGE: 'unused' },
    });
    assert.notEqual(stagedSchemaFailure.status, 0);
    assert.match(stagedSchemaFailure.stderr, /Schema operation failed\./);
    const stagedProxyFailure = runScript(`bash() { printf 'Schema operation failed during proxy-start.\\nsensitive proxy diagnostic\\n' >&2; return 7; }\n${schema.run}`, {
      env: { RUNNER_TEMP: temporary, IMAGE: 'unused' },
    });
    assert.notEqual(stagedProxyFailure.status, 0);
    assert.match(stagedProxyFailure.stderr, /Schema operation failed during proxy-start/);
    assert.doesNotMatch(stagedProxyFailure.stdout + stagedProxyFailure.stderr, /sensitive|UNREACHABLE/);
    for (const reason of ['proxy-authentication', 'database-permission', 'sensitive-token']) {
      const classified = runScript(`bash() { printf 'Schema failure reason: ${reason}.\nSchema operation failed during schema-apply.\nsensitive diagnostic\n' >&2; return 7; }\n${schema.run}`, {
        env: { RUNNER_TEMP: temporary, IMAGE: 'unused' },
      });
      assert.notEqual(classified.status, 0);
      assert.doesNotMatch(classified.stdout + classified.stderr, /sensitive/);
      if (reason !== 'sensitive-token') assert.ok(classified.stderr.includes(`Schema failure reason: ${reason}.`));
    }
    assert.doesNotMatch(stagedSchemaFailure.stdout + stagedSchemaFailure.stderr, /sensitive|UNREACHABLE/);
    const deployment = steps.find((step) => step.name === 'Initialize the application infrastructure');
    const failedInit = runScript(`terraform() { printf 'sensitive init diagnostic\\n' >&2; return 9; }\n${deployment.run}\nprintf 'UNREACHABLE'`, {
      cwd: temporary, env: { RUNNER_TEMP: temporary, BACKEND_HCL: 'bucket = "test"', TFVARS: 'image = "stale"' },
    });
    assert.notEqual(failedInit.status, 0);
    assert.doesNotMatch(failedInit.stdout + failedInit.stderr, /sensitive|UNREACHABLE/);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('infrastructure overrides stale inputs with the state digest before planning and rejects an unenabled runtime', () => {
  const steps = workflow('infrastructure').jobs.deployment.steps;
  const plan = steps.find((step) => step.run?.includes('terraform -chdir=infra plan'));
  assert.doesNotMatch(plan.run, /terraform[^\n]*(?:console|validate)/);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-state-'));
  const image = `us-central1-docker.pkg.dev/demo-project/demo/api@sha256:${'a'.repeat(64)}`;
  try {
    fs.mkdirSync(path.join(temporary, 'infra'));
    fs.mkdirSync(path.join(temporary, 'gcp-deployment'));
    fs.writeFileSync(path.join(temporary, 'infra/terraform.tfvars'), 'enable_runtime = false\nimage = "invalid-stale-value"\n');
    const mock = String.raw`terraform() {
      if [[ "$2" == output ]]; then printf '%s' "$CURRENT";
      elif [[ "$2" == plan ]]; then
        test "$(cat infra/release.auto.tfvars)" = "$(printf 'enable_runtime = true\nimage = "%s"\n' "$EXPECTED_IMAGE")" || return 98
        printf 'sensitive plan output\n'
        printf 'sensitive plan error\n' >&2
        return "$PLAN_EXIT"
      else return 99; fi
    }
`;
    for (const [enabled, stateImage, planExit, success] of [
      [true, image, '0', true], [false, image, '0', false], [true, 'invalid', '0', false], [true, image, '6', false],
    ]) {
      const result = runScript(`${mock}${plan.run}\nprintf 'PLANNED'`, {
        cwd: temporary,
        env: { RUNNER_TEMP: temporary, CURRENT: JSON.stringify({ enable_runtime: enabled, image: stateImage }), EXPECTED_IMAGE: image, PLAN_EXIT: planExit },
      });
      assert.equal(result.status === 0, success, result.stderr);
      assert.doesNotMatch(result.stdout + result.stderr, /sensitive/);
      if (!enabled) assert.match(result.stderr, /runtime enabled and a digest-pinned image; use Publish And Deploy API/);
      assert.equal(result.stdout.includes('PLANNED'), success);
      if (enabled && stateImage === image) assert.equal(fs.readFileSync(path.join(temporary, 'infra/release.auto.tfvars'), 'utf8'), `enable_runtime = true\nimage = "${image}"\n`);
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

for (const name of ['release', 'infrastructure']) {
  test(`${name} applies only its generated binary, hides failures and removes private files`, () => {
    const steps = Object.values(workflow(name).jobs)[0].steps;
    const plan = steps.find((step) => step.id !== 'base-plan' && step.run?.includes('terraform -chdir=infra plan'));
    const apply = steps.find((step) => step.id !== 'base-apply' && step.run?.includes('terraform -chdir=infra apply'));
    const cleanup = steps.at(-1);
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-plan-'));
    const image = `us-central1-docker.pkg.dev/demo-project/demo/api@sha256:${'b'.repeat(64)}`;
    try {
      fs.mkdirSync(path.join(temporary, 'infra/.terraform'), { recursive: true });
      fs.mkdirSync(path.join(temporary, 'gcp-deployment'));
      for (const filename of ['infra/backend.hcl', 'infra/terraform.tfvars', 'infra/errored.tfstate', 'infra/crash.log', 'infra/crash.123.log', 'gha-creds.json', 'gcp-deployment/deployer-credentials.json']) {
        fs.writeFileSync(path.join(temporary, filename), 'private');
      }
      const mock = String.raw`terraform() {
        case "$2" in
          output) printf '%s' "$CURRENT" ;;
          plan)
            for argument in "$@"; do
              if [[ "$argument" == -out=* ]]; then
                IFS='=' read -r option plan_file <<< "$argument"
                printf 'exact private binary' > "$plan_file"
              fi
            done
            printf 'sensitive plan stdout\n'
            printf 'sensitive plan stderr\n' >&2
            ;;
          apply)
            test "$#" -eq 5 || return 90
            test "$(cat "$5")" = 'exact private binary' || return 91
            printf 'sensitive apply stdout\n'
            printf 'sensitive apply stderr\n' >&2
            return "$APPLY_EXIT"
            ;;
          *) return 99 ;;
        esac
      }
`;
      for (const applyExit of ['0', '8']) {
        const result = runScript(`${mock}${plan.run}\n${apply.run}\nprintf 'APPLIED'`, {
          cwd: temporary,
          env: { RUNNER_TEMP: temporary, IMAGE: image, CURRENT: JSON.stringify({ enable_runtime: true, image }), APPLY_EXIT: applyExit },
        });
        assert.equal(result.status === 0, applyExit === '0', result.stderr);
        assert.equal(result.stdout.includes('APPLIED'), applyExit === '0');
        assert.doesNotMatch(result.stdout + result.stderr, /sensitive|exact private binary/);
        if (applyExit !== '0') assert.match(result.stderr, /Terraform apply failed/);
      }
      const cleaned = runScript(cleanup.run, {
        cwd: temporary, env: { RUNNER_TEMP: temporary, ORIGINAL_CREDENTIALS: path.join(temporary, 'gha-creds.json') },
      });
      assert.equal(cleaned.status, 0, cleaned.stderr);
      assert.deepEqual(fs.readdirSync(temporary), ['infra']);
      assert.deepEqual(fs.readdirSync(path.join(temporary, 'infra')), []);
    } finally {
      fs.rmSync(temporary, { recursive: true, force: true });
    }
  });
}