"""Send a 32x32 grayscale image to the SoC over UART and print the predicted digit.

Usage:
    python sw/fpga_test.py --port COM8 --image mem/digit5_32x32.hex

The image file holds 1024 hex bytes (one per pixel, row major).
Requires: pip install pyserial
"""
import argparse
import sys
import time
from pathlib import Path

import serial


def load_image(path: Path) -> bytes:
    data = bytes(int(tok, 16) for tok in path.read_text().split())
    if len(data) != 1024:
        sys.exit(f"Expected 1024 bytes, got {len(data)} from {path}")
    return data


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="serial port, for example COM8 or /dev/ttyUSB0")
    ap.add_argument("--image", required=True, type=Path, help="hex image file, 1024 bytes")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=20.0, help="seconds to wait for the result")
    args = ap.parse_args()

    data = load_image(args.image)
    print(f"Image loaded: {len(data)} bytes ({args.image})")

    with serial.Serial(args.port, args.baud, timeout=0.25) as ser:
        time.sleep(2)
        ser.reset_input_buffer()

        print("Sending image...")
        for i, b in enumerate(data):
            ser.write(bytes([b]))
            ser.flush()
            time.sleep(2 * 8.68e-6)  # small gap between bytes
            if (i + 1) % 128 == 0:
                print(f"Sent {i + 1}/{len(data)} bytes")

        print("Transmission complete. Waiting for prediction...")
        received = bytearray()
        deadline = time.time() + args.timeout
        while time.time() < deadline and not received:
            received.extend(ser.read(ser.in_waiting or 1))

    if not received:
        sys.exit("NO RESPONSE RECEIVED")

    print("RAW RESPONSE:", bytes(received))
    print("HEX:", received.hex(" "))
    print("DECIMAL:", list(received))
    if received[0] <= 9:
        print("PREDICTED DIGIT:", received[0])
        print("Check the 7-segment display too.")


if __name__ == "__main__":
    main()
