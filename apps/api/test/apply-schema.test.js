const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { applySchema, schemaFailureReason } = require('../src/db/apply-schema');

const environment = { DB_HOST: 'mysql', DB_USER: 'schema', DB_PASSWORD: 'disposable' };

test('schema failure reasons expose only allowlisted categories, never error messages', () => {
  assert.equal(schemaFailureReason({ code: 'ER_ACCESS_DENIED_ERROR', message: 'secret' }), 'database-authentication');
  assert.equal(schemaFailureReason({ code: 'ER_DBACCESS_DENIED_ERROR' }), 'database-permission');
  assert.equal(schemaFailureReason({ code: 'ECONNREFUSED' }), 'connection-refused');
  assert.equal(schemaFailureReason({ code: 'ETIMEDOUT' }), 'connection-timeout');
  assert.equal(schemaFailureReason({ code: 'ENOTFOUND' }), 'proxy-dns');
  assert.equal(schemaFailureReason({ code: 'secret', message: 'secret' }), 'unclassified');
  assert.equal(schemaFailureReason({ code: '__proto__' }), 'unclassified');
  assert.equal(schemaFailureReason(null), 'unclassified');
});

test('applySchema validates required environment before connecting', async () => {
  for (const name of Object.keys(environment)) {
    await assert.rejects(applySchema({ ...environment, [name]: '' }, () => assert.fail('must not connect')), {
      message: `Missing required environment variable: ${name}`,
    });
  }
});

test('applySchema executes the unchanged schema and closes the injected connection', async () => {
  const schema = await fs.readFile(path.join(__dirname, '../src/db/schema.sql'), 'utf8');
  let closed = false;
  await applySchema({ ...environment, DB_PORT: '3307' }, async (options) => {
    assert.deepEqual(options, { host: 'mysql', user: 'schema', password: 'disposable', port: '3307', multipleStatements: true });
    return {
      async query(sql) { assert.equal(sql, schema); },
      async end() { closed = true; },
    };
  });
  assert.equal(closed, true);
});

test('applySchema closes the connection after SQL failure', async () => {
  let closed = false;
  await assert.rejects(applySchema(environment, async () => ({
    async query() { throw new Error('DDL denied'); },
    async end() { closed = true; },
  })), /DDL denied/);
  assert.equal(closed, true);
});