#include "PTYManager.h"
#include <stdio.h>
#include <string.h>

int spawn_pty(int *master_fd, int rows, int cols) {
  struct winsize win = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  int pid = forkpty(master_fd, NULL, NULL, &win);

  if (pid < 0) {
    return -1; // Error
  } else if (pid == 0) {
    // Child process
    char *shell = getenv("SHELL");
    if (!shell)
      shell = "/bin/zsh";

    setenv("TERM", "xterm-256color", 1);

    execlp(shell, shell, "-l", NULL);
    perror("execlp failed");
    exit(1);
  }

  return pid; // Parent process
}

ssize_t read_pty(int fd, char *buffer, size_t count) {
  return read(fd, buffer, count);
}

ssize_t write_pty(int fd, const char *buffer, size_t count) {
  return write(fd, buffer, count);
}

void resize_pty(int fd, int rows, int cols) {
  struct winsize win = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  ioctl(fd, TIOCSWINSZ, &win);
}
