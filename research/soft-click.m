// Research tools used to find the replacement click: blind A/B comparisons, timed
// trials and a firmware report experiment. Not part of the app. See research/README.md.
#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../Sources/Haptics.h"
#include "native-click.h"

static int32_t play(const Trackpad *pad, float scale) {
    return play_waveform(pad, 6, scale);
}

static uint64_t deadline_after(double seconds) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return mach_continuous_time() + (uint64_t)(seconds * 1e9 * timebase.denom / timebase.numer);
}

typedef enum { Probe, WindowDemo, GlobalDemo, GlobalPair } Trial;

static NSWindow *make_window(NSString *title, CGFloat width, CGFloat height) {
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app finishLaunching];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = title;
    return window;
}

static void show_window(NSWindow *window) {
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
}

static NSEvent *next_window_event(void) {
    return [NSApp nextEventMatchingMask:NSEventMaskAny
                             untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                inMode:NSDefaultRunLoopMode dequeue:YES];
}

static NSWindow *show_test_window(float scale, double seconds) {
    NSWindow *window = make_window(@"Soft Click", 460, 150);
    NSTextField *label = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:@"Нажимай трекпадом внутри окна.\n"
                                   "Сила импульса: %.2f. Проба длится до %.0f с.\n"
                                   "Esc или закрытие окна вернут обычный щелчок.", scale, seconds]];
    label.font = [NSFont systemFontOfSize:15];
    label.frame = NSMakeRect(28, 25, 404, 98);
    [window.contentView addSubview:label];
    show_window(window);
    return window;
}

static bool handle_window_event(NSWindow *window, Demo *demo) {
    @autoreleasepool {
        NSEvent *event = next_window_event();
        if (event.type == NSEventTypeKeyDown && event.keyCode == kVK_Escape && event.window == window) {
            return false;
        }
        if (event.type == NSEventTypeLeftMouseDown && event.window == window) {
            NSView *content = window.contentView;
            if (NSPointInRect([content convertPoint:event.locationInWindow fromView:nil], content.bounds)) {
                click(demo);
            }
        }
        if (event) [NSApp sendEvent:event];
        return window.isVisible;
    }
}

static int try_pulse(Trackpad *pad, Trial trial, float scale, double seconds) {
    if (system_enabled(pad) != 1) {
        fputs("Expected system haptics on; no changes made. Run status or restore first.\n", stderr);
        return 1;
    }
    if (!watch_signals()) {
        fputs("Could not install interrupt handlers; no changes made.\n", stderr);
        return 1;
    }

    Demo demo = {.pad = pad, .scale = scale};
    if (trial == GlobalPair && !click_profile(&demo.pair_profile)) {
        fputs("Cannot read the built-in click profile; no changes made.\n", stderr);
        return 1;
    }
    ClickTap tap = {0};
    NSWindow *window = nil;
    if (trial == WindowDemo) {
        window = show_test_window(scale, seconds);
        if (!window.isVisible) {
            fputs("Could not show the test window; no changes made.\n", stderr);
            return 1;
        }
    } else if (trial == GlobalDemo || trial == GlobalPair) {
        if (!attach_click_tap(&tap, &demo)) {
            fputs("Cannot listen for clicks in this session; no changes made.\n"
                  "Run from the Mac's Terminal. If needed, allow Terminal in Input Monitoring.\n",
                  stderr);
            return 1;
        }
    }

    bool tried_to_mute = false;
    int result = 1;
    if (!interrupted) {
        tried_to_mute = true;
        if (!set_system_enabled(pad, 0)) {
            fputs("Could not verify that system haptics are off.\n", stderr);
        } else if (trial != Probe) {
            printf("System haptics off. Click %s for up to %.0f s (scale %.2f); Ctrl+C stops.\n",
                   window ? "inside the Soft Click window" : "normally", seconds, scale);
            fflush(stdout);
            uint64_t deadline = deadline_after(seconds);
            while (!interrupted && !demo.error && !demo.tap_disabled &&
                   mach_continuous_time() < deadline) {
                if (window) {
                    if (!handle_window_event(window, &demo)) break;
                } else {
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
                    if (!CGEventTapIsEnabled(tap.port)) demo.tap_disabled = true;
                }
            }
            printf("Replacement pulses accepted: %u\n", demo.count);
            if (demo.tap_disabled) fputs("The click listener stopped.\n", stderr);
            if (demo.error) fprintf(stderr, "Pulse failed: 0x%08x\n", (uint32_t)demo.error);
            result = demo.error || demo.tap_disabled;
        } else if (!interrupted) {
            puts("System haptics off (verified).");
            int32_t error = play(pad, scale);
            if (error) {
                fprintf(stderr, "Pulse failed: 0x%08x\n", (uint32_t)error);
            } else {
                printf("One test pulse accepted (scale %.2f).\n", scale);
                nanosleep(&(struct timespec){.tv_nsec = 150000000}, NULL);
                result = 0;
            }
        }
    }

    close_click_tap(&tap);
    if (tried_to_mute) {
        if (!set_system_enabled(pad, 1)) {
            fputs("Could not verify restoration. Run ./build/soft-click restore.\n", stderr);
            result = 1;
        } else {
            puts("System haptics on again (verified).");
        }
    }
    [window close];
    return result;
}

enum { RoundCount = 3, NoPreference = 2, Different = 3, NotSelected = -1 };
static const float comparison_scale = 0.35f;
static const NSRect sample_rect = {{24, 100}, {472, 80}};

typedef struct {
    int32_t waveform;
    int native_side;
    int vote;
} ComparisonRound;

static void shuffle_rounds(ComparisonRound rounds[RoundCount]) {
    // Tactile's three stock waveform IDs, all with the same requested scale.
    const int32_t waveforms[RoundCount] = {3, 4, 6};
    for (unsigned i = 0; i < RoundCount; i++) {
        rounds[i] = (ComparisonRound){waveforms[i], (int)arc4random_uniform(2), NotSelected};
    }
    for (unsigned i = RoundCount - 1; i > 0; i--) {
        unsigned j = arc4random_uniform(i + 1);
        ComparisonRound tmp = rounds[i];
        rounds[i] = rounds[j];
        rounds[j] = tmp;
    }
}

static NSString *side_name(int side) {
    return side == 0 ? @"A" : @"B";
}

static NSTextField *comparison_label(NSWindow *window, NSString *title, NSRect rect) {
    NSTextField *label = [NSTextField wrappingLabelWithString:title];
    label.font = [NSFont systemFontOfSize:15];
    label.frame = rect;
    [window.contentView addSubview:label];
    return label;
}

static void update_comparison(NSTextField *sample, NSTextField *prompt,
                              int round, int count, int selected, unsigned sampled, bool too_early) {
    sample.stringValue = selected == NotSelected
        ? @"Сначала выбери A или B на клавиатуре"
        : [NSString stringWithFormat:@"%@  ·  нажимай в этом поле", side_name(selected)];
    NSString *status = too_early ? @"Сначала нажми трекпадом в каждом варианте."
        : sampled == 3 ? @"Оба опробованы. Можно сравнить ещё раз или выбрать."
        : @"Попробуй оба варианта, прежде чем выбрать.";
    prompt.stringValue = [NSString stringWithFormat:@"Раунд %d из %d.  %@", round + 1, count, status];
}

static NSString *comparison_results(const ComparisonRound rounds[RoundCount], int first, int completed, bool pair) {
    NSMutableString *summary = [NSMutableString string];
    for (int i = first; i < completed; i++) {
        const ComparisonRound *r = &rounds[i];
        if (pair && i == 0) {
            [summary appendFormat:@"100%%: штатный %@, пара %@. %@.\n", side_name(r->native_side),
                side_name(1 - r->native_side), r->vote == Different
                    ? @"Разница есть. Пробу на 60% пропустили" : @"Разницы не заметил"];
            continue;
        }
        NSString *vote = r->vote == NoPreference ? @"без предпочтения" : side_name(r->vote);
        if (pair) {
            [summary appendFormat:@"60%%: штатный %@, пара %@. Выбор: %@.\n",
                side_name(r->native_side), side_name(1 - r->native_side), vote];
        } else {
            [summary appendFormat:@"%d. Штатный: %@ · Импульс %d: %@ · Выбор: %@\n",
                i + 1, side_name(r->native_side), r->waveform, side_name(1 - r->native_side), vote];
        }
    }
    return summary;
}

static int compare_clicks(Trackpad *pad, bool pair, int first) {
    if (system_enabled(pad) != 1 || !watch_signals()) {
        fputs("Comparison needs stock haptics on and working interrupt handlers. No changes made.\n", stderr);
        return 1;
    }
    ComparisonRound rounds[RoundCount];
    int total = pair ? 2 : RoundCount;
    uint32_t options = 0;
    if (pair) {
        if (!click_profile(&options)) {
            fputs("Cannot read the built-in click profile; no changes made.\n", stderr);
            return 1;
        }
        for (int i = 0; i < total; i++) {
            rounds[i] = (ComparisonRound){2, (int)arc4random_uniform(2), NotSelected};
        }
    } else {
        shuffle_rounds(rounds);
    }
    NSWindow *window = make_window(@"Soft Click · A/B", 520, 288);
    NSString *prefer = @"1 / 2: переключить A / B, затем нажимать трекпадом в поле.\n"
                        "Что приятнее?  ← A   → B   ↓ без предпочтения";
    NSTextField *instructions = comparison_label(window, pair && first == 0
        ? @"1 / 2: выбрать A / B. Нажми и отпусти трекпад в поле.\n"
           "Ощущения:  ↑ различаются   ↓ одинаковые"
        : prefer,
        NSMakeRect(24, 198, 472, 63));
    NSTextField *sample = comparison_label(window, @"", sample_rect);
    sample.alignment = NSTextAlignmentCenter;
    sample.font = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    sample.drawsBackground = YES;
    sample.backgroundColor = NSColor.controlBackgroundColor;
    sample.bezeled = YES;
    NSTextField *prompt = comparison_label(window, @"", NSMakeRect(24, 45, 472, 38));
    NSTextField *footer = comparison_label(window, @"Esc: выйти  ·  до 2 минут на весь тест",
                                            NSMakeRect(24, 16, 472, 22));
    int current = first, selected = NotSelected;
    unsigned sampled = 0;
    bool failed = false, was_key = false, held = false, finished = false;
    update_comparison(sample, prompt, current, total, selected, sampled, false);
    show_window(window);
    if (!window.isVisible) {
        fputs("Could not show comparison window; no changes made.\n", stderr);
        return 1;
    }

    uint64_t deadline = deadline_after(120);
    while (!finished && !interrupted && window.isVisible && !failed &&
           mach_continuous_time() < deadline) {
        @autoreleasepool {
            if (window.isKeyWindow) was_key = true;
            else if (was_key) break;
            NSEvent *event = next_window_event();
            if (interrupted || mach_continuous_time() >= deadline) break;
            if (event.window == window && event.type == NSEventTypeKeyDown) {
                switch (event.keyCode) {
                    case kVK_Escape:
                        [window orderOut:nil];
                        continue;
                    case kVK_ANSI_1:
                    case kVK_ANSI_2:
                    case kVK_ANSI_Keypad1:
                    case kVK_ANSI_Keypad2:
                        if (held) continue;
                        selected = event.keyCode == kVK_ANSI_1 || event.keyCode == kVK_ANSI_Keypad1 ? 0 : 1;
                        failed = !ensure_system_enabled(pad, selected == rounds[current].native_side);
                        update_comparison(sample, prompt, current, total, selected, sampled, false);
                        continue;
                    case kVK_LeftArrow:
                    case kVK_RightArrow:
                    case kVK_DownArrow:
                    case kVK_UpArrow: {
                        if (event.isARepeat || held) continue;
                        bool calibration = pair && current == 0;
                        if (calibration && event.keyCode != kVK_UpArrow && event.keyCode != kVK_DownArrow) continue;
                        if (!calibration && event.keyCode == kVK_UpArrow) continue;
                        if (sampled != 3) {
                            update_comparison(sample, prompt, current, total, selected, sampled, true);
                            continue;
                        }
                        int vote = event.keyCode == kVK_LeftArrow ? 0 : event.keyCode == kVK_RightArrow ? 1 :
                            event.keyCode == kVK_UpArrow ? Different : NoPreference;
                        rounds[current++].vote = vote;
                        failed = !ensure_system_enabled(pad, 1);
                        finished = current == total || (calibration && vote == Different);
                        selected = NotSelected;
                        sampled = 0;
                        if (!finished) {
                            instructions.stringValue = prefer;
                            update_comparison(sample, prompt, current, total, selected, sampled, false);
                        }
                        continue;
                    }
                    default:
                        break;
                }
            }
            if (selected != NotSelected && event.window == window &&
                event.type == NSEventTypeLeftMouseDown && NSPointInRect(event.locationInWindow, sample_rect)) {
                if (pair) {
                    if (!held && selected != rounds[current].native_side) {
                        failed = play_pair_edge(pad, true, options, current == 0 ? 1.0f : 0.6f) != 0;
                    }
                    held = true;
                    continue; // Do not let a text field's tracking loop consume mouseUp.
                }
                if (selected != rounds[current].native_side) {
                    failed = play_waveform(pad, rounds[current].waveform, comparison_scale) != 0;
                }
                if (!failed) {
                    sampled |= 1u << selected;
                    update_comparison(sample, prompt, current, total, selected, sampled, false);
                }
                continue; // The test area isn't an editable or selectable control.
            }
            if (held && event.type == NSEventTypeLeftMouseUp) {
                if (selected != rounds[current].native_side) {
                    failed = play_pair_edge(pad, false, options, current == 0 ? 1.0f : 0.6f) != 0;
                }
                held = false;
                if (!failed) {
                    sampled |= 1u << selected;
                    update_comparison(sample, prompt, current, total, selected, sampled, false);
                }
                continue;
            }
            if (event) [NSApp sendEvent:event];
        }
    }

    if (!ensure_system_enabled(pad, 1)) {
        fputs("Could not verify restoration. Run ./build/soft-click restore.\n", stderr);
        failed = true;
    } else {
        puts("System haptics on (verified).");
    }
    if (failed) fputs("Comparison stopped because the haptic API failed.\n", stderr);
    if (current > first) {
        NSString *summary = comparison_results(rounds, first, current, pair);
        printf("%s", summary.UTF8String);
        fflush(stdout);
        if (finished && !failed) {
            instructions.stringValue = @"Готово. Обычный щелчок восстановлен.";
            sample.hidden = YES;
            prompt.frame = NSMakeRect(24, 86, 472, 110);
            prompt.stringValue = summary;
            footer.stringValue = @"Esc: закрыть  ·  результаты также в Терминале";
            uint64_t results_deadline = deadline_after(30);
            while (!interrupted && window.isVisible && mach_continuous_time() < results_deadline) {
                @autoreleasepool {
                    NSEvent *event = next_window_event();
                    if (event.window == window && event.type == NSEventTypeKeyDown &&
                        event.keyCode == kVK_Escape) break;
                    if (event) [NSApp sendEvent:event];
                }
            }
        }
    }
    [window close];
    return failed;
}

static bool parse_number(const char *text, double min, double max, double *value) {
    char *end;
    errno = 0;
    double n = strtod(text, &end);
    if (errno || end == text || *end || !isfinite(n) || n < min || n > max) return false;
    *value = n;
    return true;
}

static void usage(FILE *out) {
    fputs("Usage: soft-click compare | compare-pair | compare-60 | status | restore | probe [scale] | {demo|global} [scale [seconds]]\n"
          "       soft-click global-pair [scale [seconds]] (defaults: 0.50, 30 seconds)\n"
          "       soft-click native-test [seconds [reduction-percent]] | restore-native\n"
          "Native reduction: 20 (default) or 40 percent.\n"
          "Scale: 0.05 to 0.75 (probe/demo/global default 0.35); duration: 1 to 30 seconds.\n", out);
}

static int run(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        usage(stdout);
        return 0;
    }
    const char *mode = argc > 1 ? argv[1] : "";
    bool native_test = strcmp(mode, "native-test") == 0, native_restore = strcmp(mode, "restore-native") == 0;
    if (native_test || native_restore) {
        double length = 15, reduction = NativeReductionDefault;
        if (argc > (native_test ? 4 : 2) || (argc >= 3 && !parse_number(argv[2], 1, 30, &length)) ||
            (argc == 4 && (!parse_number(argv[3], NativeReductionDefault, NativeReductionStrong, &reduction) ||
                           (reduction != NativeReductionDefault && reduction != NativeReductionStrong)))) {
            usage(stderr);
            return 2;
        }
        Trackpad pad = {0};
        int result = 1;
        if (open_trackpad(&pad, false) && (native_restore || system_enabled(&pad) == 1) && watch_signals()) {
            result = native_click_run(pad.library, pad.system_actuator, native_restore, length,
                                      (unsigned)reduction, &interrupted);
        } else {
            fputs("Built-in trackpad, stock haptics, or interrupt handling unavailable. No changes made.\n", stderr);
        }
        close_trackpad(&pad);
        return result;
    }
    bool status = strcmp(mode, "status") == 0, restore = strcmp(mode, "restore") == 0;
    bool probe = strcmp(mode, "probe") == 0, demo = strcmp(mode, "demo") == 0;
    bool global_pair = strcmp(mode, "global-pair") == 0;
    bool global = global_pair || strcmp(mode, "global") == 0;
    bool second_only = strcmp(mode, "compare-60") == 0;
    bool pair = second_only || strcmp(mode, "compare-pair") == 0;
    bool compare = pair || strcmp(mode, "compare") == 0;
    double scale = global_pair ? 0.50 : 0.35, seconds = global_pair ? 30 : 20;
    if ((!status && !restore && !probe && !demo && !global && !compare) ||
        argc > (demo || global ? 4 : probe ? 3 : 2) ||
        (argc >= 3 && !parse_number(argv[2], 0.05, 0.75, &scale)) ||
        (argc == 4 && !parse_number(argv[3], 1, 30, &seconds))) {
        usage(stderr);
        return 2;
    }
    Trackpad pad = {0};
    int result = 1;
    if (!open_trackpad(&pad, probe || demo || global || compare)) {
        fputs("Could not open the built-in trackpad or its haptic API. No changes made.\n", stderr);
    } else if (status) {
        long enabled = system_enabled(&pad);
        printf("System haptics: %s\n", enabled == 1 ? "on" : enabled == 0 ? "off" : "unknown");
        result = enabled != 0 && enabled != 1;
    } else if (restore) {
        result = !set_system_enabled(&pad, 1);
        puts(result ? "Could not verify restoration." : "System haptics on (verified).");
    } else if (compare) {
        result = compare_clicks(&pad, pair, second_only ? 1 : 0);
    } else {
        Trial trial = probe ? Probe : demo ? WindowDemo : global_pair ? GlobalPair : GlobalDemo;
        result = try_pulse(&pad, trial, (float)scale, seconds);
    }
    close_trackpad(&pad);
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        return run(argc, argv);
    }
}
