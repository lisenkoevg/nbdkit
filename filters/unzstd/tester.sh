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

function main() {
  cd $(dirname $ZSTD)
  make myzstd -q || make myzstd
  [ $? != 0 ] && exit 1

  cd $libnbd_build_dir/copy
  make -q || { make && sudo make install && printf "\n"; }
  [ $? != 0 ] && exit 1

  cd $nbdkit_build_dir/filters/unzstd
  CFLAGS="-Wno-unused-variable -Wno-unused-function -Wall -Werror -Wfatal-errors"
  make -q || { CFLAGS="$CFLAGS" make -e && sudo make install && printf "\n"; }
  [ $? != 0 ] && exit 1

  cd $root_dir

  data=1

  if [ -z "$1" ]; then
    usage
  fi

  while getopts ":d:rpz" opt; do
    case $opt in
      r ) random=1 ;;
      p ) pipe=1 ;;
      d ) data=$OPTARG ;;
      z ) zero=1 ;;
      \? | h) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  sample_size=${1:-1}

  t1=$(date +%s%3N)
  if [ -n "$random" ]; then
    bs=1024
    dd if=/dev/random of=sample bs=$bs count=$((sample_size / bs)) status=none
    dd if=/dev/random of=sample oflag=append conv=notrunc bs=1 count=$((sample_size % bs)) status=none
  else
    if [ -n "$zero" ]; then
      rm -f sample
      fallocate -l $((sample_size / 2)) sample
      echo -en $(yes "\x$data" | head -n $((sample_size - sample_size / 2)) ) | sed -E 's/\s+//g' >> sample
    else
      echo -en $(yes "\x$data" | head -n $((sample_size)) ) | sed -E 's/\s+//g' > sample
    fi
  fi
  t2=$(date +%s%3N)
  echo "Sample data ($sample_size) written in $((t2 - t1))ms"

  if [ -z "$pipe" ]; then
    cmd_nbdcopy='nbdcopy $V1 sample nbd://localhost'
  else
    cmd_nbdcopy='cat sample | nbdcopy $V1 - nbd://localhost'
  fi

  file_size=$((sample_size))

  rm -f file.img
  $ZSTD < sample > sample.zt \
    && fallocate -l $file_size file.img \
    && t1=$(date +%s%3N) \
    && nbdkit $V2 -P nbdkit.pid --filter=log -D unzstd.flag=1 --filter=unzstd file file.img logfile=nbdkit.log \
    && eval $cmd_nbdcopy \
    && t2=$(date +%s%3N) \
    && { diff -qs <(head -c $sample_size file.img) sample > /dev/null && echo Test passed || echo Test FAILED; } \
    ; kill $(cat nbdkit.pid) > /dev/null 2>&1 ; rm -rf nbdkit.pid

  echo "elapsed $((t2 - t1))ms"
}

function usage() {
  msg=$(cat <<-END

	./tester.sh [-r] [-p] -d {0|1|...} [sample_data_size=1]
	  -d {0,1,...} - use specified value (0x00, 0x01, ...) for input data
	  -r - use random data
	  -p - use pipe
      -z - add zeros in beginning (half of sample_data_size)
	  use V1 and V2 env variable to pass cmd params to nbdcopy and nbdkit respectively
	  for example, V1="--zstd --no-extents -v" V2="-v" ./tester.sh ...
END
  )
  echo -e "$msg\n"
  exit
}

main $*
