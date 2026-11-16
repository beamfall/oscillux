/* SPDX-License-Identifier: AGPL-3.0-only */
#include <jni.h>
#include <stdint.h>
#include <string.h>
#include "oscillux.h"
#define JNI(name) Java_org_oscillux_Oscillux_##name
/* Bootstrap ByteBuffer remains loaded for the VM lifetime; publish before native calls. */
static jmethodID byte_buffer_is_read_only;
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass cls = (*env)->FindClass(env, "java/nio/ByteBuffer");
    if (!cls) return JNI_ERR;
    byte_buffer_is_read_only = (*env)->GetMethodID(env, cls, "isReadOnly", "()Z");
    (*env)->DeleteLocalRef(env, cls);
    if (!byte_buffer_is_read_only || (*env)->ExceptionCheck(env)) return JNI_ERR;
    return JNI_VERSION_1_6;
}
/* JNI capacities use bytes for ByteBuffer. Require natural alignment before C/Rust access. */
static void *buffer(JNIEnv *env, jobject obj, size_t bytes, size_t align) {
    if (!obj) return NULL;
    jlong capacity = (*env)->GetDirectBufferCapacity(env, obj);
    void *ptr = (*env)->GetDirectBufferAddress(env, obj);
    if (capacity < 0 || (uint64_t)capacity < bytes || !ptr || (uintptr_t)ptr % align) return NULL;
    return ptr;
}
static void *writable(JNIEnv *env, jobject obj, size_t bytes, size_t align) {
    void *ptr = buffer(env, obj, bytes, align);
    if (!ptr) return NULL;
    if (!byte_buffer_is_read_only) return NULL;
    jboolean readonly = (*env)->CallBooleanMethod(env, obj, byte_buffer_is_read_only);
    if ((*env)->ExceptionCheck(env) || readonly) return NULL;
    return ptr;
}
#define OUT(type, obj) ((type *)writable(env, obj, sizeof(type), _Alignof(type)))
#define BUF(type, obj) ((type *)buffer(env, obj, sizeof(type), _Alignof(type)))
#define UNUSED() (void)type
JNIEXPORT jint JNICALL JNI(abiVersion)(JNIEnv *env, jclass type) { (void)env; UNUSED(); return oscillux_abi_version(); }
/* Packed major << 16 | minor << 8 | patch; non-negative as a jint while major < 32768. */
JNIEXPORT jint JNICALL JNI(version)(JNIEnv *env, jclass type) { (void)env; UNUSED(); return (jint)oscillux_version(); }
JNIEXPORT jstring JNICALL JNI(statusString)(JNIEnv *env, jclass type, jint status) { UNUSED(); return (*env)->NewStringUTF(env, oscillux_status_string(status)); }
/* Struct sizes, so Java allocates buffers from the linked header rather than literals. */
#define SIZE(name, ctype) JNIEXPORT jint JNICALL JNI(name)(JNIEnv *env, jclass type) { (void)env; UNUSED(); return (jint)sizeof(ctype); }
SIZE(dspConfigSize, OscilluxDspConfig)
SIZE(dspVersionedConfigSize, OscilluxDspVersionedConfig)
SIZE(dspFrameSize, OscilluxDspFrame)
SIZE(dspFrameExtSize, OscilluxDspFrameExt)
SIZE(limiterPolicySize, OscilluxLimiterPolicy)
SIZE(limiterFrameSize, OscilluxLimiterFrame)
SIZE(flashConfigSize, OscilluxFlashConfig)
SIZE(flashRegionSize, OscilluxFlashRegion)
SIZE(flashColorSize, OscilluxFlashColor)
SIZE(flashReportSize, OscilluxFlashReport)
SIZE(curveConfigSize, OscilluxCurveConfig)
SIZE(curveInputSize, OscilluxCurveInput)
SIZE(governorConfigSize, OscilluxGovernorConfig)
SIZE(governorStatsSize, OscilluxGovernorStats)
SIZE(mappingConfigSize, OscilluxMappingConfig)
SIZE(mappedSize, OscilluxMapped)
SIZE(uniformFieldSize, OscilluxUniformField)
/* True when [a, a + an) and [b, b + bn) share a byte. */
static int overlaps(const void *a, size_t an, const void *b, size_t bn) {
    uintptr_t x = (uintptr_t)a, y = (uintptr_t)b;
    return x <= y ? y - x < an : x - y < bn;
}
JNIEXPORT jint JNICALL JNI(dspConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_dsp_config_default(OUT(OscilluxDspConfig, out)); }
JNIEXPORT jint JNICALL JNI(limiterPolicyDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_limiter_policy_default(OUT(OscilluxLimiterPolicy, out)); }
JNIEXPORT jint JNICALL JNI(curveConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_curve_config_default(OUT(OscilluxCurveConfig, out)); }
JNIEXPORT jint JNICALL JNI(governorConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_governor_config_default(OUT(OscilluxGovernorConfig, out)); }
JNIEXPORT jint JNICALL JNI(mappingConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_mapping_config_default(OUT(OscilluxMappingConfig, out)); }
/* Returns the first refused member's name, "config" when none is named, or null when valid. */
JNIEXPORT jstring JNICALL JNI(dspConfigValidate)(JNIEnv *env, jclass type, jobject cfg) {
    UNUSED(); const char *field = NULL;
    if (oscillux_dsp_config_validate(BUF(OscilluxDspConfig, cfg), &field) == OSCILLUX_OK) return NULL;
    return (*env)->NewStringUTF(env, field ? field : "config");
}
/* The caller writes struct_size (offset 0) first, as in C. */
JNIEXPORT jint JNICALL JNI(dspVersionedConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_dsp_versioned_config_default(OUT(OscilluxDspVersionedConfig, out)); }
/* As dspConfigValidate, for a versioned config; a wrong struct_size names "struct_size". */
JNIEXPORT jstring JNICALL JNI(dspVersionedConfigValidate)(JNIEnv *env, jclass type, jobject cfg) {
    UNUSED(); const char *field = NULL;
    if (oscillux_dsp_versioned_config_validate(BUF(OscilluxDspVersionedConfig, cfg), &field) == OSCILLUX_OK) return NULL;
    return (*env)->NewStringUTF(env, field ? field : "config");
}
JNIEXPORT jint JNICALL JNI(mappingConfigFromDsp)(JNIEnv *env, jclass type, jobject dsp, jobject out) {
    UNUSED(); OscilluxDspConfig *in = BUF(OscilluxDspConfig, dsp); OscilluxMappingConfig *config = OUT(OscilluxMappingConfig, out);
    if (!in || !config) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxDspConfig copy = *in;
    return oscillux_mapping_config_from_dsp(&copy, config);
}
JNIEXPORT jlong JNICALL JNI(dspCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxDsp *p = NULL; oscillux_dsp_create(BUF(OscilluxDspConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT jlong JNICALL JNI(dspCreateVersioned)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxDsp *p = NULL; oscillux_dsp_create_versioned(BUF(OscilluxDspVersionedConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(dspDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_dsp_destroy((OscilluxDsp *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(dspBegin)(JNIEnv *env, jclass type, jlong p, jdouble t, jboolean stalled) { (void)env; UNUSED(); return oscillux_dsp_begin_segment((OscilluxDsp *)(uintptr_t)p, t, stalled ? 1 : 0); }
/* The larger of the frame and frame-extension element sizes: every count that sizes either
 * array is bounded by it, so neither byte size can wrap on a 32-bit target. */
#define FRAME_ELEMENT_MAX (sizeof(OscilluxDspFrame) > sizeof(OscilluxDspFrameExt) ? sizeof(OscilluxDspFrame) : sizeof(OscilluxDspFrameExt))
/* PCM is `width`-byte samples (float or double); counts receives two native-endian uint64.
 * With `with_ext`, `ext` receives `capacity` OscilluxDspFrameExt elements: this layer sets each
 * struct_size to the linked header's size, so Java only sizes the buffer with dspFrameExtSize. */
static jint push(JNIEnv *env, jlong p, jobject pcm, jint frames, jint channels, jobject out, jobject ext, jint capacity, jobject counts, size_t width, int with_ext) {
    if (frames < 0 || channels <= 0 || capacity < 0 || (size_t)frames > SIZE_MAX / width / (size_t)channels || (size_t)capacity > SIZE_MAX / FRAME_ELEMENT_MAX) return OSCILLUX_ERR_INVALID_ARGUMENT;
    size_t sn = (size_t)frames * (size_t)channels * width, on = (size_t)capacity * sizeof(OscilluxDspFrame);
    size_t en = with_ext ? (size_t)capacity * sizeof(OscilluxDspFrameExt) : 0;
    void *samples = buffer(env, pcm, sn, width);
    OscilluxDspFrame *output = writable(env, out, on, _Alignof(OscilluxDspFrame));
    OscilluxDspFrameExt *extended = with_ext ? writable(env, ext, en, _Alignof(OscilluxDspFrameExt)) : NULL;
    void *result = writable(env, counts, 16, 1);
    if (!samples || !output || !result || (with_ext && !extended)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    /* Prevent output buffers from aliasing reads or one another, including sliced buffers. */
    if (overlaps(samples, sn, output, on) || overlaps(samples, sn, result, 16) || overlaps(output, on, result, 16)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    if (with_ext && (overlaps(samples, sn, extended, en) || overlaps(output, on, extended, en) || overlaps(result, 16, extended, en))) return OSCILLUX_ERR_INVALID_ARGUMENT;
    for (size_t i = 0; with_ext && i < (size_t)capacity; i++) {
        extended[i].struct_size = (uint32_t)sizeof(OscilluxDspFrameExt);
        extended[i].reserved = 0;
    }
    OscilluxDspPushResult progress = {0, 0};
    OscilluxDsp *dsp = (OscilluxDsp *)(uintptr_t)p;
    int status;
    if (with_ext) {
        status = width == sizeof(float)
            ? oscillux_dsp_push_ext_f32(dsp, samples, (size_t)frames, (uint32_t)channels, output, extended, (size_t)capacity, &progress)
            : oscillux_dsp_push_ext_f64(dsp, samples, (size_t)frames, (uint32_t)channels, output, extended, (size_t)capacity, &progress);
    } else {
        status = width == sizeof(float)
            ? oscillux_dsp_push_f32(dsp, samples, (size_t)frames, (uint32_t)channels, output, (size_t)capacity, &progress)
            : oscillux_dsp_push_f64(dsp, samples, (size_t)frames, (uint32_t)channels, output, (size_t)capacity, &progress);
    }
    uint64_t values[2] = {progress.consumed, progress.produced};
    memcpy(result, values, sizeof(values));
    return status;
}
JNIEXPORT jint JNICALL JNI(dspPush)(JNIEnv *env, jclass type, jlong p, jobject pcm, jint frames, jint channels, jobject out, jint capacity, jobject counts) {
    UNUSED(); return push(env, p, pcm, frames, channels, out, NULL, capacity, counts, sizeof(float), 0);
}
JNIEXPORT jint JNICALL JNI(dspPushF64)(JNIEnv *env, jclass type, jlong p, jobject pcm, jint frames, jint channels, jobject out, jint capacity, jobject counts) {
    UNUSED(); return push(env, p, pcm, frames, channels, out, NULL, capacity, counts, sizeof(double), 0);
}
JNIEXPORT jint JNICALL JNI(dspPushExt)(JNIEnv *env, jclass type, jlong p, jobject pcm, jint frames, jint channels, jobject out, jobject ext, jint capacity, jobject counts) {
    UNUSED(); return push(env, p, pcm, frames, channels, out, ext, capacity, counts, sizeof(float), 1);
}
JNIEXPORT jint JNICALL JNI(dspPushExtF64)(JNIEnv *env, jclass type, jlong p, jobject pcm, jint frames, jint channels, jobject out, jobject ext, jint capacity, jobject counts) {
    UNUSED(); return push(env, p, pcm, frames, channels, out, ext, capacity, counts, sizeof(double), 1);
}
JNIEXPORT jlong JNICALL JNI(limiterCreate)(JNIEnv *env, jclass type, jobject policy) { UNUSED(); OscilluxLimiter *p = NULL; oscillux_limiter_create(BUF(OscilluxLimiterPolicy, policy), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(limiterDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_limiter_destroy((OscilluxLimiter *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(limiterReset)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); return oscillux_limiter_reset((OscilluxLimiter *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(limiterProcess)(JNIEnv *env, jclass type, jlong p, jobject input, jobject output) {
    UNUSED(); OscilluxLimiterFrame *in = BUF(OscilluxLimiterFrame, input), *out = OUT(OscilluxLimiterFrame, output);
    if (!in || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    /* Copy permits arbitrary input/output overlap without violating Rust references. */
    OscilluxLimiterFrame frame = *in;
    return oscillux_limiter_process((OscilluxLimiter *)(uintptr_t)p, &frame, out);
}
/* The caller writes struct_size (offset 0) first, as in C. */
JNIEXPORT jint JNICALL JNI(flashConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_flash_config_default(OUT(OscilluxFlashConfig, out)); }
/* Writes element `index` of a region array; an index outside the buffer is refused. */
JNIEXPORT jint JNICALL JNI(flashRegionFromLinearRgb)(JNIEnv *env, jclass type, jdouble r, jdouble g, jdouble b, jobject regions, jint index) {
    UNUSED(); if (index < 0 || index >= (jint)(OSCILLUX_FLASH_MAX_GRID * OSCILLUX_FLASH_MAX_GRID)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxFlashRegion *array = writable(env, regions, ((size_t)index + 1) * sizeof(OscilluxFlashRegion), _Alignof(OscilluxFlashRegion));
    if (!array) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_flash_region_from_linear_rgb(r, g, b, &array[index]);
}
JNIEXPORT jlong JNICALL JNI(flashCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxFlashAnalyzer *p = NULL; oscillux_flash_analyzer_create(BUF(OscilluxFlashConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(flashDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_flash_analyzer_destroy((OscilluxFlashAnalyzer *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(flashReset)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); return oscillux_flash_analyzer_reset((OscilluxFlashAnalyzer *)(uintptr_t)p); }
/*
 * Unusable buffers reach C as null, so C refuses them and still writes the zeroed report to a
 * usable `output`. The count is capped at the largest grid before it sizes the element buffer.
 * `rgb` selects OscilluxFlashColor elements and the _rgb entry points.
 */
static jint flash(JNIEnv *env, jlong p, jdouble t, jobject regions, jint count, jobject output, int admit, int rgb) {
    int valid = count > 0 && count <= (jint)(OSCILLUX_FLASH_MAX_GRID * OSCILLUX_FLASH_MAX_GRID);
    size_t size = rgb ? sizeof(OscilluxFlashColor) : sizeof(OscilluxFlashRegion);
    size_t align = rgb ? _Alignof(OscilluxFlashColor) : _Alignof(OscilluxFlashRegion);
    size_t n = valid ? (size_t)count : 0, bytes = n * size;
    const void *in = valid ? buffer(env, regions, bytes, align) : NULL;
    OscilluxFlashReport *out = OUT(OscilluxFlashReport, output);
    if (in && out && overlaps(in, bytes, out, sizeof(*out))) in = NULL;
    OscilluxFlashAnalyzer *analyzer = (OscilluxFlashAnalyzer *)(uintptr_t)p;
    if (rgb) return admit ? oscillux_flash_analyzer_admit_rgb(analyzer, t, in, n, out) : oscillux_flash_analyzer_measure_rgb(analyzer, t, in, n, out);
    return admit ? oscillux_flash_analyzer_admit(analyzer, t, in, n, out) : oscillux_flash_analyzer_measure(analyzer, t, in, n, out);
}
JNIEXPORT jint JNICALL JNI(flashMeasure)(JNIEnv *env, jclass type, jlong p, jdouble t, jobject regions, jint count, jobject output) { UNUSED(); return flash(env, p, t, regions, count, output, 0, 0); }
JNIEXPORT jint JNICALL JNI(flashAdmit)(JNIEnv *env, jclass type, jlong p, jdouble t, jobject regions, jint count, jobject output) { UNUSED(); return flash(env, p, t, regions, count, output, 1, 0); }
JNIEXPORT jint JNICALL JNI(flashMeasureRgb)(JNIEnv *env, jclass type, jlong p, jdouble t, jobject colors, jint count, jobject output) { UNUSED(); return flash(env, p, t, colors, count, output, 0, 1); }
JNIEXPORT jint JNICALL JNI(flashAdmitRgb)(JNIEnv *env, jclass type, jlong p, jdouble t, jobject colors, jint count, jobject output) { UNUSED(); return flash(env, p, t, colors, count, output, 1, 1); }
JNIEXPORT jlong JNICALL JNI(curveCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxCurve *p = NULL; oscillux_curve_create(BUF(OscilluxCurveConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(curveDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_curve_destroy((OscilluxCurve *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(curveEvaluate)(JNIEnv *env, jclass type, jlong p, jobject input, jobject output) {
    UNUSED(); OscilluxCurveInput *in = BUF(OscilluxCurveInput, input); double *out = OUT(double, output);
    if (!in || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxCurveInput copy = *in;
    return oscillux_curve_evaluate((const OscilluxCurve *)(uintptr_t)p, &copy, out);
}
JNIEXPORT jlong JNICALL JNI(governorCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxGovernor *p = NULL; oscillux_governor_create(BUF(OscilluxGovernorConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(governorDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_governor_destroy((OscilluxGovernor *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(governorRecord)(JNIEnv *env, jclass type, jlong p, jdouble frameMs, jobject stats) {
    UNUSED(); OscilluxGovernorStats *out = OUT(OscilluxGovernorStats, stats);
    if (!out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_governor_record((OscilluxGovernor *)(uintptr_t)p, frameMs, out);
}
JNIEXPORT jint JNICALL JNI(governorReset)(JNIEnv *env, jclass type, jlong p, jint level) {
    (void)env; UNUSED(); if (level < 0) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_governor_reset((OscilluxGovernor *)(uintptr_t)p, (uint32_t)level);
}
JNIEXPORT jlong JNICALL JNI(mappingCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxMapper *p = NULL; oscillux_mapping_create(BUF(OscilluxMappingConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(mappingDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_mapping_destroy((OscilluxMapper *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(mappingReset)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); return oscillux_mapping_reset((OscilluxMapper *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(mappingSetLevelSource)(JNIEnv *env, jclass type, jlong p, jint source) {
    (void)env; UNUSED(); if (source < 0) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_mapping_set_level_source((OscilluxMapper *)(uintptr_t)p, (uint32_t)source);
}
/* Maps frame `index` of a frame array (for example a push output) without slicing it. */
JNIEXPORT jint JNICALL JNI(mappingProcess)(JNIEnv *env, jclass type, jlong p, jobject frames, jint index, jboolean unavailable, jobject output) {
    UNUSED(); if (index < 0 || (size_t)index >= SIZE_MAX / sizeof(OscilluxDspFrame)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxDspFrame *in = buffer(env, frames, ((size_t)index + 1) * sizeof(OscilluxDspFrame), _Alignof(OscilluxDspFrame));
    OscilluxMapped *out = OUT(OscilluxMapped, output);
    if (!in || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxDspFrame frame = in[index];
    return oscillux_mapping_process((OscilluxMapper *)(uintptr_t)p, &frame, unavailable ? 1 : 0, out);
}
/* As mappingProcess, with element `index` of an OscilluxDspFrameExt array (a pushExt output, or
 * null for none) feeding FLUX and CENTROID, and its levels feeding the relative level source. */
JNIEXPORT jint JNICALL JNI(mappingProcessExt)(JNIEnv *env, jclass type, jlong p, jobject frames, jobject exts, jint index, jboolean unavailable, jobject output) {
    UNUSED(); if (index < 0 || (size_t)index >= SIZE_MAX / FRAME_ELEMENT_MAX) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxDspFrame *in = buffer(env, frames, ((size_t)index + 1) * sizeof(OscilluxDspFrame), _Alignof(OscilluxDspFrame));
    OscilluxDspFrameExt *ext = exts ? buffer(env, exts, ((size_t)index + 1) * sizeof(OscilluxDspFrameExt), _Alignof(OscilluxDspFrameExt)) : NULL;
    OscilluxMapped *out = OUT(OscilluxMapped, output);
    if (!in || !out || (exts && !ext)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxDspFrame frame = in[index];
    if (!ext) return oscillux_mapping_process_ext((OscilluxMapper *)(uintptr_t)p, &frame, NULL, unavailable ? 1 : 0, out);
    OscilluxDspFrameExt copy = ext[index];
    return oscillux_mapping_process_ext((OscilluxMapper *)(uintptr_t)p, &frame, &copy, unavailable ? 1 : 0, out);
}
JNIEXPORT jlong JNICALL JNI(packerCreate)(JNIEnv *env, jclass type, jobject fields, jint count, jint blockSize) {
    UNUSED(); if (count <= 0 || count > OSCILLUX_PACKER_MAX_FIELDS || blockSize < 0) return 0;
    OscilluxUniformField *layout = buffer(env, fields, (size_t)count * sizeof(OscilluxUniformField), _Alignof(OscilluxUniformField));
    OscilluxPacker *p = NULL;
    if (layout) oscillux_packer_create(layout, (size_t)count, (size_t)blockSize, &p);
    return (jlong)(uintptr_t)p;
}
JNIEXPORT void JNICALL JNI(packerDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_packer_destroy((OscilluxPacker *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(packerPack)(JNIEnv *env, jclass type, jlong p, jobject mapped, jobject host, jint hostCount, jobject output, jint capacity) {
    UNUSED(); if (hostCount < 0 || capacity < 0 || (size_t)hostCount > SIZE_MAX / sizeof(double)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    size_t hn = (size_t)hostCount * sizeof(double);
    OscilluxMapped *in = BUF(OscilluxMapped, mapped);
    double *values = hostCount ? buffer(env, host, hn, _Alignof(double)) : NULL;
    uint8_t *out = writable(env, output, (size_t)capacity, 1);
    if (!in || (hostCount && !values) || !out || (values && overlaps(values, hn, out, (size_t)capacity))) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxMapped copy = *in;
    return oscillux_packer_pack((const OscilluxPacker *)(uintptr_t)p, &copy, values, (size_t)hostCount, out, (size_t)capacity);
}
/* ---- Transition scheduler: clock and status are buffers of the header structs; the clock is
 * copied before the call, so it may share storage with nothing the call writes. ---- */
SIZE(transitionConfigSize, OscilluxTransitionConfig)
SIZE(transitionClockSize, OscilluxTransitionClock)
SIZE(transitionStatusSize, OscilluxTransitionStatus)
JNIEXPORT jint JNICALL JNI(transitionConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_transition_config_default(OUT(OscilluxTransitionConfig, out)); }
JNIEXPORT jlong JNICALL JNI(transitionCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxTransition *p = NULL; oscillux_transition_create(BUF(OscilluxTransitionConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(transitionDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_transition_destroy((OscilluxTransition *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(transitionRequest)(JNIEnv *env, jclass type, jlong p, jobject clock, jint quantise, jdouble maxWaitSeconds, jobject status) {
    UNUSED(); OscilluxTransitionClock *in = BUF(OscilluxTransitionClock, clock); OscilluxTransitionStatus *out = OUT(OscilluxTransitionStatus, status);
    if (!in || !out || quantise < 0) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxTransitionClock copy = *in;
    return oscillux_transition_request((OscilluxTransition *)(uintptr_t)p, &copy, (uint32_t)quantise, maxWaitSeconds, out);
}
JNIEXPORT jint JNICALL JNI(transitionUpdate)(JNIEnv *env, jclass type, jlong p, jobject clock, jobject status) {
    UNUSED(); OscilluxTransitionClock *in = BUF(OscilluxTransitionClock, clock); OscilluxTransitionStatus *out = OUT(OscilluxTransitionStatus, status);
    if (!in || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxTransitionClock copy = *in;
    return oscillux_transition_update((OscilluxTransition *)(uintptr_t)p, &copy, out);
}
JNIEXPORT jint JNICALL JNI(transitionStatus)(JNIEnv *env, jclass type, jlong p, jdouble timeSeconds, jobject status) {
    UNUSED(); OscilluxTransitionStatus *out = OUT(OscilluxTransitionStatus, status);
    if (!out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_transition_status((const OscilluxTransition *)(uintptr_t)p, timeSeconds, out);
}
JNIEXPORT jint JNICALL JNI(transitionReset)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); return oscillux_transition_reset((OscilluxTransition *)(uintptr_t)p); }
/* ==== Reaction sampler ==== */
SIZE(reactionConfigSize, OscilluxReactionConfig)
SIZE(beatClockSize, OscilluxBeatClock)
SIZE(reactionSize, OscilluxReaction)
JNIEXPORT jint JNICALL JNI(reactionConfigDefault)(JNIEnv *env, jclass type, jint behaviorVersion, jint sampleRateHz, jobject out) {
    UNUSED(); if (behaviorVersion < 0 || sampleRateHz < 0) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_reaction_config_default((uint32_t)behaviorVersion, (uint32_t)sampleRateHz, OUT(OscilluxReactionConfig, out));
}
JNIEXPORT jlong JNICALL JNI(reactionCreate)(JNIEnv *env, jclass type, jobject cfg) { UNUSED(); OscilluxReactionSampler *p = NULL; oscillux_reaction_create(BUF(OscilluxReactionConfig, cfg), &p); return (jlong)(uintptr_t)p; }
JNIEXPORT void JNICALL JNI(reactionDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_reaction_destroy((OscilluxReactionSampler *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(reactionReset)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); return oscillux_reaction_reset((OscilluxReactionSampler *)(uintptr_t)p); }
/* Queues a mapped hop with the beat of element `index` of an OscilluxDspFrameExt array (a
 * pushExt output), or none when `exts` is null. */
JNIEXPORT jint JNICALL JNI(reactionPush)(JNIEnv *env, jclass type, jlong p, jdouble mediaTimeMs, jobject mapped, jobject exts, jint index) {
    UNUSED(); if (index < 0 || (size_t)index >= SIZE_MAX / sizeof(OscilluxDspFrameExt) - 1) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxMapped *in = BUF(OscilluxMapped, mapped);
    OscilluxDspFrameExt *ext = exts ? buffer(env, exts, ((size_t)index + 1) * sizeof(OscilluxDspFrameExt), _Alignof(OscilluxDspFrameExt)) : NULL;
    if (!in || (exts && !ext)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxMapped copy = *in;
    if (!ext) return oscillux_reaction_push((OscilluxReactionSampler *)(uintptr_t)p, mediaTimeMs, &copy, NULL);
    OscilluxDspBeat beat = ext[index].beat;
    return oscillux_reaction_push((OscilluxReactionSampler *)(uintptr_t)p, mediaTimeMs, &copy, &beat);
}
/* A null clock returns the beat outputs to the tracker. */
JNIEXPORT jint JNICALL JNI(reactionSetBeatClock)(JNIEnv *env, jclass type, jlong p, jobject clock) {
    UNUSED(); if (!clock) return oscillux_reaction_set_beat_clock((OscilluxReactionSampler *)(uintptr_t)p, NULL);
    OscilluxBeatClock *in = BUF(OscilluxBeatClock, clock);
    if (!in) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxBeatClock copy = *in;
    return oscillux_reaction_set_beat_clock((OscilluxReactionSampler *)(uintptr_t)p, &copy);
}
JNIEXPORT jint JNICALL JNI(reactionSample)(JNIEnv *env, jclass type, jlong p, jdouble timeMs, jobject output) {
    UNUSED(); OscilluxReaction *out = OUT(OscilluxReaction, output);
    if (!out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_reaction_sample((OscilluxReactionSampler *)(uintptr_t)p, timeMs, out);
}
/* The queued hop count (at most OSCILLUX_REACTION_MAX_CAPACITY), or a negative status. */
JNIEXPORT jint JNICALL JNI(reactionQueued)(JNIEnv *env, jclass type, jlong p) {
    (void)env; UNUSED(); uint32_t queued = 0;
    int32_t status = oscillux_reaction_queued((const OscilluxReactionSampler *)(uintptr_t)p, &queued);
    return status == OSCILLUX_OK ? (jint)queued : status;
}
/* ==== Beat grid ==== */
SIZE(beatGridConfigSize, OscilluxBeatGridConfig)
SIZE(beatGridInfoSize, OscilluxBeatGridInfo)
SIZE(beatGridBeatSize, OscilluxBeatGridBeat)
SIZE(beatGridClockSize, OscilluxBeatGridClock)
/* The caller writes struct_size (offset 0) first, as in C. */
JNIEXPORT jint JNICALL JNI(beatGridConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_beatgrid_config_default(OUT(OscilluxBeatGridConfig, out)); }
/* As dspConfigValidate; a wrong struct_size names "struct_size". */
JNIEXPORT jstring JNICALL JNI(beatGridConfigValidate)(JNIEnv *env, jclass type, jobject cfg) {
    UNUSED(); const char *field = NULL;
    if (oscillux_beatgrid_config_validate(BUF(OscilluxBeatGridConfig, cfg), &field) == OSCILLUX_OK) return NULL;
    return (*env)->NewStringUTF(env, field ? field : "config");
}
/* `pcm` holds `frames` frames of config->channels floats; it may be null when `frames` is 0.
 * The config is copied and validated first, so the channel count sizing the buffer is the one
 * the analysis reads. Returns 0 on any refusal. */
JNIEXPORT jlong JNICALL JNI(beatGridCreate)(JNIEnv *env, jclass type, jobject cfg, jobject pcm, jint frames) {
    UNUSED(); OscilluxBeatGridConfig *in = BUF(OscilluxBeatGridConfig, cfg);
    if (!in || frames < 0) return 0;
    OscilluxBeatGridConfig config = *in;
    if (oscillux_beatgrid_config_validate(&config, NULL) != OSCILLUX_OK || (size_t)frames > SIZE_MAX / sizeof(float) / config.channels) return 0;
    const float *samples = frames ? buffer(env, pcm, (size_t)frames * config.channels * sizeof(float), _Alignof(float)) : NULL;
    if (frames && !samples) return 0;
    OscilluxBeatGrid *p = NULL;
    oscillux_beatgrid_create(&config, samples, (size_t)frames, &p);
    return (jlong)(uintptr_t)p;
}
JNIEXPORT void JNICALL JNI(beatGridDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_beatgrid_destroy((OscilluxBeatGrid *)(uintptr_t)p); }
/* The beat count, or a negative status; a count that does not fit a jint is refused. */
JNIEXPORT jint JNICALL JNI(beatGridBeatCount)(JNIEnv *env, jclass type, jlong p) {
    (void)env; UNUSED(); size_t count = 0;
    jint status = oscillux_beatgrid_beat_count((const OscilluxBeatGrid *)(uintptr_t)p, &count);
    if (status != OSCILLUX_OK) return status;
    return count > INT32_MAX ? OSCILLUX_ERR_INVALID_ARGUMENT : (jint)count;
}
JNIEXPORT jint JNICALL JNI(beatGridInfo)(JNIEnv *env, jclass type, jlong p, jobject out) { UNUSED(); return oscillux_beatgrid_info((const OscilluxBeatGrid *)(uintptr_t)p, OUT(OscilluxBeatGridInfo, out)); }
/* Copies into `capacity` OscilluxBeatGridBeat elements; returns how many, or a negative status. */
JNIEXPORT jint JNICALL JNI(beatGridCopyBeats)(JNIEnv *env, jclass type, jlong p, jint first, jobject out, jint capacity) {
    UNUSED(); if (first < 0 || capacity < 0 || (size_t)capacity > SIZE_MAX / sizeof(OscilluxBeatGridBeat)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxBeatGridBeat *beats = capacity ? writable(env, out, (size_t)capacity * sizeof(OscilluxBeatGridBeat), _Alignof(OscilluxBeatGridBeat)) : NULL;
    if (capacity && !beats) return OSCILLUX_ERR_INVALID_ARGUMENT;
    size_t written = 0;
    jint status = oscillux_beatgrid_copy_beats((const OscilluxBeatGrid *)(uintptr_t)p, (size_t)first, beats, (size_t)capacity, &written);
    return status != OSCILLUX_OK ? status : (jint)written;
}
JNIEXPORT jint JNICALL JNI(beatGridClock)(JNIEnv *env, jclass type, jlong p, jdouble t, jobject out) { UNUSED(); return oscillux_beatgrid_clock((const OscilluxBeatGrid *)(uintptr_t)p, t, OUT(OscilluxBeatGridClock, out)); }
/* ==== Overlay regions (OSC-OVERLAY) ==== */
SIZE(overlayConfigSize, OscilluxOverlayConfig)
SIZE(overlayRegionSize, OscilluxOverlayRegion)
SIZE(flashOverlaySize, OscilluxFlashOverlay)
SIZE(flashOverlayReportSize, OscilluxFlashOverlayReport)
/* The caller writes struct_size (offset 0) first, as in C. */
JNIEXPORT jint JNICALL JNI(overlayConfigDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_overlay_config_default(OUT(OscilluxOverlayConfig, out)); }
JNIEXPORT jint JNICALL JNI(flashOverlayDefault)(JNIEnv *env, jclass type, jobject out) { UNUSED(); return oscillux_flash_overlay_default(OUT(OscilluxFlashOverlay, out)); }
/* Region arrays: `count` capped at OSCILLUX_OVERLAY_MAX_REGIONS before it sizes the buffer; a
 * zero count passes a null array, which C accepts. Unusable buffers reach C as null. */
static const OscilluxOverlayRegion *overlay_regions(JNIEnv *env, jobject regions, jint count, int *ok) {
    *ok = count >= 0 && count <= (jint)OSCILLUX_OVERLAY_MAX_REGIONS;
    if (!*ok || count == 0) return NULL;
    const OscilluxOverlayRegion *in = buffer(env, regions, (size_t)count * sizeof(OscilluxOverlayRegion), _Alignof(OscilluxOverlayRegion));
    *ok = in != NULL;
    return in;
}
JNIEXPORT jint JNICALL JNI(overlayPack)(JNIEnv *env, jclass type, jobject config, jobject regions, jint count, jobject output, jint capacity) {
    UNUSED(); int ok; const OscilluxOverlayRegion *in = overlay_regions(env, regions, count, &ok);
    OscilluxOverlayConfig *cfg = BUF(OscilluxOverlayConfig, config);
    uint8_t *out = capacity >= 0 ? writable(env, output, (size_t)capacity, 1) : NULL;
    if (!ok || !cfg || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    if (in && overlaps(in, (size_t)count * sizeof(*in), out, (size_t)capacity)) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxOverlayConfig copy = *cfg;
    return oscillux_overlay_pack(&copy, in, (size_t)count, out, (size_t)capacity);
}
JNIEXPORT jint JNICALL JNI(overlayPresentationIntensity)(JNIEnv *env, jclass type, jobject config, jobject output) {
    UNUSED(); OscilluxOverlayConfig *cfg = BUF(OscilluxOverlayConfig, config); double *out = OUT(double, output);
    if (!cfg || !out) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxOverlayConfig copy = *cfg;
    return oscillux_overlay_presentation_intensity(&copy, out);
}
JNIEXPORT jint JNICALL JNI(overlayFlashConfig)(JNIEnv *env, jclass type, jobject config, jobject flashConfig) {
    UNUSED(); OscilluxOverlayConfig *cfg = BUF(OscilluxOverlayConfig, config); OscilluxFlashConfig *flash = OUT(OscilluxFlashConfig, flashConfig);
    if (!cfg || !flash) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxOverlayConfig copy = *cfg;
    return oscillux_overlay_flash_config(&copy, flash);
}
/* A null overlay clears; otherwise the overlay and regions are copied before the call. */
JNIEXPORT jint JNICALL JNI(flashSetOverlay)(JNIEnv *env, jclass type, jlong p, jobject overlay, jobject regions, jint count) {
    UNUSED(); OscilluxFlashAnalyzer *analyzer = (OscilluxFlashAnalyzer *)(uintptr_t)p;
    if (!overlay) return oscillux_flash_analyzer_set_overlay(analyzer, NULL, NULL, 0);
    int ok; const OscilluxOverlayRegion *in = overlay_regions(env, regions, count, &ok);
    OscilluxFlashOverlay *rules = BUF(OscilluxFlashOverlay, overlay);
    if (!ok || !rules) return OSCILLUX_ERR_INVALID_ARGUMENT;
    OscilluxFlashOverlay copy = *rules;
    return oscillux_flash_analyzer_set_overlay(analyzer, &copy, in, (size_t)count);
}
JNIEXPORT jint JNICALL JNI(flashOverlayReport)(JNIEnv *env, jclass type, jlong p, jobject output) {
    UNUSED(); return oscillux_flash_analyzer_overlay_report((const OscilluxFlashAnalyzer *)(uintptr_t)p, OUT(OscilluxFlashOverlayReport, output));
}
/* ==== CD+G (OSC-CDG) ==== */
SIZE(cdgStateSize, OscilluxCdgState)
JNIEXPORT jlong JNICALL JNI(cdgCreate)(JNIEnv *env, jclass type, jobject packs, jint bytes) {
    UNUSED(); if (bytes < 0) return 0;
    uint8_t *in = bytes ? buffer(env, packs, (size_t)bytes, 1) : NULL;
    OscilluxCdg *p = NULL;
    if (bytes && !in) return 0;
    oscillux_cdg_create(in, (size_t)bytes, &p);
    return (jlong)(uintptr_t)p;
}
JNIEXPORT void JNICALL JNI(cdgDestroy)(JNIEnv *env, jclass type, jlong p) { (void)env; UNUSED(); oscillux_cdg_destroy((OscilluxCdg *)(uintptr_t)p); }
JNIEXPORT jint JNICALL JNI(cdgAdvanceToTime)(JNIEnv *env, jclass type, jlong p, jdouble seconds) { (void)env; UNUSED(); return oscillux_cdg_advance_to_time((OscilluxCdg *)(uintptr_t)p, seconds); }
JNIEXPORT jint JNICALL JNI(cdgAdvanceToPack)(JNIEnv *env, jclass type, jlong p, jlong applied) {
    (void)env; UNUSED(); if (applied < 0) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_cdg_advance_to_pack((OscilluxCdg *)(uintptr_t)p, (uint64_t)applied);
}
/* The caller writes struct_size (offset 0) first, as in C. */
JNIEXPORT jint JNICALL JNI(cdgState)(JNIEnv *env, jclass type, jlong p, jobject out) {
    UNUSED(); OscilluxCdgState *state = OUT(OscilluxCdgState, out);
    if (!state) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_cdg_state((const OscilluxCdg *)(uintptr_t)p, state);
}
JNIEXPORT jint JNICALL JNI(cdgScreen)(JNIEnv *env, jclass type, jlong p, jobject out) {
    UNUSED(); uint8_t *screen = writable(env, out, OSCILLUX_CDG_SCREEN_PIXELS, 1);
    if (!screen) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_cdg_screen((const OscilluxCdg *)(uintptr_t)p, screen, OSCILLUX_CDG_SCREEN_PIXELS);
}
JNIEXPORT jint JNICALL JNI(cdgWindowRgba)(JNIEnv *env, jclass type, jlong p, jint keyMode, jint keyIndex, jobject out) {
    UNUSED(); uint8_t *rgba = writable(env, out, OSCILLUX_CDG_WINDOW_RGBA_BYTES, 1);
    if (!rgba) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_cdg_window_rgba((const OscilluxCdg *)(uintptr_t)p, (uint32_t)keyMode, (uint32_t)keyIndex, rgba, OSCILLUX_CDG_WINDOW_RGBA_BYTES);
}
JNIEXPORT jint JNICALL JNI(cdgIndexCounts)(JNIEnv *env, jclass type, jlong p, jint region, jobject out) {
    UNUSED(); uint32_t *counts = writable(env, out, OSCILLUX_CDG_INDEX_COUNT * sizeof(uint32_t), _Alignof(uint32_t));
    if (!counts) return OSCILLUX_ERR_INVALID_ARGUMENT;
    return oscillux_cdg_index_counts((const OscilluxCdg *)(uintptr_t)p, (uint32_t)region, counts, OSCILLUX_CDG_INDEX_COUNT);
}
