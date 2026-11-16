// SPDX-License-Identifier: AGPL-3.0-only
// Exercises a wasm-bindgen package (the npm artifact or a dev build) against the conformance
// vectors: DSP, limiter, region flash analyzer, curves, governor, mapping/packing, and DSP -> mapping -> packing.
// Run from the repository root: node tools/test-wasm-package.mjs <package-directory>
import { existsSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const directory = process.argv[2];
const m = await import(pathToFileURL(directory + '/oscillux.js'));
await m.default({ module_or_path: readFileSync(directory + '/oscillux_bg.wasm') });
const json = path => JSON.parse(readFileSync(path, 'utf8'));
// Views must be re-created after any allocation: a memory growth detaches old buffers.
const f64 = (ptr, n) => new Float64Array(m.wasmMemory().buffer, ptr, n);
const bytes = (ptr, n) => new Uint8Array(m.wasmMemory().buffer, ptr, n);
const dataView = () => new DataView(m.wasmMemory().buffer);

assert.equal(m.abiVersion(), 1);
assert.ok(Number.isInteger(m.version()) && m.version() >= 0 && m.version() < 2 ** 32);
assert.equal(m.statusString(0), 'ok');
assert.equal(m.statusString(-2), 'invalid argument');
assert.equal(m.statusString(42), 'unknown status');

// ---- DSP -------------------------------------------------------------------------------
const dspConfig = new m.DspConfig();
assert.deepEqual([dspConfig.sampleRateHz, dspConfig.fftWindowSamples, dspConfig.hopSamples, dspConfig.spectrumBands], [48000, 2048, 512, 24]);
assert.equal(dspConfig.behaviorVersion, 2);
assert.equal(dspConfig.validate(), undefined);
const badConfig = new m.DspConfig();
badConfig.fftWindowSamples = 3;
assert.equal(badConfig.validate(), 'fft_window_samples');
assert.throws(() => new m.Dsp(badConfig, 1024, 4));
assert.throws(() => m.MappingConfig.fromDsp(badConfig));
badConfig.fftWindowSamples = 2048;
badConfig.behaviorVersion = 5;
assert.equal(badConfig.validate(), 'behavior_version');
assert.throws(() => new m.Dsp(badConfig, 1024, 4));
badConfig.free();
assert.equal(dspConfig.onsetBandGroup(0).length, 2);

const wav = readFileSync('conformance/dsp/sine-440.wav');
let offset = 12, pcm;
while (offset + 8 <= wav.length) {
  const length = wav.readUInt32LE(offset + 4);
  if (wav.toString('ascii', offset, offset + 4) === 'data') { pcm = wav.subarray(offset + 8, offset + 8 + length); break; }
  offset += 8 + length + (length % 2);
}
assert.ok(pcm);
const sampleCount = pcm.length / 2;
// Pushes the sine through a new analyzer and compares its frames with a .frames fixture.
function analyze(config, fixture) {
  const dsp = new m.Dsp(config, sampleCount, 64);
  const samples = new Float32Array(m.wasmMemory().buffer, dsp.inputPtr(), sampleCount);
  for (let i = 0; i < samples.length; i++) samples[i] = pcm.readInt16LE(i * 2) / 32768;
  assert.equal(dsp.beginSegment(0, false), 0);
  assert.equal(dsp.push(sampleCount, 1), 0);
  const expected = readFileSync(fixture, 'utf8').split('\n').filter(x => x.startsWith('frame ')).map(x => x.split(' ').slice(1).map(Number));
  assert.equal(dsp.consumed(), sampleCount);
  assert.equal(dsp.produced(), expected.length);
  const view = dataView();
  for (let i = 0; i < expected.length; i++) {
    const base = dsp.outputPtr() + i * dsp.frameBytes(), row = expected[i];
    assert.equal(view.getBigUint64(base, true), BigInt(row[0]));
    assert.equal(view.getUint32(base + 8, true), row[1]);
    assert.equal(view.getUint32(base + 12, true), 24);
    for (let j = 2; j < row.length; j++) assert.ok(Math.abs(view.getFloat64(base + 16 + (j - 2) * 8, true) - row[j]) <= 1e-5, `${fixture} frame ${i} field ${j}`);
  }
  return { dsp, expected };
}
// behaviorVersion 1 is the ABI-1 analysis; the default is version 2 (conformance/dsp/README.md).
const v1Config = new m.DspConfig();
v1Config.behaviorVersion = 1;
analyze(v1Config, 'conformance/dsp/sine-440.frames').dsp.free();
v1Config.free();
const { dsp, expected } = analyze(dspConfig, 'conformance/dsp/v2/sine-440.frames');
let view;

// pushF64 analyzes a Float64Array input; on Float32-representable samples it matches push bit for bit.
const dsp64 = new m.Dsp(dspConfig, 0, 64, sampleCount);
new Float64Array(m.wasmMemory().buffer, dsp64.inputF64Ptr(), sampleCount).set(new Float32Array(m.wasmMemory().buffer, dsp.inputPtr(), sampleCount));
assert.equal(dsp64.push(1, 1), -2, 'no Float32 input with sampleCapacity 0');
assert.equal(dsp64.pushF64(sampleCount + 1, 1), -2);
assert.equal(dsp64.pushF64(3, 2), -2, 'scalar count not a multiple of channels');
assert.equal(dsp64.beginSegment(0, false), 0);
assert.equal(dsp64.pushF64(sampleCount, 1), 0);
assert.deepEqual([dsp64.consumed(), dsp64.produced()], [sampleCount, expected.length]);
assert.deepEqual(bytes(dsp64.outputPtr(), expected.length * dsp.frameBytes()), bytes(dsp.outputPtr(), expected.length * dsp.frameBytes()), 'pushF64 frames equal push frames');
dsp64.free();

// pushExt and pushExtF64 produce the push frames plus one OscilluxDspFrameExt per frame:
// struct_size and reserved uint32 at 0/4, six descriptor doubles from offset 8, the beat at 56
// and the levels at 104.
const dspExt = new m.Dsp(dspConfig, sampleCount, 64), dspExt64 = new m.Dsp(dspConfig, 0, 64, sampleCount);
assert.equal(dspExt.extBytes(), 672);
assert.equal(dspExt.extPtr(), 0, 'no ext buffer before the first pushExt');
new Float32Array(m.wasmMemory().buffer, dspExt.inputPtr(), sampleCount).set(new Float32Array(m.wasmMemory().buffer, dsp.inputPtr(), sampleCount));
new Float64Array(m.wasmMemory().buffer, dspExt64.inputF64Ptr(), sampleCount).set(new Float32Array(m.wasmMemory().buffer, dsp.inputPtr(), sampleCount));
assert.equal(dspExt.beginSegment(0, false), 0);
assert.equal(dspExt.pushExt(sampleCount, 1), 0);
assert.deepEqual([dspExt.consumed(), dspExt.produced()], [sampleCount, expected.length]);
assert.deepEqual(bytes(dspExt.outputPtr(), expected.length * dsp.frameBytes()), bytes(dsp.outputPtr(), expected.length * dsp.frameBytes()), 'pushExt frames equal push frames');
const descriptors = Array.from(bytes(dspExt.extPtr(), expected.length * dspExt.extBytes()));
view = dataView();
for (let i = 0; i < expected.length; i++) {
  const base = dspExt.extPtr() + i * dspExt.extBytes();
  assert.deepEqual([view.getUint32(base, true), view.getUint32(base + 4, true)], [672, 0]);
  for (let j = 8; j < 56; j += 8) assert.ok(Number.isFinite(view.getFloat64(base + j, true)), `ext ${i} field ${j}`);
  assert.equal(view.getUint32(base + 104, true), 24, `ext ${i} levels band count`);
}
const lastExt = dspExt.extPtr() + (expected.length - 1) * dspExt.extBytes();
const centroidHz = view.getFloat64(lastExt + 40, true), spectralFlux = view.getFloat64(lastExt + 48, true);
assert.ok(Math.abs(centroidHz - 440) <= 0.02 * 440, `sine centroid ${centroidHz}`);
assert.equal(view.getFloat64(dspExt.extPtr() + 48, true), 0, 'no flux on the first frame');
const mapperExtConfig = m.MappingConfig.fromDsp(dspConfig), mapperExt = new m.Mapper(mapperExtConfig);
for (let i = 0; i < expected.length; i++) assert.equal(mapperExt.processExt(dspExt, i, false), 0);
assert.equal(mapperExt.value(m.MappedValue.Flux), Math.min(1, Math.max(0, spectralFlux)));
assert.ok(Math.abs(mapperExt.value(m.MappedValue.Centroid) - Math.min(1, Math.log10(centroidHz / 20) / 3)) <= 1e-12);
assert.equal(mapperExt.processExt(dspExt, expected.length, false), -2);
// The relative level source on the pushExt output: BASS, MID, TREBLE and the spectrum from the
// levels (relative bands from byte 160), every other slot as the absolute source maps it.
const mapperAbs = new m.Mapper(mapperExtConfig), mapperRel = new m.Mapper(mapperExtConfig);
assert.equal(mapperRel.setLevelSource(m.LevelSource.Relative), 0);
assert.equal(mapperRel.process(dsp, 0, false), -2, 'the relative source needs the ext levels');
view = dataView();
for (let i = 0; i < expected.length; i++) {
  assert.equal(mapperAbs.processExt(dspExt, i, false), 0);
  assert.equal(mapperRel.processExt(dspExt, i, false), 0);
  for (const slot of [0, 1, 5, 6, 7, 8]) assert.equal(mapperRel.value(slot), mapperAbs.value(slot), `relative slot ${slot}`);
  for (const slot of [2, 3, 4]) assert.ok(mapperRel.value(slot) >= 0 && mapperRel.value(slot) <= 1);
  const band0 = view.getFloat64(dspExt.extPtr() + i * dspExt.extBytes() + 160, true);
  assert.equal(mapperRel.spectrum(0), Math.fround(Math.min(1, Math.max(0, band0))));
}
mapperAbs.free(); mapperRel.free();
assert.equal(dspExt64.beginSegment(0, false), 0);
assert.equal(dspExt64.pushExtF64(sampleCount, 1), 0);
assert.deepEqual(Array.from(bytes(dspExt64.extPtr(), expected.length * dspExt64.extBytes())), descriptors, 'pushExtF64 ext equals pushExt');
assert.equal(dspExt.push(sampleCount, 1), 0);
assert.equal(mapperExt.processExt(dspExt, 0, false), -2, 'no descriptors after a plain push');
mapperExt.free(); mapperExtConfig.free(); dspExt64.free(); dspExt.free();

// Beat and levels through oscillux_dsp_push_ext_f32/f64: a 120 BPM train of decaying noise
// clicks, pushed a second at a time, locks near 120 BPM and emits beats, and every level stays
// in [0, 1] with the bands past band_count zero. The Float64 push writes the same bytes.
let clickTrain;
{
  const rate = dspConfig.sampleRateHz, period = rate / 2, chunk = rate, seconds = 12, clickSamples = 480;
  const clicks = new m.Dsp(dspConfig, chunk, 128), clicks64 = new m.Dsp(dspConfig, 0, 128, chunk);
  assert.equal(clicks.beginSegment(0, false), 0);
  assert.equal(clicks64.beginSegment(0, false), 0);
  let seed = 1, frames = 0, beats = 0, downbeats = 0, tempo = 0, maxLow = 0, minLow = 1, extAt;
  // Every mapped hop also feeds a reaction sampler with its beat (sampled below).
  assert.throws(() => new m.ReactionConfig(99, rate), 'no measured latencies for version 99');
  const reactionConfig = new m.ReactionConfig(dspConfig.behaviorVersion, rate);
  assert.ok(reactionConfig.analysisLatencyMs > 0 && reactionConfig.onsetLatencyMs > 0 && reactionConfig.capacity === 256);
  reactionConfig.capacity = 4096;
  const clickMapper = new m.Mapper(m.MappingConfig.fromDsp(dspConfig)), reaction = new m.ReactionSampler(reactionConfig);
  assert.equal(reaction.pushWithBeat(0, clickMapper, clicks, 0), -2, 'no ext frames before pushExt');
  for (let start = 0; start < seconds * rate; start += chunk) {
    const input = new Float32Array(m.wasmMemory().buffer, clicks.inputPtr(), chunk);
    for (let i = 0; i < chunk; i++) {
      const t = (start + i) % period;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      input[i] = t < clickSamples ? 0.8 * (1 - t / clickSamples) * (seed / 2 ** 31 - 1) : 0;
    }
    new Float64Array(m.wasmMemory().buffer, clicks64.inputF64Ptr(), chunk).set(input);
    assert.equal(clicks.pushExt(chunk, 1), 0);
    assert.equal(clicks64.pushExtF64(chunk, 1), 0);
    if (start === 0) extAt = [clicks.extPtr(), clicks64.extPtr()];
    assert.deepEqual([clicks.extPtr(), clicks64.extPtr()], extAt, 'ext buffer allocated once');
    const produced = clicks.produced();
    assert.equal(clicks64.produced(), produced);
    assert.deepEqual(bytes(clicks64.extPtr(), produced * clicks.extBytes()), bytes(clicks.extPtr(), produced * clicks.extBytes()), `click ext at ${start}`);
    view = dataView();
    for (let i = 0; i < produced; i++, frames++) {
      const ext = clicks.extPtr() + i * clicks.extBytes(), at = `click frame ${frames}`;
      assert.equal(clickMapper.processExt(clicks, i, false), 0, at);
      assert.equal(reaction.pushWithBeat(view.getFloat64(clicks.outputPtr() + i * clicks.frameBytes() + 16, true), clickMapper, clicks, i), 0, at);
      assert.equal(view.getUint32(ext, true), 672, at);
      tempo = view.getFloat64(ext + 56, true);
      const beatPhase = view.getFloat64(ext + 64, true), barPhase = view.getFloat64(ext + 72, true), confidence = view.getFloat64(ext + 80, true);
      const beat = view.getUint32(ext + 88, true), downbeat = view.getUint32(ext + 92, true), beatInBar = view.getUint32(ext + 96, true);
      assert.ok(beatPhase >= 0 && beatPhase < 1 && barPhase >= 0 && barPhase < 1 && confidence >= 0 && confidence <= 1, at);
      assert.ok(beat <= 1 && downbeat <= beat && beatInBar < 4 && view.getUint32(ext + 100, true) === 0, at);
      beats += beat; downbeats += downbeat;
      assert.deepEqual([view.getUint32(ext + 104, true), view.getUint32(ext + 108, true)], [24, 0], at);
      for (let j = 112; j < 160 + 24 * 8; j += 8) {
        const level = view.getFloat64(ext + j, true);
        assert.ok(level >= 0 && level <= 1, `${at} level at ${j}`);
      }
      for (let j = 160 + 24 * 8; j < 672; j += 8) assert.equal(view.getFloat64(ext + j, true), 0, `${at} band past band_count`);
      const low = view.getFloat64(ext + 112, true);
      if (frames >= rate / dspConfig.hopSamples) { maxLow = Math.max(maxLow, low); minLow = Math.min(minLow, low); }
    }
  }
  assert.ok(Math.abs(tempo - 120) <= 0.04 * 120, `click train tempo ${tempo}`);
  assert.ok(beats >= seconds && downbeats >= 2, `click train beats ${beats}, downbeats ${downbeats}`);
  assert.ok(maxLow >= 0.9 && minLow <= 0.1, `click train relative low level spans ${minLow} to ${maxLow}`);
  assert.equal(reaction.pushWithBeat(NaN, clickMapper, clicks, 0), -2, 'non-finite media time');
  assert.equal(reaction.pushWithBeat(1e9, clickMapper, clicks, clicks.produced()), -2, 'ext index');
  assert.equal(reaction.queued(), frames);
  // Sampled at 60 Hz with no output or display latency: every click raises the onset to at
  // least 0.5 in the first frame at or after it, the beat phase only steps back at the wrap,
  // and once locked the wraps land within a frame of the clicks.
  const frameMs = 1000 / 60, clickMs = 1000 * period / rate, outputAt = reaction.outputPtr();
  let previous = null, wraps = [], lowest = 1;
  for (let k = 0; k * frameMs <= seconds * 1000 - 100; k++) {
    const t = k * frameMs;
    assert.equal(reaction.sample(t), 0);
    const onset = reaction.value(m.MappedValue.Onset), phase = reaction.beatPhase();
    assert.equal(new DataView(m.wasmMemory().buffer).getFloat64(outputAt + 344, true), phase, 'beatPhase at byte 344');
    if (t % clickMs < frameMs && t >= clickMs) lowest = Math.min(lowest, onset);
    if (previous && previous.locked && reaction.locked()) {
      if (phase < previous.phase) wraps.push(previous.t + (1 - previous.phase) / (1 + phase - previous.phase) * frameMs);
      else assert.ok(phase - previous.phase <= 2.05 * frameMs / clickMs, `beat phase step at ${t}`);
    }
    previous = { t, phase, locked: reaction.locked() };
  }
  assert.ok(lowest >= 0.5, `lowest first-frame onset ${lowest}`);
  const offsets = wraps.filter(w => w >= 6000).map(w => w - Math.round(w / clickMs) * clickMs);
  const meanOffset = offsets.reduce((a, o) => a + Math.abs(o), 0) / offsets.length;
  assert.ok(offsets.length >= 10 && offsets.every(o => Math.abs(o) <= frameMs), `beat wraps ${offsets}`);
  assert.equal(reaction.sample(Infinity), -2);
  const clock = new m.BeatClock();
  clock.tempoBpm = 90; clock.beatIndex = 7; clock.mediaTimeMs = seconds * 1000;
  assert.equal(reaction.setBeatClock(clock), 0);
  // Slewed onto the clock within a second: 1.5 beats after beat 7.
  for (let k = 0; k < 60; k++) assert.equal(reaction.sample(seconds * 1000 + k * frameMs), 0);
  assert.equal(reaction.sample(seconds * 1000 + 1000), 0);
  assert.deepEqual([reaction.locked(), reaction.tempoBpm(), reaction.confidence(), reaction.beatCount()], [true, 90, 1, 8]);
  assert.ok(Math.abs(reaction.beatPhase() - 0.5) < 1e-9, `clock phase ${reaction.beatPhase()}`);
  clock.beatsPerBar = 0;
  assert.equal(reaction.setBeatClock(clock), -2, 'beats per bar 0');
  assert.equal(reaction.clearBeatClock(), 0);
  assert.equal(reaction.reset(), 0);
  assert.equal(reaction.queued(), 0);
  assert.equal(reaction.sample(0), 0);
  assert.equal(reaction.locked(), false);
  clock.free(); reaction.free(); clickMapper.free(); reactionConfig.free();
  clickTrain = `${frames} click-train frames (${beats} beats near ${tempo.toFixed(1)} BPM; reaction onset >= ${lowest.toFixed(3)}, ${offsets.length} locked wraps, mean |offset| ${meanOffset.toFixed(2)} ms)`;
  clicks64.free(); clicks.free();
}

// ---- DSP -> mapping -> packing ---------------------------------------------------------
const layout = json('conformance/packing/reference.json');
const fields = layout.fields.map(f => ({ source: f.source, sourceOffset: f.source_offset, components: f.components, offset: f.offset, stride: f.stride }));
assert.throws(() => new m.Packer([{ ...fields[0], offset: 2 }], layout.block_size, 2));
const mappingConfig = m.MappingConfig.fromDsp(dspConfig);
const mapper = new m.Mapper(mappingConfig);
const packer = new m.Packer(fields, layout.block_size, 2);
assert.equal(packer.blockSize(), layout.block_size);
f64(packer.hostPtr(), 2).set([0.25, 0.5]);
const { loudnessReference: reference, dbFloor: floor } = mappingConfig;
let pipelineFrames = 0;
for (let i = 0; i < dsp.produced(); i++) {
  assert.equal(mapper.process(dsp, i, false), 0);
  view = dataView();
  const frame = dsp.outputPtr() + i * dsp.frameBytes();
  const rms = view.getFloat64(frame + 24, true), loudness = view.getFloat64(frame + 32, true);
  const amplitude = rms > 0 ? Math.min(1, Math.max(0, (loudness + reference - floor) / -floor)) : 0;
  assert.ok(Math.abs(mapper.value(m.MappedValue.Amplitude) - amplitude) <= 1e-12, `amplitude ${i}`);
  for (let j = 0; j < 9; j++) assert.ok(mapper.value(j) >= 0 && mapper.value(j) <= 1);
  assert.equal(mapper.value(m.MappedValue.Flux), mapper.value(m.MappedValue.Onset), 'process keeps the onset proxy in FLUX');
  assert.equal(packer.pack(mapper, 2), 0);
  view = dataView();
  const block = packer.outputPtr();
  for (let j = 0; j < 9; j++) assert.equal(view.getFloat32(block + j * 4, true), Math.fround(mapper.value(j)));
  for (let k = 0; k < 64; k++) assert.equal(view.getFloat32(block + 48 + k * 4, true), mapper.spectrum(k));
  assert.equal(view.getFloat32(block + 320, true), 0.25);
  assert.equal(view.getFloat32(block + 336, true), 0.5);
  for (const [from, to] of [[36, 48], [304, 320], [324, 336], [340, 352]]) for (let b = from; b < to; b++) assert.equal(view.getUint8(block + b), 0);
  pipelineFrames++;
}
assert.ok(pipelineFrames > 0);
assert.equal(mapper.process(dsp, dsp.produced(), false), -2);
assert.equal(mapper.process(dsp, 0, true), 0);
for (let j = 0; j < 9; j++) assert.equal(mapper.value(j), 0);
assert.equal(mapper.value(9), undefined);
assert.equal(mapper.spectrum(64), undefined);
assert.equal(packer.pack(mapper, 1), -2, 'absent host value');
assert.equal(packer.pack(mapper, 3), -2, 'host count above capacity');
assert.equal(mapper.reset(), 0);
assert.equal(dsp.push(sampleCount + 1, 1), -2);
assert.equal(dsp.pushF64(1, 1), -2, 'no Float64 input without f64Capacity');
assert.equal(dsp.produced(), 0);
assert.equal(mapper.process(dsp, 0, false), -2);
packer.free(); mapper.free(); mappingConfig.free(); dsp.free(); dspConfig.free();

// ---- Mapping/packing reference vectors -------------------------------------------------
// descriptors.json (the descriptor path) and levels.json (the relative level source) share
// reference.json's layout.
const descriptorLayout = json('conformance/packing/descriptors.json');
const levelsLayout = json('conformance/packing/levels.json');
for (const other of [descriptorLayout, levelsLayout]) {
  assert.deepEqual([other.fields, other.block_size, other.tolerance], [layout.fields, layout.block_size, layout.tolerance]);
}
assert.equal(levelsLayout.level_source, 'relative');
let packingSteps = 0;
const relativeCases = new Set(levelsLayout.cases);
for (const fixture of [...layout.cases, ...descriptorLayout.cases, ...levelsLayout.cases]) {
  const config = new m.MappingConfig(), mapperRef = new m.Mapper(config), packerRef = new m.Packer(fields, layout.block_size, 2);
  const relative = relativeCases.has(fixture);
  if (relative) {
    assert.equal(mapperRef.setLevelSource(2), -2, 'an unknown level source is refused');
    assert.equal(mapperRef.setLevelSource(m.LevelSource.Relative), 0);
    assert.equal(mapperRef.processFrame(false), -2, 'the relative source needs the ext levels');
  }
  for (const step of fixture.frames) {
    const input = step.input, frame = mapperRef.frameInputPtr();
    bytes(frame, 584).fill(0);
    view = dataView();
    view.setUint32(frame + 12, input.bands.length, true);
    view.setFloat64(frame + 24, input.rms, true);
    view.setFloat64(frame + 32, input.loudness_db, true);
    view.setFloat64(frame + 40, input.broadband, true);
    view.setFloat64(frame + 48, input.low, true);
    input.bands.forEach((band, i) => view.setFloat64(frame + 72 + i * 8, band, true));
    // FLUX and CENTROID come from the descriptors, when the case gives them.
    const ext = mapperRef.extInputPtr();
    if (input.descriptors) {
      view.setFloat64(ext + 40, input.descriptors.centroid_hz, true);
      view.setFloat64(ext + 48, input.descriptors.spectral_flux, true);
    }
    // The relative level source reads the levels band count and relative bands (at 104, 160).
    if (relative) {
      view.setUint32(ext + 104, input.levels.relative_bands.length, true);
      input.levels.relative_bands.forEach((level, i) => view.setFloat64(ext + 160 + i * 8, level, true));
    }
    const map = () => relative || input.descriptors ? mapperRef.processFrameExt(input.unavailable) : mapperRef.processFrame(input.unavailable);
    for (let r = 0; r < step.repeat; r++) assert.equal(map(), 0);
    step.values.forEach((want, j) => assert.ok(Math.abs(mapperRef.value(j) - want) <= layout.tolerance, `${fixture.source} value ${j}`));
    step.spectrum.forEach((want, k) => assert.equal(mapperRef.spectrum(k), want));
    f64(packerRef.hostPtr(), step.host.length).set(step.host);
    assert.equal(packerRef.pack(mapperRef, step.host.length), 0);
    assert.deepEqual(Array.from(bytes(packerRef.outputPtr(), layout.block_size)), step.bytes, fixture.source);
    packingSteps++;
  }
  packerRef.free(); mapperRef.free(); config.free();
}

// ---- Limiter ---------------------------------------------------------------------------
const limiterFields = ['timeMs', 'broadband', 'low', 'mid', 'high', 'red', 'area'];
const limiterFor = p => {
  const policy = new m.LimiterPolicy();
  Object.assign(policy, { maxFlashHz: p.maxFlashHz, maxLuminanceDelta: p.maxLuminanceDelta, maxFlashArea: p.maxFlashArea, maxRedFlashes: p.maxRedFlashes });
  const limiter = new m.Limiter(policy);
  policy.free();
  return limiter;
};
const cases = json('conformance/limiter/reference-sequences.json').cases;
for (const fixture of cases) {
  const limiter = limiterFor(fixture.policy);
  fixture.input.forEach((frame, i) => {
    f64(limiter.inputPtr(), 7).set(limiterFields.map(key => frame[key]));
    assert.equal(limiter.process(), 0);
    const output = f64(limiter.outputPtr(), 7);
    limiterFields.forEach((key, j) => assert.equal(output[j], fixture.clamped[i][key], `${fixture.name} ${i} ${key}`));
  });
  limiter.free();
}
const timelines = json('conformance/limiter/timeline-sequences.json').cases;
for (const fixture of timelines) {
  const limiter = limiterFor(fixture.policy);
  fixture.steps.forEach((step, i) => {
    if (step.reset) return assert.equal(limiter.reset(), 0);
    f64(limiter.inputPtr(), 7).set(limiterFields.map(key => step.input[key]));
    assert.equal(limiter.process(), step.error ? -2 : 0, `${fixture.name} ${i}`);
    const output = f64(limiter.outputPtr(), 7);
    limiterFields.forEach((key, j) => assert.equal(output[j], step.output[key], `${fixture.name} ${i} ${key}`));
  });
  limiter.free();
}
const strict = new m.LimiterPolicy();
strict.strobeBanned = 0;
assert.throws(() => new m.Limiter(strict));
strict.free();

// ---- Region flash analyzer -------------------------------------------------------------
const regionDoc = json('conformance/limiter/region-sequences.json');
const flashConfig = c => {
  const config = new m.FlashConfig();
  Object.assign(config, { columns: c.columns, rows: c.rows, fieldWidth: c.fieldWidth, fieldHeight: c.fieldHeight, maxFieldArea: c.maxFieldArea, maxFlashHz: c.maxFlashHz, maxRedFlashes: c.maxRedFlashes, redRule: c.redRule });
  return config;
};
const defaults = new m.FlashConfig();
assert.deepEqual([defaults.columns, defaults.rows, defaults.maxFlashHz, defaults.maxFieldArea, defaults.maxRedFlashes, defaults.redRule], [16, 16, 3, 0.25, 3, m.FlashRedRule.Wcag20]);
assert.deepEqual([m.FlashRedRule.Wcag20, m.FlashRedRule.Iso9241_391], [0, 1]);
for (const v of regionDoc.validation) {
  const config = flashConfig(v.config);
  if (v.error === null) new m.FlashAnalyzer(config).free();
  else assert.throws(() => new m.FlashAnalyzer(config), v.name);
  config.free();
}
const close = (actual, wanted, what) => assert.ok(Math.abs(actual - wanted) <= regionDoc.tolerance, `${what}: ${actual} != ${wanted}`);
const reportOf = a => ({ admitted: a.admitted, general: a.generalTransition, red: a.redTransition, generalRegions: a.generalRegions, redRegions: a.redRegions, flashes: a.flashesInWindow, redFlashes: a.redFlashesInWindow, exceeds: a.exceeds });
let regionFrames = 0, firstExceeds, refusals = 0, isoCases = 0;
for (const fixture of regionDoc.cases) {
  const config = flashConfig(fixture.config);
  const analyzer = new m.FlashAnalyzer(config);
  config.free();
  const n = analyzer.regionCount();
  assert.equal(n, fixture.config.columns * fixture.config.rows);
  const level = (value, i) => (value === undefined ? 0 : Array.isArray(value) ? value[i] : value);
  if (fixture.config.redRule === m.FlashRedRule.Iso9241_391) {
    // The ISO 9241-391 rule needs colors: the sample path is refused and changes nothing.
    assert.equal(analyzer.measure(0), -2);
    assert.equal(analyzer.admitted, false);
    isoCases++;
  }
  fixture.frames.forEach((frame, i) => {
    if (frame.reset) assert.equal(analyzer.reset(), 0);
    let status;
    if (frame.rgb !== undefined) {
      // One [r, g, b] for every region, or one per region.
      const colors = f64(analyzer.colorsPtr(), 3 * n);
      for (let r = 0; r < n; r++) colors.set(Array.isArray(frame.rgb[0]) ? frame.rgb[r] : frame.rgb, 3 * r);
      status = fixture.mode === 'admit' ? analyzer.admitRgb(frame.t) : analyzer.measureRgb(frame.t);
    } else {
      const regions = f64(analyzer.regionsPtr(), 2 * n);
      for (let r = 0; r < n; r++) { regions[2 * r] = level(frame.luminance, r); regions[2 * r + 1] = level(frame.red, r); }
      status = fixture.mode === 'admit' ? analyzer.admit(frame.t) : analyzer.measure(frame.t);
    }
    assert.equal(status, 0, `${fixture.name} ${i}`);
    const want = fixture.expected[i];
    assert.equal(want.t, frame.t);
    assert.equal(analyzer.timeMs, frame.t);
    assert.deepEqual(reportOf(analyzer), Object.fromEntries(Object.keys(reportOf(analyzer)).map(k => [k, want[k]])), `${fixture.name} ${i}`);
    if (fixture.name === 'full-screen-0.15-10hz-measure' && analyzer.exceeds && firstExceeds === undefined) firstExceeds = frame.t;
    if (fixture.name === 'full-screen-0.15-10hz-admit' && !analyzer.admitted) refusals++;
    regionFrames++;
  });
  if (fixture.name.startsWith('full-screen')) {
    // Invalid input: a decreasing time is refused with a zeroed report carrying its time.
    assert.equal(analyzer.measure(0), -2);
    assert.deepEqual([analyzer.timeMs, analyzer.flashesInWindow, analyzer.admitted, analyzer.exceeds], [0, 0, false, false]);
    assert.equal(analyzer.setRegionFromLinearRgb(n, 0, 0, 0), -2);
  }
  analyzer.free();
}
assert.equal(firstExceeds, 350);
assert.ok(refusals > 0, 'admit refused an over-budget frame');
assert.ok(isoCases >= 4, 'ISO 9241-391 red-rule cases ran');
const probeConfig = flashConfig(regionDoc.validation[1].config);
const colorProbe = new m.FlashAnalyzer(probeConfig);
probeConfig.free();
for (const color of regionDoc.colors) {
  assert.equal(colorProbe.setRegionFromLinearRgb(0, ...color.rgb), 0);
  const [luminance, red] = f64(colorProbe.regionsPtr(), 2);
  close(luminance, color.luminance, `${color.rgb} luminance`);
  close(red, color.red, `${color.rgb} red`);
}
for (const rgb of regionDoc.invalidColors) {
  const before = Array.from(f64(colorProbe.regionsPtr(), 2));
  assert.equal(colorProbe.setRegionFromLinearRgb(0, ...rgb), -2);
  assert.deepEqual(Array.from(f64(colorProbe.regionsPtr(), 2)), before);
}
colorProbe.free(); defaults.free();

// ---- Overlay regions (OSC-OVERLAY) ----------------------------------------------------
// OverlayUniforms packing against conformance/packing/overlay-uniforms.json, reduced motion,
// and overlay regions as a stricter flash area against conformance/limiter/overlay-sequences.json.
const overlayDoc = json('conformance/packing/overlay-uniforms.json');
const overlayConfig = c => {
  const config = new m.OverlayConfig();
  Object.assign(config, { viewportWidth: c.viewport_width, viewportHeight: c.viewport_height, contrastRatio: c.contrast_ratio, intensity: c.intensity, frameIntervalMs: c.frame_interval_ms, alpha: c.alpha, outputLevels: c.output_levels, reducedMotion: c.reduced_motion, premultipliedAlpha: c.premultiplied_alpha });
  return config;
};
const overlayRegions = list => {
  const regions = new m.OverlayRegions();
  list.forEach((r, i) => assert.equal(regions.setRegion(i, r.x, r.y, r.width, r.height, r.corner_radius, r.feather, r.strength, r.mode), 0));
  assert.equal(regions.setCount(list.length), 0);
  return regions;
};
const hex = b => Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
let overlayPacks = 0;
for (const c of overlayDoc.pack) {
  if (c.regions.length > 8 || c.regions.some(r => r.reserved !== 0)) {
    // setRegion writes reserved 0 and refuses an index past 8, so these refusals stay C-side.
    const regions = new m.OverlayRegions();
    if (c.regions.length > 8) assert.equal(regions.setCount(c.regions.length), -2, c.name);
    regions.free();
    continue;
  }
  const config = overlayConfig(c.config), regions = overlayRegions(c.regions);
  assert.equal(regions.uniformsBytes(), overlayDoc.size);
  bytes(regions.uniformsPtr(), overlayDoc.size).fill(0xa5);
  const status = regions.pack(config);
  const out = hex(bytes(regions.uniformsPtr(), overlayDoc.size));
  if (c.bytes !== undefined) {
    assert.equal(status, 0, c.name);
    assert.equal(out, c.bytes, c.name);
  } else {
    assert.equal(status, -2, c.name);
    assert.equal(out, 'a5'.repeat(overlayDoc.size), `${c.name}: refusal wrote the block`);
  }
  config.free(); regions.free();
  overlayPacks++;
}
assert.ok(overlayPacks >= 20, 'overlay pack vectors');
{
  const config = new m.OverlayConfig();
  assert.deepEqual([config.contrastRatio, config.intensity, config.outputLevels, config.reducedMotion], [4.5, 1, 255, false]);
  assert.equal(config.presentationIntensity(), 1);
  const flash = new m.FlashConfig();
  assert.equal(config.tightenFlashConfig(flash), 0);
  assert.deepEqual([flash.maxFlashHz, flash.maxFieldArea, flash.maxRedFlashes], [3, 0.25, 3]);
  config.reducedMotion = true;
  assert.equal(config.presentationIntensity(), 0.5);
  assert.equal(config.tightenFlashConfig(flash), 0);
  assert.deepEqual([flash.maxFlashHz, flash.maxFieldArea, flash.maxRedFlashes], [1, 0.1, 1]);
  config.contrastRatio = 0.5;
  assert.throws(() => config.presentationIntensity());
  assert.equal(config.tightenFlashConfig(flash), -2);
  config.free(); flash.free();
}
const overlaySeq = json('conformance/limiter/overlay-sequences.json');
const flashOverlay = o => {
  const overlay = new m.FlashOverlay();
  Object.assign(overlay, { luminanceChange: o.luminanceChange, darkerLimit: o.darkerLimit, maxFlashHz: o.maxFlashHz, maxArea: o.maxArea });
  return overlay;
};
let overlayFrames = 0;
for (const seq of overlaySeq.sequences) {
  const config = flashConfig(seq.config);
  const analyzer = new m.FlashAnalyzer(config), report = new m.FlashOverlayReport();
  config.free();
  const n = analyzer.regionCount();
  seq.frames.forEach((frame, i) => {
    if (frame.setOverlay) {
      const overlay = flashOverlay(frame.setOverlay.overlay), regions = overlayRegions(frame.setOverlay.regions);
      assert.equal(analyzer.setOverlay(overlay, regions), 0, `${seq.name} ${i}`);
      overlay.free(); regions.free();
    }
    if (frame.clearOverlay) assert.equal(analyzer.clearOverlay(), 0);
    if (frame.reset) assert.equal(analyzer.reset(), 0);
    const regions = f64(analyzer.regionsPtr(), 2 * n);
    for (let r = 0; r < n; r++) { regions[2 * r] = Array.isArray(frame.luminance) ? frame.luminance[r] : frame.luminance; regions[2 * r + 1] = 0; }
    assert.equal(seq.mode === 'admit' ? analyzer.admit(frame.t) : analyzer.measure(frame.t), 0);
    const want = seq.expected[i], at = `${seq.name} t=${frame.t}`;
    assert.deepEqual([analyzer.admitted, analyzer.generalTransition, analyzer.generalRegions, analyzer.flashesInWindow, analyzer.exceeds], [want.admitted, want.general, want.generalRegions, want.flashes, want.exceeds], at);
    assert.equal(analyzer.overlayReport(report), 0);
    const o = want.overlay;
    assert.deepEqual([report.active, report.transition, report.regions, report.cells, report.flashesInWindow, report.exceeds], [o.active, o.transition, o.regions, o.cells, o.flashes, o.exceeds], at);
    overlayFrames++;
  });
  analyzer.free(); report.free();
}
for (const c of overlaySeq.refusals) {
  const config = flashConfig({ ...overlaySeq.sequences[0].config });
  const analyzer = new m.FlashAnalyzer(config), overlay = flashOverlay(c.overlay);
  config.free();
  if (c.regions.length <= 8 && c.regions.every(r => r.reserved === 0)) {
    const regions = overlayRegions(c.regions);
    assert.equal(analyzer.setOverlay(overlay, regions), -2, c.name);
    regions.free();
    const report = new m.FlashOverlayReport();
    assert.equal(analyzer.overlayReport(report), 0);
    assert.equal(report.active, false, c.name);
    report.free();
  }
  analyzer.free(); overlay.free();
}
assert.ok(overlayFrames > 500, 'overlay sequence frames');

// ---- Curves ----------------------------------------------------------------------------
const present = (o, k) => o[k] !== undefined && o[k] !== null;
const num = (o, k) => (present(o, k) ? o[k] : 0);
const curveDoc = json('conformance/curves/reference.json');
for (const fixture of curveDoc.cases) {
  const c = fixture.curve, config = new m.CurveConfig();
  config.kind = { constant: m.CurveKind.Constant, easing: m.CurveKind.Easing, envelope: m.CurveKind.Envelope, lfo: m.CurveKind.Lfo }[c.kind];
  config.unit = { '': m.CurveUnit.Unspecified, seconds: m.CurveUnit.Seconds, beats: m.CurveUnit.Beats }[c.unit ?? ''];
  config.easing = { '': m.CurveEasing.Linear, linear: m.CurveEasing.Linear, easeIn: m.CurveEasing.In, easeOut: m.CurveEasing.Out, easeInOut: m.CurveEasing.InOut }[c.easing ?? ''];
  config.shape = { '': m.CurveShape.Sine, sine: m.CurveShape.Sine, triangle: m.CurveShape.Triangle, square: m.CurveShape.Square }[c.shape ?? ''];
  let flags = c.wrap === true ? m.CurveFlag.Wrap : 0;
  for (const [key, flag] of [['value', m.CurveFlag.Value], ['from', m.CurveFlag.From], ['to', m.CurveFlag.To], ['min', m.CurveFlag.Min], ['max', m.CurveFlag.Max]]) if (present(c, key)) flags |= flag;
  config.flags = flags;
  for (const key of ['value', 'from', 'to', 'duration', 'attack', 'release', 'releaseAt', 'period', 'phase', 'min', 'max', 'smoothingSeconds']) config[key] = num(c, key);
  const curve = new m.Curve(config), input = new m.CurveInput(), i = fixture.input;
  Object.assign(input, { elapsedSeconds: num(i, 'elapsedSeconds'), elapsedBeats: num(i, 'elapsedBeats'), beatPhase: num(i, 'beatPhase'), deltaSeconds: num(i, 'deltaSeconds'), previousValue: num(i, 'previousValue'), hasPrevious: i.hasPrevious === true });
  const got = curve.evaluate(input);
  assert.ok(Math.abs(got - fixture.want) <= curveDoc.tolerance, `${fixture.source}: got ${got}, want ${fixture.want}`);
  if (fixture.negativeZero === true) assert.ok(Object.is(got, -0), fixture.source);
  input.elapsedSeconds = NaN;
  assert.equal(curve.evaluate(input), undefined);
  curve.free(); input.free(); config.free();
}
const invalidCurve = new m.CurveConfig();
invalidCurve.kind = 99;
assert.throws(() => new m.Curve(invalidCurve));
invalidCurve.free();

// ---- Governor --------------------------------------------------------------------------
const governorDoc = json('conformance/governor/reference.json');
const checkStats = (governor, want, label) => {
  assert.ok(Math.abs(governor.refreshMs - want.refreshEstimateMs) <= governorDoc.tolerance, `${label} refresh`);
  assert.equal(governor.level, want.level, `${label} level`);
  if (want.emaMs === null || want.emaMs === undefined) assert.equal(governor.emaMs, undefined, `${label} ema`);
  else assert.ok(Math.abs(governor.emaMs - want.emaMs) <= governorDoc.tolerance, `${label} ema`);
};
for (const fixture of governorDoc.cases) {
  const c = fixture.config, config = new m.GovernorConfig();
  for (const [key, field] of [['targetFrameMs', 'targetMs'], ['emaAlpha', 'emaAlpha'], ['pauseGapMs', 'pauseGapMs'], ['demoteFrames', 'demoteFrames'], ['promoteFrames', 'promoteFrames'], ['settleFrames', 'settleFrames'], ['initialLevel', 'initialLevel']]) if (present(c, key)) config[field] = c[key];
  const governor = new m.Governor(config);
  checkStats(governor, fixture.initial, `${fixture.source} initial`);
  for (const step of fixture.steps) {
    for (let i = 0; i < step.count; i++) assert.equal(governor.record(step.samples[i % step.samples.length]), 0);
    checkStats(governor, step.want, fixture.source);
  }
  if (fixture.reset) {
    assert.equal(governor.reset(fixture.reset.level), 0);
    checkStats(governor, fixture.reset.want, `${fixture.source} reset`);
  }
  governor.free(); config.free();
}
const invalidGovernor = new m.GovernorConfig();
invalidGovernor.initialLevel = invalidGovernor.maxLevel + 1;
assert.throws(() => new m.Governor(invalidGovernor));
invalidGovernor.free();

// ---- Transition scheduler ----------------------------------------------------------------
// conformance/transition/reference.json, exact (tolerance 0).
const transitionDoc = json('conformance/transition/reference.json');
const tnum = v => (v === 'NaN' ? NaN : v === 'Infinity' ? Infinity : v === '-Infinity' ? -Infinity : v);
let transitionSteps = 0;
for (const fixture of transitionDoc.cases) {
  const config = new m.TransitionConfig();
  for (const [key, field] of [['easing', 'easing'], ['beats_per_bar', 'beatsPerBar'], ['auto_advance_bars', 'autoAdvanceBars'],
    ['duration_beats', 'durationBeats'], ['fallback_seconds', 'fallbackSeconds'], ['pre_roll_seconds', 'preRollSeconds'],
    ['min_confidence', 'minConfidence']]) config[field] = tnum(fixture.config[key]);
  if ('create' in fixture) {
    assert.throws(() => new m.Transition(config), fixture.name);
    config.free();
    continue;
  }
  const t = new m.Transition(config);
  fixture.steps.forEach((step, i) => {
    const label = `${fixture.name} step ${i}`;
    let rc = 0;
    if (step.op === 'request') rc = t.request(...step.clock.map(tnum), step.quantise, tnum(step.max_wait));
    else if (step.op === 'update') rc = t.update(...step.clock.map(tnum));
    else if (step.op === 'status') rc = t.status(tnum(step.time));
    else assert.equal(t.reset(), 0, label);
    transitionSteps++;
    if (step.want === undefined) return;
    if (step.want === 'refused') return assert.equal(rc, -2, label);
    assert.equal(rc, 0, label);
    const got = [t.progress, t.requestSeconds, t.startSeconds, t.endSeconds, t.state, t.quantise, t.autoRequested ? 1 : 0];
    step.want.map(tnum).forEach((w, k) => assert.ok(Object.is(got[k], w), `${label} field ${k}: ${got[k]} vs ${w}`));
  });
  t.free(); config.free();
}
assert.ok(transitionSteps > 1500, 'transition vectors parsed');
console.log(`WASM adapter: ${transitionDoc.cases.length} transition cases (${transitionSteps} steps) passed`);

// ---- Beat grid -------------------------------------------------------------------------
// A 20 s mono 120 BPM click train in 4/4 through the offline grid and its clock.
const gridConfig = new m.BeatGridConfig();
assert.equal(gridConfig.validate(), undefined);
assert.equal(gridConfig.sampleRateHz, 44100);
gridConfig.channels = 0;
assert.equal(gridConfig.validate(), 'channels');
assert.throws(() => new m.BeatGrid(gridConfig, new Float32Array(8)));
gridConfig.channels = 2;
assert.throws(() => new m.BeatGrid(gridConfig, new Float32Array(3)));
gridConfig.channels = 1;
const gridRate = 44100, gridPcm = new Float32Array(20 * gridRate);
for (let onset = 0, index = 0; onset < gridPcm.length; onset += gridRate / 2, index++) {
  const freq = index % 4 === 0 ? 2000 : 1000, amp = index % 4 === 0 ? 0.8 : 0.5;
  for (let n = 0; n < Math.trunc(0.03 * gridRate) && onset + n < gridPcm.length; n++) {
    const t = n / gridRate;
    gridPcm[onset + n] = amp * Math.exp(-t / 0.008) * Math.sin(2 * Math.PI * freq * t);
  }
}
const grid = new m.BeatGrid(gridConfig, gridPcm);
const gridBeats = grid.beatCount;
assert.ok(gridBeats >= 36 && gridBeats <= 41, `beat count ${gridBeats}`);
assert.ok(Math.abs(grid.tempoBpm - 120) <= 1.2 && grid.beatsPerBar === 4, `tempo ${grid.tempoBpm}`);
assert.ok(Math.abs(grid.durationSeconds - 20) <= 1e-9 && grid.barCount >= 9 && grid.confidence > 0);
const beatAt = i => dataView().getFloat64(grid.beatsPtr() + i * m.BeatGrid.beatBytes(), true);
const barPositionAt = i => dataView().getUint32(grid.beatsPtr() + i * m.BeatGrid.beatBytes() + 16, true);
for (let i = 0; i < gridBeats; i++) {
  assert.ok(Math.abs(beatAt(i) - Math.round(beatAt(i) * 2) / 2) <= 0.01, `beat ${i} at ${beatAt(i)}`);
  assert.equal(barPositionAt(i), (barPositionAt(0) + i) % 4);
}
assert.equal(grid.clock(0.5 * (beatAt(10) + beatAt(11))), 0);
assert.ok(grid.beatIndex === 10 && Math.abs(grid.beatPhase - 0.5) <= 1e-9 && grid.beatInBar === barPositionAt(10));
assert.ok(grid.clock(Number.NaN) < 0 && grid.beatIndex === -1);
grid.free(); gridConfig.free();

// ---- CD+G (OSC-CDG) ------------------------------------------------------------------
// Seeks through mixed.cdg and karaoke-tiles.cdg in the order of the independent oracle's
// .expect files and checks every state, window digest and index count through the Cdg class.
const { createHash } = await import('node:crypto');
const sha256 = view => createHash('sha256').update(view).digest('hex');
const cdg = new m.Cdg(readFileSync('conformance/cdg/mixed.cdg'));
assert.equal(cdg.packCount, 3000);
assert.equal(cdg.applied, 0);
assert.ok(cdg.advanceToPack(-1) < 0 && cdg.advanceToPack(1.5) < 0 && cdg.advanceToTime(NaN) < 0);
assert.ok(cdg.windowRgba(3, 16) < 0 && cdg.windowRgba(5, 0) < 0 && cdg.windowRgba(4, 0x10000) < 0);
assert.ok(cdg.indexCounts(2) < 0);
assert.equal(cdg.advanceToTime(1), 0);
assert.equal(cdg.applied, 301);
let cdgLines = 0;
const cdgCheck = (cdg, name) => {
for (const line of readFileSync(`conformance/cdg/${name}.expect`, 'utf8').split('\n')) {
  const v = line.split(' ');
  if (v[0] !== 'state' && v[0] !== 'rgba' && v[0] !== 'counts') continue;
  assert.equal(cdg.advanceToPack(Number(v[1])), 0);
  assert.equal(cdg.applied, Number(v[1]));
  if (v[0] === 'state') {
    assert.equal(cdg.screen(), 0);
    assert.equal(sha256(bytes(cdg.screenPtr(), 300 * 216)), v[2], line);
    let palette = '', transparent = '';
    for (let i = 0; i < 16; i++) {
      palette += cdg.colour(i).toString(16).padStart(3, '0');
      transparent += cdg.transparency(i).toString(16).padStart(2, '0');
    }
    assert.deepEqual([palette, transparent, cdg.hOffset, cdg.vOffset, cdg.presetColour, cdg.borderColour],
      [v[3], v[4], Number(v[5]), Number(v[6]), Number(v[7]), Number(v[8])]);
    assert.deepEqual([cdg.windowX, cdg.windowY], [6 + cdg.hOffset, 12 + cdg.vOffset]);
    assert.ok(cdg.dirtyX0 <= cdg.dirtyX1 && cdg.dirtyY0 <= cdg.dirtyY1 && cdg.dirtyX1 <= 300 && cdg.dirtyY1 <= 216);
  } else if (v[0] === 'counts') {
    assert.equal(cdg.indexCounts(v[2] === 'edge' ? 1 : 0), 0);
    assert.equal(Array.from({ length: 16 }, (_, i) => cdg.count(i)).join(','), v[3], line);
  } else {
    const [mode, index] = { none: [0, 0], table: [1, 0], preset: [2, 0] }[v[2]]
      ?? (v[2].startsWith('mask:') ? [4, parseInt(v[2].slice(5), 16)] : [3, Number(v[2].slice(6))]);
    assert.equal(cdg.windowRgba(mode, index), 0);
    assert.equal(sha256(bytes(cdg.rgbaPtr(), 288 * 192 * 4)), v[3], line);
  }
  cdgLines++;
}
};
cdgCheck(cdg, 'mixed');
assert.equal(cdgLines, 181);
assert.throws(() => cdg.colour(16));
assert.throws(() => cdg.count(16));
cdg.free();
const karaoke = new m.Cdg(readFileSync('conformance/cdg/karaoke-tiles.cdg'));
cdgCheck(karaoke, 'karaoke-tiles');
assert.equal(cdgLines, 181 + 288);
karaoke.free();

// ---- Binding coverage table and shipped types ------------------------------------------
const types = readFileSync(directory + '/oscillux.d.ts', 'utf8');
if (existsSync(directory + '/package.json')) {
  const pkg = json(directory + '/package.json');
  assert.equal(pkg.types, 'oscillux.d.ts');
}
const docs = readFileSync('docs/packaging.md', 'utf8');
const table = docs.split('<!-- binding-coverage:start -->')[1].split('<!-- binding-coverage:end -->')[0];
let bound = 0;
for (const row of table.split('\n').filter(line => line.startsWith('| `oscillux_'))) {
  const cell = row.split('|')[2].trim();
  if (cell.startsWith('excluded:')) continue;
  for (const name of cell.match(/`[^`]+`/g).map(x => x.slice(1, -1))) {
    const [, isNew, owner, member] = name.match(/^(new )?(\w+)(?:\.(\w+))?$/);
    assert.ok(owner in m, `${name}: ${owner} is not exported`);
    assert.ok(types.includes(isNew || member ? `class ${owner} ` : `function ${owner}(`), `${name}: missing from oscillux.d.ts`);
    if (member) {
      const target = m[owner];
      assert.ok(member in target.prototype || member in target, `${name}: no ${member}`);
      if (member !== 'free') assert.ok(types.includes(`${member}(`), `${name}: ${member} missing from oscillux.d.ts`);
    }
    bound++;
  }
}
assert.ok(bound >= 30, 'coverage table parsed');
assert.ok(types.includes('export interface UniformField'));

console.log(`WASM adapter: ${expected.length} DSP frames through mapping and packing, ${clickTrain} through the ext beat and levels, ${packingSteps} packing checkpoints, ${cases.length} limiter and ${timelines.length} timeline fixtures, ${regionDoc.cases.length} region flash cases (${regionFrames} frames), ${overlayPacks} overlay packs and ${overlayFrames} overlay flash frames, ${curveDoc.cases.length} curve and ${governorDoc.cases.length} governor cases, a ${gridBeats}-beat grid, ${cdgLines} CD+G oracle lines, ${bound} documented bindings passed`);
