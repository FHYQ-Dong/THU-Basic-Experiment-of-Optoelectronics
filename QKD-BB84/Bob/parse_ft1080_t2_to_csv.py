import argparse
import csv
import os
import re
from typing import Dict, List, Tuple


def parse_header(lines: List[str]) -> Tuple[Dict[str, str], int]:
    header: Dict[str, str] = {}
    i = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[Flag:]") or stripped.startswith("Flag"):
            return header, i
        if ":" in stripped:
            key, value = stripped.split(":", 1)
            header[key.strip()] = value.strip()
    return header, i


def expand_stop_delay(header: Dict[str, str]) -> Dict[str, str]:
    expanded = dict(header)
    stop_key = None
    for key in header:
        if key.startswith("Stop Delay"):
            stop_key = key
            break
    if not stop_key:
        return expanded

    raw = header.get(stop_key, "")
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        match = re.match(r"(ch\d+)\s+([\d.]+)\s*ns", item)
        if match:
            ch, value = match.groups()
            expanded[f"{stop_key} {ch}"] = value
    return expanded


def parse_events(lines: List[str], start_index: int) -> Tuple[List[str], List[List[str]]]:
    headers: List[str] = []
    rows: List[List[str]] = []
    in_table = False

    for line in lines[start_index:]:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[Flag:]"):
            continue
        if stripped.startswith("Flag"):
            headers = re.split(r"\s+", stripped)
            in_table = True
            continue
        if not in_table:
            continue
        parts = re.split(r"\s+", stripped)
        if len(parts) < 4:
            continue
        rows.append(parts[:4])
    return headers, rows


def write_csv(path: str, headers: List[str], rows: List[List[str]]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        if headers:
            writer.writerow(headers)
        writer.writerows(rows)


def write_header_csv(path: str, header: Dict[str, str]) -> None:
    rows = [[k, v] for k, v in header.items()]
    write_csv(path, ["key", "value"], rows)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Parse FT1080 T2 text file into CSV files."
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to the FT1080 T2 text file",
    )
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory (default: same as input file)",
    )
    args = parser.parse_args()

    input_path = args.input
    if not input_path:
        input_path = input("Enter the FT1080 T2 file path: ").strip()
    if not input_path:
        raise SystemExit("No input file path provided.")

    with open(input_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    header, start_index = parse_header(lines)
    header = expand_stop_delay(header)
    table_headers, rows = parse_events(lines, start_index)

    base_dir = args.out_dir or os.path.dirname(input_path)
    base_name = os.path.splitext(os.path.basename(input_path))[0]

    header_csv = os.path.join(base_dir, f"{base_name}_header.csv")
    events_csv = os.path.join(base_dir, f"{base_name}_events.csv")

    write_header_csv(header_csv, header)
    write_csv(events_csv, table_headers, rows)

    print(f"Header CSV: {header_csv}")
    print(f"Events CSV: {events_csv}")


if __name__ == "__main__":
    main()
