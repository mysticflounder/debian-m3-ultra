// SPDX-License-Identifier: GPL-2.0-or-later
// RAM-only J575d diagnostic initramfs /init. It must run only as PID 1.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/utsname.h>
#include <unistd.h>

static void diag(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    fputs("J575D_INITRAMFS_DIAG: ", stdout);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}

static void mkdir_if_needed(const char *path)
{
    if (mkdir(path, 0755) != 0 && errno != EEXIST)
        diag("mkdir %s: %s", path, strerror(errno));
}

static void mount_if_needed(const char *source, const char *target,
                            const char *fstype, unsigned long flags,
                            const char *data)
{
    if (mount(source, target, fstype, flags, data) != 0 && errno != EBUSY)
        diag("mount %s on %s: %s", fstype, target, strerror(errno));
}

static void reconnect_console(void)
{
    int fd = open("/dev/console", O_RDWR | O_NOCTTY);

    if (fd < 0) {
        diag("open /dev/console: %s", strerror(errno));
        return;
    }
    if (dup2(fd, STDIN_FILENO) < 0 || dup2(fd, STDOUT_FILENO) < 0 ||
        dup2(fd, STDERR_FILENO) < 0)
        dprintf(STDERR_FILENO, "J575D_INITRAMFS_DIAG: dup2 console: %s\n",
                strerror(errno));
    if (fd > STDERR_FILENO)
        close(fd);
}

static void ensure_console_node(void)
{
    struct stat st;

    if (stat("/dev/console", &st) == 0)
        return;
    if (errno != ENOENT) {
        diag("stat /dev/console: %s", strerror(errno));
        return;
    }
    if (mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1)) != 0 &&
        errno != EEXIST)
        diag("mknod /dev/console: %s", strerror(errno));
}

static void print_file(const char *label, const char *path)
{
    char buf[4096];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t n;

    if (fd < 0) {
        diag("%s unavailable: %s", label, strerror(errno));
        return;
    }
    n = read(fd, buf, sizeof(buf) - 1);
    if (n < 0)
        diag("%s read: %s", label, strerror(errno));
    else {
        buf[n] = '\0';
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
            buf[--n] = '\0';
        diag("%s=%s", label, buf);
    }
    close(fd);
}

static void print_diagnostics(void)
{
    struct utsname uts;
    long page_size = sysconf(_SC_PAGESIZE);

    if (uname(&uts) == 0)
        diag("uname=%s %s %s %s %s", uts.sysname, uts.release, uts.version,
             uts.machine, uts.nodename);
    else
        diag("uname unavailable: %s", strerror(errno));
    if (page_size > 0)
        diag("runtime_pagesize=%ld", page_size);
    else
        diag("runtime_pagesize unavailable: %s", strerror(errno));
    print_file("cpu_online", "/sys/devices/system/cpu/online");
    print_file("cmdline", "/proc/cmdline");
}

int main(void)
{
    if (getpid() != 1) {
        fprintf(stderr, "J575D_INITRAMFS_DIAG: refusing non-PID1 execution\n");
        return 2;
    }

    signal(SIGCHLD, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    signal(SIGTERM, SIG_IGN);

    mkdir_if_needed("/proc");
    mkdir_if_needed("/sys");
    mkdir_if_needed("/dev");
    mount_if_needed("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV,
                    NULL);
    mount_if_needed("sysfs", "/sys", "sysfs",
                    MS_NOSUID | MS_NOEXEC | MS_NODEV | MS_RDONLY, NULL);
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID | MS_NOEXEC,
              "mode=0755") != 0 && errno != EBUSY)
        mount_if_needed("tmpfs", "/dev", "tmpfs", MS_NOSUID | MS_NOEXEC,
                        "mode=0755");
    ensure_console_node();
    reconnect_console();
    diag("begin ram-only diagnostic; no persistent root, network, firmware, or raw devices");
    print_diagnostics();
    diag("alive; PID1 will not exit");
    for (;;)
        pause();
}
