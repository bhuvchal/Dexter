#ifndef PTYManager_h
#define PTYManager_h

#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int spawn_pty(int *master_fd, int rows, int cols, const char *extra_path);
ssize_t read_pty(int fd, char *buffer, size_t count);
ssize_t write_pty(int fd, const char *buffer, size_t count);
void resize_pty(int fd, int rows, int cols);

#endif /* PTYManager_h */
