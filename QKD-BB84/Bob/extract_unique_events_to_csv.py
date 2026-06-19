import argparse
import csv
import os
import re
from typing import Dict, List, Tuple


CHANNEL_MAP = {
    0: 0,
    1: 3,
    2: 2,
    3: 1,
}


def parse_events(lines: List[str]) -> List[Tuple[int, int]]:
    events: List[Tuple[int, int]] = []
    in_table = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[Flag:]"):
            continue
        if stripped.startswith("Flag"):
            in_table = True
            continue
        if not in_table:
            continue
        parts = re.split(r"\s+", stripped)
        if len(parts) < 5:
            continue
        try:
            flag = int(parts[0])
            channel = int(parts[1])
            seq = int(parts[4])
        except ValueError:
            continue
        if flag != 0:
            continue
        events.append((channel, seq))

    return events


def filter_unique_events(events: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    seq_count: Dict[int, int] = {}
    for _, seq in events:
        seq_count[seq] = seq_count.get(seq, 0) + 1

    unique_events: List[Tuple[int, int]] = []
    for channel, seq in events:
        if seq_count.get(seq, 0) != 1:
            continue
        if channel not in CHANNEL_MAP:
            continue
        unique_events.append((channel, seq))

    return unique_events


def write_csv(path: str, rows: List[Tuple[int, int]]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["channel_mapped", "seq", "channel_raw"])
        for channel, seq in rows:
            writer.writerow([CHANNEL_MAP[channel], seq, channel])


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Extract unique events (channel 0-3) and map channels to numbers."
        )
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to the FT1080 text file",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output CSV path (default: <input>_unique_events.csv)",
    )
    args = parser.parse_args()

    input_path = args.input
    if not input_path:
        input_path = input("Enter the FT1080 file path: ").strip()
    if not input_path:
        raise SystemExit("No input file path provided.")

    with open(input_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    events = parse_events(lines)
    unique_events = filter_unique_events(events)

    out_path = args.out
    if not out_path:
        base_dir = os.path.dirname(input_path)
        base_name = os.path.splitext(os.path.basename(input_path))[0]
        out_path = os.path.join(base_dir, f"{base_name}_unique_events.csv")

    write_csv(out_path, unique_events)
    print(f"Output CSV: {out_path}")


if __name__ == "__main__":
    main()
