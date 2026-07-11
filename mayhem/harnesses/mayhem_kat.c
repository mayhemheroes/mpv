/*
 * mayhem_kat.c — mayhem/test.sh's behavioral oracle (SPEC §6.3).
 *
 * mpv's OSS-Fuzz harnesses (fuzzers/*.c) drive libmpv's public client API in-process; there is no
 * separate "library API" distinct from what they already fuzz. So the KAT drives that SAME API
 * (mpv_create/mpv_set_option_string/mpv_initialize/mpv_set_property_string/mpv_get_property),
 * round-tripping a FIXED value through mpv's real property-dispatch code (player/command.c's
 * mp_property_udata, registered as the "user-data/<key>" property subtree) and asserting the
 * retrieved value is byte-exact. This is a real, deterministic known-answer test against the
 * project's own compiled+sanitized code — not an exit-code check.
 *
 * Built (by mayhem/build.sh) as ANOTHER meson `fuzzers`-style executable — mpv's meson.build adds
 * `-fsanitize=...,fuzzer` to EVERY link when `-Dfuzzers=true` (project-wide, not just files under
 * fuzzers/), so a plain `main()` here would collide with libFuzzer's own driver main. Instead this
 * ships as a libFuzzer target whose LLVMFuzzerTestOneInput() IGNORES the fuzz input and always runs
 * the same deterministic check; mayhem/test.sh invokes it as `mayhem_kat <any-file>`, which is
 * libFuzzer's standard single-input replay mode (run once on that file, exit 0 unless it crashes).
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <mpv/client.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    (void)data;
    (void)size;

    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mpv_create returned NULL\n");
        abort();
    }

    if (mpv_set_option_string(ctx, "vo", "null") < 0 ||
        mpv_set_option_string(ctx, "ao", "null") < 0) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mpv_set_option_string failed\n");
        abort();
    }
    if (mpv_initialize(ctx) < 0) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mpv_initialize failed\n");
        abort();
    }

    const char *key    = "user-data/mayhem_kat_probe";
    const char *expect = "mayhem-kat-4f9c2b17";

    if (mpv_set_property_string(ctx, key, expect) < 0) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mpv_set_property_string failed\n");
        abort();
    }

    // Read back via MPV_FORMAT_NODE (not MPV_FORMAT_STRING): user-data is stored as a generic
    // mpv_node, and mpv's generic property-to-STRING conversion path JSON-quotes node values —
    // reading the NODE directly gives the raw string mpv actually stored, byte-exact.
    mpv_node node;
    memset(&node, 0, sizeof node);
    if (mpv_get_property(ctx, key, MPV_FORMAT_NODE, &node) < 0) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mpv_get_property failed\n");
        abort();
    }
    if (node.format != MPV_FORMAT_STRING || !node.u.string ||
        strcmp(node.u.string, expect) != 0) {
        fprintf(stderr, "MAYHEM_KAT_FAIL: mismatch expect=%s got=%s (format=%d)\n",
                expect, (node.format == MPV_FORMAT_STRING && node.u.string) ? node.u.string : "(none)",
                node.format);
        abort();
    }

    printf("MAYHEM_KAT_OK expect=%s got=%s\n", expect, node.u.string);

    mpv_free_node_contents(&node);
    mpv_terminate_destroy(ctx);

    return 0;
}
