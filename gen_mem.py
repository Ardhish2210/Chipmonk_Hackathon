import random

with open("image.mem", "w") as f:
    for i in range(4096):
        # Generate random pixel values 0-127 in hex (fits in positive signed 8-bit)
        val = random.randint(0, 127)
        val_hex = hex(val)[2:].zfill(2)
        f.write(f"{val_hex}\n")
print("image.mem generated for random 64x64 image.")
