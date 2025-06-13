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

_TEST_DIR_=$root_dir/$_TEST_DIR_

function main() {

  if [ -z "$1" ]; then
    usage
  fi

  while getopts ":d:nprz" opt; do
    case $opt in
      d ) data=$OPTARG ;;
      n ) nomake=1 ;;
      p ) pipe=1 ;;
      r ) random=1 ;;
      z ) zero=1 ;;
      \? | h) usage ;;
    esac
  done
  shift $((OPTIND - 1))
  sample_size=${1:-1}

  if [ -z $nomake ]; then
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
  fi

  cd $root_dir

  t1=$(date +%s%3N)
  if [ -n "$random" ]; then
    bs=1024
    dd if=/dev/random of=sample bs=$bs count=$((sample_size / bs)) status=none
    dd if=/dev/random of=sample oflag=append conv=notrunc bs=1 count=$((sample_size % bs)) status=none
  else
    if [ -n "$zero" ]; then
      rm -f sample
      if [ -n "$data" ]; then
        fallocate -l $((sample_size / 2)) sample
        generate_data $data $((sample_size - sample_size / 2)) >> sample
      else
        fallocate -l $((sample_size)) sample
      fi
    else
      generate_data $data $((sample_size)) > sample
    fi
    fallocate -d sample
  fi
  t2=$(date +%s%3N)
  echo "Sample data ($sample_size) written in $((t2 - t1))ms"

  V1=${NBDCOPY_ARGS:-$V1}
  V2=${NBDKIT_ARGS:-$V2}

  if [ -z "$pipe" ]; then
    cmd_nbdcopy='$VALGRIND1 nbdcopy $V1 sample nbd://localhost'
  else
    cmd_nbdcopy='cat sample | $VALGRIND1 nbdcopy $V1 - nbd://localhost'
  fi

  file_size=$((sample_size))

  rm -f file.img
  $ZSTD < sample > sample.zt
  fallocate -l $file_size file.img
  t1=$(date +%s%3N)
  $VALGRIND2 nbdkit $V2 -P nbdkit.pid file file.img \
    && eval $cmd_nbdcopy
  t2=$(date +%s%3N)
  kill $(cat nbdkit.pid) > /dev/null 2>&1
  rm -rf nbdkit.pid

  failed=0
  diff -qs <(head -c $sample_size file.img) sample > /dev/null || failed=1

  if [ $failed == 0 ]; then
    printc "Test passed" 15 22
  else
    printc "Test FAILED" 15 1
  fi
  echo ", $((t2 - t1))ms"

  exit $failed
}

# Kind of str_repeat(ch, size) function
function generate_data() {
  local ch=${1:0:1}
  local size=$2

  mkfifo tmp_fifo
  yes "$1" | tr -d '\n' > tmp_fifo &
  dd bs=1024 count=$((size/1024)) if=tmp_fifo status=none

  # repeat as previous dd make pipe broken
  yes "$1" | tr -d '\n' > tmp_fifo &
  dd bs=1 count=$((size % 1024)) if=tmp_fifo status=none
  rm tmp_fifo
}

function usage() {
  msg=$(cat <<-END

	./tester.sh [-n] [-r] [-p] [-d {0|1|...}] [-z] sample_data_size

	  -d {0,1,...} - use specified value (0x00, 0x01, ...) for input data
	  -r - use random data
	  -p - use pipe
	  -z - add zeros in beginning (half of sample_data_size)
      -n - no pre make && make install

	use V1 and V2 env variable to pass cmd params to nbdcopy and nbdkit respectively
	for example, V1="--zstd --no-extents -v" V2="-v" ./tester.sh ...
	use VALGRIND1 and VALGRIND2 env variables to prepend invocation of nbdcopy and nbdkit respectively
	with their values
	suggested usage:
	VALGRIND1="valgrind" V1="..." ./tester.sh 1
	VALGRIND2="valgrind" V1="..." ./tester.sh 1

END
  )
  echo -e "$msg\n"
  exit
}

function printc() {
  local str=$1
  if [ -z "$1" ]; then
    return
  fi
  local fg=${2:-16}
  local bg=${3:-15}
  printf "\e[38;5;${fg}m\e[48;5;${bg}m${str}\e[0m"
}

main $*
