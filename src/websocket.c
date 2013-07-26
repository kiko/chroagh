/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket server to interface with crouton Chromium extension, that provides
 * clipboard synchronization.
 *
 * FIXME: should payload be BINARY or TEXT?
 * FIXME: error handling everywhere
 * FIXME: add debug/verbose flag
 *
 * compile libwebsockets with:
 * mkdir build; cd build; cmake .. -DWITH_SSL=OFF -DWITHOUT_EXTENSIONS=YES; make -j3
 * gcc websocket.c /tmp/libwebsockets/build/lib/libwebsockets.a -Wall -I/tmp/libwebsockets/lib -o crouton-websocket
 */

#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "libwebsockets.h"

const int VERSION = 0;
const int PORT = 30001;
const char* PIPEIN_FILENAME = "/tmp/crouton-websocket-in";
const char* PIPEOUT_FILENAME = "/tmp/crouton-websocket-out";

const int write_timeout = 3000;

static int verbose = 0;

/**/
/* Pipe out functions */
/**/

/* Write some data to the pipe out. */
static void write_pipeout(char* buffer, int len) {
    int pipeout_fd;
    int i;

    if (verbose)
        printf("write_pipeout: opening pipe out\n");

    for (i = 0; i < write_timeout/10; i++) {
        pipeout_fd = open(PIPEOUT_FILENAME, O_WRONLY | O_NONBLOCK);
        if (pipeout_fd > -1)
            break;
        usleep(10000);
    }

    if (pipeout_fd < 0) {
        fprintf(stderr, "write_pipeout: timeout while opening.\n");
    } else {
        /* Remove non-blocking flag */
        int n;
        int flags = fcntl(pipeout_fd, F_GETFL, 0);
        if (flags < 0) {
            perror("write_pipeout: error in fnctl GETFL.\n");
            return;
        }

        n = fcntl(pipeout_fd, F_SETFL, flags & ~O_NONBLOCK);
        if (n < 0) {
            perror("write_pipeout: error in fnctl SETFL.\n");
            return;
        }

        /* Write the data */
        if (verbose)
            printf("write_pipeout: writing len=%d\n", len);

        n = write(pipeout_fd, buffer, len);

        if (n < 0)
            perror("write_pipeout: error in write.\n");
        else if (n != len)
            fprintf(stderr, "write_pipeout: Incomplete write (%d/%d).\n", n, len);

        close(pipeout_fd);
        if (verbose)
            printf("write_pipeout: ok\n");
    }
}

/* Write a string to the pipe out. */
static void write_pipeoutstr(char* str) {
    write_pipeout(str, strlen(str));
}

/**/
/* Websocket functions */
/**/

static int websocket_callback(struct libwebsocket_context *context,
        struct libwebsocket *wsi,
        enum libwebsocket_callback_reasons reason, void *user,
                               void *in, size_t len);

struct per_session_data {
    unsigned char* buffer;
    int wlen;
    int pipeout_waiting; /* is pipe out waiting? */
    int active; /* is this the last connection */
};

static struct libwebsocket_protocols protocols[] = {
    {
        "default",        /* name */
        websocket_callback,        /* callback */
        sizeof(struct per_session_data)    /* per_session_data_size */
    },
    {
        NULL, NULL, 0        /* End of list */
    }
};

/* Current active connection (last one to have been connected) */
struct per_session_data *current_data = NULL;

/* Close current session when a new connection is made. */
static void close_session(struct per_session_data* pss) {
    if (!pss)
        return;

    char* error = "EAnother connection to websocket!\n";

    pss->active = 0;
    free(pss->buffer);
    pss->wlen = strlen(error);
    pss->buffer = malloc(LWS_SEND_BUFFER_PRE_PADDING+pss->wlen+
                                              LWS_SEND_BUFFER_POST_PADDING);
    memcpy(&pss->buffer[LWS_SEND_BUFFER_PRE_PADDING], error, pss->wlen);

    if (pss->pipeout_waiting) {
        write_pipeoutstr("Error: new connection.");
        pss->pipeout_waiting = 0;
    }

    /* Make sure the buffer gets written. */
    libwebsocket_callback_on_writable_all_protocol(protocols);
}

/* Callback from libwebsocket */
static int websocket_callback(struct libwebsocket_context *context,
        struct libwebsocket *wsi,
        enum libwebsocket_callback_reasons reason, void *user,
                               void *in, size_t len) {
    struct per_session_data *pss = (struct per_session_data *)user;
    int n;

    switch(reason) {
    case LWS_CALLBACK_ESTABLISHED:
        if (verbose)
            printf("websocket_callback: Established\n");

        /* Close current session, if any */
        close_session(current_data);

        pss->buffer = NULL;
        pss->wlen = 0;
        pss->pipeout_waiting = 0;
        pss->active = 1;
        current_data = pss;
        break;

    case LWS_CALLBACK_CLOSED:
        if (verbose)
            printf("websocket_callback: Closed\n");

        free(pss->buffer);

        if (pss->pipeout_waiting) {
            write_pipeoutstr("Error: Websocket closed.");
            pss->pipeout_waiting = 0;
        }

        if (current_data == pss)
            current_data = NULL;

        break;

    case LWS_CALLBACK_SERVER_WRITEABLE:
        if (verbose)
            printf("websocket_callback: Writeable\n");

        if (pss->buffer) {
            if (verbose)
                printf("Writing buffer (%d).\n", pss->wlen);

            n = libwebsocket_write(wsi,
                &pss->buffer[LWS_SEND_BUFFER_PRE_PADDING], pss->wlen,
                                                    LWS_WRITE_TEXT);
            free(pss->buffer);
            pss->buffer = NULL;

            if (n < 0) {
                fprintf(stderr,
                    "websocket_callback: ERROR %d writing to socket\n", n);
                return -1;
            }

            if (n < pss->wlen) {
                fprintf(stderr,
                    "websocket_callback: Partial write (%d/%d)\n",
                                                            n, pss->wlen);
                return -1;
            }
        } else {
            if (verbose)
                printf("LWS_CALLBACK_SERVER_WRITEABLE, but nothing to write.\n");
        }

        if (!pss->active) {
            /* This connection is inactive: hang up. */
            return -1;
        }

        break;

    case LWS_CALLBACK_RECEIVE:
        if (!pss->active) {
            fprintf(stderr,
                "websocket_callback: data on inactive connection!\n");
            libwebsocket_callback_on_writable(context, wsi);
            return 0;
        }

        if (len == 0) {
            fprintf(stderr, "websocket_callback: 0-length packet!\n");
            return 0;
        }

        if (pss->buffer != NULL) {
            fprintf(stderr, "websocket_callback: pss->buffer should be NULL!");
            free(pss->buffer);
            pss->buffer = NULL;
        }

        if (verbose)
            printf("cmd=%c\n", *((char*)in));

        switch(*((char*)in)) {
        case 'V': /* Version */
            pss->buffer = malloc(LWS_SEND_BUFFER_PRE_PADDING+16+
                                             LWS_SEND_BUFFER_POST_PADDING);
            pss->wlen = snprintf(
                (char*)&pss->buffer[LWS_SEND_BUFFER_PRE_PADDING], 16,
                "V%d", VERSION);
            libwebsocket_callback_on_writable(context, wsi);
            break;
        case 'R': /* Read */
        case 'W': /* Write */
            write_pipeout(in, len);
            pss->pipeout_waiting = 0;
            break;
        default:
            fprintf(stderr, "Invalid command %c\n", *((char*)in));
        }

        break;

    default:
        printf("Callback reason %d\n", reason);
    }

    return 0;
}

/**/
/* Pipe in functions */
/**/

/* Flush the pipe, but ignore the data. */
static void flush_pipein(int pipein_fd, char* buffer, int buffersize) {
    while (read(pipein_fd, buffer, buffersize) > 0);
}

/* Read data from the pipe */
static void read_pipein(int pipein_fd) {
    int n;
    int wlen = 0;
    int buffersize = 4096;
    char* buffer = malloc(LWS_SEND_BUFFER_PRE_PADDING+buffersize+LWS_SEND_BUFFER_POST_PADDING);

    if (!current_data) {
        flush_pipein(pipein_fd, buffer, buffersize);
        free(buffer);
        write_pipeoutstr("Error: not connected\n");
        return;
    }

    while ((n = read(pipein_fd, buffer+LWS_SEND_BUFFER_PRE_PADDING+wlen, buffersize-wlen)) > 0) {
        wlen += n;
        if (verbose)
            printf("read n=%d wlen=%d\n", n, wlen);
        if (buffersize-wlen == 0) {
            if (buffersize >= 1048576) {
                fprintf(stderr, "Will not allocate more than 1MB of buffer.\n");
                /* Flush */
                flush_pipein(pipein_fd, buffer, buffersize);
                free(buffer);
                write_pipeoutstr("Error: too much data\n");
                return;
            }

            buffersize = buffersize * 2;
            buffer = realloc(buffer, LWS_SEND_BUFFER_PRE_PADDING+buffersize+LWS_SEND_BUFFER_POST_PADDING);
        }
    }
    if (verbose)
        printf("EOF (wlen=%d)\n", wlen);

    char cmd = buffer[LWS_SEND_BUFFER_PRE_PADDING];

    if (cmd == 'R' || cmd == 'W') {
        current_data->buffer = (unsigned char*)buffer;
        current_data->wlen = wlen;
        libwebsocket_callback_on_writable_all_protocol(protocols);
    } else {
        fprintf(stderr, "Invalid command: %c\n", cmd);
        free(buffer);
        write_pipeoutstr("Error: Invalid command\n");
        return;
    }
}

int main(int argc, char **argv)
{
    int n = 0;
    struct libwebsocket_context *context;
    int opts = 0;
    struct lws_context_creation_info info;
    struct pollfd fds[2];
    int nfds;
    int pipein_fd = -1;

    memset(&info, 0, sizeof info);

    info.port = PORT;
    info.iface = "lo";
    info.protocols = protocols;
    info.gid = -1;
    info.uid = -1;
    info.options = opts;

    context = libwebsocket_create_context(&info);

    if (context == NULL) {
        fprintf(stderr, "libwebsocket init failed\n");
        return 1;
    }

    /* Create fifos */
    mkfifo(PIPEIN_FILENAME, S_IRUSR|S_IWUSR);
    mkfifo(PIPEOUT_FILENAME, S_IRUSR|S_IWUSR);

    pipein_fd = open(PIPEIN_FILENAME, O_RDONLY | O_NONBLOCK);

    if (pipein_fd < 0) {
        perror("main: cannot open pipe in.\n");
        return 1;
    }

    /* Now that open completed, make sure we block on further operations, until EOF */
    int flags = fcntl(pipein_fd, F_GETFL, 0);
    if (flags < 0) {
        perror("main: error in fnctl GETFL.\n");
        return 1;
    }

    n = fcntl(pipein_fd, F_SETFL, flags & ~O_NONBLOCK);
    if (n < 0) {
        perror("main: error in fnctl SETFL.\n");
        return 1;
    }

    memset(fds, 0, sizeof(fds));
    fds[0].fd = pipein_fd;
    fds[0].events = POLLIN;
    nfds = 1;

    if (verbose)
        printf("Main loop!\n");

    /* FIXME: Put everything in a single poll */
    n = 0;
    while (n >= 0) {
        n = libwebsocket_service(context, 10);

        int n2 = poll(fds, nfds, 10);
        if (n2 > 0) {
            if (fds[0].revents & POLLIN) {
                read_pipein(pipein_fd);
            }
        }
    }

    libwebsocket_context_destroy(context);

    return 0;
}
