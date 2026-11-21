// cpufan — run the Mac's fans from CPU temperature only, ignoring battery sensors.
//
//   cpufan status            show CPU temperature and fan state (no root needed)
//   cpufan probe             list every fan/temperature key the SMC exposes
//   cpufan run [LOW HIGH]    control fans: minimum RPM at <= LOW C, maximum at >= HIGH C,
//                            straight line in between (default 55 85). Needs root.
//   cpufan auto              hand the fans back to macOS. Needs root.
//   cpufan watch             print a JSON line of readings every 2 seconds (for the app)
//
// While the file PAUSE_FILE exists, "run" leaves the fans to macOS. The menu bar app creates
// and removes it to stop and start CPU control without asking for a password each time.
//
// Build: clang -O2 -Wall -framework IOKit -o cpufan cpufan.c

#include <IOKit/IOKitLib.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// ---- SMC plumbing -------------------------------------------------------------------------

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_t keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_data_t;
_Static_assert(sizeof(smc_data_t) == 80, "SMC struct layout");

static io_connect_t conn;

static uint32_t k2u(const char *k) {
    return ((uint32_t)k[0] << 24) | ((uint32_t)k[1] << 16) | ((uint32_t)k[2] << 8) | (uint32_t)k[3];
}
static void u2k(uint32_t v, char out[5]) {
    out[0] = v >> 24; out[1] = v >> 16; out[2] = v >> 8; out[3] = v; out[4] = 0;
}

static bool smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS;
}

static bool smc_call(smc_data_t *in, smc_data_t *out) {
    size_t sz = sizeof(*out);
    memset(out, 0, sizeof(*out));
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &sz);
    return kr == KERN_SUCCESS && out->result == 0;
}

static bool smc_info(uint32_t key, smc_keyinfo_t *info) {
    smc_data_t in = {0}, out;
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (!smc_call(&in, &out)) return false;
    *info = out.keyInfo;
    return true;
}

static bool smc_read_u(uint32_t key, smc_keyinfo_t *info, uint8_t bytes[32]) {
    if (!smc_info(key, info)) return false;
    smc_data_t in = {0}, out;
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (!smc_call(&in, &out)) return false;
    memcpy(bytes, out.bytes, 32);
    return true;
}

// Decode a value in whatever format the SMC stores it. NAN if unknown/unreadable.
static double decode(const smc_keyinfo_t *info, const uint8_t *b) {
    char t[5];
    u2k(info->dataType, t);
    if (!strcmp(t, "flt ") && info->dataSize == 4) { float f; memcpy(&f, b, 4); return f; }
    if (!strcmp(t, "ui8 ")) return b[0];
    if (!strcmp(t, "ui16")) return (b[0] << 8) | b[1];
    if (!strcmp(t, "ui32")) return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | (b[2] << 8) | b[3];
    if (!strcmp(t, "sp78")) return (int16_t)((b[0] << 8) | b[1]) / 256.0;
    if (!strcmp(t, "fpe2")) return ((b[0] << 8) | b[1]) / 4.0;
    return NAN;
}

static double smc_get(const char *key) {
    smc_keyinfo_t info;
    uint8_t b[32];
    if (!smc_read_u(k2u(key), &info, b)) return NAN;
    return decode(&info, b);
}

// Write a number, encoded in the key's own format.
static bool smc_set(const char *key, double v) {
    smc_keyinfo_t info;
    if (!smc_info(k2u(key), &info)) return false;
    char t[5];
    u2k(info.dataType, t);
    smc_data_t in = {0}, out;
    in.key = k2u(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = info.dataSize;
    if (!strcmp(t, "flt ")) { float f = (float)v; memcpy(in.bytes, &f, 4); }
    else if (!strcmp(t, "ui8 ")) in.bytes[0] = (uint8_t)v;
    else if (!strcmp(t, "fpe2")) { uint16_t u = (uint16_t)(v * 4); in.bytes[0] = u >> 8; in.bytes[1] = u; }
    else if (!strcmp(t, "ui16")) { uint16_t u = (uint16_t)v; in.bytes[0] = u >> 8; in.bytes[1] = u; }
    else return false;
    return smc_call(&in, &out);
}

static int key_count(void) {
    double n = smc_get("#KEY");
    return isnan(n) ? 0 : (int)n;
}

static bool key_at(int i, char out[5]) {
    smc_data_t in = {0}, o;
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = (uint32_t)i;
    if (!smc_call(&in, &o)) return false;
    u2k(o.key, out);
    return true;
}

// ---- CPU temperature ----------------------------------------------------------------------

#define MAX_SENSORS 64
static char sensors[MAX_SENSORS][5];
static int nsensors;

static bool plausible(double c) { return !isnan(c) && c > 5 && c < 130; }

// Apple Silicon CPU die sensors are "Tp??"; Intel CPU sensors are "TC??". Battery sensors
// ("TB??") and everything else are deliberately ignored.
static void find_cpu_sensors(void) {
    int n = key_count();
    nsensors = 0;
    for (int pass = 0; pass < 2 && nsensors == 0; pass++) {
        const char *prefix = pass == 0 ? "Tp" : "TC";
        for (int i = 0; i < n && nsensors < MAX_SENSORS; i++) {
            char k[5];
            if (!key_at(i, k) || strncmp(k, prefix, 2)) continue;
            if (plausible(smc_get(k))) memcpy(sensors[nsensors++], k, 5);
        }
    }
}

// Hottest CPU sensor right now, or NAN if none could be read.
static double cpu_temp(void) {
    double hi = NAN;
    for (int i = 0; i < nsensors; i++) {
        double c = smc_get(sensors[i]);
        if (plausible(c) && (isnan(hi) || c > hi)) hi = c;
    }
    return hi;
}

// ---- Fans ---------------------------------------------------------------------------------

#define MAX_FANS 4
static int nfans;
static double fan_min[MAX_FANS], fan_max[MAX_FANS];
static bool used_ftst;

static void fkey(char out[5], int fan, const char *suffix) { snprintf(out, 5, "F%d%s", fan, suffix); }

static double fan_get(int fan, const char *suffix) { char k[5]; fkey(k, fan, suffix); return smc_get(k); }
static bool fan_set(int fan, const char *suffix, double v) { char k[5]; fkey(k, fan, suffix); return smc_set(k, v); }

static void load_fans(void) {
    double n = smc_get("FNum");
    nfans = isnan(n) ? 0 : (int)n;
    if (nfans > MAX_FANS) nfans = MAX_FANS;
    for (int f = 0; f < nfans; f++) {
        fan_min[f] = fan_get(f, "Mn");
        fan_max[f] = fan_get(f, "Mx");
    }
}

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...) {
    time_t now = time(NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    printf("%s  ", ts);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

// Put every fan in manual mode. The SMC takes a moment to report the new mode, so wait for
// it. Some Apple Silicon firmware also needs the "Ftst" (fan test) key set first; try that
// as a fallback where the key exists.
static bool manual_mode(void) {
    for (int attempt = 0; attempt < 2; attempt++) {
        for (int f = 0; f < nfans; f++) fan_set(f, "Md", 1);
        for (int i = 0; i < 12; i++) {
            bool ok = true;
            for (int f = 0; f < nfans; f++) ok &= fan_get(f, "Md") == 1;
            if (ok) return true;
            usleep(250 * 1000);
        }
        if (attempt == 0 && smc_set("Ftst", 1)) used_ftst = true;
        else break;
    }
    return false;
}

static void auto_mode(void) {
    for (int f = 0; f < nfans; f++) fan_set(f, "Md", 0);
    if (used_ftst || smc_get("Ftst") == 1) smc_set("Ftst", 0);
    used_ftst = false;
}

#define PAUSE_FILE "/Library/Application Support/cpufan/paused"

// ---- Commands -----------------------------------------------------------------------------

static volatile sig_atomic_t stop;
static void on_signal(int sig) { (void)sig; stop = 1; }

static int cmd_run(double low, double high) {
    if (geteuid() != 0) { fprintf(stderr, "cpufan run needs root (sudo).\n"); return 1; }
    load_fans();
    find_cpu_sensors();
    if (nfans == 0) { fprintf(stderr, "No fans found.\n"); return 1; }
    if (nsensors == 0) { fprintf(stderr, "No CPU temperature sensors found.\n"); return 1; }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    logmsg("start: %d fan(s), %d CPU sensors, %.0f-%.0f C curve", nfans, nsensors, low, high);
    bool manual = false, paused = false;
    int failures = 0;
    double smooth = NAN, last_rpm[MAX_FANS], logged_rpm[MAX_FANS];
    for (int f = 0; f < nfans; f++) last_rpm[f] = logged_rpm[f] = -1;

    while (!stop) {
        if (access(PAUSE_FILE, F_OK) == 0) {
            if (!paused) {
                auto_mode();
                manual = false;
                paused = true;
                logmsg("paused: fans back on automatic");
            }
            sleep(2);
            continue;
        }
        if (paused) { paused = false; logmsg("resumed"); }

        double t = cpu_temp();
        if (isnan(t)) {
            // Can't see the CPU: give control back to macOS rather than guess.
            if (++failures == 3 && manual) {
                auto_mode();
                manual = false;
                logmsg("CPU temperature unreadable; fans back on automatic");
            }
            sleep(2);
            continue;
        }
        failures = 0;
        smooth = isnan(smooth) ? t : smooth + 0.3 * (t - smooth);
        // React to heat immediately, cool down gently.
        if (t > smooth) smooth = t;

        // Re-assert manual mode every pass: sleep/wake or macOS can reset it.
        bool need = !manual;
        for (int f = 0; f < nfans && !need; f++) need = fan_get(f, "Md") != 1;
        if (need) {
            if (!manual_mode()) {
                logmsg("SMC refused manual fan mode; leaving fans on automatic");
                auto_mode();
                manual = false;
                sleep(10);
                continue;
            }
            if (!manual) logmsg("fans on CPU control%s", used_ftst ? " (via Ftst)" : "");
            manual = true;
            for (int f = 0; f < nfans; f++) last_rpm[f] = -1;
        }

        double frac = (smooth - low) / (high - low);
        frac = frac < 0 ? 0 : frac > 1 ? 1 : frac;
        for (int f = 0; f < nfans; f++) {
            double rpm = round(fan_min[f] + frac * (fan_max[f] - fan_min[f]));
            if (last_rpm[f] < 0 || fabs(rpm - last_rpm[f]) >= 50) {
                if (fan_set(f, "Tg", rpm)) last_rpm[f] = rpm;
            }
            if (logged_rpm[f] < 0 || fabs(rpm - logged_rpm[f]) >= 500) {
                logmsg("CPU %.1f C -> fan %d target %.0f RPM", t, f, rpm);
                logged_rpm[f] = rpm;
            }
        }
        sleep(2);
    }

    auto_mode();
    logmsg("stop: fans back on automatic");
    return 0;
}

static int cmd_status(void) {
    load_fans();
    find_cpu_sensors();
    double t = cpu_temp();
    printf("CPU temperature: %s", isnan(t) ? "unreadable" : "");
    if (!isnan(t)) printf("%.1f C (hottest of %d sensors)", t, nsensors);
    printf("\n");
    for (int f = 0; f < nfans; f++) {
        double md = fan_get(f, "Md");
        printf("Fan %d: %.0f RPM now, target %.0f, range %.0f-%.0f, mode %s\n", f, fan_get(f, "Ac"),
               fan_get(f, "Tg"), fan_min[f], fan_max[f],
               md == 1 ? "manual (cpufan)" : md == 0 ? "automatic (macOS)" : "unknown");
    }
    double ftst = smc_get("Ftst");
    if (!isnan(ftst)) printf("Ftst: %.0f\n", ftst);
    return 0;
}

// One JSON object per line, every 2 seconds, until stdout closes.
static int cmd_watch(void) {
    load_fans();
    find_cpu_sensors();
    char batt[8][5];
    int nbatt = 0, n = key_count();
    for (int i = 0; i < n && nbatt < 8; i++) {
        char k[5];
        if (key_at(i, k) && !strncmp(k, "TB", 2) && k[3] == 'T') memcpy(batt[nbatt++], k, 5);
    }
    signal(SIGPIPE, SIG_DFL);
    for (;;) {
        // Hottest sensor (what the fan follows), which one it is, and the average across all.
        double t = NAN, sum = 0;
        int count = 0, hot = -1;
        for (int i = 0; i < nsensors; i++) {
            double c = smc_get(sensors[i]);
            if (!plausible(c)) continue;
            sum += c;
            count++;
            if (isnan(t) || c > t) { t = c; hot = i; }
        }
        double power = smc_get("PSTR");
        if (isnan(t)) printf("{\"cpu\":null,\"avg\":null,\"hottest\":\"\",");
        else printf("{\"cpu\":%.1f,\"avg\":%.1f,\"hottest\":\"%s\",", t, sum / count, sensors[hot]);
        printf("\"sensors\":%d,\"power\":", count);
        if (isnan(power)) printf("null"); else printf("%.2f", power);
        printf(",\"fans\":[");
        for (int f = 0; f < nfans; f++) {
            printf("%s{\"rpm\":%.0f,\"target\":%.0f,\"min\":%.0f,\"max\":%.0f,\"manual\":%s}",
                   f ? "," : "", fan_get(f, "Ac"), fan_get(f, "Tg"), fan_min[f], fan_max[f],
                   fan_get(f, "Md") == 1 ? "true" : "false");
        }
        printf("],\"battery\":[");
        for (int i = 0; i < nbatt; i++) {
            double c = smc_get(batt[i]);
            printf(i ? ",%.1f" : "%.1f", isnan(c) ? 0 : c);
        }
        printf("]}\n");
        if (fflush(stdout) != 0 || ferror(stdout)) return 0;
        sleep(2);
    }
}

static int cmd_probe(void) {
    int n = key_count();
    printf("%d SMC keys\n", n);
    for (int i = 0; i < n; i++) {
        char k[5], t[5];
        if (!key_at(i, k) || (k[0] != 'F' && k[0] != 'T' && k[0] != 'P')) continue;
        smc_keyinfo_t info;
        uint8_t b[32];
        if (!smc_read_u(k2u(k), &info, b)) continue;
        u2k(info.dataType, t);
        double v = decode(&info, b);
        if (isnan(v)) printf("%s  %-4s  -\n", k, t);
        else printf("%s  %-4s  %.2f\n", k, t, v);
    }
    return 0;
}


// Root-only troubleshooting: show exactly how the SMC answers fan-mode writes.
static void diag_write(const char *key, double v) {
    smc_keyinfo_t info;
    if (!smc_info(k2u(key), &info)) { printf("  %s: no such key\n", key); return; }
    smc_data_t in = {0}, out;
    in.key = k2u(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = info.dataSize;
    char t[5]; u2k(info.dataType, t);
    if (!strcmp(t, "flt ")) { float f = (float)v; memcpy(in.bytes, &f, 4); } else in.bytes[0] = (uint8_t)v;
    size_t sz = sizeof(out);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &sz);
    printf("  write %s=%g: kr=0x%x result=%d attrs=0x%02x\n", key, v, kr, out.result, info.dataAttributes);
}

static int cmd_diag(void) {
    if (geteuid() != 0) { fprintf(stderr, "cpufan diag needs root (sudo).\n"); return 1; }
    const char *keys[] = {"F0Md", "F0Tg", "F0Mn", "FOff", "Ftst", "FRmp", "F0St", "F0Fb"};
    for (unsigned i = 0; i < sizeof keys / sizeof *keys; i++) {
        smc_keyinfo_t info; uint8_t b[32]; char t[5];
        if (!smc_read_u(k2u(keys[i]), &info, b)) { printf("%s: missing\n", keys[i]); continue; }
        u2k(info.dataType, t);
        printf("%s: %s attrs=0x%02x value=%g\n", keys[i], t, info.dataAttributes, decode(&info, b));
    }
    diag_write("F0Md", 1);
    for (int i = 0; i < 6; i++) { usleep(500 * 1000); printf("  F0Md now %g, F0Tg %g, F0Ac %g\n", smc_get("F0Md"), smc_get("F0Tg"), smc_get("F0Ac")); }
    diag_write("F0Tg", 3000);
    for (int i = 0; i < 4; i++) { usleep(500 * 1000); printf("  F0Md now %g, F0Tg %g, F0Ac %g\n", smc_get("F0Md"), smc_get("F0Tg"), smc_get("F0Ac")); }
    diag_write("F0Md", 0);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) {
        fprintf(stderr, "usage: cpufan status | watch | probe | run [LOW HIGH] | auto\n");
        return 2;
    }
    if (!smc_open()) { fprintf(stderr, "Could not open the SMC.\n"); return 1; }
    const char *cmd = argv[1];
    if (!strcmp(cmd, "status")) return cmd_status();
    if (!strcmp(cmd, "probe")) return cmd_probe();
    if (!strcmp(cmd, "watch")) return cmd_watch();
    if (!strcmp(cmd, "diag")) return cmd_diag();
    if (!strcmp(cmd, "auto")) {
        if (geteuid() != 0) { fprintf(stderr, "cpufan auto needs root (sudo).\n"); return 1; }
        load_fans();
        auto_mode();
        printf("Fans back on automatic.\n");
        return 0;
    }
    if (!strcmp(cmd, "run")) {
        double low = argc > 2 ? atof(argv[2]) : 55, high = argc > 3 ? atof(argv[3]) : 85;
        if (!(high > low)) { fprintf(stderr, "HIGH must be above LOW.\n"); return 2; }
        return cmd_run(low, high);
    }
    fprintf(stderr, "unknown command: %s\n", cmd);
    return 2;
}
