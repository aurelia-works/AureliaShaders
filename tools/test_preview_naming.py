"""Focused test: rainy CLI renders must not overwrite dry ones in one --out dir.

`tools/preview.py` builds output names from preset/view/viewpoint/time only,
so `--rain 0.8` wrote the same filename as the dry render and silently
replaced it (hit during V1-FINAL-CHECK on sunview/nightsky). The CLI must
append a deterministic rain suffix whenever rain != 0 while leaving dry
(default) paths byte-identical to the legacy names.

Run: tools/.venv/bin/python tools/test_preview_naming.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from preview import output_filename


def test_dry_names_unchanged() -> None:
    assert output_filename("ADAPTIVE", "normal", "overview", 0.25, 0.0) == \
        "adaptive-normal-overview-t0.25.png"
    assert output_filename("ADAPTIVE", "normal", "sheet", 0.25, 0.0) == \
        "adaptive-normal-sheet-t0.25.png"
    assert output_filename("BALANCED", "debug5", "shore", 0.5, 0.0) == \
        "balanced-debug5-shore-t0.5.png"


def test_rainy_names_distinct_and_deterministic() -> None:
    dry = output_filename("ADAPTIVE", "normal", "overview", 0.25, 0.0)
    wet08 = output_filename("ADAPTIVE", "normal", "overview", 0.25, 0.8)
    wet1 = output_filename("ADAPTIVE", "normal", "overview", 0.25, 1.0)
    assert wet08 != dry
    assert wet1 != dry
    assert wet08 != wet1
    # Deterministic: same inputs, same name; :g formatting, no float noise.
    assert wet08 == output_filename("ADAPTIVE", "normal", "overview", 0.25, 0.8)
    assert wet08 == "adaptive-normal-overview-t0.25-rain0.8.png"
    assert wet1 == "adaptive-normal-overview-t0.25-rain1.png"
    # Contact sheet follows the same rule.
    assert output_filename("ADAPTIVE", "normal", "sheet", 0.25, 0.8) == \
        "adaptive-normal-sheet-t0.25-rain0.8.png"


def main() -> int:
    test_dry_names_unchanged()
    test_rainy_names_distinct_and_deterministic()
    print("PASS: rainy CLI output names carry a deterministic rain suffix; dry names unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
