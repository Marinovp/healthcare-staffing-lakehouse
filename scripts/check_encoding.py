"""Report which lines of a file are not valid UTF-8, and what the bad bytes are."""

import sys
from pathlib import Path


def main() -> None:
    path = Path(sys.argv[1])
    bad_lines = 0
    bad_bytes = set()

    with path.open("rb") as file:
        for line_number, line in enumerate(file, start=1):
            try:
                line.decode("utf-8")
            except UnicodeDecodeError as error:
                bad_lines += 1
                bad_bytes.add(line[error.start])
                if bad_lines <= 3:
                    text = line.decode("cp1252", errors="replace").strip()
                    print(f"line {line_number}: {text[:160]}")

    print(f"\n{bad_lines} lines are not valid UTF-8")
    print(f"bad byte values: {sorted(hex(b) for b in bad_bytes)}")


if __name__ == "__main__":
    main()
