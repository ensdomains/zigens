// Surface #1: schema + language + introspection conformance, against the graphql-js
// reference implementation. No running server needed.
//   - Parse schema.graphql with graphql-js's canonical parser/validator.
//   - Diff the server's generated introspection.json against introspectionFromSchema().
// Usage: node schemacheck.mjs [schema.graphql] [introspection.json]
import { buildSchema, introspectionFromSchema } from 'graphql';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const schemaPath = process.argv[2] || resolve(root, 'schema.graphql');
const introspectionPath = process.argv[3] || resolve(root, 'src/api/introspection.json');

let schema;
try {
  schema = buildSchema(readFileSync(schemaPath, 'utf8'));
  console.log('SCHEMA: builds under the graphql-js reference parser/validator  OK');
} catch (e) {
  console.log('SCHEMA: INVALID SDL  FAIL -- ' + String(e).split('\n')[0]);
  process.exit(1);
}

const canonical = introspectionFromSchema(schema).__schema;
const server = JSON.parse(readFileSync(introspectionPath, 'utf8')).data.__schema;

const idx = (arr) => Object.fromEntries((arr || []).map((t) => [t.name, t]));
const cT = idx(canonical.types), sT = idx(server.types);
const fnames = (t) => new Set((t.fields || t.inputFields || t.enumValues || []).map((x) => x.name));

const missingTypes = [], missingFields = [], extraFields = [];
for (const name of Object.keys(cT)) {
  if (name.startsWith('__')) continue;
  if (!sT[name]) { missingTypes.push(name); continue; }
  const cf = fnames(cT[name]), sf = fnames(sT[name]);
  for (const f of cf) if (!sf.has(f)) missingFields.push(name + '.' + f);
  for (const f of sf) if (!cf.has(f)) extraFields.push(name + '.' + f);
}
const real = (arr) => arr.filter((n) => !n.startsWith('__'));
console.log('TYPES: canonical=' + real(Object.keys(cT)).length + ' server=' + real(Object.keys(sT)).length);
console.log('  types in schema but missing from server introspection: ' + missingTypes.length + (missingTypes.length ? ' -> ' + missingTypes.slice(0, 15).join(', ') : ''));
console.log('  fields in schema but absent from server introspection: ' + missingFields.length + (missingFields.length ? ' -> ' + missingFields.slice(0, 20).join(', ') : ''));
console.log('  fields in server introspection but not in schema:      ' + extraFields.length + (extraFields.length ? ' -> ' + extraFields.slice(0, 20).join(', ') : ''));

const fail = missingTypes.length + missingFields.length + extraFields.length;
process.exit(fail ? 1 : 0);
