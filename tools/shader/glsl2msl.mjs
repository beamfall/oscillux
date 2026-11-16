// SPDX-License-Identifier: AGPL-3.0-only
// GLSL 450 -> SPIR-V (glslangValidator) -> MSL or HLSL SM 5.0 (SPIRV-Cross), with
// an ABI check on the reflected bindings and the emitted entry point, and for
// HLSL on the cbuffer packing against the uniform schema.
import { execFileSync } from 'node:child_process';
import { accessSync, constants, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import { layout, loadSchema } from './uniforms.mjs';

export const PINNED_GLSLANG = '16.6.0';
export const PINNED_SPIRV_CROSS_STAMP = '2026-07-06T12:43:32';

const FRAG = 'shader.frag';
const SPV = 'shader.spv';

const TOOLCHAIN_FIX = 'Fix: put the pinned build first on PATH. Under make, set SHADER_TOOLS to its bin '
  + 'directory (or OSCILLUX_BUILD_DIR to the directory holding .tools/); to install the pinned '
  + 'toolchain, run node tools/shader/provision.mjs.';

export function assertShaderToolchain() {
  const versions = shaderToolchainVersions();
  if (!versions.glslang.includes(`Glslang Version: 11:${PINNED_GLSLANG}`)) {
    throw new Error(`glslangValidator version mismatch; expected ${PINNED_GLSLANG}\n${TOOLCHAIN_FIX}\n${versions.glslang}`);
  }
  if (!versions.spirvCross.includes(`Timestamp: ${PINNED_SPIRV_CROSS_STAMP}`)) {
    throw new Error(`spirv-cross version mismatch; expected ${PINNED_SPIRV_CROSS_STAMP}\n${TOOLCHAIN_FIX}\n${versions.spirvCross}`);
  }
  return versions;
}

export function shaderToolchainVersions() {
  return {
    glslang: run('glslangValidator', ['--version']),
    spirvCross: runAllowFail('spirv-cross', ['--version']),
  };
}

export function validateGLSL450(src, label = 'shader') {
  withTempDir(label, dir => compileGLSLToSPV(src, dir));
}

export function glslToMsl(src, id, headerComment = '') {
  return withTempDir(id, dir => {
    const spv = compileGLSLToSPV(src, dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const entry = mslEntryPoint(id);
    const msl = run('spirv-cross', [
      spv,
      '--msl',
      '--msl-decoration-binding',
      '--msl-force-native-arrays',
      '--rename-entry-point', 'main', entry, 'frag',
    ]);
    checkMetalABI(msl, reflection, entry);
    return `${headerComment}
// GENERATED from glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP}.
// Author GLSL in visuals/*.glsl; do not hand-edit generated Metal.

${msl}`;
  });
}

export const mslEntryPoint = id => `frag_${id.replace(/-/g, '_')}`;

export function compileGLSLToSPV(src, dir) {
  const frag = join(dir, FRAG);
  const spv = join(dir, SPV);
  writeFileSync(frag, src);
  run('glslangValidator', [
    '-V',
    '--target-env', 'vulkan1.0',
    '-S', 'frag',
    '-e', 'main',
    '-o', spv,
    frag,
  ]);
  return spv;
}

// SPIRV-Cross numbers each resource class from its own binding: buffer/cbuffer 0,
// textures 0 and 1, sampler 0, in MSL and in HLSL.
function checkReflection(reflection) {
  const need = [
    [reflection.ubos, 'VisualUniformBlock', 0],
    [reflection.separate_images, 'uImageTex', 0],
    [reflection.separate_images, 'uPrevTex', 1],
    [reflection.separate_samplers, 'uSamp', 0],
  ];
  for (const [list, name, binding] of need) {
    const found = (list || []).find(r => r.name === name);
    if (!found || found.binding !== binding) {
      throw new Error(`SPIR-V reflection mismatch for ${name}: expected binding ${binding}`);
    }
  }
}

function checkMetalABI(msl, reflection, entry) {
  checkReflection(reflection);
  const signature = new RegExp(
    `fragment\\s+\\w+\\s+${entry}\\([\\s\\S]*\\[\\[buffer\\(0\\)\\]\\][\\s\\S]*` +
    `\\[\\[texture\\(0\\)\\]\\][\\s\\S]*\\[\\[texture\\(1\\)\\]\\][\\s\\S]*\\[\\[sampler\\(0\\)\\]\\]`
  );
  if (!signature.test(msl)) throw new Error(`MSL ABI mismatch for ${entry}`);
}

export function glslToHlsl(src, id, headerComment = '') {
  return withTempDir(id, dir => {
    const spv = compileGLSLToSPV(src, dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const entry = mslEntryPoint(id);
    const hlsl = run('spirv-cross', [
      spv,
      '--hlsl',
      '--shader-model', '50',
      '--rename-entry-point', 'main', entry, 'frag',
    ]);
    checkReflection(reflection);
    checkHlslABI(hlsl, entry);
    return `${headerComment}
// GENERATED from glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP} (HLSL SM 5.0).
// Author GLSL in visuals/*.glsl; do not hand-edit generated HLSL.

${hlsl}`;
  });
}

// Registers b0/t0/t1/s0, the entry point and its stage IO, and one cbuffer member
// per schema member with its HLSL type, array length and a packoffset equal to its
// std140 offset (register = offset / 16, component = offset % 16 / 4), so a D3D11
// host can upload the block the Packer writes.
const HLSL_TYPES = { float: 'float', vec2: 'float2', vec4: 'float4' };

export function checkHlslABI(hlsl, entry) {
  const need = [
    /cbuffer VisualUniformBlock : register\(b0\)/,
    /Texture2D<float4> uImageTex : register\(t0\);/,
    /Texture2D<float4> uPrevTex : register\(t1\);/,
    /SamplerState uSamp : register\(s0\);/,
    new RegExp(`\\bSPIRV_Cross_Output ${entry}\\(SPIRV_Cross_Input stage_input\\)`),
    /float2 vUV : TEXCOORD0;/,
    /float4 outColor : SV_Target0;/,
  ];
  for (const re of need) if (!re.test(hlsl)) throw new Error(`HLSL ABI mismatch for ${entry}: no ${re.source}`);
  const start = hlsl.indexOf('cbuffer VisualUniformBlock');
  const block = hlsl.slice(start, hlsl.indexOf('};', start));
  const packed = [...block.matchAll(/\b(\w+) ub_(\w+)(\[\d+\])? : packoffset\(c(\d+)(?:\.([yzw]))?\);/g)]
    .map(([, type, name, count, reg, comp]) =>
      `${type} ${name}${count ?? ''}@${16 * Number(reg) + 4 * ' yzw'.indexOf(comp ?? ' ')}`);
  const want = layout(loadSchema()).members
    .map(m => `${HLSL_TYPES[m.type]} ${m.name}${m.count ? `[${m.count}]` : ''}@${m.offset}`);
  if (packed.join(', ') !== want.join(', ')) {
    throw new Error(`HLSL cbuffer packing mismatch for ${entry}:\n  got  ${packed.join(', ')}\n  want ${want.join(', ')}`);
  }
}

// glslang's HLSL front end compiles the generated HLSL back to SPIR-V. It catches
// syntax and type errors in SPIRV-Cross output but is not a D3D compiler, so it
// does not replace FXC or DXC validation.
export function compileHLSLWithGlslang(hlsl, entry) {
  withTempDir(`hlsl-glslang-${entry}`, dir => {
    const src = join(dir, 'shader.hlsl');
    writeFileSync(src, hlsl);
    run('glslangValidator', [
      '-D', '-V', '--target-env', 'vulkan1.0', '-S', 'frag', '-e', entry, '-o', join(dir, SPV), src,
    ]);
  });
}

// An HLSL validator from the environment: OSCILLUX_FXC or OSCILLUX_DXC (a path),
// else fxc, fxc.exe or dxc on PATH. FXC compiles the SM 5.0 profile ps_5_0; DXC
// has no profile below SM 6.0, so it validates the same source as ps_6_0.
// Returns null when none is configured.
export function hlslValidator(env = process.env) {
  if (env.OSCILLUX_FXC) return { kind: 'fxc', path: env.OSCILLUX_FXC };
  if (env.OSCILLUX_DXC) return { kind: 'dxc', path: env.OSCILLUX_DXC };
  for (const [kind, name] of [['fxc', 'fxc'], ['fxc', 'fxc.exe'], ['dxc', 'dxc'], ['dxc', 'dxc.exe']]) {
    for (const dir of (env.PATH || '').split(delimiter).filter(Boolean)) {
      const path = join(dir, name);
      try { accessSync(path, constants.X_OK); return { kind, path }; } catch { /* next */ }
    }
  }
  return null;
}

export function validateHLSL(hlsl, entry, validator) {
  withTempDir(`hlsl-${entry}`, dir => {
    const src = join(dir, 'shader.hlsl');
    const out = join(dir, 'shader.bin');
    writeFileSync(src, hlsl);
    const args = validator.kind === 'fxc'
      ? ['/nologo', '/T', 'ps_5_0', '/E', entry, '/Fo', out, src]
      : ['-T', 'ps_6_0', '-E', entry, '-HV', '2018', '-Fo', out, src];
    try {
      execFileSync(validator.path, args, { stdio: 'pipe' });
    } catch (e) {
      throw new Error(`${validator.kind} rejected ${entry}:\n${(e.stderr || e.stdout || e.message).toString()}`);
    }
  });
}

export function withTempDir(label, fn) {
  const dir = mkdtempSync(join(tmpdir(), `oscillux-${label}-`));
  try { return fn(dir); }
  finally { rmSync(dir, { recursive: true, force: true }); }
}

export function run(cmd, args) {
  return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function runAllowFail(cmd, args) {
  try { return run(cmd, args); }
  catch (e) { return (e.stdout || '') + (e.stderr || ''); }
}
