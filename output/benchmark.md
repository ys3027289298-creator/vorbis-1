# 解码性能基准说明（bench_decode）

## 目标

让性能回退能被及时发现：固定素材、固定机器，输出解析（解码）耗时与
内存峰值，超阈值即失败；基准与现有测试一起跑；不改变库行为。

## 基准构成

- 源码：`test/bench_decode.c`（新增，仅使用公开 API，不改动 `lib/`）
- 接入：`test/CMakeLists.txt`（`ctest` 的 `bench_decode` 用例）、
  `test/Makefile.am`（`make check`）

## 固定素材

运行时确定性生成，不依赖外部文件、无随机数：

- 信号：440 / 554.37 / 659.26 Hz 三正弦叠加，立体声相位固定
- 参数：44.1 kHz、2 声道、2 秒、VBR q=0.4、ogg 流序列号固定 `0x4F474753`
- 产物：约 11.5 KB 的内存 Ogg Vorbis 流（每次运行逐字节一致）

## 固定机器（阈值校准基准机）

- CPU：AMD Ryzen 7 9700X（16 逻辑核）
- 系统：Ubuntu 24.04.5 LTS（WSL2，内核 6.18.33.2）
- 编译：gcc 13，CMake 默认 `-O3`（本仓库 Release 默认）

## 指标与阈值（超过即失败，退出码 1）

| 指标 | 实测（基准机） | 阈值 | 判定 |
|---|---|---|---|
| 解码总耗时（25 次完整解码） | 约 115–135 ms | ≤ 500 ms | 超时 FAIL |
| 内存峰值（ru_maxrss） | 约 4 MB | ≤ 64 MB | 超量 FAIL |
| 解码确定性（两次完整解码的 FNV-1a 哈希） | 逐比特一致 | 必须相等 | 不等 FAIL |

阈值留有约 4–16 倍余量，避免正常抖动误报。每次运行打印解码 PCM 的
FNV-1a 哈希，同一构建下逐次运行完全恒定（本机 CMake 构建为
`0x13c54b8c0705d39a`，autotools `-O2` 构建为 `0x19ca2ab319df7a01`；
浮点优化级别不同会导致合法的跨构建差异，因此哈希用于同一构建内的
逐比特稳定性判定，而非跨构建金值）。
阈值可用环境变量覆盖（无需重编译）：
`BENCH_MAX_DECODE_MS`、`BENCH_MAX_RSS_KB`。

## 复现步骤

```sh
cmake -S . -B build -DBUILD_TESTING=ON   # 需要 libogg 开发文件
cmake --build build -j
cd build && ctest --output-on-failure    # bench_decode 与现有测试一起跑
./test/bench_decode                      # 或单独运行，查看耗时/内存明细
```

## 验收对照

- 可复现：素材运行时确定性生成，哈希恒定，多次运行结果见
  `output/benchmark-results.txt`
- 阈值可判定：超时/超内存/哈希不符均退出码 1 并打印 FAIL 原因
- 库输出零变化：`git diff` 仅触及 `test/`，`lib/` 与 `include/` 未改
  一行；解码哈希逐次运行恒定

## 录屏

`output/benchmark-demo.cast`（asciinema 格式，`asciinema play` 回放），
分段标题 + 段间停顿，全程无需键盘输入。
