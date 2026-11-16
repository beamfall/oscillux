// SPDX-License-Identifier: AGPL-3.0-only
// Install the pinned glslang + SPIRV-Cross from source via a pinned homebrew/core.
// This mutates the global Homebrew install: meant for disposable CI hosts.
//
//   node tools/shader/provision.mjs [--reset-core] [--check-only]
//   node tools/shader/provision.mjs --assert-trust-boundary [checkout-dir ...]
//
// --assert-trust-boundary checks the environment and the Git config of
// $GITHUB_WORKSPACE plus each extra checkout dir for credentials. Extra dirs are
// relative paths inside $GITHUB_WORKSPACE and must be Git checkouts.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertShaderToolchain } from './glsl2msl.mjs';

const CORE_REVISION = '44018c0fb8f91e44a93581ddeeb91546871fedd5';
const FORMULAE = [
  {
    name: 'spirv-headers',
    version: '1.4.357.0',
    sourceSha256: '4d703067a7e06331ccb37bdfed3f9b7879cc61969a2689ae95c95db34a47ff07',
    formulaSha256: '4688d92e89b93dea4a9998ed1a590fcf771b363d4b1cd969d6bddb9177cdca47',
  },
  {
    name: 'spirv-tools',
    version: '1.4.357.0',
    sourceSha256: 'd31e7109b6ef3559067e53e520870eafed7c9534d00db9728814b6df03fa4a5e',
    formulaSha256: '7f51413cdd48c7504ddaa341ef03b23d00210f326aa4d01d1f9b888aa50459d0',
  },
  {
    name: 'glslang',
    version: '16.6.0',
    sourceSha256: '9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2',
    formulaSha256: 'c60ef015494366d8e9a552e1aa017d0fd89b29253b4e07d8f5c7974b1f78a649',
  },
  {
    name: 'spirv-cross',
    version: '1.4.357.0',
    sourceSha256: '97c910326afdd44d794ce8561326fa675fd1958b27142f03295403044d639639',
    formulaSha256: 'e57dce80f56e8b66e23578483defc250566f97148f5421178758aa30a9ed9147',
  },
];

const argv = process.argv.slice(2);
const args = new Set(argv);

const SAFE_CHILD_ENV_NAMES = new Set([
  'PATH',
  'HOME',
  'TMPDIR',
  'LANG',
  'LANGUAGE',
  'LC_ALL',
  'LC_CTYPE',
  '__CF_USER_TEXT_ENCODING',
  'HOMEBREW_ARCH',
  'HOMEBREW_NO_AUTO_UPDATE',
  'HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK',
]);
const SAFE_ASSERTION_ENV_NAMES = new Set([
  ...SAFE_CHILD_ENV_NAMES,
  'GITHUB_WORKSPACE',
]);
const FIXED_GIT_ENV = {
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_TERMINAL_PROMPT: '0',
};
for (const name of Object.keys(FIXED_GIT_ENV)) SAFE_ASSERTION_ENV_NAMES.add(name);
const CREDENTIAL_CONFIG = /authorization:|credential\.helper|x-access-token|oauth2:|bearer /i;

if (isMain()) {
  if (args.has('--assert-trust-boundary')) {
    assertTrustBoundary(process.env, argv.filter(a => !a.startsWith('--')));
  } else {
    provision();
  }
}

function provision() {
  sanitizeProcessEnvironment();
  if (args.has('--reset-core')) resetHomebrewCore();
  assertFormulaMetadata();
  if (!args.has('--check-only')) {
    run('brew', ['install', '--build-from-source', ...FORMULAE.map(f => f.name)], installEnv());
  }
  assertShaderToolchain();
}

function sanitizeProcessEnvironment() {
  const clean = sanitizedChildEnvironment(process.env);
  for (const name of Object.keys(process.env)) {
    if (!(name in clean)) delete process.env[name];
  }
  Object.assign(process.env, clean);
}

export function assertTrustBoundary(env = process.env, checkouts = []) {
  const workspace = env.GITHUB_WORKSPACE;
  if (!workspace) throw new Error('GITHUB_WORKSPACE is required for the CI trust-boundary assertion');
  for (const name of Object.keys(env)) {
    if (!SAFE_ASSERTION_ENV_NAMES.has(name)) {
      throw new Error(`${name} is not allowed across the repository trust boundary`);
    }
  }
  for (const [name, expected] of Object.entries(FIXED_GIT_ENV)) {
    if (name in env && env[name] !== expected) {
      throw new Error(`${name} must equal ${expected} across the repository trust boundary`);
    }
  }
  for (const dir of checkouts) {
    const rel = relative(workspace, resolve(workspace, dir));
    if (isAbsolute(dir) || rel === '..' || rel.startsWith(`..${sep}`)) {
      throw new Error(`checkout ${dir} must be a relative path inside GITHUB_WORKSPACE`);
    }
    if (!existsSync(join(workspace, rel, '.git/config'))) throw new Error(`checkout ${dir} has no .git/config`);
  }
  for (const dir of ['.', ...checkouts]) assertConfigClean(resolve(workspace, dir, '.git/config'));
}

export function sanitizedChildEnvironment(env) {
  const clean = Object.fromEntries(
    [...SAFE_CHILD_ENV_NAMES]
      .filter(name => env[name] !== undefined)
      .map(name => [name, env[name]]),
  );
  return {
    ...clean,
    ...FIXED_GIT_ENV,
  };
}

function assertConfigClean(config) {
  if (!existsSync(config)) return;
  if (CREDENTIAL_CONFIG.test(readFileSync(config, 'utf8'))) {
    throw new Error(`credential-bearing Git configuration is visible at ${config}`);
  }
}

function isMain() {
  return process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

function resetHomebrewCore() {
  const core = run('brew', ['--repo', 'homebrew/core']).trim();
  run('git', ['-C', core, 'fetch', '--depth=1', 'origin', CORE_REVISION]);
  run('git', ['-C', core, 'checkout', '--detach', CORE_REVISION]);
}

function assertFormulaMetadata() {
  const json = JSON.parse(run('brew', ['info', '--json=v2', ...FORMULAE.map(f => f.name)]));
  const found = new Map(json.formulae.map(f => [f.name, f]));
  for (const expected of FORMULAE) {
    const actual = found.get(expected.name);
    if (!actual) throw new Error(`missing Homebrew formula metadata for ${expected.name}`);
    assertEq(`${expected.name} tap revision`, actual.tap_git_head, CORE_REVISION);
    assertEq(`${expected.name} stable version`, actual.versions?.stable, expected.version);
    assertEq(`${expected.name} source sha256`, actual.urls?.stable?.checksum, expected.sourceSha256);
    assertEq(`${expected.name} formula sha256`, actual.ruby_source_checksum?.sha256, expected.formulaSha256);
  }
}

function assertEq(label, actual, expected) {
  if (actual !== expected) throw new Error(`${label} mismatch: expected ${expected}, got ${actual}`);
}

function run(cmd, argv, env = {}) {
  return execFileSync(cmd, argv, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: sanitizedChildEnvironment({ ...process.env, ...env }),
  });
}

function installEnv() {
  return {
    HOMEBREW_NO_AUTO_UPDATE: '1',
    HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: '1',
  };
}
