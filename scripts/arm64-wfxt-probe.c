/* Bounded WFxT observations in isolated children; not a feature detector. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__aarch64__)
static void child_signal(int sig)
{
    _exit(sig == SIGALRM ? 124 : 125);
}

static int reap_bounded(pid_t child, int *status)
{
    struct timespec start;
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
        return -1;
    for (;;) {
        pid_t waited = waitpid(child, status, WNOHANG);
        if (waited == child)
            return 0;
        if (waited < 0 && errno != EINTR)
            return -1;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
            return -1;
        time_t seconds = now.tv_sec - start.tv_sec;
        long nanoseconds = now.tv_nsec - start.tv_nsec;
        if (nanoseconds < 0) {
            --seconds;
            nanoseconds += 1000000000L;
        }
        if (seconds > 3 || (seconds == 3 && nanoseconds >= 0))
            break;
        const struct timespec pause = {0, 10 * 1000 * 1000};
        while (nanosleep(&pause, NULL) != 0 && errno == EINTR)
            ;
    }

    /* The child was not reaped by the deadline; kill it, then reap it. */
    if (kill(child, SIGKILL) != 0 && errno != ESRCH)
        return -1;
    pid_t waited;
    do {
        waited = waitpid(child, status, 0);
    } while (waited < 0 && errno == EINTR);
    return waited == child ? 1 : -1;
}

static uint64_t execute(unsigned op)
{
    /* WFxT's source register is fixed to X0; it is deliberately always zero. */
    register uint64_t deadline __asm__("x0") = 0;
    register uint64_t marker __asm__("x1") = 0;

    switch (op) {
    case 0: /* NOP marker control. */
        __asm__ volatile("nop\n\tmov %x1, #0xa001"
                         : "+r"(deadline), "+r"(marker) :: "memory");
        break;
    case 1: /* ADD marker control. */
        __asm__ volatile("add %x1, %x0, #1"
                         : "+r"(deadline), "+r"(marker) :: "memory");
        break;
    case 2: /* WFET X0, encoded explicitly for review. */
        __asm__ volatile("mov %x0, #0\n\t.inst 0xd5031000\n\tmov %x1, #0xa003"
                         : "+r"(deadline), "+r"(marker) :: "memory");
        break;
    case 3: /* WFIT X0, encoded explicitly for review. */
        __asm__ volatile("mov %x0, #0\n\t.inst 0xd5031020\n\tmov %x1, #0xa004"
                         : "+r"(deadline), "+r"(marker) :: "memory");
        break;
    }
    return marker;
}

static uint64_t expected(unsigned op)
{
    static const uint64_t markers[] = {0xa001, 1, 0xa003, 0xa004};
    return markers[op];
}
#endif

int main(void)
{
#if !defined(__aarch64__)
    fputs("AArch64 required\n", stderr);
    return 2;
#else
    static const char *const names[] = {"NOP", "ADD", "WFET", "WFIT"};
    static const uint64_t input = 0;
    struct rlimit no_core = {0, 0};
    unsigned rows = 0;
    int valid = 1;

    if (setrlimit(RLIMIT_CORE, &no_core) != 0)
        return 2;
    printf("{\"schema_version\":1,\"core_dumps_disabled\":true,"
           "\"samples\":[");
    for (unsigned op = 0; op < 4; ++op) {
        int fd[2];
        if (pipe(fd) != 0)
            return 2;
        fflush(stdout);
        pid_t child = fork();
        if (child < 0) {
            close(fd[0]);
            close(fd[1]);
            return 2;
        }
        if (child == 0) {
            struct sigaction child_action = {0};
            sigset_t unblock;
            uint64_t result;
            ssize_t count;

            close(fd[0]);
            child_action.sa_handler = child_signal;
            sigemptyset(&child_action.sa_mask);
            if (sigaction(SIGILL, &child_action, NULL) != 0 ||
                sigaction(SIGALRM, &child_action, NULL) != 0)
                _exit(126);
            sigemptyset(&unblock);
            sigaddset(&unblock, SIGILL);
            sigaddset(&unblock, SIGALRM);
            if (sigprocmask(SIG_UNBLOCK, &unblock, NULL) != 0)
                _exit(126);
            alarm(1);
            result = execute(op);
            count = write(fd[1], &result, sizeof(result));
            close(fd[1]);
            _exit(count == (ssize_t)sizeof(result) ? 0 : 126);
        }

        close(fd[1]);
        int status;
        int wait_result = reap_bounded(child, &status);
        if (wait_result < 0) {
            close(fd[0]);
            return 2;
        }

        uint64_t result = 0;
        ssize_t count;
        do {
            count = read(fd[0], &result, sizeof(result));
        } while (count < 0 && errno == EINTR);
        close(fd[0]);

        const char *outcome = "error";
        if (wait_result == 0 && WIFEXITED(status) &&
            WEXITSTATUS(status) == 0 && count == (ssize_t)sizeof(result))
            outcome = "result";
        else if (wait_result == 0 && WIFEXITED(status) &&
                 WEXITSTATUS(status) == 125 && count == 0)
            outcome = "SIGILL";
        else if (wait_result == 1 ||
                 (WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL) ||
                 (WIFEXITED(status) && WEXITSTATUS(status) == 124))
            outcome = "timeout";

        uint64_t want = expected(op);
        int is_control = op < 2;
        int matched = outcome[0] == 'r' && result == want;
        if (is_control ? !matched
                       : !((outcome[0] == 'r' && matched) ||
                           (outcome[0] == 'S' && count == 0)))
            valid = 0;

        printf("%s{\"op\":\"%s\",\"input\":\"0x%016" PRIx64
               "\",\"outcome\":\"%s\",\"result\":",
               rows++ ? "," : "", names[op], input, outcome);
        if (outcome[0] == 'r')
            printf("\"0x%016" PRIx64 "\"", result);
        else
            fputs("null", stdout);
        printf(",\"expected_if_executed\":\"0x%016" PRIx64 "\"}",
               want);
    }
    printf("],\"observations_valid\":%s}\n", valid ? "true" : "false");
    return valid ? 0 : 1;
#endif
}
