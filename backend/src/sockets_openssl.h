#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#include <string.h>

/*
    A template for opening a non-blocking OpenSSL connection.
*/
void open_nb_socket(BIO**       bio,
                    SSL_CTX**   ssl_ctx,
                    const char* addr,
                    const char* port,
                    const char* ca_file,
                    const char* ca_path,
                    const char* cert_file,
                    const char* key_file);
