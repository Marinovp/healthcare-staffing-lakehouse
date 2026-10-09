"""Print an inventory of the local source files: size, rows, columns, encoding and MD5."""

import csv
import hashlib
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def md5_of(path: Path) -> str:
    """MD5 of a file, read in chunks."""
    with path.open("rb") as f:
        return hashlib.file_digest(f, "md5").hexdigest()


def count_rows_and_columns(path: Path) -> tuple[int, int, bool]:
    """Count rows and columns, and tell me if the file is valid UTF-8."""
    for encoding in ("utf-8", "latin-1"):  # latin-1 never fails, so one of the two always returns
        try:
            with path.open(newline="", encoding=encoding) as f:
                reader = csv.reader(f)
                header = next(reader, None)  # Skip the header row
                rows = sum(1 for _ in reader)  # Count the remaining rows
            return rows, len(header), encoding == "utf-8"
        except UnicodeDecodeError:
            continue


def main() -> None:
    csv_files = sorted(DATA_DIR.rglob("*.csv"))
    print(f"{'file':<80} {'MB':>7} {'rows':>9} {'cols':>5} {'utf8':>5}  md5")
    for path in csv_files:
        size_mb = path.stat().st_size / (1024 * 1024)
        rows, cols, is_utf8 = count_rows_and_columns(path)
        name = str(path.relative_to(DATA_DIR))
        print(
            f"{name:<80} {size_mb:>7.2f} {rows:>9} {cols:>5} {str(is_utf8):>5}  {md5_of(path)}"
        )
    print(f"\nTotal CSV files: {len(csv_files)}")


if __name__ == "__main__":
    main()
