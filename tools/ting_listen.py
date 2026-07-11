# /// script
# dependencies = ["pyserial"]
# ///
"""Listen on the ting serial port for N seconds, printing whatever arrives."""
import sys, time
import serial

PORT = "/dev/cu.usbmodemEPTXP3AG1"
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 60

ser = serial.Serial(PORT, 115200, timeout=0.2)
end = time.time() + DUR
buf = b""
while time.time() < end:
    chunk = ser.read(4096)
    if chunk:
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            print(f"[{time.strftime('%H:%M:%S')}] {line.decode('utf-8','replace').strip()}", flush=True)
ser.close()
print("--- listen done ---")
