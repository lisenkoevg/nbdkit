#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <sys/types.h>
#include <sys/stat.h>

#include <pthread.h>

#include <nbdkit-filter.h>
#include <zstd.h>

#include "cleanup.h"
#include "poll.h"
#include "minmax.h"
#include "utils.h"

#if 0
#include "../../../nbd/experiments/dump_buffer.c"
#endif

int unzstd_debug_flag;
void *bufOut;

static int unzstd_config(nbdkit_next_config *next, nbdkit_backend *nxdata,
                      const char *key, const char *value) {
  return next(nxdata, key, value);
}

static int unzstd_config_complete(nbdkit_next_config_complete *next,
                               nbdkit_backend *nxdata) {
  return next(nxdata);
}

struct handle {
  /* These are copied from the globals during unzstd_prepare, so that we
   * don't have to keep grabbing the lock on each request.
   */
  uint64_t offset, size;
};

static void *unzstd_open(nbdkit_next_open *next, nbdkit_context *nxdata,
                      int readonly, const char *exportname, int is_tls) {
  struct handle *h;
  if (next(nxdata, readonly, exportname) == -1)
    return NULL;

  h = calloc(1, sizeof *h);
  if (h == NULL) {
    nbdkit_error("calloc: %m");
    return NULL;
  }
  return h;
}

static void unzstd_close(void *handle) {
  free(handle);
}

static int unzstd_prepare(nbdkit_next *next, void *handle, int readonly) {
  return 0;
}

/* Get the file size. */
static int64_t unzstd_get_size(nbdkit_next *next, void *handle) {
  struct handle *h = handle;
  int64_t size;

  /* We must call underlying get_size even though we don't use the
   * result, because it caches the plugin size in server/backend.c.
   */
  size = next->get_size(next);

  if (size == -1)
    return -1;

  // while testing file-plugin file size is set to size of nbdcopy input data
  // so ZSTD_compressBound() used for handle error:
  // nbd_pwrite: request out of bounds: No space left on device
  // as compressed-random data (or several-bytes data) is bigger than not compressed
  return ZSTD_compressBound(size);
//   return size;
}

static int unzstd_pwrite(nbdkit_next *next, void *handle, const void *buf,
                      uint32_t count, uint64_t offs, uint32_t flags, int *err) {
  struct {
    size_t size;
    uint64_t offset;
  } orig;

#if 0
  char *s = buffer_to_str_wrap(buf, count, 0);
  nbdkit_debug("%s", s);
#endif

  memcpy(&orig, buf, sizeof orig);
  nbdkit_debug("pwrite orig.size=%lu orig.offset=%lu", orig.size, orig.offset);

  void *ptr = realloc(bufOut, orig.size);
  if (ptr == NULL) {
    nbdkit_error("unzstd realloc");
    return -1;
  }
  bufOut = ptr;

  size_t const ret = ZSTD_decompress(bufOut, orig.size, buf + sizeof orig, count - sizeof orig);
  if (ZSTD_isError(ret)) {
    fprintf(stderr, "ZSTD_decompress() error: %s\n", ZSTD_getErrorName(ret));
    nbdkit_error("%s", ZSTD_getErrorName(ret));
    return -1;
  }

  return next->pwrite(next, bufOut, orig.size, orig.offset, flags, err);
}

static struct nbdkit_filter filter = {
    .name = "unzstd",
    .open = unzstd_open,
    .close = unzstd_close,
    .get_size = unzstd_get_size,
    .pwrite = unzstd_pwrite,
};

NBDKIT_REGISTER_FILTER(filter)
