# Bob 接收端解码工具链

QKD-BB84 实验中 Bob（接收方）的后处理脚本：把 FT1080 单光子计数器导出的
原始事件文件，一步一步处理成「与 Alice 真值对齐、含 match 标注」的事件
CSV，作为 `ecc/ecc_simplified.py` 误码协调的输入。

---

## 1. 数据流总览

```
FT1080 原始 .txt（含 header + 事件表）
        │
        ├── 路径 A：T3 模式 / 快速单步流程
        │   └─→ extract_unique_events_to_csv.py
        │       └─→ <input>_unique_events.csv
        │           （channel_mapped, seq, channel_raw）
        │
        └── 路径 B：T2 模式 / 完整流程（含门控窗口分析）
            └─→ parse_ft1080_t2_to_csv.py
                ├─→ <input>_header.csv  （实验参数）
                └─→ <input>_events.csv  （Flag, Channel, Time(ps), Sequence）
                    └─→ extract_effective_events_from_t2_csv.py
                        └─→ *_effective_events.csv
                            （channel_mapped, seq, channel_raw, time_diff_ps）

            *_unique_events.csv 或 *_effective_events.csv
                └─→ compare_channel_with_txt.py（vs Alice 端 random_data_*.txt）
                    └─→ *_compare.csv
                        （seq, channel_mapped, txt_value, match）
                        └─→ 喂给 ecc/ecc_simplified.py
```

---

## 2. 文件清单

| 文件                                       | 输入                                  | 输出                                     | 作用 |
| ------------------------------------------ | ------------------------------------- | ---------------------------------------- | ---- |
| `parse_ft1080_t2_to_csv.py`                | FT1080 T2 模式原始 `.txt`              | `<base>_header.csv` + `<base>_events.csv` | 把原始文本里的实验参数 header 与事件表分别写成 CSV；事件表 4 列（Flag, Channel, Time(ps), Sequence） |
| `parse_ft1080_t3_to_csv.py`                | FT1080 T3 模式原始 `.txt`              | 同上                                     | T3 模式版本，事件表 5 列 |
| `extract_unique_events_to_csv.py`          | FT1080 原始 `.txt`                     | `*_unique_events.csv`                    | 直接从原始 txt 解析、按 `Sequence` 去重（一周期内多事件全丢）、并把 raw channel 映射到 Alice 偏振索引；用于 T3 模式或不需要时间差的快速流程 |
| `extract_effective_events_from_t2_csv.py`  | T2 模式 `*_events.csv`                 | `*_effective_events.csv`                 | T2 模式专用：通道 4 = 同步信号；筛选「夹在两个同步事件中间」的单光子事件，并计算相对前一个同步信号的时间差 `time_diff_ps`，用于后续门控筛选 |
| `compare_channel_with_txt.py`              | 任一上面输出的事件 CSV + Alice 真值 txt | `*_compare.csv`                          | 按 `seq` 对齐 Alice 真值与 Bob 接收偏振，写出 4 列 CSV；并打印 4×4 解码分布矩阵；可选画出每通道的 `time_diff_ps` 直方图（用于定位门控窗口） |

---

## 3. 关键约定

### 3.1 通道映射

Bob 探测器的物理通道编号与 Alice 偏振索引不一致。脚本中硬编码：

```python
CHANNEL_MAP = {0: 0, 1: 3, 2: 2, 3: 1}
```

含义：

| Bob 物理通道 | Alice 偏振索引 | 偏振态 |
| ------------ | -------------- | ------ |
| 0            | 0              | H (0°) |
| 1            | 3              | -45°   |
| 2            | 2              | +45°   |
| 3            | 1              | V (90°)|

> 这个表与 `Alice/random-gen.py` 末尾的注释一致，是光路对齐后实测出的
> 物理对应关系；如果某次实验改了光路接线，这两处必须一起改。

### 3.2 基匹配规则

在 `compare_channel_with_txt.py` 中，「同基」=「Bob 偏振索引与 Alice 真值
同在直角基 `{0, 1}` 或同在对角基 `{2, 3}`」：

```python
if int(channel_mapped) < 2 and int(txt_value) < 2:   # 都用直角基
    ...
if int(channel_mapped) >= 2 and int(txt_value) >= 2: # 都用对角基
    ...
```

基不匹配的事件 `match=0`（弃用）；基匹配但偏振不一致的 `match=-1`（真实
错误，贡献 QBER）；基匹配且一致的 `match=1`。

### 3.3 门控窗口（T2 模式）

`extract_effective_events_from_t2_csv.py` 输出的 `time_diff_ps` 字段是
单光子事件相对最近一次同步信号的时间差。由于激光器建立时间、SPD 响应
时间等因素，真实光子事件集中在 $(6\sim11)\times10^6$ ps 内。

如果需要排除暗计数，可以在 `compare_channel_with_txt.py` 第 39 行启用
被注释掉的过滤行：

```python
if int(time_arrow) > 11000000 or int(time_arrow) < 7000000:
    continue
```

或者先跑一遍 `compare_channel_with_txt.py` 时回答 `y` 计算直方图，确定
本次实验的实际时延窗口后再批量过滤。

---

## 4. 典型流程

### 4.1 T2 模式（完整，推荐）

```bash
cd QKD-BB84
# 1. 解析原始 FT1080 文本，分离 header 和事件表
python Bob/parse_ft1080_t2_to_csv.py Alice/data/TCSPC_10s_1.txt

# 2. 筛同步包夹的单光子事件，附加 time_diff_ps 列
python Bob/extract_effective_events_from_t2_csv.py \
    Alice/data/TCSPC_10s_1_events.csv

# 3. 与 Alice 真值比对
python Bob/compare_channel_with_txt.py
#   Input CSV path:  Alice/data/TCSPC_10s_1_events_effective_events.csv
#   Input TXT path:  Alice/data/random_data_10s_1.txt
#   Compute time_diff_ps histogram? (y/n): n
#   Output CSV path (leave empty for default): <Enter>

# 4. 喂给纠错
python ecc/ecc_simplified.py Alice/data/TCSPC_10s_1_events_effective_events_compare.csv
```

### 4.2 T3 模式（快速）

T3 模式不需要时间差信息：

```bash
python Bob/extract_unique_events_to_csv.py Alice/data/TCSPC_10s_1.txt
python Bob/compare_channel_with_txt.py    # 输入 *_unique_events.csv 即可
python ecc/ecc_simplified.py *_compare.csv
```

> 但缺了 `time_diff_ps`，`compare_channel_with_txt.py` 里的门控过滤就只能
> 跳过。暗计数贡献的 QBER 会高一些。

---

## 5. 注意事项

- 所有脚本都通过 `argparse` 接收文件路径，路径参数缺省时会用
  `input()` 交互式提问。`compare_channel_with_txt.py` 没有命令行参数，
  完全交互式。
- 输出文件默认放在输入文件同一目录下，文件名后缀逐级追加（`_header`,
  `_events`, `_effective_events`, `_compare`），方便沿着数据流追溯。
- `parse_ft1080_t2_to_csv.py` 中的 `expand_stop_delay` 会把 header 里
  形如 `Stop Delay: ch1 12.5ns, ch2 13.0ns, ...` 的字段拆成 per-channel
  键值对，便于后续在分析里直接用。
- `compare_channel_with_txt.py` 同时打印一个 4×4 的「Bob 接收 × Alice 发送」
  分布表，对应实验报告里「实际解码概率」那张表，用来定量分析 PBS 不
  理想性带来的误码。
