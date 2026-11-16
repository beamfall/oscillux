// SPDX-License-Identifier: AGPL-3.0-only
// AudioWorklet for the web host's microphone source (audio.js): mixes the input to mono and
// posts it in blocks of 1024 sample frames with the context frame of the block's first sample.
// It writes nothing to its output, so the capture is never heard.
const BLOCK = 1024;

class OscilluxCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.block = new Float32Array(BLOCK);
    this.fill = 0;
    this.start = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const n = input[0].length, k = 1 / input.length;
    for (let i = 0; i < n; i++) {
      if (this.fill === 0) this.start = currentFrame + i;
      let s = 0;
      for (const ch of input) s += ch[i];
      this.block[this.fill++] = s * k;
      if (this.fill === BLOCK) {
        this.port.postMessage({ frame: this.start, samples: this.block }, [this.block.buffer]);
        this.block = new Float32Array(BLOCK);
        this.fill = 0;
      }
    }
    return true;
  }
}

registerProcessor('oscillux-capture', OscilluxCapture);
