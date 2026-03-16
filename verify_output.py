"""
Reference Python model for the CNN accelerator.
Computes convolution of the same 8x8 image with the Laplacian kernel
and ReLU, to verify simulator output.
"""
import numpy as np

# ─── image ───────────────────────────────────────────────────────────────────
pixels = [i % 50 for i in range(64)]
image  = np.array(pixels, dtype=np.int32).reshape(8, 8)

print("Input image (8x8):")
for row in image:
    print(" ".join(f"{p:4d}" for p in row))

# ─── Laplacian kernel ─────────────────────────────────────────────────────────
kernel = np.array([[-1,-1,-1],
                   [-1, 8,-1],
                   [-1,-1,-1]], dtype=np.int32)

print("\nKernel (3x3):")
for row in kernel:
    print(" ".join(f"{w:3d}" for w in row))

# ─── VALID convolution (no padding, stride=1) ─────────────────────────────────
H, W   = 8, 8
K      = 3
out_h  = H - K + 1  # 6
out_w  = W - K + 1  # 6
outputs = np.zeros((out_h, out_w), dtype=np.int32)

for r in range(out_h):
    for c in range(out_w):
        window = image[r:r+K, c:c+K]
        outputs[r, c] = np.sum(window * kernel)

print("\nConv output (before ReLU):")
for row in outputs:
    print(" ".join(f"{v:6d}" for v in row))

# ─── ReLU + saturate to uint8 ─────────────────────────────────────────────────
relu_out = np.clip(outputs, 0, 255).astype(np.uint8)

print("\nConv output (after ReLU, saturated to 8-bit):")
for row in relu_out:
    print(" ".join(f"{v:4d}" for v in row))

print("\nSimulator produced:")
sim = [[0,0,0,0,0,0],
       [0,0,0,0,0,0],
       [0,0,0,0,0,0],
       [0,0,0,0,0,0],
       [0,28,78,78,78,78],
       [128,178,228,228,228,228]]
for row in sim:
    print(" ".join(f"{v:4d}" for v in row))

print("\nMatch check:")
for r in range(out_h):
    for c in range(out_w):
        if relu_out[r,c] != sim[r][c]:
            print(f"  MISMATCH at ({r},{c}): expected {relu_out[r,c]}, got {sim[r][c]}")
all_match = all(relu_out[r,c] == sim[r][c] for r in range(out_h) for c in range(out_w))
print("  ALL MATCH!" if all_match else "  Some mismatches found.")
