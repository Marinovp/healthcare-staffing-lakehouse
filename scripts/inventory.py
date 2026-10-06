"""Print an inventory of the local source files: size, rows, columns, encoding and MD5."""

import csv
import hashlib
from os import path
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CHUNK_SIZE = 1024 * 1024  # Read files in 1MB chunks


def md5_of(path: Path) -> str:
    """Calculate the MD5 hash of a file."""
    # digest = hashlib.md5()
    # with path.open("rb") as f:
    #     for chunk in iter(lambda: f.read(chunk_size), b""):
    #         digest.update(chunk)
    # return digest.hexdigest()

    digest = hashlib.md5()
    with path.open("rb") as f:
        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def count_rows_and_columns(path: Path) -> tuple[int, int, bool]:
    """Count the number of rows and columns in a CSV file."""
    try:
        with path.open(newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = next(reader, None)  # Skip the header row if present
            rows = sum(1 for _ in reader)  # Count the remaining rows
        return rows, len(header), True
    except UnicodeDecodeError:
        with path.open(newline="", encoding="latin-1") as f:
            reader = csv.reader(f)
            header = next(reader, None)  # Skip the header row if present
            rows = sum(1 for _ in reader)  # Count the remaining rows
        return rows, len(header), False


def main() -> None:
    csv_files = sorted(DATA_DIR.rglob("*.csv"))
    print(f"{'file':<80} {'MB':>7} {'rows':>9} {'cols':>5} {'utf8':>5}  md5")
    for paht in csv_files:
        size_mb = paht.stat().st_size / (1024 * 1024)
        rows, cols, is_utf8 = count_rows_and_columns(paht)
        name = str(paht.relative_to(DATA_DIR))
        print(
            f"{name:<80} {size_mb:>7.2f} {rows:>9} {cols:>5} {str(is_utf8):>5}  {md5_of(paht)}"
        )
    print(f"\nTotal CSV files: {len(csv_files)}")


if __name__ == "__main__":
    main()
