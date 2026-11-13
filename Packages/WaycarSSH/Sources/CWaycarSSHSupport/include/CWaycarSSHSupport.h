#ifndef C_WAYCAR_SSH_SUPPORT_H
#define C_WAYCAR_SSH_SUPPORT_H

#include <CLibSSH2/libssh2.h>

int waycar_libssh2_abandon_session(LIBSSH2_SESSION *session);
void waycar_libssh2_prepare_session_abandonment(LIBSSH2_SESSION *session);

typedef ssize_t (*waycar_libssh2_receive_callback)(
    libssh2_socket_t socket,
    void *buffer,
    size_t length,
    int flags,
    void **abstract
);

void waycar_libssh2_set_receive_callback(
    LIBSSH2_SESSION *session,
    waycar_libssh2_receive_callback callback
);

#endif
