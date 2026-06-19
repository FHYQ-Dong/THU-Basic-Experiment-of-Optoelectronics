import argparse
import csv
import os
from typing import Dict, List, Tuple


CHANNEL_MAP: Dict[int, int] = {
    0: 0,
    1: 3,
    2: 2,
    3: 1,
}


def read_events(path: str) -> List[Tuple[int, int, int]]:
    events: List[Tuple[int, int, int]] = []
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or "Channel" not in reader.fieldnames:
            raise ValueError("CSV must contain a 'Channel' column.")
        if "Time(ps)" not in reader.fieldnames:
            raise ValueError("CSV must contain a 'Time(ps)' column.")
        for row in reader:
            try:
                channel = int(row["Channel"])
                time_ps = int(row["Time(ps)"])
            except (TypeError, ValueError):
                continue
            events.append((channel, time_ps, len(events)))
    return events


def build_channel4_indices(events: List[Tuple[int, int, int]]) -> List[int]:
    indices: List[int] = []
    for idx, (channel, _, _) in enumerate(events):
        if channel == 4:
            indices.append(idx)
    return indices


def map_prev_channel4(events: List[Tuple[int, int, int]]) -> Dict[int, Tuple[int, int]]:
    prev_data: Dict[int, Tuple[int, int]] = {}
    count = -1
    last_time_ps = None
    for idx, (channel, time_ps, _) in enumerate(events):
        if channel == 4:
            count += 1
            last_time_ps = time_ps
        prev_data[idx] = (count, last_time_ps)
    return prev_data


def extract_effective_events(
    events: List[Tuple[int, int, int]]
) -> List[Tuple[int, int, int, int]]:
    effective: List[Tuple[int, int, int, int]] = []
    if len(events) < 3:
        return effective

    prev_channel4 = map_prev_channel4(events)

    for idx in range(1, len(events) - 1):
        channel = events[idx][0]
        if channel not in CHANNEL_MAP:
            continue
        if events[idx - 1][0] != 4 or events[idx + 1][0] != 4:
            continue
        seq, prev_time_ps = prev_channel4[idx]
        if seq < 0 or prev_time_ps is None:
            continue
        time_diff_ps = events[idx][1] - prev_time_ps
        effective.append((CHANNEL_MAP[channel], seq, channel, time_diff_ps))

    return effective


def write_csv(path: str, rows: List[Tuple[int, int, int, int]]) -> None:
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["channel_mapped", "seq", "channel_raw", "time_diff_ps"])
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Extract effective events from FT1080 T2 events CSV and map channels."
        )
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to the FT1080 T2 events CSV file",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output CSV path (default: <input>_effective_events.csv)",
    )
    args = parser.parse_args()

    input_path = args.input
    if not input_path:
        input_path = input("Enter the T2 events CSV path: ").strip()
    if not input_path:
        raise SystemExit("No input file path provided.")

    events = read_events(input_path)
    effective_events = extract_effective_events(events)

    out_path = args.out
    if not out_path:
        base_dir = os.path.dirname(input_path)
        base_name = os.path.splitext(os.path.basename(input_path))[0]
        out_path = os.path.join(base_dir, f"{base_name}_effective_events.csv")

    write_csv(out_path, effective_events)
    print(f"Output CSV: {out_path}")


if __name__ == "__main__":
    main()
