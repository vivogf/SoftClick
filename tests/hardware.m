// Run with `make hardware-test` on a Force Touch Mac with Soft Click quit. Substitutes only the
// session, permission and click tap, not the actuator: stock haptics are briefly muted and restored.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

static bool allow, enabled;
static void *context;
static CGEventMask watched;
static int errors;
static NSString *home;

static void receive(CFMachPortRef p, void *msg, CFIndex size, void *info) {
    (void)p; (void)msg; (void)size; (void)info;
}
static CFMachPortRef test_tap(CGEventTapLocation loc, CGEventTapPlacement place,
    CGEventTapOptions opt, CGEventMask mask, CGEventTapCallBack call, void *ctx) {
    (void)loc; (void)place; (void)call;
    watched = mask; context = ctx;
    if (opt != kCGEventTapOptionListenOnly) errors++;
    return allow ? CFMachPortCreate(NULL, receive, NULL, NULL) : NULL;
}
static bool test_enabled(CFMachPortRef p) { return p && enabled; }
static void test_enable(CFMachPortRef p, bool on) { (void)p; enabled = on; }
static CFDictionaryRef test_session(void) {
    return CFBridgingRetain(@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES});
}
static NSString *test_home(void) { return home; }
static bool test_preflight(void) { return allow; }
static bool test_request(void) { return allow; }
#define CGEventTapCreate test_tap
#define CGEventTapIsEnabled test_enabled
#define CGEventTapEnable test_enable
#define CGPreflightListenEventAccess test_preflight
#define CGRequestListenEventAccess test_request
#define CGSessionCopyCurrentDictionary test_session
#define NSHomeDirectory test_home
#define main app_main
#include "../Sources/Haptics.m"
#include "../Sources/App.m"
#undef main

static void exercise_pair(float expected) {
    Demo *d = context;
    CGEventMask button_edges = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                               CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                               CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
    if (!d || !enabled || system_enabled(d->pad) != 0 || d->scale != expected ||
        watched != button_edges) {
        errors++;
        return;
    }
    unsigned before = d->count;
    on_click(NULL, kCGEventLeftMouseDown, NULL, d);
    on_click(NULL, kCGEventLeftMouseDragged, NULL, d);
    on_click(NULL, kCGEventLeftMouseUp, NULL, d);
    if (d->count != before + 2 || d->held_buttons || d->error) errors++;
}

static void select_item(NSMenuItem *item) {
    if (!item || ![NSApp sendAction:item.action to:item.target from:item]) errors++;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 || !watch_signals()) return 2;
        russian = true;
        home = [NSString stringWithUTF8String:argv[1]];
        NSString *directory = [home stringByAppendingPathComponent:@"Library/Application Support/SoftClick"];
        int fd = open_feedback_owner(directory);
        Trackpad pad = {0};
        if (fd < 0 || !open_trackpad(&pad, false) || system_enabled(&pad) != 1) return 1;
        int duplicate = open_feedback_owner(directory);
        if (duplicate >= 0) { errors++; close(duplicate); }
        AppFeedback f = {0};
        if (start_app_feedback(&f, fd, 0.30f) != FeedbackPermission ||
            system_enabled(&pad) != 1 || lseek(fd, 0, SEEK_END) != 0) errors++;
        if (!set_system_enabled(&pad, 0)) return 1;
        if (app_feedback_recover(fd) != FeedbackOff ||
            start_app_feedback(&f, fd, 0.30f) != FeedbackUnavailable ||
            system_enabled(&pad) != 0) errors++;
        if (pwrite(fd, "1", 1, 0) != 1) { set_system_enabled(&pad, 1); return 1; }
        if (app_feedback_recover(fd) != FeedbackOff || system_enabled(&pad) != 1 ||
            lseek(fd, 0, SEEK_END) != 0) errors++;
        close(fd);

        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
        SoftClickApp *app = [[SoftClickApp alloc] init];
        NSString *domain = [NSString stringWithFormat:@"local.soft-click.test.%d", getpid()];
        app.defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        [app applicationDidFinishLaunching:[NSNotification notificationWithName:
            NSApplicationDidFinishLaunchingNotification object:NSApp]];
        NSMenu *menu = [[NSMenu alloc] init];
        [app menuNeedsUpdate:menu];
        if (![menu itemWithTitle:@"Нужен доступ к мониторингу ввода"] || ![menu itemWithTitle:@"Запускать при входе"] ||
            [[[menu itemWithTitle:@"Сила отклика"].submenu itemWithTitle:@"30%"] state] != NSControlStateValueOn) errors++;
        NSMenu *steps = [menu itemWithTitle:@"Сила отклика"].submenu;
        if (steps.numberOfItems != 10 || steps.itemArray.firstObject.tag != 10 ||
            ![steps itemWithTitle:@"100% (как штатный)"] || steps.itemArray.lastObject.tag != 100) errors++;
        select_item([menu itemWithTitle:@"Мягкий щелчок"]);
        [app menuNeedsUpdate:menu];
        if (![menu itemWithTitle:@"Штатный щелчок"] ||
            [menu itemWithTitle:@"Мягкий щелчок"].state != NSControlStateValueOff) errors++;

        select_item([[menu itemWithTitle:@"Сила отклика"].submenu itemWithTitle:@"50%"]);
        allow = true;
        select_item([menu itemWithTitle:@"Мягкий щелчок"]);
        exercise_pair(0.50f);
        select_item([[menu itemWithTitle:@"Сила отклика"].submenu itemWithTitle:@"10%"]);
        exercise_pair(0.10f);
        select_item([[menu itemWithTitle:@"Сила отклика"].submenu itemWithTitle:@"100% (как штатный)"]);
        exercise_pair(1.0f);
        select_item([[menu itemWithTitle:@"Сила отклика"].submenu itemWithTitle:@"30%"]);
        exercise_pair(0.30f);
        select_item([menu itemWithTitle:@"Мягкий щелчок"]);
        if (system_enabled(&pad) != 1) errors++;
        select_item([menu itemWithTitle:@"Мягкий щелчок"]);
        exercise_pair(0.30f);
        [app willSleep:nil];
        if (system_enabled(&pad) != 1) errors++;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.1, false);
        if (system_enabled(&pad) != 1) errors++;
        [app didWake:nil];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.1, false);
        exercise_pair(0.30f);
        [app applicationWillTerminate:[NSNotification notificationWithName:
            NSApplicationWillTerminateNotification object:NSApp]];
        fd = open_feedback_owner(directory);
        if (fd < 0 || lseek(fd, 0, SEEK_END) != 0 || system_enabled(&pad) != 1) errors++;
        if (fd >= 0) close(fd);
        if (system_enabled(&pad) != 1) set_system_enabled(&pad, 1);
        [app.defaults removePersistentDomainForName:domain];
        printf("Single owner, permission, orphan recovery, menu, 10-100%% strengths, sleep/wake and quit: %d errors.\n", errors);
        close_trackpad(&pad); return errors != 0;
    }
}
