#include "native-click.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

enum { Press = 0, Release = 1, ReportCount = 2, ReportLimit = 512, Strength = 1 };
static const uint32_t report_ids[ReportCount] = {0x22, 0x23};
static const int32_t report_sizes[ReportCount] = {18, 3};
static const char backup_path[] = "native-click.backup";
static const uint8_t signature[] = {'S', 'C', 'N', 1};

typedef struct {
    uint8_t version[sizeof signature];
    uint8_t data[ReportCount][18];
} ClickReports;

typedef struct {
    ClickReports stock;
    uint8_t reduction;
} ClickBackup;

typedef struct {
    void *actuator;
    int32_t (*get)(void *, uint32_t, uint8_t *, int32_t, int32_t *);
    int32_t (*set)(void *, uint32_t, const uint8_t *, int32_t);
} ReportIO;

static bool sysctl_matches(const char *name, const char *expected) {
    char value[64] = {0};
    size_t size = sizeof value;
    return sysctlbyname(name, value, &size, NULL, 0) == 0 &&
        size == strlen(expected) + 1 && memcmp(value, expected, size) == 0;
}

static bool valid(const ClickReports *reports) {
    if (memcmp(reports->version, signature, sizeof signature) != 0) return false;
    for (int i = 0; i < ReportCount; i++) {
        if (reports->data[i][0] != 1 || reports->data[i][Strength] < 5) return false;
    }
    return true;
}

static bool read_reports(const ReportIO *io, ClickReports *reports) {
    *reports = (ClickReports){0};
    memcpy(reports->version, signature, sizeof signature);
    for (int i = 0; i < ReportCount; i++) {
        uint8_t buffer[ReportLimit] = {0};
        int32_t length = 0;
        int32_t code = io->get(io->actuator, report_ids[i], buffer, sizeof buffer, &length);
        if (code != 0 || length != report_sizes[i]) {
            fprintf(stderr, "Report 0x%02x read failed: status 0x%08x, length %d.\n",
                    report_ids[i], (uint32_t)code, length);
            return false;
        }
        memcpy(reports->data[i], buffer, (size_t)length);
    }
    return valid(reports);
}

static bool same_report(const ClickReports *a, const ClickReports *b, int i) {
    return memcmp(a->data[i], b->data[i], (size_t)report_sizes[i]) == 0;
}

static bool same_reports(const ClickReports *a, const ClickReports *b) {
    return same_report(a, b, Press) && same_report(a, b, Release);
}

static bool supported_reduction(unsigned reduction) {
    return reduction == NativeReductionDefault || reduction == NativeReductionStrong;
}

static ClickReports reduced(ClickReports stock, unsigned reduction) {
    for (int i = 0; i < ReportCount; i++) {
        // Apple omits the report ID from the payload returned by GetReport.
        stock.data[i][Strength] = (uint8_t)((stock.data[i][Strength] * (100 - reduction) + 50) / 100);
    }
    return stock;
}

static bool write_report(const ReportIO *io, const ClickReports *reports, int i) {
    int32_t code = io->set(io->actuator, report_ids[i], reports->data[i], report_sizes[i]);
    if (code == 0) return true;
    fprintf(stderr, "Report 0x%02x write failed: status 0x%08x.\n", report_ids[i], (uint32_t)code);
    return false;
}

static bool restore_reports(const ReportIO *io, const ClickReports *stock) {
    for (int attempt = 0; attempt < 2; attempt++) {
        ClickReports current;
        bool readable = read_reports(io, &current);
        if (readable && same_reports(&current, stock)) return true;
        for (int i = 0; i < ReportCount; i++) {
            if (!readable || !same_report(&current, stock, i)) write_report(io, stock, i);
        }
    }
    ClickReports checked;
    return read_reports(io, &checked) && same_reports(&checked, stock);
}

static int save_backup(const ClickReports *stock, unsigned reduction) {
    ClickBackup backup = {*stock, (uint8_t)reduction};
    int fd = open(backup_path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd == -1) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) == 0 &&
        write(fd, &backup, sizeof backup) == sizeof backup && fsync(fd) == 0) return fd;
    int saved = errno;
    unlink(backup_path);
    close(fd);
    errno = saved;
    return -1;
}

static int load_backup(ClickBackup *backup) {
    int fd = open(backup_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd == -1) return -1;
    struct stat info;
    // Legacy backups stored only the stock reports; those trials always used 20%.
    *backup = (ClickBackup){.reduction = NativeReductionDefault};
    if (flock(fd, LOCK_EX | LOCK_NB) == 0 && fstat(fd, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_uid == geteuid() &&
        (info.st_size == sizeof backup->stock || info.st_size == sizeof *backup) &&
        read(fd, backup, (size_t)info.st_size) == info.st_size &&
        valid(&backup->stock) && supported_reduction(backup->reduction)) return fd;
    close(fd);
    return -1;
}

static int finish(int fd, bool restored, bool success) {
    if (restored) {
        puts("Both original reports restored and verified byte for byte.");
        if (unlink(backup_path) != 0) {
            perror("Could not remove the verified backup");
            success = false;
        }
    } else {
        fputs("Could not verify restoration. Backup kept. Run ./build/soft-click restore-native from this directory.\n", stderr);
    }
    close(fd);
    return !(restored && success);
}

static int restore_backup(const ReportIO *io) {
    ClickBackup backup;
    ClickReports current;
    int fd = load_backup(&backup);
    if (fd == -1) {
        fputs("Backup missing, invalid or in use; no changes made.\n", stderr);
        return 1;
    }
    const ClickReports *stock = &backup.stock;
    ClickReports soft = reduced(*stock, backup.reduction);
    if (!read_reports(io, &current) ||
        (!same_report(&current, stock, Press) && !same_report(&current, &soft, Press)) ||
        (!same_report(&current, stock, Release) && !same_report(&current, &soft, Release))) {
        fputs("Current reports do not match this trial; not applying the backup.\n", stderr);
        close(fd);
        return 1;
    }
    return finish(fd, restore_reports(io, stock), true);
}

static int run_trial(const ReportIO *io, double seconds, unsigned reduction,
                     const volatile sig_atomic_t *interrupted) {
    ClickReports stock, checked;
    if (!read_reports(io, &stock) || !read_reports(io, &checked) || !same_reports(&stock, &checked)) {
        fputs("Could not confirm stable stock reports. No changes made.\n", stderr);
        return 1;
    }
    ClickReports soft = reduced(stock, reduction);
    if (!valid(&soft) || same_report(&stock, &soft, Press) || same_report(&stock, &soft, Release)) {
        fputs("The reported strengths are outside the supported range for this trial. No changes made.\n", stderr);
        return 1;
    }
    int fd = save_backup(&stock, reduction);
    if (fd == -1) {
        perror("Could not save native-click.backup; no changes made");
        return 1;
    }
    bool applied = false;
    if (!*interrupted) {
        applied = write_report(io, &soft, Press) && !*interrupted &&
                  write_report(io, &soft, Release) &&
                  read_reports(io, &checked) && same_reports(&soft, &checked);
        if (applied) {
            printf("Native click strength (press/release): %u/%u -> %u/%u. Only strength changed (verified).\n",
                   stock.data[Press][Strength], stock.data[Release][Strength],
                   soft.data[Press][Strength], soft.data[Release][Strength]);
            printf("Try normal clicks now for up to %g seconds. Ctrl+C restores stock early.\n", seconds);
            fflush(stdout);
            uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + (uint64_t)(seconds * 1e9);
            while (!*interrupted && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadline) {
                nanosleep(&(struct timespec){.tv_nsec = 50000000}, NULL);
            }
        } else {
            fputs("Could not verify both reduced reports; restoring now.\n", stderr);
        }
    }
    return finish(fd, restore_reports(io, &stock), applied || *interrupted);
}

int native_click_run(void *library, void *actuator, bool restore, double seconds, unsigned reduction,
                     const volatile sig_atomic_t *interrupted) {
    if (!restore && !supported_reduction(reduction)) return 2;
    // Private ABI and report layout confirmed only on this model and OS build.
    if (!sysctl_matches("hw.model", "Mac17,2") || !sysctl_matches("kern.osversion", "26B131")) {
        fputs("Native click trial is not verified on this Mac model or OS build. No changes made.\n", stderr);
        return 1;
    }
    ReportIO io = {actuator, dlsym(library, "MTActuatorGetReport"), dlsym(library, "MTActuatorSetReport")};
    if (!io.get || !io.set) {
        fputs("Trackpad report API unavailable. No changes made.\n", stderr);
        return 1;
    }
    return restore ? restore_backup(&io) : run_trial(&io, seconds, reduction, interrupted);
}
