/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket server to interface with crouton Chromium extension, that provides
 * clipboard synchronization.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>

const int BUFFERSIZE = 4096;

/* Websocket constants */
#define VERSION "0"
const int PORT = 30001;
const int FRAMEMAXHEADERSIZE = 2+8;
const int MAXFRAMESIZE = 1048576; // 1MiB
const char* GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/* Pipe constants */
const char* PIPEIN_FILENAME = "/tmp/crouton-websocket-in";
const char* PIPEOUT_FILENAME = "/tmp/crouton-websocket-out";
const int PIPEOUT_WRITE_TIMEOUT = 3000;

static int verbose = 0;

static int server_fd = -1;
static int pipein_fd = -1;
static int client_fd = -1;

/* Poll array:
 * 0 - server_fd
 * 1 - pipein_fd
 * 2 - client_fd (if any)
 */
static struct pollfd fds[3];

static int socket_client_write_packet(char* buffer, unsigned int size, unsigned int opcode, int fin);
static int socket_client_read_packet(char** buffer, unsigned int* size, unsigned int* opcode);

/**/
/* Pipe out functions */
/**/

/* Write some data to the pipe out. */
static void pipeout_write(char* buffer, int len) {
    int pipeout_fd;
    int i;

    if (verbose)
        printf("write_pipeout: opening pipe out\n");

    for (i = 0; i < PIPEOUT_WRITE_TIMEOUT/10; i++) {
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
static void pipeout_writestr(char* str) {
    pipeout_write(str, strlen(str));
}

/**/
/* Pipe in functions */
/**/

/* Flush the pipe, but ignore the data. */
static void pipein_flush(char* buffer, int buffersize) {
    while (read(pipein_fd, buffer, buffersize) > 0);
}

/* Read data from the pipe */
static void pipein_read() {
    int n;
    int wlen = 0;
    int buffersize = BUFFERSIZE;
    char* buffer = malloc(FRAMEMAXHEADERSIZE+buffersize);

    if (client_fd < 0) {
        pipein_flush(buffer, buffersize);
        free(buffer);
        pipeout_writestr("Error: not connected\n");
        return;
    }

    while ((n = read(pipein_fd, buffer+FRAMEMAXHEADERSIZE+wlen, buffersize-wlen)) > 0) {
        wlen += n;
        if (verbose)
            printf("read n=%d wlen=%d\n", n, wlen);
        if (buffersize-wlen == 0) {
            if (buffersize >= 1048576) {
                fprintf(stderr, "Will not allocate more than 1MB of buffer.\n");
                /* Flush */
                pipein_flush(buffer, buffersize);
                free(buffer);
                pipeout_writestr("Error: too much data\n");
                return;
            }

            buffersize = buffersize * 2;
            buffer = realloc(buffer, FRAMEMAXHEADERSIZE+buffersize);
        }
    }
    if (verbose)
        printf("EOF (wlen=%d)\n", wlen);

    char cmd = buffer[FRAMEMAXHEADERSIZE];

    socket_client_write_packet(buffer, wlen, 1, 1);
    free(buffer);
    unsigned int opcode;
    unsigned int rlen;
    socket_client_read_packet(&buffer, &rlen, &opcode);
    pipeout_write(buffer, rlen);
}

/**/
/*  Websocket functions. */
/**/

static void socket_client_close() {
    close(client_fd);
    client_fd = -1;
    fds[2].fd = -1;
}


/* FIXME: Is there a way to get rid of these functions, socket options?! */
/* Read exactly size bytes from fd, no matter how many reads it takes */
static int block_read(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = read(fd, buffer+tot, size-tot);
        printf("block_read n=%d+%d/%d\n", n, tot, size);
        if (n < 0) return n;
        tot += n;
        if (n == 0 && tot < size) return -1; /* EOF */
    }

    return tot;
}

/* Write exactly size bytes from fd, no matter how many writes it takes */
static int block_write(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = write(fd, buffer+tot, size-tot);
        if (n < 0) return n;
        tot += n;
    }

    return tot;
}


/* buffer needs to be FRAMEMAXHEADERSIZE+size long,
 * and data must start at buffer[FRAMEMAXHEADERSIZE] only. */
static int socket_client_write_packet(char* buffer, unsigned int size, unsigned int opcode, int fin) {
    char* pbuffer = buffer+FRAMEMAXHEADERSIZE-2;
    int payloadlen = size;
    int extlensize = 0;
    int i;

    if (payloadlen > 125) {
        if (payloadlen < 65536) {
            payloadlen = 126;
            extlensize = 2;
        } else {
            payloadlen = 127;
            extlensize = 8;
        }
        pbuffer -= extlensize;

        unsigned int tmpsize = size;
        for (i = extlensize-1; i >= 0; i--) {
            pbuffer[2+i] = tmpsize & 0xff;
            tmpsize >>= 8;
        }
    }

    pbuffer[0] = 0x00;
    if (fin) pbuffer[0] |= 0x80;
    pbuffer[0] |= (opcode & 0x0f);
    pbuffer[1] = payloadlen; /* No mask there */

    if (block_write(client_fd, pbuffer, 2+extlensize+size) < 0) {
        fprintf(stderr, "Write error\n");
        socket_client_close();
        return -1;
    }

    return size;
}

static int socket_client_read_packet(char** buffer, unsigned int* size, unsigned int* opcode) {
    char header[2]; /* Min header length */
    char extlen[8]; /* Extended length */
    uint32_t maskkey; /* Masking key */
    int n, i;

    *buffer = NULL;
    *size = 0;
    *opcode = 0;

    n = block_read(client_fd, header, 2);
    if (n < 0) {
        fprintf(stderr, "Read error.\n");
        socket_client_close();
        return -1;
    }

    for (i = 0; i < n; i++) {
        printf("%02x", header[i]);
    }
    printf("\n");

    int fin, mask;
    uint64_t length;
    fin = !!(header[0] & 0x80);
    if (header[0] & 0x70) { /* Reserved bits are on */
        fprintf(stderr, "Reserved bits are on.\n");
        socket_client_close();
        return -1;
    }
    *opcode = header[0] & 0x0F;
    mask = !!(header[1] & 0x80);
    length = header[1] & 0x7F;

    printf("fin=%d; opcode=%d; mask=%d; length=%lld\n", fin, *opcode, mask, length);

    int extlensize = 0;
    if (length == 126) extlensize = 2;
    else if (length == 127) extlensize = 8;

    if (extlensize > 0) {
        n = block_read(client_fd, extlen, extlensize);
        if (n < 0) {
            fprintf(stderr, "Read error.\n");
            socket_client_close();
            return -1;
        }

        length = 0;
        for (i = 0; i < extlensize; i++) {
            length = length << 8 | extlen[i];
        }

        printf("updated length=%lld\n", length);
    }

    if (mask) {
        n = block_read(client_fd, (char*)&maskkey, 4);
        if (n < 0) {
            fprintf(stderr, "Read error.\n");
            socket_client_close();
            return -1;
        }
    } else {
        maskkey = 0;
    }

    printf("maskingkey=%04x\n", maskkey);

    if (length > MAXFRAMESIZE) {
        fprintf(stderr, "Frame too big! (%lld>%d)\n", length, MAXFRAMESIZE);
        socket_client_close();
        return -1;
    }

    /* +3 to make sure we always have enough space for the unmasking */
    *buffer = malloc(length+3);
    n = block_read(client_fd, *buffer, length);
    if (n < 0) {
        fprintf(stderr, "Read error.\n");
        free(*buffer);
        *buffer = NULL;
        socket_client_close();
        return -1;
    }

    if (maskkey != 0) {
        int len32 = (length+3)/4;
        uint32_t* buffer32 = (uint32_t*)*buffer;
        for (i = 0; i < len32; i++) {
            buffer32[i] = buffer32[i] ^ maskkey;
        }
    }

    /*
    for (i = 0; i < length; i++) {
        printf("%02x(%c)", (*buffer)[i], (*buffer)[i]);
    }
    printf("\n");*/

    /* FIXME: React on opcode */

    *size = length;

    return 0;
}

/* "Unexpected" data came in from client. */
static void socket_client_read() {
    char* buffer;
    unsigned int size;
    unsigned int opcode;

    socket_client_read_packet(&buffer, &size, &opcode);

    if (opcode == 1 && size == 1 && buffer[0] == 'V') {
        char* version = "V"VERSION;
        int versionlen = strlen(version);
        char* outbuf = malloc(FRAMEMAXHEADERSIZE+versionlen);
        memcpy(outbuf+FRAMEMAXHEADERSIZE, version, versionlen);
        socket_client_write_packet(outbuf, versionlen, 1, 1);
        free(outbuf);
    }

    free(buffer);
}

static int popen2(char* cmd, char* input, int inlen, char* output, int outlen) {
    pid_t pid = 0;
    int stdin_fd[2];
    int stdout_fd[2];

    if (pipe(stdin_fd) || pipe(stdout_fd)) {
        perror("Failed to create pipe!");
        return -1;
    }

    pid = fork();

    if (pid < 0) {
        perror("Fork error.\n");
        return -1;
    } else if (pid == 0) {
        close(stdin_fd[1]);
        dup2(stdin_fd[0], STDIN_FILENO);
        close(stdout_fd[0]);
        dup2(stdout_fd[1], STDOUT_FILENO);
        execlp(cmd, cmd, NULL);
        fprintf(stderr, "Error running %s\n", cmd);
        exit(1);
    }

    if (write(stdin_fd[1], input, inlen) != inlen) {
        perror("popen2: Cannot write to pipe!\n");
    }
    close(stdin_fd[1]);
    outlen = read(stdout_fd[0], output, outlen);
    close(stdout_fd[0]);
    return outlen;
}

static void socket_server_accept() {
    int newclient_fd;
    struct sockaddr_in client_addr;
    unsigned int client_addr_len = sizeof(client_addr);
    char buffer[BUFFERSIZE];

    newclient_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_addr_len);

    if (newclient_fd < 0) {
        perror("Error accepting new connection.\n");
        return;
    }

    int first = 1;
    /* bitmask whether we received everything we need in the header:
     *  - 0x01: Upgrade
     *  - 0x02: Connection
     *  - 0x04: Sec-WebSocket-Version
     *  - 0x08: Sec-WebSocket-Key
     *  - 0x10: Host
     *
     * Therefore a correct final value is 0x1F
     */
    int ok = 0x00;
    char* websocket_key = NULL;
    int websocket_keylen = 0;
    char* pbuffer = buffer;
    int n = read(newclient_fd, buffer, BUFFERSIZE);
    if (n <= 0) {
        perror("Cannot read from client");
        goto error;
    }
    while (1) {
        char* key = pbuffer;
        char* value = NULL;

        while (1) {
            if (n == 0) {
                /* No more data in buffer: read more */
                memmove(buffer, key, pbuffer-key);
                if (value) value -= (key-buffer);
                pbuffer -= (key-buffer);
                key = buffer;
                n = read(newclient_fd, pbuffer, BUFFERSIZE-(pbuffer-buffer));
                if (n < 0) {
                    perror("Cannot read from client");
                    goto error;
                }
            }
            if (*pbuffer == '\n') {
                *(pbuffer-1) = '\0';
                n--; pbuffer++;
                break;
            }
            if (*pbuffer == ':' && !value) {
                value = pbuffer+2;
                *pbuffer = '\0';
            }

            n--; pbuffer++;
        }

        printf("key=%s; value=%s\n", key, value);

        if (strlen(key) == 0 && !value) {
            goto out;
        }

        if (first) {
            if (strcmp(key, "GET / HTTP/1.1")) {
                fprintf(stderr, "Invalid header.\n");
                goto error;
            }
            first = 0;
        } else {
            if (!strcmp(key, "Upgrade") && !strcmp(value, "websocket")) {
                ok |= 0x01;
            } else if (!strcmp(key, "Connection") && !strcmp(value, "Upgrade")) {
                ok |= 0x02;
            } else if (!strcmp(key, "Sec-WebSocket-Version")) {
                if (strcmp(value, "13")) {
                    fprintf(stderr, "Invalid Sec-WebSocket-Version: %s\n", value);
                    goto error;
                }
                ok |= 0x04;
            } else if (!strcmp(key, "Sec-WebSocket-Key")) {
                int valuelen = strlen(value);
                websocket_keylen = valuelen+strlen(GUID);
                websocket_key = malloc(websocket_keylen);
                memcpy(websocket_key, value, valuelen);
                memcpy(websocket_key+valuelen, GUID, strlen(GUID));
                ok |= 0x08;
            } else if (!strcmp(key, "Host")) {
                /* FIXME: We ignore the value (RFC says we should not...) */
                ok |= 0x10;
            }
        }
    }
out:
    if (ok != 0x1F) {
        fprintf(stderr, "Some websocket headers missing (%x)\n", ok);
        goto error;
    }
    printf("Header read successfully.\n");

    /* Compute response */
    char sha1[20];
    char b64[32];
    int i;
    n = popen2("sha1sum", websocket_key, websocket_keylen, buffer, BUFFERSIZE);
    free(websocket_key);

    if (n < 40) {
        fprintf(stderr, "sha1sum response too short.\n");
        exit(1);
    }

    for (i = 0; i < 20; i++) {
        unsigned int value;
        n = sscanf(&buffer[i*2], "%02x", &value);
        sha1[i] = (char)value;
    }

    n = popen2("base64", sha1, 20, b64, 32);
    /* base64 encoding of 20 bytes must be 28 bytes long (ceil(20/3*4)+1).
     * +1 for line feed */
    if (n != 29) {
        fprintf(stderr, "Invalid base64 response.\n");
        exit(1);
    }
    b64[28] = '\0';

    int len = snprintf(buffer, BUFFERSIZE,
        "HTTP/1.1 101 Switching Protocols\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: %s\r\n" \
        "\r\n", b64);

    n = write(newclient_fd, buffer, len);

    if (n < 0) {
        perror("Cannot write response");
        goto error;
    } else if (n != len) {
        fprintf(stderr, "Incomplete write\n");
        goto error;
    }

    printf("Reponse sent\n");

    /* FIXME: Clean up old fd first. */

    client_fd = newclient_fd;
    fds[2].fd = newclient_fd;

    return;

error:
    /* FIXME: RFC says we MUST reply with a HTTP 400 Bad Request, or
     * a different code depening on the reason... */

    if (websocket_key)
        free(websocket_key);

    close(newclient_fd);
}

static void socket_server_init() {
    struct sockaddr_in server_addr;
    int optval;

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("Cannot create server socket");
        exit(1);
    }

    optval = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    server_addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("Cannot bind server socket");
        exit(1);
    }

    if (listen(server_fd, 1) < 0) {
        perror("Cannot listen on server socket");
        exit(1);
    }

    fds[0].fd = server_fd;
}

void pipe_init() {
    int n;

    /* Create fifos */
    /* FIXME: Error checking */
    mkfifo(PIPEIN_FILENAME, S_IRUSR|S_IWUSR);
    mkfifo(PIPEOUT_FILENAME, S_IRUSR|S_IWUSR);

    pipein_fd = open(PIPEIN_FILENAME, O_RDONLY | O_NONBLOCK);

    if (pipein_fd < 0) {
        perror("main: cannot open pipe in.\n");
        exit(1);
    }

    /* Now that open completed, make sure we block on further operations, until EOF */
    int flags = fcntl(pipein_fd, F_GETFL, 0);
    if (flags < 0) {
        perror("main: error in fnctl GETFL.\n");
        exit(1);
    }

    n = fcntl(pipein_fd, F_SETFL, flags & ~O_NONBLOCK);
    if (n < 0) {
        perror("main: error in fnctl SETFL.\n");
        exit(1);
    }

    fds[1].fd = pipein_fd;
}

int main(int argc, char **argv) {
    int n;
    int nfds = 3;

    memset(fds, 0, sizeof(fds));
    fds[0].fd = -1;
    fds[0].events = POLLIN;
    fds[1].fd = -1;
    fds[1].events = POLLIN;
    fds[2].fd = -1;
    fds[2].events = POLLIN;

    pipe_init();
    socket_server_init();

    while ((n = poll(fds, nfds, -1)) >= 0) {
        if (fds[0].revents & POLLIN) {
            printf("accept\n");
            socket_server_accept();
        }
        if (fds[1].revents & POLLIN) {
            printf("pipe data\n");
            pipein_read();
        }
        if (fds[2].revents & POLLIN) {
            printf("client data\n");
            socket_client_read();
        }
    }

    return 0;
}
