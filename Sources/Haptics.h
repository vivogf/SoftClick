// Built-in Force Touch trackpad access and the replacement click pulse.
// See THIRD-PARTY.md for the source of the private API declarations.
#ifndef SOFT_CLICK_HAPTICS_H
#define SOFT_CLICK_HAPTICS_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void *library;
    CFArrayRef devices;
    void *system_actuator;
    void *pulse_actuator;
    long (*get_enabled)(void *);
    int32_t (*set_enabled)(void *, long);
    int32_t (*close_actuator)(void *);
    int32_t (*pulse)(void *, int32_t, uint32_t, float, float);
} Trackpad;

extern volatile sig_atomic_t interrupted;

bool watch_signals(void);
bool open_trackpad(Trackpad *pad, bool need_pulse);
void close_trackpad(Trackpad *pad);
long system_enabled(const Trackpad *pad);
bool set_system_enabled(const Trackpad *pad, long enabled);
bool ensure_system_enabled(const Trackpad *pad, long enabled);

int32_t play_waveform(const Trackpad *pad, int32_t waveform, float scale);
// The stock click: waveform 2 on press and 1 on release, with the click pressure profile.
int32_t play_pair_edge(const Trackpad *pad, bool down, uint32_t profile, float scale);
bool profile_options(long pressure, uint32_t *options);
bool click_profile(uint32_t *options);

typedef struct {
    Trackpad *pad;
    float scale;
    unsigned count;
    int32_t error;
    bool tap_disabled;
    uint32_t pair_profile; // Zero plays a single waveform 6 pulse on press only.
    uint32_t held_buttons;
} Demo;

void click(Demo *demo);
CGEventRef on_click(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info);

typedef struct {
    CFMachPortRef port;
    CFRunLoopSourceRef source;
} ClickTap;

void close_click_tap(ClickTap *tap);
bool attach_click_tap(ClickTap *tap, Demo *demo);

#endif
