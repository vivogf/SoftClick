// Soft Click: a menu bar app that replaces the built-in trackpad's click feedback
// with the same press/release pulse pair at a lower strength.
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "Haptics.h"

static NSString *const RepositoryURL = @"https://github.com/vivogf/SoftClick";

static bool russian;
static NSString *T(NSString *en, NSString *ru) { return russian ? ru : en; }

static bool login_session_active(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue] &&
           ![session[@"CGSSessionScreenIsLocked"] boolValue];
}

// The locked owner file is empty unless this app muted the stock haptics and still owes a
// restore. The marker is written before muting and cleared only after the restore is read back,
// so a crash or force quit is repaired on the next launch.
static bool recover_haptics(int fd, Trackpad *pad) {
    return ensure_system_enabled(pad, 1) && ftruncate(fd, 0) == 0 && fsync(fd) == 0;
}

typedef enum {
    FeedbackOff, FeedbackActive, FeedbackPermission, FeedbackWaiting, FeedbackUnavailable,
    FeedbackNeedsRestore, FeedbackOwnerError
} FeedbackState;

typedef struct {
    Trackpad pad;
    ClickTap tap;
    Demo demo;
    bool owns_haptics;
} AppFeedback;

static bool stop_app_feedback(AppFeedback *feedback, int fd) {
    close_click_tap(&feedback->tap);
    bool restored = !feedback->owns_haptics || recover_haptics(fd, &feedback->pad);
    close_trackpad(&feedback->pad);
    *feedback = (AppFeedback){0};
    return restored;
}

static FeedbackState app_feedback_recover(int fd) {
    char marker = 0;
    ssize_t n = pread(fd, &marker, 1, 0);
    if (n == 0) return FeedbackOff;
    if (n != 1 || marker != '1') return FeedbackOwnerError;
    Trackpad pad = {0};
    bool restored = open_trackpad(&pad, false) && recover_haptics(fd, &pad);
    close_trackpad(&pad);
    return restored ? FeedbackOff : FeedbackNeedsRestore;
}

static FeedbackState start_app_feedback(AppFeedback *feedback, int fd, float scale) {
    if (!login_session_active()) return FeedbackWaiting;
    feedback->demo = (Demo){.pad = &feedback->pad, .scale = scale};
    FeedbackState state = FeedbackUnavailable;
    if (!click_profile(&feedback->demo.pair_profile) ||
        !open_trackpad(&feedback->pad, true) || system_enabled(&feedback->pad) != 1) goto done;
    if (!CGPreflightListenEventAccess() || !attach_click_tap(&feedback->tap, &feedback->demo)) {
        state = FeedbackPermission;
        goto done;
    }
    if (interrupted) goto done;
    if (pwrite(fd, "1", 1, 0) != 1 || fsync(fd) != 0) {
        state = FeedbackOwnerError;
        goto done;
    }
    feedback->owns_haptics = true;
    if (set_system_enabled(&feedback->pad, 0)) return FeedbackActive;
done:
    return stop_app_feedback(feedback, fd) ? state : FeedbackNeedsRestore;
}

static NSString *owner_directory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SoftClick"];
}

static int open_feedback_owner(NSString *directory) {
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:nil]) return -1;
    NSString *path = [directory stringByAppendingPathComponent:@"owner"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    struct stat s;
    if (fd >= 0 && fstat(fd, &s) == 0 && S_ISREG(s.st_mode) && s.st_uid == geteuid() &&
        s.st_size <= 1 && flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
    if (fd >= 0) close(fd);
    return -1;
}

enum { ScaleMin = 10, ScaleMax = 100, ScaleStep = 10, ScaleDefault = 30 };

static NSInteger sanitized_scale(NSInteger value) {
    return value >= ScaleMin && value <= ScaleMax && value % ScaleStep == 0 ? value : ScaleDefault;
}

@interface SoftClickApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, readonly) NSInteger scalePercent;
@end

@implementation SoftClickApp {
    NSStatusItem *_statusItem;
    NSTimer *_timer;
    AppFeedback _feedback;
    FeedbackState _state;
    int _owner;
    bool _asleep;
    bool _playbackFailed;
    NSTimeInterval _retryAt;
}

- (bool)enabled {
    return [self.defaults objectForKey:@"enabled"] == nil || [self.defaults boolForKey:@"enabled"];
}

- (NSInteger)scalePercent {
    return sanitized_scale([self.defaults integerForKey:@"scalePercent"]);
}

- (NSString *)statusText {
    switch (_state) {
        case FeedbackActive:
            return [NSString stringWithFormat:T(@"Soft click on · %ld%%", @"Мягкий щелчок · %ld%%"),
                                              (long)self.scalePercent];
        case FeedbackOff: return T(@"Stock click", @"Штатный щелчок");
        case FeedbackPermission: return T(@"Needs Input Monitoring access", @"Нужен доступ к мониторингу ввода");
        case FeedbackWaiting: return T(@"Waiting for an active session", @"Ожидание активного сеанса");
        case FeedbackUnavailable:
            return _playbackFailed ? T(@"Playback error · stock click", @"Ошибка воспроизведения · штатный щелчок")
                                   : T(@"Trackpad or stock haptics unavailable", @"Трекпад или штатный отклик недоступен");
        case FeedbackNeedsRestore: return T(@"Could not restore the stock click", @"Не удалось восстановить штатный отклик");
        case FeedbackOwnerError: return T(@"Can't access the click state file", @"Нет доступа к файлу состояния отклика");
    }
    return @"";
}

- (void)setFeedbackState:(FeedbackState)state {
    _state = state;
    NSString *symbol = state == FeedbackActive || state == FeedbackOff || state == FeedbackWaiting ?
        @"trackpad" : @"exclamationmark.triangle";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Soft Click"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.title = image ? @"" : @"SC";
    _statusItem.button.appearsDisabled = state == FeedbackOff || state == FeedbackWaiting;
    _statusItem.button.toolTip = [@"Soft Click: " stringByAppendingString:self.statusText];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _owner = -1;
    if (!self.defaults) self.defaults = NSUserDefaults.standardUserDefaults;
    if (watch_signals()) _owner = open_feedback_owner(owner_directory());
    // Another copy holds the owner lock and already handles the clicks.
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (_owner < 0 && bundleID) {
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
            if (other.processIdentifier != getpid() && !other.terminated) {
                [NSApp terminate:nil];
                return;
            }
        }
    }
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.menu = [[NSMenu alloc] initWithTitle:@"Soft Click"];
    _statusItem.menu.delegate = self;
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(sessionResigned:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(sessionBecameActive:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    if (self.enabled && !CGPreflightListenEventAccess()) CGRequestListenEventAccess();
    [self reconcile];
    __weak SoftClickApp *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf reconcile];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)reconcile {
    if (interrupted) { [NSApp terminate:nil]; return; }
    if (_owner < 0) { [self setFeedbackState:FeedbackOwnerError]; return; }
    bool sessionReady = !_asleep && login_session_active();
    if (_feedback.owns_haptics) {
        if (self.enabled && sessionReady && CGEventTapIsEnabled(_feedback.tap.port) &&
            !_feedback.demo.tap_disabled && !_feedback.demo.error && system_enabled(&_feedback.pad) == 0) return;
        if (_feedback.demo.error) _playbackFailed = true;
        if (!stop_app_feedback(&_feedback, _owner)) {
            [self setFeedbackState:FeedbackNeedsRestore];
            return;
        }
        _retryAt = 0;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < _retryAt) return;
    _retryAt = now + 3;
    FeedbackState state = app_feedback_recover(_owner);
    if (state == FeedbackOff && self.enabled) {
        state = _playbackFailed ? FeedbackUnavailable : !sessionReady ? FeedbackWaiting :
            start_app_feedback(&_feedback, _owner, (float)self.scalePercent / 100.0f);
    }
    [self setFeedbackState:state];
}

- (void)sessionResigned:(NSNotification *)notification {
    (void)notification;
    if (_owner < 0) return;
    bool restored = stop_app_feedback(&_feedback, _owner);
    if (!restored) [self setFeedbackState:FeedbackNeedsRestore];
    else if (_state == FeedbackActive) [self setFeedbackState:FeedbackWaiting];
    _retryAt = NSProcessInfo.processInfo.systemUptime + 3;
}

- (void)willSleep:(NSNotification *)notification {
    _asleep = true;
    [self sessionResigned:notification];
}

- (void)didWake:(NSNotification *)notification {
    _asleep = false;
    [self sessionBecameActive:notification];
}

- (void)sessionBecameActive:(NSNotification *)notification {
    (void)notification;
    _retryAt = NSProcessInfo.processInfo.systemUptime + 2;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_timer invalidate];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    if (_owner >= 0) {
        stop_app_feedback(&_feedback, _owner);
        if (app_feedback_recover(_owner) == FeedbackNeedsRestore)
            NSLog(@"Could not restore stock haptics. Reopen Soft Click to retry.");
        close(_owner);
        _owner = -1;
    }
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSMenuItem *header = [self item:self.statusText action:nil];
    header.enabled = NO;
    [menu addItem:header];
    if (_state == FeedbackPermission) {
        [menu addItem:[self item:T(@"Open Input Monitoring Settings…", @"Открыть настройки мониторинга ввода…")
                          action:@selector(openInputMonitoring)]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *toggle = [self item:T(@"Soft Click", @"Мягкий щелчок") action:@selector(toggleEnabled)];
    toggle.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:toggle];
    NSMenuItem *strength = [self item:T(@"Strength", @"Сила отклика") action:nil];
    strength.submenu = [[NSMenu alloc] initWithTitle:strength.title];
    for (NSInteger value = ScaleMin; value <= ScaleMax; value += ScaleStep) {
        NSString *title = value == ScaleMax ? T(@"100% (like stock)", @"100% (как штатный)")
                                            : [NSString stringWithFormat:@"%ld%%", (long)value];
        NSMenuItem *entry = [self item:title action:@selector(chooseScale:)];
        entry.tag = value;
        entry.state = value == self.scalePercent ? NSControlStateValueOn : NSControlStateValueOff;
        [strength.submenu addItem:entry];
    }
    [menu addItem:strength];
    NSMenuItem *login = [self item:T(@"Launch at Login", @"Запускать при входе") action:@selector(toggleLogin)];
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    login.state = loginStatus == SMAppServiceStatusEnabled ? NSControlStateValueOn :
        loginStatus == SMAppServiceStatusRequiresApproval ? NSControlStateValueMixed : NSControlStateValueOff;
    [menu addItem:login];
    [menu addItem:NSMenuItem.separatorItem];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSMenuItem *versionItem = [self item:[NSString stringWithFormat:T(@"Version %@", @"Версия %@"), version] action:nil];
    versionItem.enabled = NO;
    [menu addItem:versionItem];
    [menu addItem:[self item:T(@"Soft Click on GitHub", @"Soft Click на GitHub") action:@selector(openRepository)]];
    NSMenuItem *quit = [self item:T(@"Quit Soft Click", @"Выйти из Soft Click") action:@selector(quit)];
    quit.keyEquivalent = @"q";
    [menu addItem:quit];
}

- (void)toggleEnabled {
    [self.defaults setBool:!self.enabled forKey:@"enabled"];
    _retryAt = 0;
    _playbackFailed = false;
    [self reconcile];
}

- (void)chooseScale:(NSMenuItem *)sender {
    [self.defaults setInteger:sanitized_scale(sender.tag) forKey:@"scalePercent"];
    if (_feedback.owns_haptics) _feedback.demo.scale = (float)self.scalePercent / 100.0f;
    [self setFeedbackState:_state];
}

- (void)openInputMonitoring {
    CGRequestListenEventAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)openRepository {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:RepositoryURL]];
}

- (void)toggleLogin {
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }
    NSError *error = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&error] :
        [service registerAndReturnError:&error];
    if (!ok && error) {
        if (@available(macOS 14.0, *)) [NSApp activate];
        else [NSApp activateIgnoringOtherApps:YES];
        [[NSAlert alertWithError:error] runModal];
    } else if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
}

- (void)quit { [NSApp terminate:nil]; }
@end

static int run_menu_app(void) {
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    __attribute__((objc_precise_lifetime)) SoftClickApp *delegate = [[SoftClickApp alloc] init];
    app.delegate = delegate;
    [app run];
    return 0;
}

// Hardware-free checks for CI: the pulse sequence, strength steps and settings handling.
typedef struct { int32_t waveform; uint32_t profile; float scale, duration; } Pulse;
static Pulse pulses[8];
static int pulse_count;
static int32_t pulse_result;

static int32_t fake_pulse(void *actuator, int32_t waveform, uint32_t profile, float scale, float duration) {
    (void)actuator;
    if (pulse_count < 8) pulses[pulse_count] = (Pulse){waveform, profile, scale, duration};
    pulse_count++;
    return pulse_result;
}

static int failures;
static void check(bool ok, const char *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static bool pulse_is(int i, int32_t waveform, uint32_t profile, float scale) {
    return pulses[i].waveform == waveform && pulses[i].profile == profile &&
           pulses[i].scale == scale && pulses[i].duration == 1.0f;
}

static void test_other_click(Demo *demo, CGEventType type, CGMouseButton button) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, CGPointZero, button);
    if (event) {
        on_click(NULL, type, event, demo);
        CFRelease(event);
    } else {
        check(false, "create a test mouse event");
    }
}

static void test_mouse_buttons(Trackpad *pad) {
    Demo demo = {.pad = pad, .scale = 0.5f, .pair_profile = 2};
    pulse_count = 0;
    on_click(NULL, kCGEventRightMouseDown, NULL, &demo);
    on_click(NULL, kCGEventRightMouseDragged, NULL, &demo);
    on_click(NULL, kCGEventRightMouseDown, NULL, &demo);
    on_click(NULL, kCGEventRightMouseUp, NULL, &demo);
    on_click(NULL, kCGEventRightMouseUp, NULL, &demo);
    check(pulse_count == 2 && pulse_is(0, 2, 2, 0.5f) && pulse_is(1, 1, 2, 0.5f) && !demo.held_buttons,
          "right click plays one press/release pair at the selected profile and strength");

    pulse_count = 0;
    test_other_click(&demo, kCGEventOtherMouseDown, kCGMouseButtonCenter);
    test_other_click(&demo, kCGEventOtherMouseUp, kCGMouseButtonCenter);
    check(pulse_count == 2 && pulse_is(0, 2, 2, 0.5f) && pulse_is(1, 1, 2, 0.5f) && !demo.held_buttons,
          "other-button click plays the same press/release pair");

    pulse_count = 0;
    on_click(NULL, kCGEventLeftMouseDown, NULL, &demo);
    on_click(NULL, kCGEventRightMouseDown, NULL, &demo);
    test_other_click(&demo, kCGEventOtherMouseDown, (CGMouseButton)3);
    on_click(NULL, kCGEventRightMouseUp, NULL, &demo);
    on_click(NULL, kCGEventLeftMouseUp, NULL, &demo);
    test_other_click(&demo, kCGEventOtherMouseUp, kCGMouseButtonCenter);
    int before_release = pulse_count;
    check(before_release == 1 && pulse_is(0, 2, 2, 0.5f) && demo.held_buttons,
          "overlapping presses and unmatched releases do not play extra pulses");
    test_other_click(&demo, kCGEventOtherMouseUp, (CGMouseButton)3);
    check(before_release == 1 && pulse_count == 2 && pulse_is(1, 1, 2, 0.5f) && !demo.held_buttons,
          "only the last held button plays a release pulse");

    Demo single = {.pad = pad, .scale = 0.4f};
    pulse_count = 0;
    on_click(NULL, kCGEventRightMouseDown, NULL, &single);
    test_other_click(&single, kCGEventOtherMouseDown, kCGMouseButtonCenter);
    on_click(NULL, kCGEventRightMouseUp, NULL, &single);
    test_other_click(&single, kCGEventOtherMouseUp, kCGMouseButtonCenter);
    check(pulse_count == 1 && !single.held_buttons, "single-pulse mode plays right press only across overlapping clicks");
    test_other_click(&single, kCGEventOtherMouseDown, kCGMouseButtonCenter);
    test_other_click(&single, kCGEventOtherMouseUp, kCGMouseButtonCenter);
    check(pulse_count == 2 && pulses[0].waveform == 6 && pulses[1].waveform == 6 &&
          pulses[1].profile == 0 && pulses[1].scale == 0.4f && pulses[1].duration == 0.0f &&
          !single.held_buttons, "single-pulse mode plays waveform 6 on other-button press and rearms on release");
}

static int self_test(void) {
    Trackpad pad = {.pulse = fake_pulse};
    Demo demo = {.pad = &pad, .scale = 0.3f, .pair_profile = 1};
    on_click(NULL, kCGEventLeftMouseDown, NULL, &demo);
    on_click(NULL, kCGEventLeftMouseDragged, NULL, &demo);
    on_click(NULL, kCGEventLeftMouseDown, NULL, &demo);
    check(pulse_count == 1 && pulse_is(0, 2, 1, 0.3f), "press plays waveform 2 once, drags are ignored");
    on_click(NULL, kCGEventLeftMouseUp, NULL, &demo);
    on_click(NULL, kCGEventLeftMouseUp, NULL, &demo);
    check(pulse_count == 2 && pulse_is(1, 1, 1, 0.3f) && !demo.held_buttons, "release plays waveform 1 once");
    demo.scale = 0.7f;
    on_click(NULL, kCGEventLeftMouseDown, NULL, &demo);
    check(pulse_count == 3 && pulse_is(2, 2, 1, 0.7f), "a new strength applies to the next click");
    on_click(NULL, kCGEventTapDisabledByTimeout, NULL, &demo);
    on_click(NULL, kCGEventLeftMouseUp, NULL, &demo);
    check(demo.tap_disabled && pulse_count == 3, "no pulses after the listener is disabled");
    Demo failing = {.pad = &pad, .scale = 0.3f, .pair_profile = 4};
    pulse_result = 5;
    on_click(NULL, kCGEventLeftMouseDown, NULL, &failing);
    on_click(NULL, kCGEventLeftMouseUp, NULL, &failing);
    check(failing.error == 5 && pulse_count == 4 && !failing.held_buttons, "a failed pulse stops playback");
    pulse_result = 0;
    test_mouse_buttons(&pad);

    uint32_t options = 0;
    bool light = profile_options(0, &options) && options == 1;
    bool medium = profile_options(1, &options) && options == 2;
    bool firm = profile_options(2, &options) && options == 4;
    check(light && medium && firm && !profile_options(3, &options) && !profile_options(-1, &options),
          "light, medium and firm click profiles map to options 1, 2 and 4");

    NSString *suite = [NSString stringWithFormat:@"io.github.vivogf.SoftClick.selftest.%d", getpid()];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    SoftClickApp *app = [[SoftClickApp alloc] init];
    app.defaults = defaults;
    bool steps = app.scalePercent == ScaleDefault;
    for (NSInteger v = 0; v <= 110; v += 5) {
        [defaults setInteger:v forKey:@"scalePercent"];
        bool valid = v >= 10 && v <= 100 && v % 10 == 0;
        steps = steps && app.scalePercent == (valid ? v : ScaleDefault);
    }
    [defaults removePersistentDomainForName:suite];
    check(steps, "strength accepts 10% to 100% in 10% steps, defaults to 30%");
    puts(failures ? "self-test failed" : "self-test passed");
    return failures != 0;
}

static int diagnose(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    printf("Soft Click %s on macOS %s\n", version.UTF8String,
           NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    Trackpad pad = {0};
    bool found = open_trackpad(&pad, false);
    long enabled = found ? system_enabled(&pad) : -1;
    close_trackpad(&pad);
    pad = (Trackpad){0};
    bool pulse = open_trackpad(&pad, true);
    close_trackpad(&pad);
    printf("built-in Force Touch trackpad: %s\n", found ? "found" : "not found");
    printf("haptic pulse API: %s\n", pulse ? "available" : "unavailable");
    printf("stock haptics: %s\n", enabled == 1 ? "on" : enabled == 0 ? "off" : "unknown");
    uint32_t options = 0;
    const char *profiles[] = {"", "light", "medium", "", "firm"};
    printf("click pressure: %s\n", click_profile(&options) ? profiles[options] : "unknown");
    printf("input monitoring: %s\n", CGPreflightListenEventAccess() ? "granted" : "not granted");
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    bool on = [defaults objectForKey:@"enabled"] == nil || [defaults boolForKey:@"enabled"];
    printf("setting: %s, strength %ld%%\n", on ? "on" : "off",
           (long)sanitized_scale([defaults integerForKey:@"scalePercent"]));
    NSString *path = [owner_directory() stringByAppendingPathComponent:@"owner"];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    printf("restore pending: %s\n", !attrs ? "no" : attrs.fileSize ? "yes (Soft Click owns muted haptics)" : "no");
    const char *login[] = {"not registered", "enabled", "requires approval", "not found"};
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    printf("launch at login: %s\n", status <= SMAppServiceStatusNotFound ? login[status] : "unknown");
    return 0;
}

static int restore(void) {
    int fd = open_feedback_owner(owner_directory());
    if (fd < 0) {
        fputs("Soft Click is running or its state file is unavailable. Quit it first.\n", stderr);
        return 1;
    }
    Trackpad pad = {0};
    bool ok = open_trackpad(&pad, false) && recover_haptics(fd, &pad);
    close_trackpad(&pad);
    close(fd);
    puts(ok ? "Stock haptics on (verified)." : "Could not restore stock haptics.");
    return !ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        russian = [NSLocale.preferredLanguages.firstObject hasPrefix:@"ru"];
        if (argc == 2 && strcmp(argv[1], "--selftest") == 0) return self_test();
        if (argc == 2 && strcmp(argv[1], "--diagnose") == 0) return diagnose();
        if (argc == 2 && strcmp(argv[1], "--restore") == 0) return restore();
        if (argc == 2 && strcmp(argv[1], "--help") == 0) {
            puts("Usage: SoftClick [--diagnose | --restore | --selftest]\n"
                 "Without options it runs as a menu bar app.");
            return 0;
        }
        return run_menu_app();
    }
}
