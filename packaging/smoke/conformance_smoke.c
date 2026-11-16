/* SPDX-License-Identifier: AGPL-3.0-only */
/*
 * Runs conformance vectors through the C interface of a shipped Oscillux library. The platform
 * gate (tools/platform-gate.py) links this file against each XCFramework slice and AAR ABI and
 * runs it where the host can execute that slice.
 *
 * usage: conformance_smoke <dsp-vectors> <region-vectors>
 *
 * <dsp-vectors> is conformance/dsp flattened by tools/platform-gate.py: every fixture's PCM,
 * chunk segments, golden frames and the output digest recorded in
 * crates/oscillux-core/tests/dsp_conformance.rs. <region-vectors> is
 * conformance/limiter/region-sequences.json flattened by tools/jni-smoke.py.
 */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oscillux.h"

static const char *context = "";

static void fail(const char *what) {
    fprintf(stderr, "conformance_smoke: %s: %s\n", context, what);
    exit(1);
}

static void require(int ok, const char *what) {
    if (!ok) fail(what);
}

static FILE *input;

static const char *token(void) {
    static char text[128];
    if (fscanf(input, "%127s", text) != 1) fail("unexpected end of vectors");
    return text;
}

/* Reads the next token, or returns 0 at the end of the file. */
static int next(char *out, size_t size) {
    char format[16];
    snprintf(format, sizeof format, "%%%zus", size - 1);
    return fscanf(input, format, out) == 1;
}

static double number(void) {
    const char *text = token();
    char *end;
    double value = strtod(text, &end);
    if (*end != '\0') fail("malformed number");
    return value;
}

static uint64_t unsigned_number(void) {
    const char *text = token();
    char *end;
    uint64_t value = strtoull(text, &end, 0);
    if (*end != '\0') fail("malformed integer");
    return value;
}

/* FNV-1a over the bit patterns of every published value, as dsp_conformance.rs digests them. */
static uint64_t mix(uint64_t hash, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return (hash ^ bits) * UINT64_C(0x00000100000001b3);
}

#define MAX_FRAMES 512

static int dsp_fixture(double time_tolerance, double value_tolerance) {
    static char name[64];
    snprintf(name, sizeof name, "dsp %s", token());
    context = name;
    uint32_t rate = (uint32_t)unsigned_number();
    uint64_t digest = unsigned_number();
    size_t count = (size_t)unsigned_number();
    double *samples = malloc(count * sizeof *samples);
    require(samples != NULL, "allocation");
    for (size_t i = 0; i < count; i++) samples[i] = (double)(int64_t)number() / 32768.0;

    OscilluxDspConfig config;
    require(oscillux_dsp_config_default(&config) == OSCILLUX_OK, "config default");
    config.sample_rate_hz = rate;
    OscilluxDsp *dsp = NULL;
    require(oscillux_dsp_create(&config, &dsp) == OSCILLUX_OK && dsp != NULL, "create");

    static OscilluxDspFrame frames[MAX_FRAMES];
    size_t produced = 0;
    for (;;) {
        const char *tag = token();
        if (strcmp(tag, "expect") == 0) break;
        require(strcmp(tag, "segment") == 0, "expected segment");
        double start = number();
        uint32_t stalled = (uint32_t)unsigned_number();
        size_t begin = (size_t)unsigned_number(), end = (size_t)unsigned_number();
        require(begin <= end && end <= count, "segment bounds");
        require(oscillux_dsp_begin_segment(dsp, start, stalled) == OSCILLUX_OK, "begin_segment");
        /* The same backpressure loop as the offline analyzer: eight frames per call. */
        while (begin < end) {
            OscilluxDspPushResult result;
            size_t room = MAX_FRAMES - produced < 8 ? MAX_FRAMES - produced : 8;
            require(room > 0, "too many frames");
            require(oscillux_dsp_push_f64(dsp, samples + begin, end - begin, 1, frames + produced,
                                          room, &result) == OSCILLUX_OK,
                    "push_f64");
            /* OK with no progress would loop forever; the adapter contract forbids it. */
            require(result.consumed > 0 || result.produced > 0, "push_f64 made no progress");
            begin += result.consumed;
            produced += result.produced;
        }
    }
    oscillux_dsp_destroy(dsp);
    free(samples);

    size_t expected = (size_t)unsigned_number();
    require(produced == expected, "frame count");
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    for (size_t f = 0; f < produced; f++) {
        const OscilluxDspFrame *frame = &frames[f];
        require(frame->sequence == unsigned_number(), "sequence");
        require(frame->flags == unsigned_number(), "flags");
        size_t values = (size_t)unsigned_number();
        require(values == 7 + (size_t)frame->band_count, "band count");
        double got[7 + OSCILLUX_DSP_MAX_BANDS] = {
            frame->media_time_ms, frame->rms,       frame->loudness_db, frame->onset.broadband,
            frame->onset.low,     frame->onset.mid, frame->onset.high,
        };
        memcpy(got + 7, frame->spectrum, frame->band_count * sizeof(double));
        for (size_t v = 0; v < values; v++) {
            double want = number();
            double tolerance = v == 0 ? time_tolerance : value_tolerance;
            require(isfinite(got[v]) && fabs(got[v] - want) <= tolerance, "value outside tolerance");
            hash = mix(hash, got[v]);
        }
    }
    if (hash != digest) {
        fprintf(stderr, "conformance_smoke: %s: output digest %016" PRIx64 ", recorded %016" PRIx64 "\n",
                context, hash, digest);
        exit(1);
    }
    return 1;
}

static int run_dsp(const char *path) {
    input = fopen(path, "r");
    if (input == NULL) {
        context = path;
        fail("cannot open");
    }
    char tag[32];
    double time_tolerance = -1, value_tolerance = -1;
    int fixtures = 0;
    while (next(tag, sizeof tag)) {
        if (strcmp(tag, "tolerance") == 0) {
            time_tolerance = number();
            value_tolerance = number();
        } else {
            require(strcmp(tag, "dsp") == 0 && time_tolerance >= 0, "expected tolerance then dsp");
            fixtures += dsp_fixture(time_tolerance, value_tolerance);
        }
    }
    fclose(input);
    return fixtures;
}

#define MAX_REGIONS 256

static void flash_config(OscilluxFlashConfig *config) {
    config->struct_size = sizeof *config;
    require(oscillux_flash_config_default(config) == OSCILLUX_OK, "flash config default");
    /* Order as tools/jni-smoke.py writes it. */
    config->columns = (uint32_t)number();
    config->rows = (uint32_t)number();
    config->field_width = number();
    config->field_height = number();
    config->max_field_area = number();
    config->max_flash_hz = number();
    config->max_red_flashes = (uint32_t)number();
    config->red_rule = (uint32_t)number();
}

/* Checks one frame's report against the eight expected values that follow it. */
static void expect_report(const OscilluxFlashReport *report, double t) {
    require(report->time_ms == t, "time_ms");
    require(report->admitted == (uint32_t)number(), "admitted");
    require(report->general_transition == (uint32_t)number(), "general_transition");
    require(report->red_transition == (uint32_t)number(), "red_transition");
    require(report->general_regions == (uint32_t)number(), "general_regions");
    require(report->red_regions == (uint32_t)number(), "red_regions");
    require(report->flashes_in_window == number(), "flashes_in_window");
    require(report->red_flashes_in_window == number(), "red_flashes_in_window");
    require(report->exceeds == (uint32_t)number(), "exceeds");
}

static int run_region(const char *path) {
    input = fopen(path, "r");
    if (input == NULL) {
        context = path;
        fail("cannot open");
    }
    static char name[96];
    static OscilluxFlashRegion regions[MAX_REGIONS];
    static OscilluxFlashColor colors[MAX_REGIONS];
    char tag[32], mode[16] = "";
    double tolerance = 0;
    int cases = 0, first_exceeds = -1, refusals = 0, full_screen_cases = 0, refusal_checks = 0, iso_cases = 0;
    size_t count = 0;
    OscilluxFlashAnalyzer *analyzer = NULL;
    while (next(tag, sizeof tag)) {
        if (strcmp(tag, "tolerance") == 0) {
            tolerance = number();
        } else if (strcmp(tag, "validation") == 0) {
            snprintf(name, sizeof name, "flash validation %s", token());
            context = name;
            int ok = strcmp(token(), "ok") == 0;
            OscilluxFlashConfig config;
            flash_config(&config);
            OscilluxFlashAnalyzer *made = NULL;
            int32_t status = oscillux_flash_analyzer_create(&config, &made);
            require(ok ? status == OSCILLUX_OK && made != NULL : status != OSCILLUX_OK && made == NULL,
                    "validation outcome");
            oscillux_flash_analyzer_destroy(made);
        } else if (strcmp(tag, "case") == 0) {
            oscillux_flash_analyzer_destroy(analyzer);
            snprintf(name, sizeof name, "flash case %s", token());
            context = name;
            snprintf(mode, sizeof mode, "%s", token());
            OscilluxFlashConfig config;
            flash_config(&config);
            count = (size_t)config.columns * config.rows;
            require(count <= MAX_REGIONS, "region count");
            require(oscillux_flash_analyzer_create(&config, &analyzer) == OSCILLUX_OK, "create");
            cases++;
            if (strncmp(name, "flash case full-screen", 22) == 0) full_screen_cases++;
            if (config.red_rule == OSCILLUX_FLASH_RED_RULE_ISO_9241_391) {
                /* The ISO 9241-391 rule needs colors: the sample path is refused, state unchanged. */
                OscilluxFlashReport report;
                static const OscilluxFlashRegion grey[MAX_REGIONS];
                require(oscillux_flash_analyzer_measure(analyzer, 0, grey, count, &report) ==
                                OSCILLUX_ERR_INVALID_ARGUMENT &&
                            report.time_ms == 0 && report.admitted == 0,
                        "iso refuses samples");
                iso_cases++;
            }
        } else if (strcmp(tag, "frame") == 0) {
            require(analyzer != NULL, "frame before case");
            double t = number();
            if (unsigned_number() == 1) require(oscillux_flash_analyzer_reset(analyzer) == OSCILLUX_OK, "reset");
            for (size_t r = 0; r < count; r++) regions[r].luminance = number();
            for (size_t r = 0; r < count; r++) regions[r].red = number();
            OscilluxFlashReport report;
            int admit = strcmp(mode, "admit") == 0;
            int32_t status = admit ? oscillux_flash_analyzer_admit(analyzer, t, regions, count, &report)
                                   : oscillux_flash_analyzer_measure(analyzer, t, regions, count, &report);
            require(status == OSCILLUX_OK, "frame status");
            expect_report(&report, t);
            if (strcmp(name, "flash case full-screen-0.15-10hz-measure") == 0 && report.exceeds == 1 &&
                first_exceeds < 0)
                first_exceeds = (int)t;
            if (strcmp(name, "flash case full-screen-0.15-10hz-admit") == 0 && report.admitted == 0)
                refusals++;
            if (strncmp(name, "flash case full-screen", 22) == 0 && t == 1983.25) {
                /* Refusals zero a report except time_ms and leave the analyzer unchanged. */
                refusal_checks++;
                require(oscillux_flash_analyzer_measure(analyzer, 0, regions, count, &report) != OSCILLUX_OK &&
                            report.time_ms == 0 && report.flashes_in_window == 0 && report.exceeds == 0,
                        "backwards time refused");
                require(oscillux_flash_analyzer_measure(analyzer, 2000, regions, count - 1, &report) !=
                                OSCILLUX_OK &&
                            report.time_ms == 2000 && report.admitted == 0,
                        "wrong region count refused");
                require(oscillux_flash_analyzer_admit(analyzer, 2000, NULL, count, &report) != OSCILLUX_OK,
                        "null regions refused");
            }
        } else if (strcmp(tag, "rgbframe") == 0) {
            require(analyzer != NULL, "rgb frame before case");
            double t = number();
            if (unsigned_number() == 1) require(oscillux_flash_analyzer_reset(analyzer) == OSCILLUX_OK, "reset");
            for (size_t r = 0; r < count; r++) {
                colors[r].r = number();
                colors[r].g = number();
                colors[r].b = number();
            }
            OscilluxFlashReport report;
            int admit = strcmp(mode, "admit") == 0;
            int32_t status = admit ? oscillux_flash_analyzer_admit_rgb(analyzer, t, colors, count, &report)
                                   : oscillux_flash_analyzer_measure_rgb(analyzer, t, colors, count, &report);
            require(status == OSCILLUX_OK, "rgb frame status");
            expect_report(&report, t);
            require(oscillux_flash_analyzer_measure_rgb(analyzer, t, NULL, count, &report) == OSCILLUX_ERR_NULL,
                    "null colors refused");
        } else if (strcmp(tag, "color") == 0) {
            context = "flash color";
            double c[5];
            for (int k = 0; k < 5; k++) c[k] = number();
            OscilluxFlashRegion out;
            require(oscillux_flash_region_from_linear_rgb(c[0], c[1], c[2], &out) == OSCILLUX_OK, "color status");
            require(fabs(out.luminance - c[3]) <= tolerance && fabs(out.red - c[4]) <= tolerance, "color levels");
        } else if (strcmp(tag, "invalid") == 0) {
            context = "flash invalid color";
            double c[3];
            for (int k = 0; k < 3; k++) c[k] = number();
            OscilluxFlashRegion out = {0.5, 0.25};
            require(oscillux_flash_region_from_linear_rgb(c[0], c[1], c[2], &out) != OSCILLUX_OK &&
                        out.luminance == 0.5 && out.red == 0.25,
                    "invalid color refused");
        } else {
            fail("unknown region vector line");
        }
    }
    oscillux_flash_analyzer_destroy(analyzer);
    fclose(input);
    context = "flash summary";
    require(first_exceeds == 350 && refusals > 0 && cases >= 2 && iso_cases >= 4,
            "expected exceed time, refusals and ISO 9241-391 cases");
    /* Every full-screen case must reach the frame the refusal checks key on, or they never run. */
    require(full_screen_cases > 0 && refusal_checks == full_screen_cases, "refusal checks ran in every full-screen case");
    return cases;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: conformance_smoke <dsp-vectors> <region-vectors>\n");
        return 2;
    }
    context = "abi";
    require(oscillux_abi_version() == 1, "abi version");
    int fixtures = run_dsp(argv[1]);
    int cases = run_region(argv[2]);
    require(fixtures >= 8, "fewer DSP fixtures than expected");
    printf("conformance_smoke: abi %" PRIu32 ", %d DSP fixtures (bit-exact digests), %d region flash cases: PASS\n",
           oscillux_abi_version(), fixtures, cases);
    return 0;
}
