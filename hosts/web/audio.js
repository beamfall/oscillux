// SPDX-License-Identifier: AGPL-3.0-only
// The web host's audio. Every source runs through Oscillux: the DSP at behaviour version 4
// (beat tracker), the mapper with relative levels, and the reaction sampler, which gives the
// values of one frame at the moment its light reaches the viewer. The bindings are the wasm
// package that `make host-web` builds into out/hosts/wasm.
//
// Sources:
// - synthetic: the loop from tools/shader/synthetic-audio.mjs (syntheticPcm), sampled on the
//   host's 1/60 s step clock with no latency, so a capture is deterministic and matches the
//   Apple host, which runs the same PCM through the same core;
// - a file: decoded, played on a loop, sampled at the frame's photon time (rAF time plus one
//   display interval) with the context's output latency;
// - the microphone: captured by an AudioWorklet (audio-capture.js) and never played; its hops
//   carry context time and values appear as soon as they are analysed.
// The host calls frame() once per stepped frame and reads `values`; nothing on that path
// allocates once the sources are open.
import { syntheticPcm, SYNTH_RATE, SYNTH_LOOP } from '../../tools/shader/synthetic-audio.mjs';

const BEHAVIOR = 4;
const CHUNK = 4096; // sample frames per DSP push
const CAPACITY = 1024; // queued hops, about 11 s at 48 kHz
// The mapped slots (OSCILLUX_MAPPED_*) and the uniform each one drives.
const MAPPED = ['amplitude', 'level', 'bass', 'mid', 'treble', 'onset', 'bassImpact', 'flux', 'spectralCentroid'];
const SYNTH_LOOP_MS = SYNTH_LOOP / SYNTH_RATE * 1000;

let wasm = null;

// Loads the bindings once; `bytes` (tests) replaces the fetch of oscillux_bg.wasm.
async function load(bytes) {
  if (wasm) return wasm;
  let m;
  try {
    m = await import('../../out/hosts/wasm/oscillux.js');
  } catch (e) {
    throw new Error(`the wasm bindings are missing (out/hosts/wasm): run make host-web (${e.message})`);
  }
  await m.default(bytes ? { module_or_path: bytes } : undefined);
  wasm = m;
  return m;
}

// One analysis chain: DSP, mapper and sampler for `channels` interleaved channels at `rate`.
// Hops are pushed at their DSP media time minus `shift`, and only from `pushFrom` on.
class Chain {
  constructor(m, rate, channels, outputLatencyMs, startMs = 0) {
    this.m = m;
    this.channels = channels;
    this.outputLatencyMs = outputLatencyMs;
    const dc = new m.DspConfig();
    dc.behaviorVersion = BEHAVIOR;
    dc.sampleRateHz = rate;
    dc.spectrumMaxHz = Math.min(dc.spectrumMaxHz, rate / 2);
    const refused = dc.validate();
    if (refused) throw new Error(`the DSP refuses ${refused} at ${rate} Hz`);
    this.dsp = new m.Dsp(dc, CHUNK * channels, Math.ceil(CHUNK / dc.hopSamples) + 2);
    if (this.dsp.beginSegment(startMs, false) !== 0) throw new Error('DSP beginSegment failed');
    this.mapper = new m.Mapper(m.MappingConfig.fromDsp(dc));
    this.mapper.setLevelSource(m.LevelSource.Relative);
    const rc = new m.ReactionConfig(BEHAVIOR, rate);
    rc.capacity = CAPACITY;
    rc.outputLatencyMs = outputLatencyMs;
    this.analysisMs = rc.analysisLatencyMs;
    this.sampler = new m.ReactionSampler(rc);
    rc.free();
    dc.free();
    this.shift = 0;
    this.pushFrom = -Infinity;
    this.lastM = -Infinity;
    this.mem = null;
  }

  free() {
    this.sampler.free();
    this.mapper.free();
    this.dsp.free();
  }

  // Typed views of wasm memory, refreshed only when memory has grown.
  views() {
    const buf = this.m.wasmMemory().buffer;
    if (this.mem !== buf) {
      this.mem = buf;
      this.input = new Float32Array(buf, this.dsp.inputPtr(), CHUNK * this.channels);
      this.frames = new DataView(buf);
      this.out64 = new Float64Array(buf, this.sampler.outputPtr(), MAPPED.length);
      this.out32 = new Float32Array(buf, this.sampler.outputPtr() + 72, 64);
    }
  }

  // Analyses `count` interleaved frames of `src` from frame `at` (no wrap).
  feed(src, at, count) {
    const ch = this.channels;
    while (count > 0) {
      const n = Math.min(count, CHUNK);
      this.views();
      this.input.set(src.subarray(at * ch, (at + n) * ch));
      if (this.dsp.pushExt(n * ch, ch) !== 0) throw new Error('DSP push failed');
      this.views();
      const done = this.dsp.consumed(), produced = this.dsp.produced();
      for (let i = 0; i < produced; i++) {
        if (this.mapper.processExt(this.dsp, i, false) !== 0) throw new Error('mapping failed');
        const mt = this.frames.getFloat64(this.dsp.outputPtr() + i * this.dsp.frameBytes() + 16, true) - this.shift;
        if (mt < this.pushFrom) continue;
        // a full queue (a hidden tab that stopped sampling) starts the sampler over
        if (this.sampler.pushWithBeat(mt, this.mapper, this.dsp, i) !== 0) {
          this.sampler.reset();
          if (this.sampler.pushWithBeat(mt, this.mapper, this.dsp, i) !== 0) throw new Error('reaction push failed');
        }
        this.lastM = mt;
      }
      at += done;
      count -= done;
      if (done === 0) throw new Error('DSP consumed nothing');
    }
  }

  // Samples at host media time `time` into `values`.
  sample(time, values) {
    const s = this.sampler;
    if (s.sample(time) !== 0) return;
    this.views();
    for (let i = 0; i < MAPPED.length; i++) values[MAPPED[i]] = this.out64[i];
    values.spectrum.set(this.out32);
    values.beat = s.beat();
    values.downbeat = s.downbeat();
    values.beatPhase = s.beatPhase();
    values.barPhase = s.barPhase();
    values.beatCount = s.beatCount();
    values.tempo = s.tempoBpm();
    values.confidence = s.confidence();
    values.beatInBar = s.beatInBar();
    values.locked = s.locked();
  }
}

// The synthetic loop on the step clock: frame k samples at k/60 s. The analyser first runs one
// loop that the sampler does not see (it warms the tracker and the level envelopes), so the
// step clock's 0 is the start of the second loop.
class Synthetic {
  constructor(m) {
    this.m = m;
    this.name = 'synthetic';
    this.pcm = syntheticPcm();
    this.chain = null;
    this.restart();
  }

  restart() {
    this.chain?.free();
    const c = this.chain = new Chain(this.m, SYNTH_RATE, 1, 0);
    c.shift = SYNTH_LOOP_MS;
    c.pushFrom = -50;
    for (let n = 0; n < SYNTH_LOOP; n += CHUNK) c.feed(this.pcm, n % SYNTH_LOOP, CHUNK);
    this.fed = SYNTH_LOOP;
    this.steps = 0;
    this.lastMediaMs = null;
  }

  // the step clock stands still while the host is paused
  play() {}
  pause() {}

  // Feeds hops until the sampler holds the one after time t, then samples there.
  frame(values) {
    const t = this.steps++ * 1000 / 60, c = this.chain;
    this.lastMediaMs = t % SYNTH_LOOP_MS;
    while (c.lastM - c.analysisMs <= t) {
      c.feed(this.pcm, this.fed % SYNTH_LOOP, 512);
      this.fed += 512;
    }
    c.sample(t, values);
  }

  free() { this.chain.free(); }
}

// A decoded file on a loop. Media time counts from the file's start and keeps counting
// across loops; the analyser reads the file on the same timeline, so loop k's hops follow
// loop k-1's.
class FileSource {
  constructor(m, ctx, clock, buffer, name) {
    this.m = m;
    this.ctx = ctx;
    this.clock = clock;
    this.buffer = buffer;
    this.name = name;
    const ch = this.channels = Math.min(2, buffer.numberOfChannels);
    this.rate = buffer.sampleRate;
    this.length = buffer.length;
    this.pcm = new Float32Array(this.length * ch);
    for (let c = 0; c < ch; c++) {
      const src = buffer.getChannelData(c);
      for (let i = 0; i < this.length; i++) this.pcm[i * ch + c] = src[i];
    }
    this.node = null;
    this.startAt = null; // context seconds at which media time `startMs` plays
    this.startMs = 0;
    this.chain = null;
    this.lastMediaMs = null;
    this.writeMs = null;
    this.rebuild(0);
  }

  latencyMs() { return ((this.ctx.baseLatency ?? 0) + (this.ctx.outputLatency ?? 0)) * 1000; }

  // A new chain whose analysis starts at media time `ms`.
  rebuild(ms) {
    this.chain?.free();
    this.fed = Math.round(ms / 1000 * this.rate);
    this.chain = new Chain(this.m, this.rate, this.channels, this.latencyMs(), this.fed / this.rate * 1000);
  }

  mediaMs(ctxSec) {
    return this.startAt === null ? this.startMs : this.startMs + Math.max(0, ctxSec - this.startAt) * 1000;
  }

  play() {
    if (this.node) return;
    // the context reports its latency once running; a changed one restarts the analysis
    if (Math.abs(this.latencyMs() - this.chain.outputLatencyMs) > 1) this.rebuild(this.startMs);
    const node = this.node = this.ctx.createBufferSource();
    node.buffer = this.buffer;
    node.loop = true;
    node.connect(this.ctx.destination);
    this.startAt = this.ctx.currentTime + 0.05;
    node.start(this.startAt, (this.startMs / 1000) % this.buffer.duration);
  }

  pause() {
    if (!this.node) return;
    this.startMs = this.mediaMs(this.ctx.currentTime);
    this.startAt = null;
    this.node.stop();
    this.node.disconnect();
    this.node = null;
  }

  restart() {
    const playing = !!this.node;
    this.pause();
    this.startMs = 0;
    this.rebuild(0);
    if (playing) this.play();
  }

  frame(values, photonMs) {
    const time = this.mediaMs(this.clock.ctxSec(photonMs)), c = this.chain, d = this.buffer.duration * 1000;
    const t = time - c.outputLatencyMs;
    // the lyrics follow the position heard at the photon, as the analysis does; the write
    // position is traced so tools/shader/cdg-host-check.mjs can tell the two apart
    this.lastMediaMs = Math.max(t, 0) % d;
    this.writeMs = time % d;
    while (c.lastM - c.analysisMs <= t) {
      const at = this.fed % this.length, n = Math.min(CHUNK, this.length - at);
      c.feed(this.pcm, at, n);
      this.fed += n;
    }
    c.sample(time, values);
  }

  free() { this.pause(); this.chain.free(); }
}

// The microphone, analysed on the context's timeline and never played back.
class MicSource {
  constructor(m, ctx, clock, stream, node, source) {
    this.m = m;
    this.ctx = ctx;
    this.clock = clock;
    this.name = 'microphone';
    this.stream = stream;
    this.node = node;
    this.source = source;
    this.chain = new Chain(m, ctx.sampleRate, 1, 0);
    this.started = false;
    this.last = -Infinity;
    node.port.onmessage = e => {
      const { frame, samples } = e.data;
      if (!this.started) {
        this.chain.free();
        this.chain = new Chain(m, ctx.sampleRate, 1, 0, frame / ctx.sampleRate * 1000);
        this.started = true;
      }
      this.chain.feed(samples, 0, samples.length);
    };
  }

  static async open(m, ctx, clock) {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    });
    await ctx.audioWorklet.addModule(new URL('./audio-capture.js', import.meta.url));
    const node = new AudioWorkletNode(ctx, 'oscillux-capture', { numberOfInputs: 1, numberOfOutputs: 1 });
    const source = ctx.createMediaStreamSource(stream);
    // a silent path to the destination keeps the worklet running
    const mute = ctx.createGain();
    mute.gain.value = 0;
    source.connect(node).connect(mute).connect(ctx.destination);
    return new MicSource(m, ctx, clock, stream, node, source);
  }

  play() {}
  pause() {}
  restart() {}

  frame(values, photonMs) {
    // context time now, never earlier than the last sample (which would resync the beat)
    this.last = Math.max(this.last, this.clock.ctxSec(photonMs) * 1000);
    this.chain.sample(this.last, values);
  }

  free() {
    this.node.port.onmessage = null;
    this.source.disconnect();
    this.node.disconnect();
    for (const t of this.stream.getTracks()) t.stop();
    this.chain.free();
  }
}

// Maps performance.now() time to context time. currentTime advances in render quanta, so the
// offset follows the largest recent reading and drifts down slowly.
class ContextClock {
  constructor(ctx) { this.ctx = ctx; this.offset = null; }
  update(nowMs) {
    const o = this.ctx.currentTime * 1000 - nowMs;
    this.offset = this.offset === null || o > this.offset ? o : this.offset + 0.01 * (o - this.offset);
  }
  ctxSec(perfMs) { return (perfMs + (this.offset ?? 0)) / 1000; }
}

// The host's audio: `values` holds the uniforms' inputs after each frame() call.
export class Audio {
  constructor(m) {
    this.m = m;
    this.values = {
      amplitude: 0, level: 0, bass: 0, mid: 0, treble: 0, onset: 0, bassImpact: 0, flux: 0, spectralCentroid: 0,
      beat: 0, downbeat: 0, beatPhase: 0, barPhase: 0, beatCount: 0, tempo: 0, confidence: 0, beatInBar: 0,
      locked: false, spectrum: new Float32Array(64),
    };
    this.ctx = null;
    this.clock = null;
    this.paused = false;
    this.interval = 1000 / 60;
    this.lastNow = null;
    this.source = new Synthetic(m);
  }

  static async create(wasmBytes) { return new Audio(await load(wasmBytes)); }

  context() {
    if (!this.ctx) {
      this.ctx = new AudioContext({ latencyHint: 'interactive' });
      this.clock = new ContextClock(this.ctx);
    }
    return this.ctx;
  }

  use(source) {
    this.source.free();
    this.source = source;
    if (!this.paused) source.play();
  }

  async openFile(file) {
    const ctx = this.context();
    await ctx.resume();
    const buffer = await ctx.decodeAudioData(await file.arrayBuffer());
    this.use(new FileSource(this.m, ctx, this.clock, buffer, file.name));
  }

  async openMic() {
    const ctx = this.context();
    await ctx.resume();
    this.use(await MicSource.open(this.m, ctx, this.clock));
  }

  synthetic() { this.use(new Synthetic(this.m)); }

  get live() { return !(this.source instanceof Synthetic); }

  setPaused(p) {
    this.paused = p;
    if (p) this.source.pause(); else this.source.play();
  }

  restart() { this.source.restart(); }

  // Called on every animation-frame tick, stepped or not: tracks the display interval and
  // the context clock.
  tick(now) {
    if (this.lastNow !== null) {
      const d = now - this.lastNow;
      if (d > 0 && d < 100) this.interval += 0.1 * (d - this.interval);
    }
    this.lastNow = now;
    this.clock?.update(performance.now());
  }

  // Samples the values for the frame drawn at rAF time `now`, shown one display interval later.
  frame(now) { this.source.frame(this.values, now + this.interval); }

  // The media position of the last sampled frame within its loop, ms: the synthetic step clock
  // or the file's playback position at the photon. Null for the microphone, which has none.
  get mediaMs() { return this.source.lastMediaMs ?? null; }

  status() {
    const v = this.values;
    return v.locked && v.tempo > 0
      ? `${this.source.name} · ${v.tempo.toFixed(1)} BPM · beat ${v.beatInBar + 1} · confidence ${v.confidence.toFixed(2)}`
      : `${this.source.name} · no tempo lock yet`;
  }
}
