// SPDX-License-Identifier: AGPL-3.0-only
// Validate a manifest's native shaders with the pinned toolchain: every
// "vulkan" visual through glslangValidator, every "msl" visual through
// SPIR-V -> MSL and `xcrun metal`, every "hlsl" visual through SPIR-V -> HLSL
// SM 5.0 with its ABI and cbuffer packing checked and glslang's HLSL front end
// compiling the result, then through FXC (ps_5_0) or DXC (ps_6_0) when one is
// configured (OSCILLUX_FXC / OSCILLUX_DXC, or on PATH). Without one, HLSL
// compiler validation is reported SKIPPED, never PASS, and fails under CI.
// The manifest's transitions go through the same checks under their entry ids
// (transitionEntryId), against the same binding ABI. The host switch-transition pass
// (tools/shader/switch.mjs) and the photo slideshow pass (tools/shader/slideshow.mjs) go through
// GLSL 450, MSL and the Metal compiler on every run.
// With --hlsl-goldens DIR, each emitted HLSL must equal DIR/<id>.hlsl byte for
// byte, which needs the pinned SPIRV-Cross that assertShaderToolchain checks.
//
//   node tools/shader/verify.mjs <manifest.json> [--hlsl-goldens DIR]
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  assertShaderToolchain, compileHLSLWithGlslang, hlslValidator, mslEntryPoint, validateGLSL450,
  validateHLSL, withTempDir,
} from './glsl2msl.mjs';
import { loadManifest, transitionEntryId } from './manifest.mjs';
import { slideshowMSL } from './slideshow.mjs';
import { switchMSL } from './switch.mjs';

const { values: { 'hlsl-goldens': hlslGoldens }, positionals } = parseArgs({
  allowPositionals: true,
  options: { 'hlsl-goldens': { type: 'string' } },
});
if (positionals.length !== 1) {
  console.error('usage: verify.mjs <manifest.json> [--hlsl-goldens DIR]');
  process.exit(64);
}
if (hlslGoldens === '') {
  console.error('verify.mjs: --hlsl-goldens needs a directory');
  process.exit(64);
}
const manifest = loadManifest(positionals[0]);
const CACHE = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'out', 'cache', 'metal-module-cache');

assertShaderToolchain();
mkdirSync(CACHE, { recursive: true });

let glsl = 0, metal = 0, hlsl = 0;
for (const v of manifest.byTarget.vulkan) {
  validateGLSL450(manifest.wrapper.wrapGLSL450(v.body, v.imageInput), v.id);
  glsl++;
}
for (const v of manifest.byTarget.msl) {
  compileMetal(manifest.wrapper.wrapMSL(v.id, v.body, v.header, v.imageInput), v.id);
  metal++;
}

const validator = hlslValidator();
for (const v of manifest.byTarget.hlsl) {
  const src = manifest.wrapper.wrapHLSL(v.id, v.body, v.header, v.imageInput);
  compileHLSLWithGlslang(src, mslEntryPoint(v.id));
  if (validator) validateHLSL(src, mslEntryPoint(v.id), validator);
  if (hlslGoldens !== undefined && src !== readFileSync(join(hlslGoldens, `${v.id}.hlsl`), 'utf8')) {
    throw new Error(`${v.id}.hlsl differs from its golden in ${hlslGoldens}; ` +
      `regenerate with emit.mjs --hlsl --out ${hlslGoldens} and review the diff`);
  }
  hlsl++;
}
// Transitions are checked like visuals, under their entry-point ids.
for (const t of manifest.transitions) {
  const id = transitionEntryId(t.id);
  if (t.targets.includes('vulkan')) { validateGLSL450(manifest.wrapper.wrapGLSL450(t.body, false, true), id); glsl++; }
  if (t.targets.includes('msl')) { compileMetal(manifest.wrapper.wrapMSL(id, t.body, t.header, false, true), id); metal++; }
  if (t.targets.includes('hlsl')) {
    const src = manifest.wrapper.wrapHLSL(id, t.body, t.header, false, true);
    compileHLSLWithGlslang(src, mslEntryPoint(id));
    if (validator) validateHLSL(src, mslEntryPoint(id), validator);
    hlsl++;
  }
}
// The host switch-transition pass (shaders/switch/switch.glsl) in both samplings: GLSL 450 to
// SPIR-V, MSL with its ABI checked, then the Metal compiler.
for (const sampling of ['linear', 'fetch']) {
  compileMetal(switchMSL({ sampling }), `switch-${sampling}`);
  glsl++; metal++;
}
// The photo slideshow pass (shaders/slideshow/slideshow.glsl), likewise in both samplings.
for (const sampling of ['linear', 'fetch']) {
  compileMetal(slideshowMSL({ sampling }), `slideshow-${sampling}`);
  glsl++; metal++;
}

console.log(`validated: ${glsl} GLSL450/Vulkan shaders, ${metal} MSL shaders, ` +
  `${hlsl} HLSL shaders (ABI, cbuffer packing, glslang HLSL front end` +
  `${hlslGoldens !== undefined && hlsl ? `, byte-equal to ${hlslGoldens}` : ''})`);
if (hlsl) {
  if (validator) {
    console.log(`HLSL compiler validation: PASS (${hlsl} with ${validator.kind} ${validator.path})`);
  } else {
    console.log('HLSL compiler validation: SKIPPED (no FXC or DXC: set OSCILLUX_FXC or OSCILLUX_DXC, ' +
      'or put fxc or dxc on PATH)');
    if (process.env.CI) {
      console.error('HLSL compiler validation is required under CI');
      process.exit(1);
    }
  }
}

function compileMetal(src, id) {
  withTempDir(`metal-${id}`, dir => {
    const metal = join(dir, `${id}.metal`);
    writeFileSync(metal, src);
    try {
      execFileSync('xcrun', [
        'metal',
        `-fmodules-cache-path=${CACHE}`,
        '-c', metal,
        '-o', join(dir, `${id}.air`),
      ], { stdio: 'pipe' });
    } catch (e) {
      process.stderr.write((e.stderr || e.stdout || e.message).toString());
      throw e;
    }
  });
}
