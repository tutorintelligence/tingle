# /// script
# dependencies = ["pyserial"]
# ///
"""Minimal MicroPython REPL client for the TE EP-2350 'ting'.
Usage: uv run ting_repl.py "cmd1" "cmd2" ...
Sends Ctrl+C to grab the REPL, runs each command, prints output.
Pass --reset as last arg to soft-reboot (Ctrl+D) when done.
"""
import sys, time
import serial

PORT = "/dev/cu.usbmodemEPTXP3AG1"

def read_all(ser, quiet_ms=300, max_s=5.0):
    out = b""
    last = time.time()
    start = last
    while True:
        chunk = ser.read(4096)
        if chunk:
            out += chunk
            last = time.time()
        elif time.time() - last > quiet_ms / 1000:
            break
        if time.time() - start > max_s:
            break
    return out.decode("utf-8", "replace")

def main():
    args = sys.argv[1:]
    do_reset = "--reset" in args
    cmds = [a for a in args if a != "--reset"]
    ser = serial.Serial(PORT, 115200, timeout=0.05)
    # Interrupt any running program and get a prompt
    ser.write(b"\r\x03\x03")
    banner = read_all(ser)
    print(f"--- interrupt ---\n{banner}")
    for cmd in cmds:
        ser.write(cmd.encode() + b"\r")
        time.sleep(0.1)
        print(f"--- {cmd} ---\n{read_all(ser)}")
    if do_reset:
        ser.write(b"\x04")  # soft reboot, restarts main program
        time.sleep(0.3)
        print(f"--- soft reset ---\n{read_all(ser, max_s=2)}")
    ser.close()

if __name__ == "__main__":
    main()
