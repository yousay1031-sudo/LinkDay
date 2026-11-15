#!/bin/bash
cd /home/user/day15_verify/v4
O=/home/user/day15_verify/v4/bench
mkdir -p $O
for r in 1 2 3; do
  for c in motion reduce; do
    echo "run $c $r $(date +%T)"; node bench.js $c $r 0 $O || echo "FAIL $c $r"
  done
done
# トレース付き（トレース自体が負荷になるため、数値の中央値には使わず、トレース分析専用）
for c in motion reduce; do
  echo "trace $c 9 $(date +%T)"; node bench.js $c 9 1 $O || echo "FAIL trace $c"
done
echo ALLDONE
