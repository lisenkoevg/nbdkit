#!/bin/bash

test_results_dir=nbd/tmp/failed_test
test_dir=nbd/tmp/test_files
N=${1:-1}

set -o errexit -o errtrace
trap 'save_failed_test' ERR

cmd=
function t() {
  N=$1
  request_size=$2
  NBDCOPY_threads=$3
  NBDKIT_threads=$4
  synch=${5:+--synchronous}
#   nopremake=${6:+-n}
  for (( i = 0; i != $N; ++i)); do
    ts=$(date +%Y%m%d_%H%M%S)
    nbdcopy_args="-v --zstd -T $NBDCOPY_threads --request-size=$request_size $synch"
#     nbdcopy_args="-v -T $NBDCOPY_threads --request-size=$request_size $synch"
    nbdkit_args="-D unzstd.flag=1 --filter=unzstd -v -t $NBDKIT_threads"
#     nbdkit_args="-t $NBDKIT_threads"
    cmd="_TEST_DIR_=$test_dir _TS_=$ts NBDCOPY_ARGS=\"$nbdcopy_args\" NBDKIT_ARGS=\"$nbdkit_args\" ./tester.sh $nopremake -r $(($i*32*1024*1024 + 1))"
    echo $((i+1)) $cmd

    # trap this line if failed
    eval $cmd 2> test.log

    # rm only if test passed
    rm -rf $test_dir/nbdcopy/$ts $test_dir/nbdkit/$ts
  done
  echo ""
}

function save_failed_test() {
  if [ $? -eq 0 ]; then
    return
  fi
  d=$test_results_dir/$ts
  mkdir -p $d
  echo $cmd > $d/cmd.txt
  mv sample* file.img test.log $d
}

# t $1 $((1024*1024)) 1 1 synch
# t $1 $((1024*1024)) 1 1
# t $1 $((1024*1024)) 1 2
# t $1 $((1024*1024)) 2 1
# t $1 $((1024*1024)) 2 2

t $1 $((1024*1024)) 4 4

