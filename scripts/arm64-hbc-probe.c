/* HBC conditional-branch observations in bounded child processes. */
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
    register uint64_t input0 __asm__("x0") = input;
    register uint64_t result __asm__("x1") = 0;

    switch (op) {
    case 0: /* B.EQ +8 */
        __asm__ volatile("cmp %x0, #0\n\t.inst 0x54000040\n\tmov %x1, #1"
                         : "+r"(input0), "+r"(result) :: "cc");
        break;
    case 1: /* B.NE +8 */
        __asm__ volatile("cmp %x0, #0\n\t.inst 0x54000041\n\tmov %x1, #1"
                         : "+r"(input0), "+r"(result) :: "cc");
        break;
    case 2: /* BC.EQ +8 */
        __asm__ volatile("cmp %x0, #0\n\t.inst 0x54000050\n\tmov %x1, #1"
                         : "+r"(input0), "+r"(result) :: "cc");
        break;
    case 3: /* BC.NE +8 */
        __asm__ volatile("cmp %x0, #0\n\t.inst 0x54000051\n\tmov %x1, #1"
                         : "+r"(input0), "+r"(result) :: "cc");
        break;
    }
    return result;
}

static uint64_t expected(unsigned op, uint64_t input)
{
    int equal = input == 0;
    int taken = (op == 0 || op == 2) ? equal : !equal;
    return taken ? 0 : 1;
}
#endif

int main(void)
{
#if !defined(__aarch64__)
    fputs("AArch64 required\n", stderr);
    return 2;
#else
    const char *names[] = {"B_EQ", "B_NE", "BC_EQ", "BC_NE"};
    const uint64_t inputs[] = {0, 1};
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) return 2;
    unsigned rows = 0;
    int valid = 1;
    printf("{\"schema_version\":1,\"core_dumps_disabled\":true,"
           "\"samples\":[");
    for (unsigned op = 0; op < 4; ++op) {
        for (unsigned i = 0; i < 2; ++i) {
            int fd[2];
            if (pipe(fd) != 0) return 2;
            fflush(stdout);
            pid_t child = fork();
            if (child < 0) {
                close(fd[0]); close(fd[1]); return 2;
            }
            if (child == 0) {
                close(fd[0]);
                struct sigaction action = {0};
                action.sa_handler = caught;
                sigemptyset(&action.sa_mask);
                if (sigaction(SIGILL, &action, NULL) != 0 ||
                    sigaction(SIGALRM, &action, NULL) != 0) _exit(126);
                sigset_t unblock;
                sigemptyset(&unblock);
                sigaddset(&unblock, SIGILL);
                sigaddset(&unblock, SIGALRM);
                if (sigprocmask(SIG_UNBLOCK, &unblock, NULL) != 0) _exit(126);
                alarm(2);
                uint64_t result = execute(op, inputs[i]);
                ssize_t count = write(fd[1], &result, sizeof(result));
                _exit(count == sizeof(result) ? 0 : 126);
            }
            close(fd[1]);
            int status;
            pid_t waited;
            do { waited = waitpid(child, &status, 0); }
            while (waited < 0 && errno == EINTR);
            if (waited != child) { close(fd[0]); return 2; }
            uint64_t result = 0;
            ssize_t count;
            do { count = read(fd[0], &result, sizeof(result)); }
            while (count < 0 && errno == EINTR);
            close(fd[0]);
            const char *outcome = "error";
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
                count == sizeof(result)) outcome = "result";
            else if (WIFEXITED(status) && WEXITSTATUS(status) == 125 &&
                     count == 0) outcome = "SIGILL";
            else if (WIFEXITED(status) && WEXITSTATUS(status) == 124)
                outcome = "timeout";
            uint64_t want = expected(op, inputs[i]);
            int matched = outcome[0] == 'r' && result == want;
            int baseline = op < 2;
            if (baseline ? !matched :
                (outcome[0] != 'r' && outcome[0] != 'S') ||
                (outcome[0] == 'r' && !matched)) valid = 0;
            printf(
                    "%s{\"op\":\"%s\",\"input\":\"0x%016" PRIx64
                    "\",\"outcome\":\"%s\",\"result\":",
                    rows++ ? "," : "", names[op], inputs[i], outcome);
            if (outcome[0] == 'r')
                printf("\"0x%016" PRIx64 "\"", result);
            else
                fputs("null", stdout);
            printf(",\"expected_if_executed\":\"0x%016" PRIx64
                   "\"}", want);
        }
    }
    printf("],\"observations_valid\":%s}\n", valid ? "true" : "false");
    return valid ? 0 : 1;
#endif
}
