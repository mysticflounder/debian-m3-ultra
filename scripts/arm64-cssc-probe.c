/* Scalar CSSC observations in bounded child processes; not a feature override. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__aarch64__)
static void caught(int sig) { _exit(sig == SIGALRM ? 124 : 125); }
static uint64_t execute(unsigned op, uint64_t input)
{
    register uint64_t value __asm__("x0") = input;
    switch (op) {
    case 0: __asm__ volatile("add %0, %0, #1" : "+r"(value)); break;
    case 1: __asm__ volatile(".inst 0x11c00400" : "+r"(value)); break;
    case 2: __asm__ volatile(".inst 0x11c80400" : "+r"(value)); break;
    case 3: __asm__ volatile(".inst 0x11c40400" : "+r"(value)); break;
    case 4: __asm__ volatile(".inst 0x11cc0400" : "+r"(value)); break;
    case 5: __asm__ volatile(".inst 0x91c00400" : "+r"(value)); break;
    case 6: __asm__ volatile(".inst 0x91c80400" : "+r"(value)); break;
    case 7: __asm__ volatile(".inst 0x91c40400" : "+r"(value)); break;
    case 8: __asm__ volatile(".inst 0x91cc0400" : "+r"(value)); break;
    }
    return value;
}
static uint64_t expected(unsigned op, uint64_t input)
{
    if (op == 0) return input + 1;
    unsigned kind = (op - 1) % 4;
    unsigned width = op <= 4 ? 32 : 64;
    uint64_t value = width == 32 ? (uint32_t)input : input;
    int below = value < 1;
    if (kind < 2 && (value >> (width - 1))) below = 1;
    return (kind == 0 || kind == 2) ? (below ? 1 : value) : (below ? value : 1);
}
#endif

int main(void)
{
#if !defined(__aarch64__)
    fputs("AArch64 required\n", stderr);
    return 2;
#else
    const char *names[] = {"ADD_X", "SMAX_W", "SMIN_W", "UMAX_W", "UMIN_W",
                          "SMAX_X", "SMIN_X", "UMAX_X", "UMIN_X"};
    const uint64_t inputs[] = {UINT64_MAX - 1, 0, 2};
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) return 2;
    unsigned rows = 0;
    int valid = 1;
    printf("{\"schema_version\":1,\"core_dumps_disabled\":true,\"samples\":[");
    for (unsigned op = 0; op < 9; ++op) {
        for (unsigned i = 0; i < 3; ++i) {
            int fd[2];
            if (pipe(fd) != 0) return 2;
            fflush(stdout);
            pid_t child = fork();
            if (child < 0) { close(fd[0]); close(fd[1]); return 2; }
            if (child == 0) {
                close(fd[0]);
                struct sigaction action = {0};
                action.sa_handler = caught;
                sigemptyset(&action.sa_mask);
                if (sigaction(SIGILL, &action, NULL) != 0 ||
                    sigaction(SIGALRM, &action, NULL) != 0) _exit(126);
                sigset_t unblock;
                sigemptyset(&unblock);
                sigaddset(&unblock, SIGILL); sigaddset(&unblock, SIGALRM);
                if (sigprocmask(SIG_UNBLOCK, &unblock, NULL) != 0) _exit(126);
                alarm(2);
                uint64_t result = execute(op, inputs[i]);
                ssize_t count = write(fd[1], &result, sizeof(result));
                _exit(count == sizeof(result) ? 0 : 126);
            }
            close(fd[1]);
            int status;
            pid_t waited;
            do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
            if (waited != child) { close(fd[0]); return 2; }
            uint64_t result = 0;
            ssize_t count;
            do { count = read(fd[0], &result, sizeof(result)); } while (count < 0 && errno == EINTR);
            close(fd[0]);
            const char *outcome = "error";
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && count == sizeof(result)) outcome = "result";
            else if (WIFEXITED(status) && WEXITSTATUS(status) == 125 && count == 0) outcome = "SIGILL";
            else if (WIFEXITED(status) && WEXITSTATUS(status) == 124) outcome = "timeout";
            uint64_t want = expected(op, inputs[i]);
            int matched = outcome[0] == 'r' && result == want;
            if ((op == 0 && !matched) || (outcome[0] != 'r' && outcome[0] != 'S') ||
                (outcome[0] == 'r' && !matched)) valid = 0;
            printf("%s{\"op\":\"%s\",\"input\":\"0x%016" PRIx64
                   "\",\"outcome\":\"%s\",\"result\":", rows++ ? "," : "", names[op], inputs[i], outcome);
            if (outcome[0] == 'r') printf("\"0x%016" PRIx64 "\"", result); else printf("null");
            printf(",\"expected_if_executed\":\"0x%016" PRIx64 "\"}", want);
        }
    }
    printf("],\"observations_valid\":%s}\n", valid ? "true" : "false");
    return valid ? 0 : 1;
#endif
}
