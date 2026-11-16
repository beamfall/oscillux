/* SPDX-License-Identifier: AGPL-3.0-only */
#define _POSIX_C_SOURCE 200809L
#include "oscillux.h"
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/utsname.h>
#include <unistd.h>

#ifndef OSCILLUX_SOURCE
#define OSCILLUX_SOURCE "NOT_OBSERVED"
#endif
#ifndef OSCILLUX_LIBRARY_SHA256
#define OSCILLUX_LIBRARY_SHA256 "NOT_OBSERVED"
#endif
/* DSP behaviour version timed; -DOSCILLUX_BENCH_DSP_BEHAVIOR=1 selects the ABI-1 analysis. */
#ifndef OSCILLUX_BENCH_DSP_BEHAVIOR
#define OSCILLUX_BENCH_DSP_BEHAVIOR OSCILLUX_DSP_BEHAVIOR_V2
#endif

#define HOP 512
#define WARMUP 128
#define ITERATIONS 2048
#define SIGNAL_BLOCKS 32
static float pcm[SIGNAL_BLOCKS][HOP];
static uint64_t samples[5][ITERATIONS];
static uint64_t worst[5];
static size_t worst_frame;
static uint64_t cpu_samples[ITERATIONS];
static uint64_t sequences[ITERATIONS];
static uint64_t sorted[ITERATIONS];
static size_t worst_cpu_frame;
static volatile uint64_t witness;

static uint64_t clock_ns(clockid_t clock) {
    struct timespec value;
    if (clock_gettime(clock, &value) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}
static uint64_t now_ns(void) { return clock_ns(CLOCK_MONOTONIC); }

static int compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}
/* Original measurement arrays remain indexed by emitted frame; sort only scratch copies. */
static void print_frame(size_t at) {
    printf("{\"index\":%zu,\"sequence\":%" PRIu64 ",\"pcm_block\":%zu,"
        "\"wall_ns\":%" PRIu64 ",\"thread_cpu_ns\":%" PRIu64 ","
        "\"dsp_ns\":%" PRIu64 ",\"proxy_limiter_ns\":%" PRIu64 ","
        "\"mapping_ns\":%" PRIu64 ",\"packing_ns\":%" PRIu64 "}",
        at, sequences[at], (WARMUP + at + 3) % SIGNAL_BLOCKS,
        samples[0][at], cpu_samples[at], samples[1][at], samples[2][at],
        samples[3][at], samples[4][at]);
}
static int status(int32_t result, const char *operation) {
    if (result == OSCILLUX_OK) return 1;
    fprintf(stderr, "%s failed: %" PRId32 "\n", operation, result);
    return 0;
}
static double unit(double value) { return fmin(1.0, fmax(0.0, value)); }

int main(void) {
    const char *pid_file = getenv("OSCILLUX_BENCH_PIDFILE");
    if (pid_file != NULL) {
        FILE *owned = fopen(pid_file, "wx");
        if (owned == NULL) { perror("owned PID file"); return 2; }
        int written = fprintf(owned, "%ld\n", (long)getpid());
        int closed = fclose(owned);
        if (written < 0 || closed != 0) { perror("owned PID file"); return 2; }
    }
    struct timespec clock_resolution;
    if (clock_getres(CLOCK_MONOTONIC, &clock_resolution) != 0) { perror("clock_getres"); return 2; }
    OscilluxDsp *dsp = NULL;
    OscilluxLimiter *limiter = NULL;
    OscilluxMapper *mapper = NULL;
    OscilluxPacker *packer = NULL;
    OscilluxDspVersionedConfig versioned = {0};
    const OscilluxDspConfig *config = &versioned.config;
    OscilluxLimiterPolicy policy;
    OscilluxMappingConfig mapping;
    OscilluxDspFrame frame;
    OscilluxDspPushResult push;
    OscilluxMapped mapped;
    OscilluxLimiterFrame limited;
    uint8_t packed[160];
    const double host[4] = {640.0, 360.0, 0.5, 1.0};
    const OscilluxUniformField fields[3] = {
        {0, 0, 9, 0, 4}, {1, 0, 24, 48, 4}, {2, 0, 4, 144, 4}
    };
    int result = 1;
    if (oscillux_abi_version() != OSCILLUX_ABI_VERSION) {
        fprintf(stderr, "unsupported ABI\n");
        return 1;
    }
    versioned.struct_size = sizeof(versioned);
    if (!status(oscillux_dsp_versioned_config_default(&versioned), "DSP config")) goto cleanup;
    versioned.behavior_version = OSCILLUX_BENCH_DSP_BEHAVIOR;
    if (config->sample_rate_hz != 48000 || config->hop_samples != HOP ||
        config->fft_window_samples != 2048 || config->spectrum_bands != 24 ||
        !status(oscillux_limiter_policy_default(&policy), "limiter policy") ||
        !status(oscillux_mapping_config_default(&mapping), "mapping config") ||
        !status(oscillux_dsp_create_versioned(&versioned, &dsp), "DSP create") ||
        !status(oscillux_limiter_create(&policy, &limiter), "limiter create") ||
        !status(oscillux_mapping_create(&mapping, &mapper), "mapping create") ||
        !status(oscillux_packer_create(fields, 3, sizeof(packed), &packer), "packer create")) goto cleanup;

    /* Generation and all storage/lifecycle operations precede the measured frame path. */
    for (size_t block = 0; block < SIGNAL_BLOCKS; block++) {
        for (size_t at = 0; at < HOP; at++) {
            double t = (double)(block * HOP + at) / 48000.0;
            double envelope = block % 8 < 3 ? 1.0 : 0.2;
            pcm[block][at] = (float)(envelope * (0.35 * sin(2.0 * 3.141592653589793 * 60.0 * t) +
                0.20 * sin(2.0 * 3.141592653589793 * 1000.0 * t) +
                0.15 * sin(2.0 * 3.141592653589793 * 6000.0 * t)));
        }
    }
    if (!status(oscillux_dsp_begin_segment(dsp, 0.0, 0), "begin segment")) goto cleanup;
    /* Prime 1536 samples: the next 512-sample push completes exactly one FFT/hop frame. */
    for (size_t i = 0; i < 3; i++) {
        if (!status(oscillux_dsp_push_f32(dsp, pcm[i], HOP, 1, &frame, 1, &push), "prime") ||
            push.consumed != HOP || push.produced != 0) goto cleanup;
    }
    for (size_t i = 0; i < WARMUP + ITERATIONS; i++) {
        uint64_t cpu_start = clock_ns(CLOCK_THREAD_CPUTIME_ID);
        uint64_t t0 = now_ns();
        int32_t dsp_status = oscillux_dsp_push_f32(dsp, pcm[(i + 3) % SIGNAL_BLOCKS], HOP, 1, &frame, 1, &push);
        uint64_t t1 = now_ns();
        if (!status(dsp_status, "DSP frame") || push.consumed != HOP || push.produced != 1) {
            fprintf(stderr, "expected one emitted frame per 512-sample hop\n");
            goto cleanup;
        }
        OscilluxLimiterFrame input = {
            frame.media_time_ms, unit(frame.onset.broadband), unit(frame.onset.low),
            unit(frame.onset.mid), unit(frame.onset.high), unit(frame.spectrum[23]), 1.0
        };
        int32_t limiter_status = oscillux_limiter_process(limiter, &input, &limited);
        uint64_t t2 = now_ns();
        int32_t mapping_status = oscillux_mapping_process(mapper, &frame, 0, &mapped);
        uint64_t t3 = now_ns();
        if (!status(mapping_status, "mapping")) goto cleanup;
        int32_t packing_status = oscillux_packer_pack(packer, &mapped, host, 4, packed, sizeof(packed));
        uint64_t t4 = now_ns();
        uint64_t cpu_end = clock_ns(CLOCK_THREAD_CPUTIME_ID);
        if (!status(limiter_status, "proxy limiter") || !status(mapping_status, "mapping") ||
            !status(packing_status, "packing")) goto cleanup;
        witness ^= (uint64_t)packed[0] + frame.sequence + (uint64_t)(limited.broadband * 1000000.0);
        if (i >= WARMUP) {
            size_t at = i - WARMUP;
            cpu_samples[at] = cpu_end - cpu_start;
            sequences[at] = frame.sequence;
            if (cpu_samples[at] > cpu_samples[worst_cpu_frame]) worst_cpu_frame = at;
            samples[0][at] = t4 - t0;
            samples[1][at] = t1 - t0;
            samples[2][at] = t2 - t1;
            samples[3][at] = t3 - t2;
            samples[4][at] = t4 - t3;
            if (samples[0][at] > worst[0]) {
                worst_frame = at;
                for (size_t component = 0; component < 5; component++) worst[component] = samples[component][at];
            }
        }
    }
    const char *names[5] = {"total", "dsp", "proxy_limiter", "mapping", "packing"};
    puts("{\"clock\":\"CLOCK_MONOTONIC wall nanoseconds\",\"sample_rate\":48000,\"hop_samples\":512,\"warmup_frames\":128,\"measured_frames\":2048,\"timings_ms\":{");
    for (size_t component = 0; component < 5; component++) {
        memcpy(sorted, samples[component], sizeof(sorted));
        qsort(sorted, ITERATIONS, sizeof(uint64_t), compare_u64);
        printf("\"%s\":{\"p50\":%.6f,\"p95\":%.6f,\"max\":%.6f}%s\n", names[component],
            (double)sorted[1023] / 1e6, (double)sorted[1945] / 1e6,
            (double)sorted[ITERATIONS - 1] / 1e6, component == 4 ? "" : ",");
    }
    printf("},\"worst_frame\":%zu,\"worst_frame_components_ms\":{", worst_frame);
    for (size_t component = 0; component < 5; component++) {
        printf("\"%s\":%.6f%s", names[component], (double)worst[component] / 1e6, component == 4 ? "" : ",");
    }
    memcpy(sorted, cpu_samples, sizeof(sorted));
    qsort(sorted, ITERATIONS, sizeof(uint64_t), compare_u64);
    printf("},\"thread_cpu_ms\":{\"p50\":%.6f,\"p95\":%.6f,\"max\":%.6f},\"clock_resolution_ns\":%" PRIu64,
        (double)sorted[1023] / 1e6, (double)sorted[1945] / 1e6,
        (double)sorted[ITERATIONS - 1] / 1e6,
        (uint64_t)clock_resolution.tv_sec * UINT64_C(1000000000) + (uint64_t)clock_resolution.tv_nsec);
    struct utsname platform;
    if (uname(&platform) != 0) { perror("uname"); goto cleanup; }
    printf(",\"source\":\"%s\",\"library_sha256\":\"%s\",\"os\":\"%s %s\",\"architecture\":\"%s\",\"witness\":%" PRIu64,
        OSCILLUX_SOURCE, OSCILLUX_LIBRARY_SHA256, platform.sysname, platform.release, platform.machine, witness);
    printf(",\"dsp_behavior_version\":%u", (unsigned)versioned.behavior_version);
    printf(",\"worst_wall_paired\":");
    print_frame(worst_frame);
    printf(",\"worst_cpu_paired\":");
    print_frame(worst_cpu_frame);
    printf(",\"raw_frames\":[\n");
    for (size_t at = 0; at < ITERATIONS; at++) {
        print_frame(at);
        printf("%s\n", at + 1 == ITERATIONS ? "" : ",");
    }
    puts("]}");
    result = 0;
cleanup:
    oscillux_packer_destroy(packer);
    oscillux_mapping_destroy(mapper);
    oscillux_limiter_destroy(limiter);
    oscillux_dsp_destroy(dsp);
    return result;
}
