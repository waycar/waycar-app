/*
 * Host-side regression test for Waycar's libssh2 patches (Patches/libssh2),
 * run by Scripts/test-libssh2-patches.sh against a disposable loopback sshd.
 * Every subcommand runs one SSH connection in non-blocking mode, the way
 * SessionDriver drives libssh2, and prints key=value results the script
 * asserts on. Any unexpected libssh2 result exits non-zero.
 */
#include <libssh2.h>

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/pem.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct key {
    EVP_PKEY *pkey;
    int is_rsa;
    unsigned char blob[2048];
    size_t blob_len;
    char *pem;
    size_t pem_len;
    char signed_alg[64];
    int sign_count;
};

struct conn {
    int sock;
    LIBSSH2_SESSION *session;
    long eagains;
};

static void fail(struct conn *c, const char *fmt, ...)
{
    va_list ap;
    char *msg = NULL;

    fprintf(stderr, "FAIL: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if(c && c->session) {
        libssh2_session_last_error(c->session, &msg, NULL, 0);
        fprintf(stderr, " (libssh2: %s)", msg ? msg : "");
    }
    fprintf(stderr, "\n");
    exit(1);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

/* Waits for the direction libssh2 reported it is blocked on. */
static void wait_io(struct conn *c)
{
    int dir = libssh2_session_block_directions(c->session);
    fd_set rfds, wfds;
    struct timeval tv = { 15, 0 };
    int rc;

    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    if(!dir || (dir & LIBSSH2_SESSION_BLOCK_INBOUND))
        FD_SET(c->sock, &rfds);
    if(dir & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        FD_SET(c->sock, &wfds);
    rc = select(c->sock + 1, &rfds, &wfds, NULL, &tv);
    if(rc == 0)
        fail(c, "timed out waiting for the socket");
    if(rc < 0 && errno != EINTR)
        fail(c, "select: %s", strerror(errno));
    c->eagains++;
}

#define DRIVE(c, rc, call) \
    do { \
        while(((rc) = (call)) == LIBSSH2_ERROR_EAGAIN) \
            wait_io(c); \
    } while(0)

static char *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    char *buf;
    long size;

    if(!f)
        fail(NULL, "open %s: %s", path, strerror(errno));
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc((size_t)size + 1);
    if(!buf || fread(buf, 1, (size_t)size, f) != (size_t)size)
        fail(NULL, "read %s", path);
    buf[size] = '\0';
    fclose(f);
    *len = (size_t)size;
    return buf;
}

static void put_u32(unsigned char **p, uint32_t v)
{
    (*p)[0] = (unsigned char)(v >> 24);
    (*p)[1] = (unsigned char)(v >> 16);
    (*p)[2] = (unsigned char)(v >> 8);
    (*p)[3] = (unsigned char)v;
    *p += 4;
}

static void put_str(unsigned char **p, const void *s, size_t len)
{
    put_u32(p, (uint32_t)len);
    memcpy(*p, s, len);
    *p += len;
}

static void put_mpint(unsigned char **p, const BIGNUM *bn)
{
    unsigned char buf[1024];
    int len = BN_bn2bin(bn, buf + 1);

    buf[0] = 0;
    if(buf[1] & 0x80)
        put_str(p, buf, (size_t)len + 1);
    else
        put_str(p, buf + 1, (size_t)len);
}

static void load_key(struct key *k, const char *path)
{
    FILE *f = fopen(path, "r");
    unsigned char *p = k->blob;

    memset(k, 0, sizeof(*k));
    if(!f)
        fail(NULL, "open %s", path);
    k->pkey = PEM_read_PrivateKey(f, NULL, NULL, NULL);
    fclose(f);
    if(!k->pkey)
        fail(NULL, "parse %s", path);
    k->pem = read_file(path, &k->pem_len);

    if(EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_ED25519) {
        unsigned char pub[32];
        size_t pub_len = sizeof(pub);
        if(!EVP_PKEY_get_raw_public_key(k->pkey, pub, &pub_len))
            fail(NULL, "ed25519 public key");
        put_str(&p, "ssh-ed25519", 11);
        put_str(&p, pub, pub_len);
    }
    else if(EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_RSA) {
        BIGNUM *e = NULL, *n = NULL;
        if(!EVP_PKEY_get_bn_param(k->pkey, OSSL_PKEY_PARAM_RSA_E, &e) ||
           !EVP_PKEY_get_bn_param(k->pkey, OSSL_PKEY_PARAM_RSA_N, &n))
            fail(NULL, "rsa public key");
        k->is_rsa = 1;
        put_str(&p, "ssh-rsa", 7);
        put_mpint(&p, e);
        put_mpint(&p, n);
        BN_free(e);
        BN_free(n);
    }
    else
        fail(NULL, "unsupported key type in %s", path);
    k->blob_len = (size_t)(p - k->blob);
}

static int get_str(const unsigned char **p, const unsigned char *end,
                   const unsigned char **s, uint32_t *len)
{
    if(end - *p < 4)
        return -1;
    *len = ((uint32_t)(*p)[0] << 24) | ((uint32_t)(*p)[1] << 16) |
           ((uint32_t)(*p)[2] << 8) | (uint32_t)(*p)[3];
    *p += 4;
    if((uint32_t)(end - *p) < *len)
        return -1;
    *s = *p;
    *p += *len;
    return 0;
}

/*
 * Signs like SessionDriver's signer: Ed25519 directly, RSA only with the
 * rsa-sha2 algorithm named in the signed USERAUTH_REQUEST (never ssh-rsa).
 */
static int sign_callback(LIBSSH2_SESSION *session, unsigned char **sig,
                         size_t *sig_len, const unsigned char *data,
                         size_t data_len, void **abstract)
{
    struct key *k = *abstract;
    const unsigned char *p = data, *end = data + data_len, *s;
    const EVP_MD *md = NULL;
    EVP_MD_CTX *ctx;
    uint32_t len;
    int i;

    (void)session;
    /* session id, byte 50, user, service, "publickey", byte 1, algorithm */
    if(get_str(&p, end, &s, &len) || p >= end)
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    p++;
    for(i = 0; i < 3; i++)
        if(get_str(&p, end, &s, &len))
            return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    if(p >= end || *p != 1)
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    p++;
    if(get_str(&p, end, &s, &len) || len >= sizeof(k->signed_alg))
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    memcpy(k->signed_alg, s, len);
    k->signed_alg[len] = '\0';

    if(k->is_rsa) {
        if(!strcmp(k->signed_alg, "rsa-sha2-512"))
            md = EVP_sha512();
        else if(!strcmp(k->signed_alg, "rsa-sha2-256"))
            md = EVP_sha256();
        else
            return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    }

    ctx = EVP_MD_CTX_new();
    if(!ctx || EVP_DigestSignInit(ctx, NULL, md, NULL, k->pkey) != 1 ||
       EVP_DigestSign(ctx, NULL, sig_len, data, data_len) != 1)
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    *sig = malloc(*sig_len);
    if(!*sig || EVP_DigestSign(ctx, *sig, sig_len, data, data_len) != 1)
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED;
    EVP_MD_CTX_free(ctx);
    k->sign_count++;
    return 0;
}

static void connect_session(struct conn *c, int port)
{
    struct sockaddr_in addr;
    int one = 1;
    int rc;

    memset(c, 0, sizeof(*c));
    c->sock = socket(AF_INET, SOCK_STREAM, 0);
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if(connect(c->sock, (struct sockaddr *)&addr, sizeof(addr)))
        fail(NULL, "connect: %s", strerror(errno));
    setsockopt(c->sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    c->session = libssh2_session_init();
    if(!c->session)
        fail(NULL, "session init");
    libssh2_session_set_blocking(c->session, 0);
    DRIVE(c, rc, libssh2_session_handshake(c->session, c->sock));
    if(rc)
        fail(c, "handshake %d", rc);
}

static void disconnect_session(struct conn *c)
{
    int rc;

    DRIVE(c, rc, libssh2_session_disconnect(c->session, "done"));
    DRIVE(c, rc, libssh2_session_free(c->session));
    close(c->sock);
}

/* Authenticates; returns the libssh2 result and the elapsed time. */
static int authenticate(struct conn *c, struct key *k, const char *path,
                        int skip_query, double *elapsed)
{
    const char *user = getenv("USER");
    void *abstract = k;
    double start;
    int rc;

    if(skip_query &&
       libssh2_session_flag(c->session, LIBSSH2_FLAG_PUBKEY_SKIP_QUERY, 1))
        fail(c, "LIBSSH2_FLAG_PUBKEY_SKIP_QUERY rejected");
    start = now_ms();
    if(!strcmp(path, "callback"))
        DRIVE(c, rc, libssh2_userauth_publickey(c->session, user, k->blob,
                                                k->blob_len, sign_callback,
                                                &abstract));
    else
        DRIVE(c, rc, libssh2_userauth_publickey_frommemory(
                  c->session, user, strlen(user), NULL, 0, k->pem, k->pem_len,
                  NULL));
    *elapsed = now_ms() - start;
    return rc;
}

static void must_authenticate(struct conn *c, struct key *k)
{
    double elapsed;
    if(authenticate(c, k, "callback", 1, &elapsed))
        fail(c, "authentication");
}

static void print_escaped(const char *label, const char *s, size_t len)
{
    size_t i;
    printf("%s=", label);
    for(i = 0; i < len; i++)
        putchar(s[i] == '\n' ? '|' : (s[i] == '\r' ? ' ' : s[i]));
    putchar('\n');
}

/* Reads stdout (stderr merged into it) to EOF. */
static size_t read_all(struct conn *c, LIBSSH2_CHANNEL *ch, char *buf,
                       size_t cap)
{
    size_t len = 0;
    ssize_t n;

    for(;;) {
        n = libssh2_channel_read(ch, buf + len, cap - len - 1);
        if(n == LIBSSH2_ERROR_EAGAIN) {
            wait_io(c);
            continue;
        }
        if(n < 0)
            fail(c, "channel read %ld", (long)n);
        if(n == 0) {
            if(libssh2_channel_eof(ch))
                break;
            wait_io(c);
            continue;
        }
        len += (size_t)n;
        if(len + 1 >= cap)
            break;
    }
    buf[len] = '\0';
    return len;
}

static void free_channel(struct conn *c, LIBSSH2_CHANNEL *ch)
{
    int rc;
    DRIVE(c, rc, libssh2_channel_free(ch));
    if(rc)
        fail(c, "channel free %d", rc);
}

static LIBSSH2_CHANNEL *open_session_stock(struct conn *c)
{
    LIBSSH2_CHANNEL *ch;
    while(!(ch = libssh2_channel_open_session(c->session))) {
        if(libssh2_session_last_errno(c->session) != LIBSSH2_ERROR_EAGAIN)
            fail(c, "stock session open");
        wait_io(c);
    }
    return ch;
}

/* auth <port> <key> <callback|memory> <skip 0|1> */
static int cmd_auth(int argc, char **argv)
{
    struct conn c;
    struct key k;
    double elapsed;
    int rc;

    if(argc != 6)
        return 2;
    load_key(&k, argv[3]);
    connect_session(&c, atoi(argv[2]));
    rc = authenticate(&c, &k, argv[4], atoi(argv[5]), &elapsed);
    printf("rc=%d\nauth_ms=%.1f\nsign_count=%d\nsigned_alg=%s\n", rc,
           elapsed, k.sign_count, k.signed_alg);
    if(!rc && !libssh2_userauth_authenticated(c.session))
        fail(&c, "authenticated flag not set");
    disconnect_session(&c);
    return 0;
}

/*
 * ptyexec <port> <key> <combined|stock> <request> <message>
 * Requests a PTY then starts <request> with <message>, either with the
 * patched back-to-back call or with the two stock calls.
 */
static int cmd_ptyexec(int argc, char **argv)
{
    struct conn c;
    struct key k;
    LIBSSH2_CHANNEL *ch;
    const char *request, *message;
    char out[4096];
    size_t len;
    double start, elapsed;
    long eagains;
    int rc, denied = -1;

    if(argc != 7)
        return 2;
    request = argv[5];
    message = argv[6];
    load_key(&k, argv[3]);
    connect_session(&c, atoi(argv[2]));
    must_authenticate(&c, &k);
    ch = open_session_stock(&c);
    if(libssh2_channel_handle_extended_data2(ch,
                                             LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE))
        fail(&c, "merge stderr");

    eagains = c.eagains;
    start = now_ms();
    if(!strcmp(argv[4], "combined")) {
        DRIVE(&c, rc, libssh2_channel_request_pty_process_startup(
                  ch, "xterm-256color", 14, NULL, 0, 100, 30, 0, 0,
                  request, (unsigned int)strlen(request),
                  message, (unsigned int)strlen(message), &denied));
    }
    else {
        DRIVE(&c, rc, libssh2_channel_request_pty_ex(
                  ch, "xterm-256color", 14, NULL, 0, 100, 30, 0, 0));
        if(!rc)
            DRIVE(&c, rc, libssh2_channel_process_startup(
                      ch, request, (unsigned int)strlen(request),
                      message, (unsigned int)strlen(message)));
    }
    elapsed = now_ms() - start;
    printf("rc=%d\ndenied=%d\nrequest_ms=%.1f\nrequest_eagains=%ld\n", rc,
           denied, elapsed, c.eagains - eagains);
    if(rc == 0 || denied == LIBSSH2_CHANNEL_DENIED_PTY) {
        len = read_all(&c, ch, out, sizeof(out));
        print_escaped("output", out, len);
    }
    free_channel(&c, ch);
    disconnect_session(&c);
    return 0;
}

/* Opens a direct-streamlocal channel with the stock, one-at-a-time call. */
static LIBSSH2_CHANNEL *open_streamlocal_stock(struct conn *c,
                                               const char *path)
{
    LIBSSH2_CHANNEL *ch;
    while(!(ch = libssh2_channel_direct_streamlocal_ex(c->session, path,
                                                       "127.0.0.1", 0))) {
        if(libssh2_session_last_errno(c->session) != LIBSSH2_ERROR_EAGAIN)
            fail(c, "stock streamlocal open");
        wait_io(c);
    }
    return ch;
}

/*
 * Drives libssh2_channel_open_finish() over every unsettled channel until all
 * have settled; results[i] gets each final return code. The first pass sends
 * the requests in order; later passes wait in reverse order, so each waiter
 * reads replies that belong to other channels before its own.
 */
static void finish_all(struct conn *c, LIBSSH2_CHANNEL **ch, int *results,
                       int n)
{
    int pending = n, pass, k, i, rc;

    for(i = 0; i < n; i++)
        results[i] = LIBSSH2_ERROR_EAGAIN;
    for(pass = 0; pending; pass++) {
        for(k = 0; k < n; k++) {
            i = pass ? n - 1 - k : k;
            if(results[i] != LIBSSH2_ERROR_EAGAIN)
                continue;
            rc = libssh2_channel_open_finish(ch[i]);
            results[i] = rc;
            if(rc != LIBSSH2_ERROR_EAGAIN)
                pending--;
        }
        if(pending)
            wait_io(c);
    }
}

/* Writes one line on the channel and expects it echoed back. */
static void echo_line(struct conn *c, LIBSSH2_CHANNEL *ch, int index)
{
    char line[64], back[64];
    size_t len, got = 0;
    ssize_t n;

    len = (size_t)snprintf(line, sizeof(line), "waycar-%d\n", index);
    DRIVE(c, n, (int)libssh2_channel_write(ch, line, len));
    if(n != (ssize_t)len)
        fail(c, "channel %d write %ld", index, (long)n);
    while(got < len) {
        n = libssh2_channel_read(ch, back + got, len - got);
        if(n == LIBSSH2_ERROR_EAGAIN) {
            wait_io(c);
            continue;
        }
        if(n <= 0)
            fail(c, "channel %d read %ld", index, (long)n);
        got += (size_t)n;
    }
    if(memcmp(line, back, len))
        fail(c, "channel %d echoed the wrong line", index);
}

/*
 * streamlocal <port> <key> <socket> <n> <pipelined|stock>
 * Opens n direct-streamlocal channels, then exchanges a line on each.
 */
static int cmd_streamlocal(int argc, char **argv)
{
    struct conn c;
    struct key k;
    LIBSSH2_CHANNEL *ch[16];
    int results[16];
    double start, elapsed;
    int n, i;

    if(argc != 7)
        return 2;
    n = atoi(argv[5]);
    if(n < 1 || n > 16)
        return 2;
    load_key(&k, argv[3]);
    connect_session(&c, atoi(argv[2]));
    must_authenticate(&c, &k);

    start = now_ms();
    if(!strcmp(argv[6], "pipelined")) {
        for(i = 0; i < n; i++) {
            ch[i] = libssh2_channel_direct_streamlocal_start(
                c.session, argv[4], "127.0.0.1", 0);
            if(!ch[i])
                fail(&c, "start %d", i);
        }
        finish_all(&c, ch, results, n);
        for(i = 0; i < n; i++)
            if(results[i])
                fail(&c, "pipelined open %d returned %d", i, results[i]);
    }
    else {
        for(i = 0; i < n; i++)
            ch[i] = open_streamlocal_stock(&c, argv[4]);
    }
    elapsed = now_ms() - start;
    printf("open_ms=%.1f\n", elapsed);

    for(i = 0; i < n; i++)
        echo_line(&c, ch[i], i);
    for(i = 0; i < n; i++)
        free_channel(&c, ch[i]);
    printf("exchanged=%d\n", n);
    disconnect_session(&c);
    return 0;
}

/*
 * mixed <port> <key> <socket> <missing-socket>
 * Pipelined opens where the middle one is refused, plus a stock open
 * interleaved while the pipelined ones are still waiting for replies.
 */
static int cmd_mixed(int argc, char **argv)
{
    struct conn c;
    struct key k;
    LIBSSH2_CHANNEL *ch[3], *stock;
    int results[3], i, rc;

    if(argc != 6)
        return 2;
    load_key(&k, argv[3]);
    connect_session(&c, atoi(argv[2]));
    must_authenticate(&c, &k);

    ch[0] = libssh2_channel_direct_streamlocal_start(c.session, argv[4],
                                                     "127.0.0.1", 0);
    ch[1] = libssh2_channel_direct_streamlocal_start(c.session, argv[5],
                                                     "127.0.0.1", 0);
    ch[2] = libssh2_channel_direct_streamlocal_start(c.session, argv[4],
                                                     "127.0.0.1", 0);
    if(!ch[0] || !ch[1] || !ch[2])
        fail(&c, "start");
    /* Put all three requests on the wire before anything else. */
    for(i = 0; i < 3; i++) {
        rc = libssh2_channel_open_finish(ch[i]);
        if(rc != LIBSSH2_ERROR_EAGAIN)
            fail(&c, "open %d settled before its reply (%d)", i, rc);
    }
    /* A stock open while three pipelined opens await their replies. */
    stock = open_streamlocal_stock(&c, argv[4]);
    finish_all(&c, ch, results, 3);
    printf("results=%d,%d,%d\n", results[0], results[1], results[2]);
    rc = libssh2_channel_open_finish(ch[1]);
    printf("refused_again=%d\n", rc);

    echo_line(&c, ch[0], 0);
    echo_line(&c, stock, 1);
    echo_line(&c, ch[2], 2);
    for(i = 0; i < 3; i++)
        free_channel(&c, ch[i]);
    free_channel(&c, stock);
    printf("ok=1\n");
    disconnect_session(&c);
    return 0;
}

/*
 * sessions <port> <key>
 * Against an sshd with MaxSessions 2. Three pipelined session opens: two are
 * confirmed and one refused. Then two opens are freed while their replies
 * are still in flight and one before it was ever sent; if freeing did not
 * close the in-flight ones on the server, the final two opens would be
 * refused by MaxSessions.
 */
static int cmd_sessions(int argc, char **argv)
{
    struct conn c;
    struct key k;
    LIBSSH2_CHANNEL *ch[3];
    int results[3], i, rc, confirmed = 0, refused = 0;

    if(argc != 4)
        return 2;
    load_key(&k, argv[3]);
    connect_session(&c, atoi(argv[2]));
    must_authenticate(&c, &k);

    for(i = 0; i < 3; i++) {
        ch[i] = libssh2_channel_open_start(
            c.session, "session", 7, LIBSSH2_CHANNEL_WINDOW_DEFAULT,
            LIBSSH2_CHANNEL_PACKET_DEFAULT, NULL, 0);
        if(!ch[i])
            fail(&c, "start %d", i);
    }
    finish_all(&c, ch, results, 3);
    for(i = 0; i < 3; i++) {
        if(results[i] == 0)
            confirmed++;
        else if(results[i] == LIBSSH2_ERROR_CHANNEL_FAILURE)
            refused++;
        else
            fail(&c, "session open %d returned %d", i, results[i]);
    }
    printf("max_sessions_confirmed=%d\nmax_sessions_refused=%d\n", confirmed,
           refused);
    for(i = 0; i < 3; i++)
        free_channel(&c, ch[i]);

    for(i = 0; i < 3; i++) {
        ch[i] = libssh2_channel_open_start(
            c.session, "session", 7, LIBSSH2_CHANNEL_WINDOW_DEFAULT,
            LIBSSH2_CHANNEL_PACKET_DEFAULT, NULL, 0);
        if(!ch[i])
            fail(&c, "start %d", i);
    }
    for(i = 0; i < 2; i++) {
        rc = libssh2_channel_open_finish(ch[i]);
        if(rc != LIBSSH2_ERROR_EAGAIN)
            fail(&c, "in-flight open %d settled early (%d)", i, rc);
    }
    for(i = 0; i < 3; i++)
        free_channel(&c, ch[i]);

    for(i = 0; i < 2; i++) {
        ch[i] = libssh2_channel_open_start(
            c.session, "session", 7, LIBSSH2_CHANNEL_WINDOW_DEFAULT,
            LIBSSH2_CHANNEL_PACKET_DEFAULT, NULL, 0);
        if(!ch[i])
            fail(&c, "start %d", i);
    }
    finish_all(&c, ch, results, 2);
    printf("after_free=%d,%d\n", results[0], results[1]);
    for(i = 0; i < 2; i++)
        free_channel(&c, ch[i]);
    disconnect_session(&c);
    return 0;
}

/* pubkey <key>: prints the authorized_keys line for a PEM private key. */
static int cmd_pubkey(int argc, char **argv)
{
    struct key k;
    unsigned char b64[4096];

    if(argc != 3)
        return 2;
    load_key(&k, argv[2]);
    EVP_EncodeBlock(b64, k.blob, (int)k.blob_len);
    printf("%s %s\n", k.is_rsa ? "ssh-rsa" : "ssh-ed25519", b64);
    return 0;
}

int main(int argc, char **argv)
{
    int rc = 2;

    if(libssh2_init(0))
        fail(NULL, "libssh2_init");
    if(argc >= 2) {
        if(!strcmp(argv[1], "auth"))
            rc = cmd_auth(argc, argv);
        else if(!strcmp(argv[1], "ptyexec"))
            rc = cmd_ptyexec(argc, argv);
        else if(!strcmp(argv[1], "streamlocal"))
            rc = cmd_streamlocal(argc, argv);
        else if(!strcmp(argv[1], "mixed"))
            rc = cmd_mixed(argc, argv);
        else if(!strcmp(argv[1], "sessions"))
            rc = cmd_sessions(argc, argv);
        else if(!strcmp(argv[1], "pubkey"))
            rc = cmd_pubkey(argc, argv);
    }
    if(rc == 2)
        fprintf(stderr, "usage: see Scripts/test-libssh2-patches.sh\n");
    libssh2_exit();
    return rc;
}
