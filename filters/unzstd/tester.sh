#!/bin/bash

# dir structure
# root_dir/
#   nbdkit/ - nbdkit src dir
#   libnbd/ - libnbd src dir
#   nbdkit_build/ - dir where nbdkit's `./configure` was made

root_dir=$HOME/work2
nbdkit_build_dir=$root_dir/nbdkit_build
# libnbd failed to `make` if `./congigure`-d in another dir
libnbd_build_dir=$root_dir/libnbd
ZSTD=$root_dir/nbd/experiments/myzstd

cd $libnbd_build_dir/copy
make -q || { make && sudo make install && printf "\n"; }
[ $? != 0 ] && exit 1

cd $nbdkit_build_dir/filters/unzstd
make -q || { CFLAGS="-Wno-unused-variable -Wno-unused-function -Wall -Werror -Wfatal-errors" make -e && sudo make install && printf "\n"; }
[ $? != 0 ] && exit 1

cd $root_dir

sample_size=${1:-1}
koef=${2:-14}
echo -en $(yes '\x1' | head -n $sample_size) | sed -E 's/\s+//g' > sample
# dd if=/dev/random of=sample bs=1 count=$sample_size status=none
file_size=$((sample_size * koef + 2 + 16))
# file_size=$((sample_size))

t1=$(date +%s%3N)

$ZSTD < sample > sample.zt \
  && dd if=/dev/zero of=file.img bs=1 count=$file_size status=none \
  && nbdkit $V2 -P nbdkit.pid --filter=log -D unzstd.flag=1 --filter=unzstd file file.img logfile=nbdkit.log \
  && cat sample | nbdcopy $V1 - nbd://localhost \
  && { diff -qs <(head -c $sample_size file.img) sample > /dev/null && echo Test passed || echo Test FAILED; } \
  ; kill $(cat nbdkit.pid) > /dev/null 2>&1 ; rm -rf nbdkit.pid

t2=$(date +%s%3N)
echo "elapsed $((t2 - t1))ms"
