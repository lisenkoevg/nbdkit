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

int unzstd_debug_flag;
size_t bufOutSize;
void *bufOut;
ZSTD_DCtx *dctx;
FILE *fdebug;

static const char *entry; /* File within tar (tar-entry=...) */
static int64_t tar_limit = 0;
static const char *tar_program = "tar";

/* Offset and size within tarball.
 *
 * These are calculated once in the first connection that calls
 * tar_prepare.  They are protected by the lock.
 */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static bool initialized = false;
static uint64_t tar_offset, tar_size;

int zstd_init() {
  bufOutSize = ZSTD_DStreamOutSize();
  nbdkit_debug("bufOutSize: %lu", bufOutSize);
  dctx = ZSTD_createDCtx();
  if (dctx == NULL)
    return 1;
  bufOut = malloc(bufOutSize);
  if (bufOut == NULL)
    return 1;
  fdebug =
      fopen("/home/evgen/work/nbdkit/build/filters/unzstd/unzstd.out", "w");
  if (!fdebug)
    return 1;
  return 0;
}

int zstd_finalize() {
  ZSTD_freeDCtx(dctx);
  free(bufOut);
  fclose(fdebug);
  return 0;
}

void zstd_decompress() {}

static int tar_config(nbdkit_next_config *next, nbdkit_backend *nxdata,
                      const char *key, const char *value) {
  if (strcmp(key, "tar-entry") == 0) {
    if (entry) {
      nbdkit_error("only one tar-entry parameter can be given");
      return -1;
    }
    entry = value;
    return 0;
  } else if (strcmp(key, "tar-limit") == 0) {
    tar_limit = nbdkit_parse_size(value);
    if (tar_limit == -1)
      return -1;
    return 0;
  } else if (strcmp(key, "tar") == 0) {
    tar_program = value;
    return 0;
  }

  return next(nxdata, key, value);
}

static int tar_config_complete(nbdkit_next_config_complete *next,
                               nbdkit_backend *nxdata) {
  if (entry == NULL) {
    nbdkit_error("you must supply the tar-entry=<FILENAME> parameter");
    return -1;
  }

  return next(nxdata);
}

#define tar_config_help                                                        \
  "tar-entry=<FILENAME> (required) The path inside the tar file to serve.\n"   \
  "tar-limit=SIZE                  Limit on reading to find entry.\n"          \
  "tar=<PATH>                      Path of the tar binary."

struct handle {
  /* These are copied from the globals during tar_prepare, so that we
   * don't have to keep grabbing the lock on each request.
   */
  uint64_t offset, size;
};

static void *tar_open(nbdkit_next_open *next, nbdkit_context *nxdata,
                      int readonly, const char *exportname, int is_tls) {
  if (zstd_init() != 0) {
    nbdkit_error("zstd_init");
    return NULL;
  }

  struct handle *h;
  if (next(nxdata, readonly, exportname) == -1)
    return NULL;

  h = calloc(1, sizeof *h);
  if (h == NULL) {
    nbdkit_error("calloc: %m");
    return NULL;
  }
  if (unzstd_debug_flag)
    nbdkit_debug("open");
  return h;
}

static void tar_close(void *handle) {
  zstd_finalize();
  if (unzstd_debug_flag)
    nbdkit_debug("close");
  free(handle);
}

static int tar_prepare(nbdkit_next *next, void *handle, int readonly) {
  struct handle *h = handle;
  h->offset = 0;
  h->size = 0;
}

/* Description. */
static const char *tar_export_description(nbdkit_next *next, void *handle) {
  const char *base = next->export_description(next);

  if (!base)
    return NULL;
  return nbdkit_printf_intern("embedded %s from within tar file: %s", entry,
                              base);
}

/* Get the file size. */
static int64_t tar_get_size(nbdkit_next *next, void *handle) {
  struct handle *h = handle;
  int64_t size;

  /* We must call underlying get_size even though we don't use the
   * result, because it caches the plugin size in server/backend.c.
   */
  size = next->get_size(next);
  if (unzstd_debug_flag)
    nbdkit_debug("get_size size=%lu h->size=%lu", size, h->size);

  if (size == -1)
    return -1;

  //   return h->size;
  return size;
}

/* Read data from the file. */
static int tar_pread(nbdkit_next *next, void *handle, void *buf, uint32_t count,
                     uint64_t offs, uint32_t flags, int *err) {
  struct handle *h = handle;
  return next->pread(next, buf, count, offs + h->offset, flags, err);
}

/* Write data to the file. */
static int tar_pwrite(nbdkit_next *next, void *handle, const void *buf,
                      uint32_t count, uint64_t offs, uint32_t flags, int *err) {
  struct handle *h = handle;

  size_t const ret = ZSTD_decompress(bufOut, bufOutSize, buf, count);
  if (ZSTD_isError(ret)) {
    // TODO handle error
    if (unzstd_debug_flag)
      nbdkit_debug("ZSTD_isError: %s", ZSTD_getErrorName(ret));
  }
  size_t unzstd_offs = h->offset;
  uint32_t unzstd_count = ret;
  h->offset += ret;

  if (unzstd_debug_flag)
    nbdkit_debug("decompress, ret=%lu, input offs/count:%lu/%u unzstd offs/count:%lu/%u, bufOutSize %lu",
        ret, offs, count, unzstd_offs, unzstd_count, bufOutSize);
  return next->pwrite(next, bufOut, unzstd_count, unzstd_offs, flags, err);
//   return next->pwrite(next, buf, count, offs, flags, err);
}

static struct nbdkit_filter filter = {
    .name = "unzstd",
    //   .longname           = "nbdkit unzstd filter",
    //   .config             = tar_config,
    //   .config_complete    = tar_config_complete,
    //   .config_help        = tar_config_help,
    .open = tar_open,
    .close = tar_close,
    //   .prepare            = tar_prepare,
    //   .export_description = tar_export_description,
    .get_size = tar_get_size,
    //   .pread = tar_pread,
    .pwrite = tar_pwrite,
};

NBDKIT_REGISTER_FILTER(filter)
