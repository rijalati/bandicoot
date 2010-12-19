/*
Copyright 2008-2010 Ostap Cherkashin
Copyright 2008-2010 Julius Chrobak

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include "config.h"
#include "system.h"
#include "string.h"
#include "memory.h"
#include "http.h"

static const char *HTTP_400 =
    "HTTP/1.1 400 Bad Request\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 0\r\n\r\n";

static const char *HTTP_404 =
    "HTTP/1.1 404 Not Found\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 0\r\n\r\n";

static const char *HTTP_405 =
    "HTTP/1.1 405 Method Not Allowed\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 0\r\n\r\n";

static const char *HTTP_500 =
    "HTTP/1.1 500 Internal Server Error\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 0\r\n\r\n";

static const char *HTTP_OPTS =
    "HTTP/1.1 200 OK\r\n"
    "Access-Control-Allow-Origin: *\r\n"
    "Access-Control-Allow-Methods: OPTIONS, GET, POST\r\n"
    "Access-Control-Allow-Headers: Content-Type, Content-Length\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 0\r\n\r\n";

static const char *HTTP_200 =
    "HTTP/1.1 200 OK\r\n"
    "Access-Control-Allow-Origin: *\r\n"
    "Access-Control-Allow-Methods: OPTIONS, GET, POST\r\n"
    "Access-Control-Allow-Headers: Content-Type, Content-Length\r\n"
    "Content-Type: text/plain\r\n"
    "Transfer-Encoding: chunked\r\n\r\n";

/* TODO: support HEAD method (e.g. to check if a func takes input params) */
/* TODO: support absolute URIs */
/* TODO: support transfer chunked encoding as input */

/* FIXME: sys_{read,write} calls cause sys_die in case of an IO error which
          can happen when (for example) clients close the socket connection
          prematurely; it looks like we should introduce sys_{send,recv} which
          do not shutdown the system */

static char *next(char *buf, const char *sep, int *off)
{
    int len = str_len(sep), idx = str_idx(buf + *off, sep);
    if (idx < 0)
        return NULL;

    buf[*off + idx] = '\0';

    char *res = buf + *off;
    *off += idx + len;

    return str_trim(res);
}

extern Http_Req *http_parse(int fd)
{
    Http_Req *req = NULL;
    char *buf, *head, *line, *p, path[MAX_NAME], method[MAX_NAME];
    int read = 0, body_start = 0, head_off = 0, off = 0;

    buf = mem_alloc(8192);
    read = sys_read(fd, buf, 8191);
    buf[read] = '\0';

    if ((head = next(buf, "\r\n\r\n", &body_start)) == NULL)
        goto exit;

    if ((line = next(head, "\r\n", &head_off)) == NULL)
        goto exit;

    if ((p = next(line, " ", &off)) == NULL)
        goto exit;

    str_cpy(method, p);

    if ((p = next(line, " ", &off)) == NULL)
        goto exit;

    str_cpy(path, p);

    if (str_cmp(line + off, "HTTP/1.1") != 0)
        goto exit;

    int m, size = 0;
    if (str_cmp(method, "POST") == 0) {
        m = POST;

        if ((p = next(head, "Content-Length:", &head_off)) == NULL)
            goto exit;

        p = next(head, "\r\n", &head_off);
        if (p == NULL) /* content length is the last header */
            p = str_trim(head + head_off);

        int error = 0;
        size = str_int(p, &error);
        if (error || size < 0)
            goto exit;

        int remaining = size - read + body_start;
        if (remaining > 0) {
            buf = mem_realloc(buf, read + remaining);

            off = read;
            while ((read = sys_read(fd, buf + off, remaining)) > 0) {
                off += read;
                remaining -= read;
            }
        }

        /* TODO: the same "if" appears twice */
        if (remaining > 0)
            goto exit;
    } else if (str_cmp(method, "GET") == 0) {
        m = GET;
    } else if (str_cmp(method, "OPTIONS") == 0) {
        m = OPTIONS;
    } else
        goto exit;

    req = mem_alloc(sizeof(Http_Req) + size + 1);
    req->body = (char*) (req + 1);
    req->method = m;
    str_cpy(req->path, path);
    if (size > 0)
        mem_cpy(req->body, buf + body_start, size);
    req->body[size] = '\0';

exit:
    mem_free(buf);

    return req;
}

extern int http_200(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_200);

    sys_write(fd, HTTP_200, size);

    return 200;
}

extern int http_400(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_400);

    sys_write(fd, HTTP_400, size);

    return 400;
}

extern int http_404(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_404);

    sys_write(fd, HTTP_404, size);

    return 404;
}

extern int http_405(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_405);

    sys_write(fd, HTTP_405, size);

    return 405;
}

extern int http_500(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_500);

    sys_write(fd, HTTP_500, size);

    return 500;
}

extern int http_opts(int fd)
{
    static int size;
    if (size == 0)
        size = str_len(HTTP_OPTS);

    sys_write(fd, HTTP_OPTS, size);

    return 200;
}

extern void http_chunk(int fd, const void *buf, int size)
{
    char hex[16];
    int s = str_print(hex, "%X\r\n", size);
    sys_write(fd, hex, s);
    sys_write(fd, buf, size);
    sys_write(fd, "\r\n", 2);
}
