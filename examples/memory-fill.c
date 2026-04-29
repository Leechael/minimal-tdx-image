#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/reboot.h>
#endif

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

static FILE *out_log;

static double monotonic_seconds(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0.0;
  }
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void emit(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  printf("\n");
  fflush(stdout);
  va_end(ap);

  if (out_log) {
    va_start(ap, fmt);
    vfprintf(out_log, fmt, ap);
    fprintf(out_log, "\n");
    fflush(out_log);
    va_end(ap);
  }
}

static void mark(const char *name) {
  emit("MEM_FILL_%s uptime=%.3f", name, monotonic_seconds());
}

static void die_errno(const char *msg) {
  emit("MEM_FILL_ERROR message=%s errno=%d detail=%s", msg, errno, strerror(errno));
  sync();
#ifdef __linux__
  reboot(RB_POWER_OFF);
#endif
  _exit(1);
}

static uint64_t parse_u64(const char *value, uint64_t fallback) {
  char *end = NULL;
  errno = 0;
  unsigned long long parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value) {
    return fallback;
  }
  return (uint64_t)parsed;
}

static bool cmdline_value(const char *key, char *out, size_t out_len) {
  FILE *f = fopen("/proc/cmdline", "r");
  if (!f) {
    return false;
  }

  char buf[8192];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';

  size_t key_len = strlen(key);
  char *save = NULL;
  for (char *tok = strtok_r(buf, " \n", &save); tok; tok = strtok_r(NULL, " \n", &save)) {
    if (strncmp(tok, key, key_len) == 0 && tok[key_len] == '=') {
      snprintf(out, out_len, "%s", tok + key_len + 1);
      return true;
    }
  }
  return false;
}

static uint64_t cmdline_u64(const char *key, uint64_t fallback) {
  char value[64];
  if (!cmdline_value(key, value, sizeof(value))) {
    return fallback;
  }
  return parse_u64(value, fallback);
}

static void cmdline_string(const char *key, char *out, size_t out_len, const char *fallback) {
  if (!cmdline_value(key, out, out_len)) {
    snprintf(out, out_len, "%s", fallback);
  }
}

static uint64_t meminfo_kb(const char *name) {
  FILE *f = fopen("/proc/meminfo", "r");
  if (!f) {
    return 0;
  }

  char key[64];
  uint64_t value;
  char unit[32];
  while (fscanf(f, "%63s %" SCNu64 " %31s\n", key, &value, unit) == 3) {
    size_t len = strlen(key);
    if (len > 0 && key[len - 1] == ':') {
      key[len - 1] = '\0';
    }
    if (strcmp(key, name) == 0) {
      fclose(f);
      return value;
    }
  }
  fclose(f);
  return 0;
}

static uint64_t xorshift64(uint64_t *state) {
  uint64_t x = *state;
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  *state = x;
  return x;
}

static uint64_t round_down(uint64_t value, uint64_t align) {
  if (align == 0) {
    return value;
  }
  return value - (value % align);
}

static uint64_t compute_target_bytes(uint64_t page_size) {
  uint64_t mem_total_kb = meminfo_kb("MemTotal");
  uint64_t mem_avail_kb = meminfo_kb("MemAvailable");
  uint64_t leave_mb = cmdline_u64("mem_fill_leave_mb", 256);
  uint64_t percent = cmdline_u64("mem_fill_percent", 90);
  uint64_t target = 0;

  uint64_t explicit_bytes = cmdline_u64("mem_fill_bytes", 0);
  uint64_t explicit_mb = cmdline_u64("mem_fill_mb", 0);
  uint64_t explicit_gb = cmdline_u64("mem_fill_gb", 0);

  if (explicit_bytes > 0) {
    target = explicit_bytes;
  } else if (explicit_mb > 0) {
    target = explicit_mb * 1024ULL * 1024ULL;
  } else if (explicit_gb > 0) {
    target = explicit_gb * 1024ULL * 1024ULL * 1024ULL;
  } else if (mem_total_kb > 0) {
    target = (mem_total_kb * 1024ULL * percent) / 100ULL;
  }

  if (mem_avail_kb > leave_mb * 1024ULL) {
    uint64_t available_target = (mem_avail_kb - leave_mb * 1024ULL) * 1024ULL;
    if (target == 0 || target > available_target) {
      target = available_target;
    }
  }

  return round_down(target, page_size);
}

static void poweroff_now(void) {
  mark("POWEROFF_BEGIN");
  sync();
#ifdef __linux__
  reboot(RB_POWER_OFF);
  reboot(RB_AUTOBOOT);
#endif
  _exit(0);
}

int main(void) {
  const char *out_dir = getenv("OUT_DIR");
  char log_path[512];
  if (out_dir && *out_dir) {
    snprintf(log_path, sizeof(log_path), "%s/memory-fill.log", out_dir);
    out_log = fopen(log_path, "w");
  }

  uint64_t page_size = (uint64_t)sysconf(_SC_PAGESIZE);
  if (page_size == 0) {
    page_size = 4096;
  }

  char mode[32];
  cmdline_string("mem_fill_mode", mode, sizeof(mode), "full");
  uint64_t progress_percent = cmdline_u64("mem_fill_progress_percent", 5);
  uint64_t sleep_seconds = cmdline_u64("mem_fill_sleep_seconds", 0);
  uint64_t seed = cmdline_u64("mem_fill_seed", 0x9e3779b97f4a7c15ULL);
  uint64_t target = compute_target_bytes(page_size);

  mark("BEGIN");
  emit("MEM_FILL_CONFIG mode=%s target_bytes=%" PRIu64 " target_mb=%" PRIu64
       " page_size=%" PRIu64 " memtotal_kb=%" PRIu64 " memavailable_kb=%" PRIu64
       " seed=%" PRIu64,
       mode, target, target / 1024ULL / 1024ULL, page_size, meminfo_kb("MemTotal"),
       meminfo_kb("MemAvailable"), seed);

  if (target == 0) {
    emit("MEM_FILL_ERROR message=target_bytes_zero");
    poweroff_now();
  }

  mark("ALLOC_BEGIN");
  uint8_t *buf = mmap(NULL, (size_t)target, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (buf == MAP_FAILED) {
    die_errno("mmap_failed");
  }
  mark("ALLOC_END");

  uint64_t checksum = 0;
  double start = monotonic_seconds();
  uint64_t next_progress = progress_percent;
  if (next_progress == 0 || next_progress > 100) {
    next_progress = 5;
  }

  mark("WRITE_BEGIN");
  if (strcmp(mode, "page") == 0) {
    uint64_t pages = target / page_size;
    for (uint64_t i = 0; i < pages; i++) {
      uint64_t value = xorshift64(&seed);
      memcpy(buf + i * page_size, &value, sizeof(value));
      checksum ^= value;

      uint64_t percent = ((i + 1) * 100ULL) / pages;
      if (percent >= next_progress) {
        uint64_t bytes = (i + 1) * page_size;
        double elapsed = monotonic_seconds() - start;
        double mib = (double)bytes / 1024.0 / 1024.0;
        double mib_per_sec = elapsed > 0 ? mib / elapsed : 0;
        emit("MEM_FILL_PROGRESS bytes=%" PRIu64 " percent=%" PRIu64
             " seconds=%.3f mib_per_sec=%.3f uptime=%.3f",
             bytes, percent, elapsed, mib_per_sec, monotonic_seconds());
        next_progress += progress_percent;
      }
    }
  } else {
    uint64_t words = target / sizeof(uint64_t);
    uint64_t *words_buf = (uint64_t *)buf;
    for (uint64_t i = 0; i < words; i++) {
      uint64_t value = xorshift64(&seed);
      words_buf[i] = value;
      checksum ^= value;

      uint64_t percent = ((i + 1) * 100ULL) / words;
      if (percent >= next_progress) {
        uint64_t bytes = (i + 1) * (uint64_t)sizeof(uint64_t);
        double elapsed = monotonic_seconds() - start;
        double mib = (double)bytes / 1024.0 / 1024.0;
        double mib_per_sec = elapsed > 0 ? mib / elapsed : 0;
        emit("MEM_FILL_PROGRESS bytes=%" PRIu64 " percent=%" PRIu64
             " seconds=%.3f mib_per_sec=%.3f uptime=%.3f",
             bytes, percent, elapsed, mib_per_sec, monotonic_seconds());
        next_progress += progress_percent;
      }
    }
  }
  double elapsed = monotonic_seconds() - start;
  mark("WRITE_END");

  double mib = (double)target / 1024.0 / 1024.0;
  double mib_per_sec = elapsed > 0 ? mib / elapsed : 0;
  emit("MEM_FILL_RESULT bytes=%" PRIu64 " mb=%" PRIu64 " seconds=%.3f"
       " mib_per_sec=%.3f checksum=%016" PRIx64,
       target, target / 1024ULL / 1024ULL, elapsed, mib_per_sec, checksum);

  if (sleep_seconds > 0) {
    mark("SLEEP_BEGIN");
    sleep((unsigned int)sleep_seconds);
    mark("SLEEP_END");
  }

  mark("END");
  poweroff_now();
}
