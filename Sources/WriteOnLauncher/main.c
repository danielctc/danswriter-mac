#include <unistd.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
    static const char failure[] = "WriteOnLauncher: failed to start child\n";
    if (argc < 2 || argv[1] == NULL || argv[1][0] != '/') {
        (void)write(STDERR_FILENO, failure, sizeof(failure) - 1);
        return 127;
    }
    if (setsid() == -1 && getpgrp() != getpid() && setpgid(0, 0) == -1) {
        (void)write(STDERR_FILENO, failure, sizeof(failure) - 1);
        return 127;
    }
    execv(argv[1], &argv[1]);
    (void)write(STDERR_FILENO, failure, sizeof(failure) - 1);
    _exit(127);
}
