#include "Haptics.h"
#include <dlfcn.h>

volatile sig_atomic_t interrupted;

static void stop(int signo) {
    interrupted = signo;
}

bool watch_signals(void) {
    struct sigaction action = {.sa_handler = stop};
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGTSTP};
    for (size_t i = 0; i < sizeof signals / sizeof *signals; i++) {
        if (sigaction(signals[i], &action, NULL) != 0) return false;
    }
    return true;
}

bool open_trackpad(Trackpad *pad, bool need_pulse) {
    pad->library = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!pad->library) return false;

    CFArrayRef (*list_devices)(void) = dlsym(pad->library, "MTDeviceCreateList");
    bool (*is_built_in)(void *) = dlsym(pad->library, "MTDeviceIsBuiltIn");
    void *(*get_actuator)(void *) = dlsym(pad->library, "MTDeviceGetMTActuator");
    pad->get_enabled = dlsym(pad->library, "MTActuatorGetSystemActuationsEnabled");
    pad->set_enabled = dlsym(pad->library, "MTActuatorSetSystemActuationsEnabled");
    if (!list_devices || !is_built_in || !get_actuator || !pad->get_enabled || !pad->set_enabled) {
        return false;
    }

    pad->devices = list_devices();
    if (!pad->devices) return false;
    void *device = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(pad->devices); i++) {
        void *candidate = (void *)CFArrayGetValueAtIndex(pad->devices, i);
        if (!is_built_in(candidate)) continue;
        void *actuator = get_actuator(candidate);
        if (!actuator) continue;
        pad->system_actuator = actuator;
        device = candidate;
        break;
    }
    if (!device) return false;
    if (!need_pulse) return true;

    int32_t (*get_id)(void *, uint64_t *) = dlsym(pad->library, "MTDeviceGetDeviceID");
    void *(*create_actuator)(uint64_t) = dlsym(pad->library, "MTActuatorCreateFromDeviceID");
    int32_t (*open_actuator)(void *) = dlsym(pad->library, "MTActuatorOpen");
    pad->close_actuator = dlsym(pad->library, "MTActuatorClose");
    pad->pulse = dlsym(pad->library, "MTActuatorActuate");
    if (!get_id || !create_actuator || !open_actuator || !pad->close_actuator || !pad->pulse) {
        return false;
    }
    uint64_t id = 0;
    if (get_id(device, &id) != 0 || !id) return false;
    void *actuator = create_actuator(id);
    if (!actuator) return false;
    if (open_actuator(actuator) != 0) {
        CFRelease(actuator);
        return false;
    }
    pad->pulse_actuator = actuator;
    return true;
}

void close_trackpad(Trackpad *pad) {
    if (pad->pulse_actuator) {
        pad->close_actuator(pad->pulse_actuator);
        CFRelease(pad->pulse_actuator);
    }
    if (pad->devices) CFRelease(pad->devices);
    if (pad->library) dlclose(pad->library);
}

long system_enabled(const Trackpad *pad) {
    return pad->get_enabled(pad->system_actuator);
}

bool set_system_enabled(const Trackpad *pad, long enabled) {
    return pad->set_enabled(pad->system_actuator, enabled) == 0 && system_enabled(pad) == enabled;
}

bool ensure_system_enabled(const Trackpad *pad, long enabled) {
    return system_enabled(pad) == enabled || set_system_enabled(pad, enabled);
}

int32_t play_waveform(const Trackpad *pad, int32_t waveform, float scale) {
    return pad->pulse(pad->pulse_actuator, waveform, 0, scale, 0);
}

int32_t play_pair_edge(const Trackpad *pad, bool down, uint32_t profile, float scale) {
    return pad->pulse(pad->pulse_actuator, down ? 2 : 1, profile, scale, 1.0f);
}

bool profile_options(long pressure, uint32_t *options) {
    if (pressure < 0 || pressure > 2) return false;
    // Host click profiles: light, medium and firm use option bits 1, 2 and 4.
    *options = 1u << pressure;
    return true;
}

bool click_profile(uint32_t *options) {
    Boolean found = false;
    CFIndex pressure = CFPreferencesGetAppIntegerValue(CFSTR("FirstClickThreshold"),
        CFSTR("com.apple.AppleMultitouchTrackpad"), &found);
    return found && profile_options(pressure, options);
}

void click(Demo *demo) {
    if (!interrupted && !demo->error && !demo->tap_disabled) {
        demo->error = play_waveform(demo->pad, 6, demo->scale);
        if (!demo->error) demo->count++;
    }
}

CGEventRef on_click(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    (void)proxy;
    Demo *demo = info;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        demo->tap_disabled = true;
    } else if (demo->pair_profile) {
        bool down = type == kCGEventLeftMouseDown;
        if ((down || type == kCGEventLeftMouseUp) && demo->held != down &&
            !interrupted && !demo->error && !demo->tap_disabled) {
            demo->error = play_pair_edge(demo->pad, down, demo->pair_profile, demo->scale);
            if (!demo->error) {
                demo->held = down;
                demo->count++;
            }
        }
    } else if (type == kCGEventLeftMouseDown) {
        click(demo);
    }
    return event;
}

void close_click_tap(ClickTap *tap) {
    if (tap->port) CGEventTapEnable(tap->port, false);
    if (tap->source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tap->source, kCFRunLoopCommonModes);
        CFRelease(tap->source);
    }
    if (tap->port) CFRelease(tap->port);
    *tap = (ClickTap){0};
}

bool attach_click_tap(ClickTap *tap, Demo *demo) {
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
    if (demo->pair_profile) mask |= CGEventMaskBit(kCGEventLeftMouseUp);
    tap->port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                 kCGEventTapOptionListenOnly, mask, on_click, demo);
    if (tap->port) tap->source = CFMachPortCreateRunLoopSource(NULL, tap->port, 0);
    if (tap->source) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), tap->source, kCFRunLoopCommonModes);
        CGEventTapEnable(tap->port, true);
        if (CGEventTapIsEnabled(tap->port)) return true;
    }
    close_click_tap(tap);
    return false;
}
