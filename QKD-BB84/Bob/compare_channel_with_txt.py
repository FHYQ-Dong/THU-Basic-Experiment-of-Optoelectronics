import csv
import os

import matplotlib.pyplot as plt

def read_txt_lines(txt_path: str) -> list[str]:
    with open(txt_path, "r", encoding="utf-8") as f:
        return [line.rstrip("\r\n") for line in f]


def compare_csv_to_txt(
    csv_path: str,
    txt_path: str,
    output_csv_path: str,
    compute_histogram: bool,
) -> None:
    txt_lines = read_txt_lines(txt_path)

    total = 0
    matched = 0
    tot = 0
    histogram: dict[int, int] = {}
    time_by_channel: dict[int, list[int]] = {0: [], 1: [], 2: [], 3: []}
    detect_distribution: dict[int, dict[int, int]] = {}

    with open(csv_path, "r", encoding="utf-8", newline="") as csv_in, open(
        output_csv_path, "w", encoding="utf-8", newline=""
    ) as csv_out:
        reader = csv.DictReader(csv_in)
        fieldnames = ["seq", "channel_mapped", "txt_value", "match"]
        writer = csv.DictWriter(csv_out, fieldnames=fieldnames)
        writer.writeheader()

        for row in reader:
            total += 1
            seq_raw = row.get("seq", "")
            channel_mapped = row.get("channel_mapped", "")
            time_arrow = row.get("time_diff_ps", "")
            #if int(time_arrow) > 11000000 or int(time_arrow) < 7000000:
            #     continue

            try:
                seq = int(seq_raw)
            except ValueError as exc:
                raise ValueError(f"Invalid seq value: {seq_raw}") from exc

            txt_value = ""
            match = 0
            

            if 0 <= seq < len(txt_lines):
                txt_value = txt_lines[seq]
                try:
                    txt_channel = int(txt_value)
                    csv_channel = int(channel_mapped)
                except ValueError:
                    txt_channel = None
                    csv_channel = None

                if txt_channel is not None and csv_channel is not None:
                    detect_distribution.setdefault(txt_channel, {})
                    detect_distribution[txt_channel][csv_channel] = (
                        detect_distribution[txt_channel].get(csv_channel, 0) + 1
                    )
                # if channel_mapped == txt_value:
                #     match = 1
                #     matched += 1
                if int(channel_mapped) < 2 and int(txt_value) < 2:
                    tot += 1
                    if(int(channel_mapped) == int(txt_value)):
                        match = 1
                        matched += 1
                        if compute_histogram:
                            try:
                                time_ps = int(time_arrow)
                            except ValueError:
                                time_ps = None
                            if time_ps is not None:
                                bin_index = time_ps // 1_000_000
                                histogram[bin_index] = histogram.get(bin_index, 0) + 1
                                time_by_channel[int(channel_mapped)].append(time_ps)
                    else:
                        match = -1

                if int(channel_mapped) >= 2 and int(txt_value) >= 2:
                    tot += 1
                    if(int(channel_mapped) == int(txt_value)):
                        match = 1
                        matched += 1
                        if compute_histogram:
                            try:
                                time_ps = int(time_arrow)
                            except ValueError:
                                time_ps = None
                            if time_ps is not None:
                                bin_index = time_ps // 1_000_000
                                histogram[bin_index] = histogram.get(bin_index, 0) + 1
                                time_by_channel[int(channel_mapped)].append(time_ps)
                    else:
                        match = -1

            writer.writerow(
                {
                    "seq": seq,
                    "channel_mapped": channel_mapped,
                    "txt_value": txt_value,
                    "match": match,
                }
            )

    ratio = matched / tot if tot else 0
    print(f"Matched {matched}/{tot} ({ratio:.6f})")

    if detect_distribution:
        print("\nDistribution of CSV detections by TXT channel:")
        header = ["txt_channel", "csv_0", "csv_1", "csv_2", "csv_3", "total"]
        rows = []
        for txt_channel in sorted(detect_distribution.keys()):
            row_counts = detect_distribution[txt_channel]
            counts = [row_counts.get(i, 0) for i in range(4)]
            total_count = sum(counts)
            rows.append([txt_channel, *counts, total_count])

        col_widths = [len(h) for h in header]
        for row in rows:
            for idx, value in enumerate(row):
                col_widths[idx] = max(col_widths[idx], len(str(value)))

        header_line = "  ".join(
            str(header[i]).rjust(col_widths[i]) for i in range(len(header))
        )
        print(header_line)
        print("  ".join("-" * w for w in col_widths))
        for row in rows:
            print(
                "  ".join(
                    str(row[i]).rjust(col_widths[i]) for i in range(len(row))
                )
            )

    if compute_histogram:
        print("Histogram of time_diff_ps for match=1 (bin width=1,000,000 ps):")
        for bin_index in sorted(histogram.keys()):
            start = bin_index * 1_000_000
            end = start + 1_000_000
            count = histogram[bin_index]
            print(f"{start}-{end}: {count}")

        all_times = [t for values in time_by_channel.values() for t in values]
        if all_times:
            max_time = max(all_times)
            bins = list(range(0, max_time + 1_000_000, 1_000_000))
        else:
            bins = [0, 1_000_000]

        fig, axes = plt.subplots(2, 2, figsize=(10, 8))
        axes_list = [axes[0][0], axes[0][1], axes[1][0], axes[1][1]]

        for channel in range(4):
            ax = axes_list[channel]
            data = time_by_channel[channel]
            ax.hist(data, bins=bins, edgecolor="black")
            ax.set_title(f"Channel {channel} time_diff_ps")
            ax.set_xlabel("time_diff_ps")
            ax.set_ylabel("count")

        fig.tight_layout()
        plt.show()


def main() -> None:
    csv_path = input("Input CSV path: ").strip().strip('"')
    txt_path = input("Input TXT path: ").strip().strip('"')
    hist_input = input("Compute time_diff_ps histogram? (y/n): ").strip().lower()
    compute_histogram = hist_input == "y"
    #compute_histogram = False
    output_csv_path = input(
        "Output CSV path (leave empty for default): "
    ).strip().strip('"')

    if not output_csv_path:
        base, ext = os.path.splitext(csv_path)
        output_csv_path = f"{base}_compare.csv"

    compare_csv_to_txt(csv_path, txt_path, output_csv_path, compute_histogram)
    print(f"Wrote: {output_csv_path}")


if __name__ == "__main__":
    main()
