#!/bin/bash
# usage: runa.sh <label> <runs> "<conds>"
cd /home/user/day15_verify/v4
O=/home/user/day15_verify/v4/$1; mkdir -p $O
for r in $(seq 1 $2); do for c in $3; do echo "run $c $r $(date +%T)"; node bench_a.js $c $r 0 $O || echo FAIL $c $r; done; done
echo ALLDONE
