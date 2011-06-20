/*
Copyright 2008-2011 Ostap Cherkashin
Copyright 2008-2011 Julius Chrobak

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
#include "memory.h"
#include "string.h"
#include "head.h"
#include "http.h"
#include "value.h"
#include "tuple.h"
#include "volume.h"
#include "expression.h"
#include "summary.h"
#include "relation.h"
#include "transaction.h"
#include "environment.h"
#include "pack.h"

extern const char *VERSION;

#define QUEUE_LEN 128
#define THREADS 8
#define PROC_WAIT_SEC 5

typedef struct {
    char exe[MAX_FILE_PATH];
    char tx[MAX_ADDR];
} Exec;

struct {
    int pos;
    int len;
    IO *ios[QUEUE_LEN];
    Mon *mon;
} queue;

static void queue_init()
{
    queue.pos = -1;
    queue.len = QUEUE_LEN;
    queue.mon = mon_new();
}

static void queue_put(IO *io)
{
    mon_lock(queue.mon);
    while (queue.pos >= queue.len)
        mon_wait(queue.mon);

    queue.pos++;
    queue.ios[queue.pos] = io;

    mon_signal(queue.mon);
    mon_unlock(queue.mon);
}

static IO *queue_get()
{
    mon_lock(queue.mon);
    while (queue.pos < 0)
        mon_wait(queue.mon);

    IO *io = queue.ios[queue.pos];
    queue.pos--;

    mon_signal(queue.mon);
    mon_unlock(queue.mon);

    return io;
}

static void *exec_thread(void *arg)
{
    Exec *x = arg;
    int p = 0;
    IO *sio = sys_socket(&p);
    char port[8];
    str_print(port, "%d", p);
    char *argv[] = {x->exe, "processor", "-p", port, "-t", x->tx, NULL};

    for (;;) {
        IO *cio = queue_get();
        IO *pio = NULL;
        int status = 0, pid = -1, cio_cnt = 0, pio_cnt = 0;

        /* creating processor */
        pid = sys_exec(argv);
        if (!sys_iready(sio, PROC_WAIT_SEC)) {
            status = http_500(cio);
            goto exit;
        }

        pio = sys_accept(sio);

        /* sends HTTP 500 if the processor dies without sending data
           to the client */
        sys_exchange(cio, &cio_cnt, pio, &pio_cnt);
        if (pio_cnt == 0)
            status = http_500(cio);
exit:
        if (status != 0)
            sys_log('E', "failed with status %d\n", status);
        if (pid != -1)
            sys_wait(pid);
        if (pio != NULL)
            sys_close(pio);
        sys_close(cio);
    }

    sys_close(sio);
    mem_free(x);

    return NULL;
}

static void processor(const char *tx_addr, int port)
{
    int status = -1;
    long sid = 0, time = sys_millis();

    TBuf *arg = NULL;
    Vars *r = NULL, *w = NULL;

    /* connect to the control thread */
    char addr[MAX_ADDR];
    sys_address(addr, port);
    IO *io = sys_connect(addr);

    Http_Req *req = http_parse(io);
    if (req == NULL) {
        status = http_400(io);
        goto exit;
    }

    if (req->method == OPTIONS) {
        status = http_opts(io);
        goto exit;
    }

    /* get env from the tx */
    tx_attach(tx_addr);
    char *code = tx_program();
    Env *env = env_new("net", code);
    mem_free(code);

    /* compare the request with the function defintion */
    Func *fn = env_func(env, req->path + 1);
    if (fn == NULL) {
        status = http_404(io);
        goto exit;
    }

    if ((fn->p.len == 1 && req->method != POST) ||
        (fn->p.len == 0 && req->method == POST))
    {
        status = http_405(io);
        goto exit;
    } if (fn->p.len == 1) {
        Head *head = NULL;
        arg = rel_pack_sep(req->body, &head);

        int eq = 0;
        if (head != NULL) {
            eq = head_eq(head, fn->p.rels[0]->head);
            mem_free(head);
        }

        if (arg == NULL || !eq) {
            status = http_400(io);
            goto exit;
        }
    }

    /* start a transaction */
    r = vars_new(fn->r.len);
    w = vars_new(fn->w.len);
    for (int i = 0; i < fn->r.len; ++i)
        vars_put(r, fn->r.names[i], 0L);
    for (int i = 0; i < fn->w.len; ++i)
        vars_put(w, fn->w.names[i], 0L);

    sid = tx_enter(addr, r, w);

    /* execute the function body */
    for (int i = 0; i < fn->p.len; ++i)
        rel_init(fn->p.rels[i], r, arg);

    for (int i = 0; i < fn->t.len; ++i)
        rel_init(fn->t.rels[i], r, arg);

    for (int i = 0; i < fn->w.len; ++i) {
        rel_init(fn->w.rels[i], r, arg);
        rel_store(w->vols[i], w->names[i], w->vers[i], fn->w.rels[i]);
    }

    if (fn->ret != NULL)
        rel_init(fn->ret, r, arg);

    /* need to set to NULL do avoid double-free in exit */
    arg = NULL;

    /* TODO: commit should not happen if the client has closed the connection */
    tx_commit(sid);

    /* confirm a success and send the result back */
    status = http_200(io);
    if (fn->ret != NULL) {
        int size;
        char *res = rel_unpack(fn->ret->head, fn->ret->body, &size);
        status = http_chunk(io, res, size);

        mem_free(res);
        tbuf_free(fn->ret->body);
        fn->ret->body = NULL;
    }
    status = http_chunk(io, NULL, 0);

exit:
    sys_log('E', "%016X method %c, path %s, time %dms - %3d\n",
                 sid,
                 (req == NULL) ? '?' : req->method,
                 (req == NULL) ? "malformed" : req->path,
                 sys_millis() - time,
                 status);

    if (r != NULL)
        vars_free(r);
    if (w != NULL)
        vars_free(w);
    if (env != NULL)
        env_free(env);
    if (arg != NULL) {
        tbuf_clean(arg);
        tbuf_free(arg);
    }
    if (req != NULL)
        mem_free(req);
    sys_close(io);
}

static void usage(char *p)
{
    sys_print("usage: %s <command> <args>\n\n", p);
    sys_print("standalone commands:\n");
    sys_print("  start -p <port> -d <data.dir> -c <source.file>"
              " -s <state.file>\n\n");
    sys_print("distributed commands:\n");
    sys_print("  tx    -p <port> -c <source.file> -s <state.file>\n");
    sys_print("  vol   -p <port> -d <data.dir> -t <tx.host:port>\n");
    sys_print("  exec  -p <port> -t <tx.host:port>\n\n");

    sys_die(VERSION);
}

static int parse_port(char *p)
{
    int port = 0, e = -1;
    port = str_int(p, &e);
    if (e || port < 1 || port > 65535)
        sys_die("invalid port '%s'\n", p);

    return port;
}

static void multiplex(const char *exe, const char *tx_addr, int port)
{
    queue_init();

    for (int i = 0; i < THREADS; ++i) {
        Exec *e = mem_alloc(sizeof(Exec));
        str_cpy(e->exe, exe);
        str_cpy(e->tx, tx_addr);

        sys_thread(exec_thread, e);
    }

    IO *sio = sys_socket(&port);

    sys_log('E', "started port=%d, tx=%s\n", port, tx_addr);

    for (;;) {
        IO *cio = sys_accept(sio);
        queue_put(cio);
    }

    mon_free(queue.mon);
}

int main(int argc, char *argv[])
{
    int port = 0;
    char *data = NULL;
    char *state = NULL;
    char *source = NULL;
    char *tx_addr = NULL;

    sys_init(1);
    if (argc < 2)
        usage(argv[0]);

    for (int i = 2; (i + 1) < argc; i += 2)
        if (str_cmp(argv[i], "-d") == 0)
            data = argv[i + 1];
        else if (str_cmp(argv[i], "-c") == 0)
            source = argv[i + 1];
        else if (str_cmp(argv[i], "-s") == 0)
            state = argv[i + 1];
        else if (str_cmp(argv[i], "-p") == 0)
            port = parse_port(argv[i + 1]);
        else if (str_cmp(argv[i], "-t") == 0) {
            tx_addr = argv[i + 1];
            if (str_len(tx_addr) >= MAX_ADDR)
                sys_die("tx address exceeds the maximum length\n");
        } else
            usage(argv[0]);

    if (str_cmp(argv[1], "start") == 0 && source != NULL && data != NULL &&
        state != NULL && port != 0 && tx_addr == NULL)
    {
        int tx_port = 0;
        tx_server(source, state, &tx_port);
        vol_init(0, data);

        char addr[MAX_ADDR];
        str_print(addr, "127.0.0.1:%d", tx_port);
        multiplex(argv[0], addr, port);

        tx_free();
    } else if (str_cmp(argv[1], "processor") == 0 && source == NULL &&
               data == NULL && state == NULL && port != 0 && tx_addr != NULL)
    {
        processor(tx_addr, port);
    } else if (str_cmp(argv[1], "tx") == 0 && source != NULL &&
               data == NULL && state != NULL && port != 0 && tx_addr == NULL)
    {
        tx_server(source, state, &port);
    } else if (str_cmp(argv[1], "vol") == 0 && source == NULL &&
               data != NULL && state == NULL && port != 0 && tx_addr != NULL)
    {
        tx_attach(tx_addr);
        vol_init(port, data);
    } else if (str_cmp(argv[1], "exec") == 0 && source == NULL &&
               data == NULL && state == NULL && port != 0 && tx_addr != NULL)
    {
        tx_attach(tx_addr);
        multiplex(argv[0], tx_addr, port);
    } else
        usage(argv[0]);

    return 0;
}
