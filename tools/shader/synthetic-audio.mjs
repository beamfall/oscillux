// SPDX-License-Identifier: AGPL-3.0-only
// Deterministic synthetic music (~124 bpm), the audio input of the shader
// harnesses. render.mjs runs it in Node and, via its source text, inside the
// page, so WebGL and Metal see the same inputs. hosts/web imports it as is;
// hosts/apple/Sources/SyntheticAudio.swift is a line-for-line port.
export function audioAt(tm) {
  const beatIvl = 0.4838;
  // count and phase come from one division, so the phase wraps on the same
  // frame the count steps and the camera never sees a one-frame jump
  const beats = tm / beatIvl;
  const beatCount = Math.floor(beats);
  const beatPhase = beats - beatCount;
  const beatT = beatPhase * beatIvl;
  const beat = Math.exp(-beatT * 9);
  const chorus = (Math.floor((tm / (beatIvl * 4)) / 8) % 2) === 1 ? 1 : 0;
  const bass = 0.32 + 0.30 * Math.abs(Math.sin(tm * 2.2)) + 0.28 * beat + 0.1 * chorus;
  const mid = 0.30 + 0.25 * Math.abs(Math.sin(tm * 1.4 + 1.7)) + 0.12 * chorus;
  const treble = 0.24 + 0.22 * Math.abs(Math.sin(tm * 3.4 + 0.6)) + 0.18 * (beatT > beatIvl/2 ? beat : 0);
  const amplitude = Math.min(1, 0.25 + bass * 0.4 + mid * 0.3 + treble * 0.2);
  const onset = Math.exp(-((tm % (beatIvl / 2))) * 16);
  const bassImpact = Math.exp(-beatT * 6);
  const spectrum = [];
  for (let i = 0; i < 64; i++) {
    const f = i / 63;
    const env = f < 0.16 ? bass : f < 0.62 ? mid : treble;
    spectrum[i] = Math.max(0, Math.min(1,
      env * (0.55 + 0.45 * Math.sin(tm * (1.3 + f * 5.1) + i * 0.7)) *
        (1.0 - f * 0.35) + beat * 0.15 * Math.exp(-Math.abs(i - 6) * 0.4)));
  }
  return { amplitude, bass, mid, treble, beat, beatPhase, onset,
           bassImpact, level: 0.55 + 0.25 * chorus,
           spectralCentroid: 0.35 + 0.25 * Math.abs(Math.sin(tm * 0.7)),
           flux: onset * 0.8, beatCount, spectrum };
}

// Deterministic synthetic PCM, the synthetic source of the reference hosts: they analyse it with
// Oscillux DSP v4 and sample it with the reaction sampler, as they would a file or a microphone.
// One loop is 8 bars of 4/4 at 125 BPM, 48 kHz mono: a kick on every beat (accented on the
// downbeat), an off-beat hi-hat (louder in bars 5-8), an off-beat bass note and a pad chord per
// bar, alternating between two notes and two chords. A beat is exactly 45 DSP hops of 512
// samples, so every loop analyses the same way. Oscillators are recurrences with decimal
// constants, envelopes are products and the noise is xorshift32, so only IEEE-754 double
// additions, subtractions, multiplications and divisions are used, each rounded once (no fused
// operations), and hosts/apple/Sources/SyntheticAudio.swift reproduces every sample exactly.
export const SYNTH_RATE = 48000;
export const SYNTH_BPM = 125;
export const SYNTH_BEAT = 23040;
export const SYNTH_LOOP = 32 * SYNTH_BEAT;
let synthLoop = null;

// n samples of a sine at the frequency whose 2cos(w) is c2 and sin(w) is s1, times a decay env
// (each sample multiplies it by k) from amplitude a.
function tone(n, c2, s1, k, a) {
  const out = new Float64Array(n);
  let y0 = 0, y1 = s1, e = a;
  for (let i = 0; i < n; i++) {
    out[i] = y0 * e;
    const y2 = c2 * y1 - y0;
    y0 = y1; y1 = y2; e = e * k;
  }
  return out;
}

// The samples of one loop, as a Float32Array of SYNTH_LOOP mono samples; built once.
export function syntheticPcm() {
  if (synthLoop) return synthLoop;
  const BEAT = SYNTH_BEAT, HALF = BEAT / 2, BAR = 4 * BEAT;
  let x = 0x9e3779b9;
  const noise = () => {
    x = (x ^ (x << 13)) >>> 0; x = (x ^ (x >>> 17)) >>> 0; x = (x ^ (x << 5)) >>> 0;
    return x * 4.656612873077393e-10 - 1;
  };
  const kick = tone(BEAT, 1.9999536678693404, 0.006806731520561792, 0.9998264039584257, 0.6);
  for (let i = 0; i < 240; i++) kick[i] = kick[i] + noise() * (1 - i / 240) * 0.3;
  const hat = new Float64Array(HALF);
  let prev = 0, e = 1;
  for (let i = 0; i < HALF; i++) {
    const v = noise();
    hat[i] = (v - prev) * e;
    prev = v; e = e * 0.9991670137924583;
  }
  const bassNote = (c1, s1, c2, s2) => {
    const a = tone(HALF, c1, s1, 0.9998611207557263, 0.5), b = tone(HALF, c2, s2, 0.9998611207557263, 0.25);
    for (let i = 0; i < HALF; i++) a[i] = (a[i] + b[i]) * (i < 480 ? i / 480 : 1);
    return a;
  };
  const bass = [bassNote(1.9999481676660484, 0.00719942097003321, 1.999792673350785, 0.014398468777274444),
    bassNote(1.9999076455921194, 0.009610009133520078, 1.9996305908978147, 0.019219130740336904)];
  const chord = notes => {
    const out = new Float64Array(BAR);
    for (const [c2, s1] of notes) {
      const t = tone(BAR, c2, s1, 1, 1 / 3);
      for (let i = 0; i < BAR; i++) out[i] = out[i] + t[i];
    }
    for (let i = 0; i < BAR; i++) out[i] = out[i] * Math.min(1, i / 9600) * Math.min(1, (BAR - i) / 9600);
    return out;
  };
  const pad = [chord([[1.9991707363874793, 0.02879395236826347], [1.9988272777241678, 0.034240012506541136],
    [1.9981385262995264, 0.04313475894669265]]),
  chord([[1.999477583299356, 0.022854944122476323], [1.9991707363874793, 0.02879395236826347],
    [1.9988272777241678, 0.034240012506541136]])];
  const out = new Float32Array(SYNTH_LOOP);
  for (let n = 0; n < SYNTH_LOOP; n++) {
    const bar = Math.floor(n / BAR), b = Math.floor(n / BEAT), j = n - b * BEAT;
    let s = (b % 4 === 0 ? 0.9 : 0.6) * kick[j];
    if (j >= HALF) s = s + (bar >= 4 ? 0.2 : 0.12) * hat[j - HALF] + 0.3 * bass[bar & 1][j - HALF];
    s = s + 0.1 * pad[bar & 1][n - bar * BAR];
    out[n] = s;
  }
  synthLoop = out;
  return out;
}
