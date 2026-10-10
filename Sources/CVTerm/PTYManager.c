#include "PTYManager.h"
#include <stdio.h>
#include <string.h>

int spawn_pty(int *master_fd, int rows, int cols, const char *extra_path) {
  struct winsize win = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  int pid = forkpty(master_fd, NULL, NULL, &win);

  if (pid < 0) {
    return -1;
  } else if (pid == 0) {
    // Child process
    char *shell = getenv("SHELL");
    if (!shell)
      shell = "/bin/zsh";

    setenv("TERM", "xterm-256color", 1);

    // Prepend the app's resources directory to PATH so bundled scripts
    // (e.g. search) are discoverable without manual setup.
    if (extra_path) {
      const char *current = getenv("PATH");
      char new_path[8192];
      if (current)
        snprintf(new_path, sizeof(new_path), "%s:%s", extra_path, current);
      else
        snprintf(new_path, sizeof(new_path), "%s", extra_path);
      setenv("PATH", new_path, 1);
      // Also expose the path so shell hooks can reference bundled tools.
      setenv("DT_RESOURCES", extra_path, 1);
    }

    execlp(shell, shell, "-l", NULL);
    perror("execlp failed");
    exit(1);
  }

  return pid;
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
