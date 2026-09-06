#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int fail(const char *what)
{
    perror(what);
    return 1;
}

int main(int argc, char **argv)
{
    int reader = -1;
    int old_writer = -1;
    int reopened_writer = -1;
    int status;
    pid_t child;
    int old_flags;
    int reopened_flags;
    char byte;

    alarm(5);
    if (argc != 2)
        return fprintf(stderr, "usage: %s FIFO\n", argv[0]), 2;
    if (mkfifo(argv[1], 0600) != 0)
        return fail("mkfifo");
    reader = open(argv[1], O_RDONLY | O_NONBLOCK);
    if (reader < 0)
        return fail("open reader");
    old_writer = open(argv[1], O_WRONLY | O_NONBLOCK);
    if (old_writer < 0)
        return fail("open old writer");
    reopened_writer = open(argv[1], O_WRONLY);
    if (reopened_writer < 0)
        return fail("reopen writer");

    old_flags = fcntl(old_writer, F_GETFL);
    reopened_flags = fcntl(reopened_writer, F_GETFL);
    if (old_flags < 0 || reopened_flags < 0)
        return fail("fcntl flags");
    if ((old_flags & O_NONBLOCK) == 0 || (reopened_flags & O_NONBLOCK) != 0) {
        fprintf(stderr, "reopened FIFO writer did not get independent blocking flags\n");
        return 1;
    }

    child = fork();
    if (child < 0)
        return fail("fork");
    if (child == 0) {
        alarm(5);
        int child_reader = open(argv[1], O_RDONLY);
        ssize_t got;

        close(reader);
        close(old_writer);
        close(reopened_writer);
        if (child_reader < 0)
            _exit(10);
        got = read(child_reader, &byte, 1);
        if (got != 1 || byte != 'x')
            _exit(11);
        got = read(child_reader, &byte, 1);
        close(child_reader);
        _exit(got == 0 ? 0 : 12);
    }

    close(reader);
    if (write(reopened_writer, "x", 1) != 1)
        return fail("write reopened writer");
    close(old_writer);
    close(reopened_writer);
    if (waitpid(child, &status, 0) != child)
        return fail("waitpid");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "FIFO reader did not observe data then EOF (status=%d)\n", status);
        return 1;
    }
    if (unlink(argv[1]) != 0)
        return fail("unlink FIFO");
    puts("idle FIFO descriptor fixture passed: independent blocking writer and EOF");
    return 0;
}
