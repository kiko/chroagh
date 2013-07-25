/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Monitors changes in virtual terminal (VT). There is no "clean" way of doing
 * this in Linux: we start a thread for each possible TTY (1 to 63), and
 * monitor WAIT_ACTIVE ioctl.
 *
 * TODO: There is a cleaner way! Look into VT_WAITEVENT.
 */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <pthread.h>

const int DEBUG = 0;

int console_fd;
pthread_t threads[MAX_NR_CONSOLES+1];
int thread_data[MAX_NR_CONSOLES+1];
int current = -1;

pthread_mutex_t current_mutex = PTHREAD_MUTEX_INITIALIZER;

void monitor_vt(int vt);

void *thread_func(void *data) {
    int vt = *((int*)data);
    if (DEBUG)
        printf("Monitoring %d!\n", vt);

    if (ioctl(console_fd, VT_WAITACTIVE, vt)) {
        fprintf(stderr, "Cannot monitor VT_WAITACTIVE on VT %d\n", vt);
        return NULL;
    }

    pthread_mutex_lock(&current_mutex);
    printf("%d\n", vt);
    fflush(stdout);

    if (current != -1) {
        monitor_vt(current);
    }
    current = vt;
    pthread_mutex_unlock(&current_mutex);

    return NULL;
}

void monitor_vt(int vt) {
    thread_data[vt] = vt;
    pthread_create(&threads[vt], NULL, thread_func, &thread_data[vt]);
}

int main(int argc, char **argv) {
    int vt;

    console_fd = open("/dev/tty0", O_RDWR);
    if (console_fd < 0) {
        fprintf(stderr, "Cannot open /dev/tty0.\n");
        exit(1);
    }

    for (vt = 1; vt < MAX_NR_CONSOLES; vt++) {
        monitor_vt(vt);
    }

    pthread_exit(0);

    return 0;
}

