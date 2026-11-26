#ifndef NATIVE_CLICK_H
#define NATIVE_CLICK_H

#include <signal.h>
#include <stdbool.h>

enum { NativeReductionDefault = 20, NativeReductionStrong = 40 };

int native_click_run(void *library, void *actuator, bool restore, double seconds, unsigned reduction,
                     const volatile sig_atomic_t *interrupted);

#endif
