"""Overwrite one Kokoro voices.bin slot with a weighted blend of others (stdlib only; runs in CI).

The model checks the speaker count, so a blend replaces an unused slot instead of being appended.
Usage: python3 blend_voice.py voices.bin TARGET_ID ID:WEIGHT [ID:WEIGHT ...]
"""
import sys
from array import array

ROW = 510 * 256  # floats per voice style table


def blend(path, target, parts):
    voices = array("f")
    with open(path, "rb") as f:
        voices.frombytes(f.read())
    assert len(voices) % ROW == 0 and target < len(voices) // ROW, "not a Kokoro voices.bin"
    assert abs(sum(w for _, w in parts) - 1) < 1e-6, "weights must sum to 1"
    mixed = [sum(w * voices[i * ROW + k] for i, w in parts) for k in range(ROW)]
    voices[target * ROW:(target + 1) * ROW] = array("f", mixed)
    with open(path, "wb") as f:
        voices.tofile(f)


if __name__ == "__main__":
    blend(sys.argv[1], int(sys.argv[2]), [(int(i), float(w)) for i, w in (p.split(":") for p in sys.argv[3:])])
