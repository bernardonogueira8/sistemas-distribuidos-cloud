require('dotenv').config();
const mysql = require('mysql2/promise');
const fs = require('node:fs/promises');
const path = require('node:path');

function schemaFailureReason(error) {
  const reasons = {
    ER_ACCESS_DENIED_ERROR: 'database-authentication',
    ER_DBACCESS_DENIED_ERROR: 'database-permission',
    ER_TABLEACCESS_DENIED_ERROR: 'database-permission',
    ER_SPECIFIC_ACCESS_DENIED_ERROR: 'database-permission',
    ER_PARSE_ERROR: 'schema-syntax',
    ECONNREFUSED: 'connection-refused',
    ECONNRESET: 'connection-reset',
    ETIMEDOUT: 'connection-timeout',
    ENOTFOUND: 'proxy-dns',
    EAI_AGAIN: 'proxy-dns',
  };
  return Object.hasOwn(reasons, error?.code) ? reasons[error.code] : 'unclassified';
}

async function applySchema(environment = process.env, createConnection = mysql.createConnection) {
  for (const name of ['DB_HOST', 'DB_USER', 'DB_PASSWORD']) {
    if (!environment[name]) throw new Error(`Missing required environment variable: ${name}`);
  }

  const sql = await fs.readFile(path.join(__dirname, 'schema.sql'), 'utf8');
  const connection = await createConnection({
    host: environment.DB_HOST,
    user: environment.DB_USER,
    password: environment.DB_PASSWORD,
    port: environment.DB_PORT || 3306,
    multipleStatements: true,
  });

  try {
    await connection.query(sql);
  } finally {
    await connection.end();
  }
}

if (require.main === module) {
  applySchema().then(() => {
    console.log('Database schema applied');
  }).catch((error) => {
    console.error(`Schema failure reason: ${schemaFailureReason(error)}.`);
    process.exitCode = 1;
  });
}

module.exports = { applySchema, schemaFailureReason };