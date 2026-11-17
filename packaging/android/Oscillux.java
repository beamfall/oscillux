// SPDX-License-Identifier: AGPL-3.0-only
package org.oscillux;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Caller-owned direct buffers follow oscillux.h layout and native byte order; size them with
 * the {@code *Size()} natives. Frame calls take preallocated buffers and do not allocate.
 * Methods return oscillux.h status codes (0 ok, negative refused) unless stated otherwise.
 */
public final class Oscillux {
    static { System.loadLibrary("oscillux_jni"); }
    private Oscillux() {}
    public static native int abiVersion();
    /** Release version of the linked library, packed as {@code major << 16 | minor << 8 | patch}. */
    public static native int version();
    /** Short description of a status code; allocates a String, so keep it off frame paths. */
    public static native String statusString(int status);
    public static native int dspConfigSize();
    public static native int dspVersionedConfigSize();
    public static native int dspFrameSize();
    /** Size of one OscilluxDspFrameExt; size pushExt buffers as {@code capacity * dspFrameExtSize()}. */
    public static native int dspFrameExtSize();
    public static native int limiterPolicySize();
    public static native int limiterFrameSize();
    public static native int flashConfigSize();
    public static native int flashRegionSize();
    public static native int flashColorSize();
    public static native int flashReportSize();
    public static native int curveConfigSize();
    public static native int curveInputSize();
    public static native int governorConfigSize();
    public static native int governorStatsSize();
    public static native int mappingConfigSize();
    public static native int mappedSize();
    public static native int uniformFieldSize();
    public static native int dspConfigDefault(ByteBuffer out);
    /** Null when valid; else the first refused member as spelled in oscillux.h, or "config". */
    public static native String dspConfigValidate(ByteBuffer config);
    /**
     * {@code out} must already hold {@code dspVersionedConfigSize()} as its uint32 struct_size at
     * offset 0. Writes the default DSP config at offset 8, behaviour version 2 as the uint32 at
     * offset 136 and 0 as the uint32 reserved at offset 140, which must stay 0. Write 1 at offset
     * 136 for the ABI-1 analysis that {@code new Dsp} runs.
     */
    public static native int dspVersionedConfigDefault(ByteBuffer out);
    /** As {@link #dspConfigValidate}; also names "struct_size", "behavior_version" or "reserved". */
    public static native String dspVersionedConfigValidate(ByteBuffer config);
    public static native int limiterPolicyDefault(ByteBuffer out);
    /** {@code out} must already hold {@code flashConfigSize()} as its uint32 struct_size at offset 0. */
    public static native int flashConfigDefault(ByteBuffer out);
    /** Writes element {@code index} of a row-major region array from a mean linear-light sRGB color. */
    public static native int flashRegionFromLinearRgb(double r, double g, double b, ByteBuffer regions, int index);
    // Overlay regions (OSC-OVERLAY): UI over visuals with guaranteed contrast.
    /** {@code OSCILLUX_OVERLAY_MAX_REGIONS}. */
    public static final int OVERLAY_MAX_REGIONS = 8;
    /** {@code OSCILLUX_OVERLAY_UNIFORMS_SIZE}: bytes of the packed std140 OverlayUniforms block. */
    public static final int OVERLAY_UNIFORMS_SIZE = 320;
    public static native int overlayConfigSize();
    public static native int overlayRegionSize();
    public static native int flashOverlaySize();
    public static native int flashOverlayReportSize();
    /** {@code out} must already hold {@code overlayConfigSize()} as its uint32 struct_size at offset 0. */
    public static native int overlayConfigDefault(ByteBuffer out);
    /**
     * Packs {@code count} (0 to 8) OscilluxOverlayRegion elements under {@code config} into
     * {@code out}, at least {@link #OVERLAY_UNIFORMS_SIZE} bytes; a refusal leaves it unchanged.
     * {@code regions} may be null when {@code count} is 0.
     */
    public static native int overlayPack(ByteBuffer config, ByteBuffer regions, int count, ByteBuffer out, int capacity);
    /** Writes one double: the config's intensity, halved under reduced motion. */
    public static native int overlayPresentationIntensity(ByteBuffer config, ByteBuffer out);
    /** Writes the vivid palette tour uniform {-1, 0, z, 0} into out (4 doubles, native order). */
    public static native int paletteTour(double timeSeconds, double offset, ByteBuffer out);
    /** Writes the vivid present pass's saturation and vibrance into out (2 doubles, native order). */
    public static native int vividPresent(ByteBuffer out);
    /** Tightens a flash config in place for reduced motion; never loosens it. */
    public static native int overlayFlashConfig(ByteBuffer config, ByteBuffer flashConfig);
    /** {@code out} must already hold {@code flashOverlaySize()} as its uint32 struct_size at offset 0. */
    public static native int flashOverlayDefault(ByteBuffer out);
    private static native int flashSetOverlay(long handle, ByteBuffer overlay, ByteBuffer regions, int count);
    private static native int flashOverlayReport(long handle, ByteBuffer out);
    public static native int curveConfigDefault(ByteBuffer out);
    public static native int governorConfigDefault(ByteBuffer out);
    public static native int mappingConfigDefault(ByteBuffer out);
    /** Writes the mapping matching a DSP configuration; refuses an invalid one. */
    public static native int mappingConfigFromDsp(ByteBuffer dspConfig, ByteBuffer out);
    private static native long dspCreate(ByteBuffer config);
    private static native long dspCreateVersioned(ByteBuffer config);
    private static native void dspDestroy(long handle);
    private static native int dspBegin(long handle, double timeMs, boolean stalled);
    private static native int dspPush(long handle, ByteBuffer pcm, int frames, int channels, ByteBuffer out, int capacity, ByteBuffer result);
    private static native int dspPushF64(long handle, ByteBuffer pcm, int frames, int channels, ByteBuffer out, int capacity, ByteBuffer result);
    private static native int dspPushExt(long handle, ByteBuffer pcm, int frames, int channels, ByteBuffer out, ByteBuffer ext, int capacity, ByteBuffer result);
    private static native int dspPushExtF64(long handle, ByteBuffer pcm, int frames, int channels, ByteBuffer out, ByteBuffer ext, int capacity, ByteBuffer result);
    private static native long limiterCreate(ByteBuffer policy);
    private static native void limiterDestroy(long handle);
    private static native int limiterReset(long handle);
    private static native int limiterProcess(long handle, ByteBuffer input, ByteBuffer output);
    private static native long flashCreate(ByteBuffer config);
    private static native void flashDestroy(long handle);
    private static native int flashReset(long handle);
    private static native int flashMeasure(long handle, double timeMs, ByteBuffer regions, int regionCount, ByteBuffer report);
    private static native int flashAdmit(long handle, double timeMs, ByteBuffer regions, int regionCount, ByteBuffer report);
    private static native int flashMeasureRgb(long handle, double timeMs, ByteBuffer colors, int regionCount, ByteBuffer report);
    private static native int flashAdmitRgb(long handle, double timeMs, ByteBuffer colors, int regionCount, ByteBuffer report);
    private static native long curveCreate(ByteBuffer config);
    private static native void curveDestroy(long handle);
    private static native int curveEvaluate(long handle, ByteBuffer input, ByteBuffer output);
    private static native long governorCreate(ByteBuffer config);
    private static native void governorDestroy(long handle);
    private static native int governorRecord(long handle, double frameMs, ByteBuffer stats);
    private static native int governorReset(long handle, int level);
    private static native long mappingCreate(ByteBuffer config);
    private static native void mappingDestroy(long handle);
    private static native int mappingReset(long handle);
    private static native int mappingSetLevelSource(long handle, int source);
    private static native int mappingProcess(long handle, ByteBuffer frames, int index, boolean unavailable, ByteBuffer output);
    private static native int mappingProcessExt(long handle, ByteBuffer frames, ByteBuffer ext, int index, boolean unavailable, ByteBuffer output);
    private static native long packerCreate(ByteBuffer fields, int count, int blockSize);
    private static native void packerDestroy(long handle);
    private static native int packerPack(long handle, ByteBuffer mapped, ByteBuffer host, int hostCount, ByteBuffer output, int capacity);
    // CD+G (OSC-CDG).
    public static native int cdgStateSize();
    private static native long cdgCreate(ByteBuffer packs, int bytes);
    private static native void cdgDestroy(long handle);
    private static native int cdgAdvanceToTime(long handle, double seconds);
    private static native int cdgAdvanceToPack(long handle, long applied);
    private static native int cdgState(long handle, ByteBuffer out);
    private static native int cdgScreen(long handle, ByteBuffer out);
    private static native int cdgWindowRgba(long handle, int keyMode, int keyIndex, ByteBuffer out);
    private static native int cdgIndexCounts(long handle, int region, ByteBuffer out);
    public static ByteBuffer buffer(int bytes) { return ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder()); }
    /** Handles are confined to their creating thread; close once after use. */
    abstract static class Handle implements AutoCloseable {
        private long handle;
        private final Thread owner = Thread.currentThread();
        private final String name;
        Handle(long handle, String name) { if (handle == 0) throw new IllegalArgumentException(name + " configuration"); this.handle = handle; this.name = name; }
        final long live() { if (owner != Thread.currentThread() || handle == 0) throw new IllegalStateException(name + " closed or wrong thread"); return handle; }
        abstract void destroy(long handle);
        public final void close() { destroy(live()); handle = 0; }
    }
    public static final class Dsp extends Handle {
        /** DSP behaviour version 1, the ABI-1 analysis. */
        public Dsp(ByteBuffer config) { super(dspCreate(config), "DSP"); }
        private Dsp(long handle) { super(handle, "DSP"); }
        /** Runs the behaviour version a versioned config selects ({@link #dspVersionedConfigDefault}). */
        public static Dsp createVersioned(ByteBuffer config) { return new Dsp(dspCreateVersioned(config)); }
        void destroy(long handle) { dspDestroy(handle); }
        public int beginSegment(double timeMs, boolean stalled) { return dspBegin(live(), timeMs, stalled); }
        /** Float32 PCM. Result is two native-endian uint64 counts (consumed, produced), on both ABIs. */
        public int push(ByteBuffer pcm, int frames, int channels, ByteBuffer out, int capacity, ByteBuffer result) { return dspPush(live(), pcm, frames, channels, out, capacity, result); }
        /** As {@link #push} with float64 PCM. */
        public int pushF64(ByteBuffer pcm, int frames, int channels, ByteBuffer out, int capacity, ByteBuffer result) { return dspPushF64(live(), pcm, frames, channels, out, capacity, result); }
        /**
         * As {@link #push}, and also writes each frame's OscilluxDspFrameExt (descriptors, beat
         * and levels) to {@code ext}, {@code capacity * dspFrameExtSize()} bytes; the frames
         * equal push's.
         */
        public int pushExt(ByteBuffer pcm, int frames, int channels, ByteBuffer out, ByteBuffer ext, int capacity, ByteBuffer result) { return dspPushExt(live(), pcm, frames, channels, out, ext, capacity, result); }
        /** As {@link #pushExt} with float64 PCM. */
        public int pushExtF64(ByteBuffer pcm, int frames, int channels, ByteBuffer out, ByteBuffer ext, int capacity, ByteBuffer result) { return dspPushExtF64(live(), pcm, frames, channels, out, ext, capacity, result); }
    }
    public static final class Limiter extends Handle {
        public Limiter(ByteBuffer policy) { super(limiterCreate(policy), "Limiter"); }
        void destroy(long handle) { limiterDestroy(handle); }
        public int reset() { return limiterReset(live()); }
        public int process(ByteBuffer input, ByteBuffer output) { return limiterProcess(live(), input, output); }
    }
    /**
     * Region flash analyzer. Regions are columns * rows (luminance, red) double pairs, row-major;
     * the Rgb methods take columns * rows (r, g, b) linear-light double triples instead and are
     * the only path the ISO 9241-391 red rule accepts.
     */
    public static final class FlashAnalyzer extends Handle {
        public FlashAnalyzer(ByteBuffer config) { super(flashCreate(config), "FlashAnalyzer"); }
        void destroy(long handle) { flashDestroy(handle); }
        public int reset() { return flashReset(live()); }
        /** Measures and commits one frame; on an error a writable {@code report} is zeroed except time_ms. */
        public int measure(double timeMs, ByteBuffer regions, int regionCount, ByteBuffer report) { return flashMeasure(live(), timeMs, regions, regionCount, report); }
        /** As {@link #measure}, committing only a frame that keeps the window within the config. */
        public int admit(double timeMs, ByteBuffer regions, int regionCount, ByteBuffer report) { return flashAdmit(live(), timeMs, regions, regionCount, report); }
        /** As {@link #measure}, from mean linear-light (r, g, b) colors. */
        public int measureRgb(double timeMs, ByteBuffer colors, int regionCount, ByteBuffer report) { return flashMeasureRgb(live(), timeMs, colors, regionCount, report); }
        /** As {@link #admit}, from mean linear-light (r, g, b) colors. */
        public int admitRgb(double timeMs, ByteBuffer colors, int regionCount, ByteBuffer report) { return flashAdmitRgb(live(), timeMs, colors, regionCount, report); }
        /** Holds the cells DAMP_FLASH regions cover to {@code overlay} (OscilluxFlashOverlay); a null overlay clears. */
        public int setOverlay(ByteBuffer overlay, ByteBuffer regions, int count) { return flashSetOverlay(live(), overlay, regions, count); }
        /** Writes the OscilluxFlashOverlayReport of the last frame; struct_size first, as in C. */
        public int overlayReport(ByteBuffer report) { return flashOverlayReport(live(), report); }
    }
    public static final class Curve extends Handle {
        public Curve(ByteBuffer config) { super(curveCreate(config), "Curve"); }
        void destroy(long handle) { curveDestroy(handle); }
        /** Writes one double to {@code output}. */
        public int evaluate(ByteBuffer input, ByteBuffer output) { return curveEvaluate(live(), input, output); }
    }
    public static final class Governor extends Handle {
        public Governor(ByteBuffer config) { super(governorCreate(config), "Governor"); }
        void destroy(long handle) { governorDestroy(handle); }
        /** Writes the stats after the sample; a non-finite duration only reports them. */
        public int record(double frameMs, ByteBuffer stats) { return governorRecord(live(), frameMs, stats); }
        public int reset(int level) { return governorReset(live(), level); }
    }
    public static final class Mapper extends Handle {
        public Mapper(ByteBuffer config) { super(mappingCreate(config), "Mapper"); }
        void destroy(long handle) { mappingDestroy(handle); }
        public int reset() { return mappingReset(live()); }
        /** Selects what BASS, MID, TREBLE and the spectrum read: {@link #LEVELS_ABSOLUTE} (the default) the band energies, {@link #LEVELS_RELATIVE} the ext frame's relative band levels, which {@link #process} and a null or levels-less ext then refuse; an unknown source is refused and leaves it unchanged, and {@link #reset} keeps it. */
        public int setLevelSource(int source) { return mappingSetLevelSource(live(), source); }
        /** {@code OSCILLUX_MAPPING_LEVELS_ABSOLUTE}. */
        public static final int LEVELS_ABSOLUTE = 0;
        /** {@code OSCILLUX_MAPPING_LEVELS_RELATIVE}. */
        public static final int LEVELS_RELATIVE = 1;
        /** Maps frame {@code index} of a frame array such as a push output; FLUX and CENTROID keep their deprecated proxies. */
        public int process(ByteBuffer frames, int index, boolean unavailable, ByteBuffer output) { return mappingProcess(live(), frames, index, unavailable, output); }
        /** As {@link #process}, with element {@code index} of a pushExt {@code ext} array (or null) feeding FLUX and CENTROID, and its levels feeding the relative level source. */
        public int processExt(ByteBuffer frames, ByteBuffer ext, int index, boolean unavailable, ByteBuffer output) { return mappingProcessExt(live(), frames, ext, index, unavailable, output); }
    }
    public static final class Packer extends Handle {
        public Packer(ByteBuffer fields, int count, int blockSize) { super(packerCreate(fields, count, blockSize), "Packer"); }
        void destroy(long handle) { packerDestroy(handle); }
        /** {@code host} may be null when {@code hostCount} is 0. A refusal leaves the block unchanged. */
        public int pack(ByteBuffer mapped, ByteBuffer host, int hostCount, ByteBuffer output, int capacity) { return packerPack(live(), mapped, host, hostCount, output, capacity); }
    }

    // ---- Transition scheduler --------------------------------------------------------------
    public static native int transitionConfigSize();
    public static native int transitionClockSize();
    public static native int transitionStatusSize();
    /** {@code out} must already hold {@code transitionConfigSize()} as its uint32 struct_size at offset 0. */
    public static native int transitionConfigDefault(ByteBuffer out);
    private static native long transitionCreate(ByteBuffer config);
    private static native void transitionDestroy(long handle);
    private static native int transitionRequest(long handle, ByteBuffer clock, int quantise, double maxWaitSeconds, ByteBuffer status);
    private static native int transitionUpdate(long handle, ByteBuffer clock, ByteBuffer status);
    private static native int transitionStatus(long handle, double timeSeconds, ByteBuffer status);
    private static native int transitionReset(long handle);
    /**
     * Transition scheduler. A clock is five doubles (time s, beat phase, bar phase, tempo BPM,
     * confidence); a status is progress, request, start and end seconds as doubles at 0, 8, 16
     * and 24, then state, quantise, auto_requested and reserved as uint32 at 32, 36, 40 and 44.
     */
    public static final class Transition extends Handle {
        public Transition(ByteBuffer config) { super(transitionCreate(config), "Transition"); }
        void destroy(long handle) { transitionDestroy(handle); }
        /** Schedules a switch; quantise 0 none, 1 beat, 2 bar. A refusal leaves {@code status} unwritten. */
        public int request(ByteBuffer clock, int quantise, double maxWaitSeconds, ByteBuffer status) { return transitionRequest(live(), clock, quantise, maxWaitSeconds, status); }
        /** Per-frame evaluation, issuing an automatic request when auto-advance is due. */
        public int update(ByteBuffer clock, ByteBuffer status) { return transitionUpdate(live(), clock, status); }
        /** Evaluates the schedule at {@code timeSeconds} without changing it. */
        public int status(double timeSeconds, ByteBuffer status) { return transitionStatus(live(), timeSeconds, status); }
        public int reset() { return transitionReset(live()); }
    }

    // ==== Reaction sampler ====
    public static native int reactionConfigSize();
    public static native int beatClockSize();
    public static native int reactionSize();
    /**
     * {@code out} must already hold {@code reactionConfigSize()} as its uint32 struct_size at
     * offset 0. Writes the default sampler configuration with the analysis latencies of DSP
     * {@code behaviorVersion} at {@code sampleRateHz}; refuses a version without measured
     * latencies or a zero rate.
     */
    public static native int reactionConfigDefault(int behaviorVersion, int sampleRateHz, ByteBuffer out);
    private static native long reactionCreate(ByteBuffer config);
    private static native void reactionDestroy(long handle);
    private static native int reactionReset(long handle);
    private static native int reactionPush(long handle, double mediaTimeMs, ByteBuffer mapped, ByteBuffer ext, int index);
    private static native int reactionSetBeatClock(long handle, ByteBuffer clock);
    private static native int reactionSample(long handle, double timeMs, ByteBuffer output);
    private static native int reactionQueued(long handle);
    /** Audio values of each display frame at its photon time (oscillux.h, Reaction sampler). */
    public static final class ReactionSampler extends Handle {
        public ReactionSampler(ByteBuffer config) { super(reactionCreate(config), "ReactionSampler"); }
        void destroy(long handle) { reactionDestroy(handle); }
        /** Forgets every hop, held peak, the beat clock and the beat state. */
        public int reset() { return reactionReset(live()); }
        /** Queues the mapped hop whose analysis window ends at {@code mediaTimeMs}, with the beat of element {@code index} of a pushExt {@code ext} array, or none when {@code ext} is null; refuses a full queue. */
        public int push(double mediaTimeMs, ByteBuffer mapped, ByteBuffer ext, int index) { return reactionPush(live(), mediaTimeMs, mapped, ext, index); }
        /** Drives the beat outputs from an OscilluxBeatClock; null returns them to the tracker. */
        public int setBeatClock(ByteBuffer clock) { return reactionSetBeatClock(live(), clock); }
        /** Writes the OscilluxReaction seen at the photon time of a frame sampled at host media time {@code timeMs}. */
        public int sample(double timeMs, ByteBuffer output) { return reactionSample(live(), timeMs, output); }
        /** Hops queued and not yet consumed. */
        public int queued() { return reactionQueued(live()); }
    }
    // ==== Beat grid ====
    public static native int beatGridConfigSize();
    public static native int beatGridInfoSize();
    public static native int beatGridBeatSize();
    public static native int beatGridClockSize();
    /** {@code out} must already hold {@code beatGridConfigSize()} as its uint32 struct_size at offset 0. */
    public static native int beatGridConfigDefault(ByteBuffer out);
    /** As {@link #dspConfigValidate}; also names "struct_size". */
    public static native String beatGridConfigValidate(ByteBuffer config);
    private static native long beatGridCreate(ByteBuffer config, ByteBuffer pcm, int frames);
    private static native void beatGridDestroy(long handle);
    private static native int beatGridBeatCount(long handle);
    private static native int beatGridInfo(long handle, ByteBuffer out);
    private static native int beatGridCopyBeats(long handle, int first, ByteBuffer out, int capacity);
    private static native int beatGridClock(long handle, double mediaTimeSeconds, ByteBuffer out);
    /**
     * Offline beat and downbeat grid of a whole PCM buffer. The constructor runs the analysis,
     * which allocates and takes time roughly linear in the length, so keep it off frame paths;
     * the queries do not allocate.
     */
    public static final class BeatGrid extends Handle {
        /** Interleaved float32 PCM, {@code frames} frames of the config's channels; refuses an invalid config or a short buffer. */
        public BeatGrid(ByteBuffer config, ByteBuffer pcm, int frames) { super(beatGridCreate(config, pcm, frames), "BeatGrid"); }
        void destroy(long handle) { beatGridDestroy(handle); }
        /** The number of beats, or a negative status. */
        public int beatCount() { return beatGridBeatCount(live()); }
        /** Writes the OscilluxBeatGridInfo summary to {@code out}. */
        public int info(ByteBuffer out) { return beatGridInfo(live(), out); }
        /** Copies beats from {@code first} into {@code out}, {@code capacity * beatGridBeatSize()} bytes; returns how many, or a negative status. */
        public int copyBeats(int first, ByteBuffer out, int capacity) { return beatGridCopyBeats(live(), first, out, capacity); }
        /** Writes the OscilluxBeatGridClock at {@code mediaTimeSeconds} from the start of the PCM to {@code out}. */
        public int clock(double mediaTimeSeconds, ByteBuffer out) { return beatGridClock(live(), mediaTimeSeconds, out); }
    }
    /**
     * CD+G lyric graphics decoder over a copy of {@code bytes} bytes of 24-byte packs (a direct
     * buffer; a trailing partial pack is ignored). State buffers are {@link #cdgStateSize()}
     * bytes with that size written at offset 0 first; screens are {@link #SCREEN_PIXELS} colour
     * indices and windows {@link #WINDOW_RGBA_BYTES} straight-alpha RGBA8 bytes.
     */
    public static final class Cdg extends Handle {
        /** {@code OSCILLUX_CDG_SCREEN_PIXELS}: 300 x 216. */
        public static final int SCREEN_PIXELS = 64800;
        /** {@code OSCILLUX_CDG_WINDOW_RGBA_BYTES}: 288 x 192 x 4. */
        public static final int WINDOW_RGBA_BYTES = 221184;
        /** {@code OSCILLUX_CDG_KEY_NONE}: every pixel opaque. */
        public static final int KEY_NONE = 0;
        /** {@code OSCILLUX_CDG_KEY_TRANSPARENT_TABLE}: alpha from the stream's transparent-colour table. */
        public static final int KEY_TRANSPARENT_TABLE = 1;
        /** {@code OSCILLUX_CDG_KEY_PRESET_COLOUR}: the Memory Preset colour is transparent. */
        public static final int KEY_PRESET_COLOUR = 2;
        /** {@code OSCILLUX_CDG_KEY_INDEX}: colour index {@code keyIndex} is transparent. */
        public static final int KEY_INDEX = 3;
        /** {@code OSCILLUX_CDG_KEY_MASK}: every index whose bit is set in the 16-bit mask {@code keyIndex} is transparent. */
        public static final int KEY_MASK = 4;
        /** {@code OSCILLUX_CDG_REGION_WINDOW}: the whole visible window. */
        public static final int REGION_WINDOW = 0;
        /** {@code OSCILLUX_CDG_REGION_EDGE}: the window's outer ring one tile deep. */
        public static final int REGION_EDGE = 1;
        /** {@code OSCILLUX_CDG_EDGE_PIXELS}: pixels in the edge region. */
        public static final int EDGE_PIXELS = 8928;
        /** {@code OSCILLUX_CDG_INDEX_COUNT}: entries written by {@link #indexCounts}. */
        public static final int INDEX_COUNT = 16;
        public Cdg(ByteBuffer packs, int bytes) { super(cdgCreate(packs, bytes), "Cdg"); }
        void destroy(long handle) { cdgDestroy(handle); }
        /** Decodes through pack floor(seconds * 300); NaN is refused unchanged. */
        public int advanceToTime(double seconds) { return cdgAdvanceToTime(live(), seconds); }
        /** Decodes the first {@code applied} packs (clamped to the stream); negative is refused. */
        public int advanceToPack(long applied) { return cdgAdvanceToPack(live(), applied); }
        public int state(ByteBuffer out) { return cdgState(live(), out); }
        public int screen(ByteBuffer out) { return cdgScreen(live(), out); }
        /** A refusal leaves {@code out} unchanged. */
        public int windowRgba(int keyMode, int keyIndex, ByteBuffer out) { return cdgWindowRgba(live(), keyMode, keyIndex, out); }
        /** Writes {@link #INDEX_COUNT} 32-bit pixel counts per colour index of {@code region}
         *  ({@code REGION_*}) to a native-order direct buffer; a refusal leaves {@code out} unchanged. */
        public int indexCounts(int region, ByteBuffer out) { return cdgIndexCounts(live(), region, out); }
    }
}
