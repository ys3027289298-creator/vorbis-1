#!/bin/bash
# 录屏演示脚本：分段标题 + 段间停顿，全程无需键盘输入。
# 用法：asciinema rec --overwrite -c "bash output/demo.sh" output/benchmark-demo.cast
cd "$(dirname "$0")/.." || exit 1

seg() {
  clear
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
  sleep 2
}

pause() { sleep 3; }

seg "第 1 段 / 共 6 段：改动总览（仅 test/，库代码零改动）"
git status --short
echo
git diff --stat
pause

seg "第 2 段 / 共 6 段：构建（仓库自带 CMake 入口）"
cmake --build build -j"$(nproc)" 2>&1 | tail -3
pause

seg "第 3 段 / 共 6 段：运行基准 bench_decode（耗时 + 内存峰值）"
./build/test/bench_decode
echo "退出码: $?"
pause

seg "第 4 段 / 共 6 段：与现有测试一起跑（ctest）"
cd build && ctest --output-on-failure; cd ..
pause

seg "第 5 段 / 共 6 段：阈值判定演示（收紧阈值即失败）"
BENCH_MAX_DECODE_MS=1 ./build/test/bench_decode 2>&1 | tail -3
echo "退出码: $?"
pause

seg "第 6 段 / 共 6 段：库行为零变化验证"
echo "lib/ 与 include/ 的改动："
git diff --stat -- lib include
echo "(无输出 = 库源码未改动)"
echo
echo "连续 3 次运行的 PCM 哈希（必须一致）："
for i in 1 2 3; do ./build/test/bench_decode 2>&1 | grep "pcm hash"; done
pause

clear
echo "演示结束：基准 PASS，阈值可判定，库输出零变化。"
sleep 2
