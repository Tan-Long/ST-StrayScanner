import numpy as np
import warnings


def read_ply(filepath) -> np.ndarray:
    """Read a binary little-endian PLY file from Stray Scanner.
    Returns (N, 4) float32 array: [x, y, z, confidence].
    """
    with open(filepath, "rb") as f:
        header_lines = []
        while True:
            line = f.readline()
            if not line:
                raise ValueError("PLY file ended before 'end_header'")
            header_lines.append(line)
            if line.strip() == b"end_header":
                break

        header_text = b"".join(header_lines).decode("ascii", errors="replace")

        n_vertices = 0
        for line in header_lines:
            line_s = line.decode("ascii", errors="replace").strip()
            if line_s.startswith("element vertex"):
                try:
                    n_vertices = int(line_s.split()[-1])
                except ValueError:
                    raise ValueError(f"Cannot parse vertex count from: {line_s!r}")

        if n_vertices == 0:
            warnings.warn("PLY file has 0 vertices — returning empty array")
            return np.empty((0, 4), dtype=np.float32)

        raw = f.read(n_vertices * 4 * 4)  # 4 floats × 4 bytes each
        if len(raw) < n_vertices * 16:
            raise ValueError(
                f"PLY payload too short: expected {n_vertices * 16} bytes, got {len(raw)}"
            )

        arr = np.frombuffer(raw, dtype="<f4").reshape(n_vertices, 4)
        return arr
