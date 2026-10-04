// Bundles an OpenAPI spec that uses EXTERNAL $refs (our specs point to contracts/common/common.yaml)
// into ONE self-contained JSON document. Needed because ng-openapi-gen 1.1.0 does not resolve
// external $refs ("Couldn't resolve reference ../../common/common.yaml#/..."), see README Phase 6.
//
//   node scripts/bundle-spec.mjs <input.yaml> <output.json>
//
// Referenced components (schemas, responses, ...) are copied into the spec's own `components`
// under the same name, and the $ref is rewritten to the internal form (#/components/<section>/<name>).
// A name that already exists with a different definition is an error, never silently overwritten.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

const require = createRequire(import.meta.url);
const yaml = require('js-yaml'); // already installed as a dependency of ng-openapi-gen: no extra package

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('usage: node scripts/bundle-spec.mjs <input.yaml> <output.json>');
  process.exit(2);
}

const docs = new Map();
const load = (file) => {
  if (!docs.has(file)) docs.set(file, yaml.load(readFileSync(file, 'utf8')));
  return docs.get(file);
};

const rootFile = resolve(input);
const root = load(rootFile);
root.components ??= {};
let imported = 0;

/** Copies components/<section>/<name> from `file` into the root document (recursively). */
function importComponent(file, section, name) {
  const source = load(file).components?.[section]?.[name];
  if (source === undefined) throw new Error(`Missing ${section}/${name} in ${file}`);
  root.components[section] ??= {};
  const existing = root.components[section][name];
  const copy = rewrite(structuredClone(source), file);
  if (existing !== undefined) {
    if (!isDeepStrictEqual(existing, copy)) throw new Error(`Name clash: components/${section}/${name}`);
    return;
  }
  root.components[section][name] = copy;
  imported++;
}

/** Rewrites every $ref in `node`, which belongs to `file`, to an internal #/components ref. */
function rewrite(node, file) {
  if (Array.isArray(node)) return node.map((n) => rewrite(n, file));
  if (node === null || typeof node !== 'object') return node;
  for (const [key, value] of Object.entries(node)) {
    if (key === '$ref' && typeof value === 'string') {
      const [refFile, pointer = ''] = value.split('#');
      const target = refFile ? resolve(dirname(file), refFile) : file;
      const parts = pointer.split('/').filter(Boolean);
      if (parts[0] !== 'components' || parts.length !== 3) throw new Error(`Unsupported $ref: ${value} in ${file}`);
      if (target !== rootFile) importComponent(target, parts[1], parts[2]);
      node[key] = `#/components/${parts[1]}/${parts[2]}`;
    } else {
      node[key] = rewrite(value, file);
    }
  }
  return node;
}

rewrite(root, rootFile);
mkdirSync(dirname(resolve(output)), { recursive: true });
writeFileSync(output, JSON.stringify(root, null, 2) + '\n');
console.log(`Bundled ${input} -> ${output} (${imported} external component(s) inlined)`);
