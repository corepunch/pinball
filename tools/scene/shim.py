"""What the scene tools share: the repository root, the vector class, the geometry module and the ramp-path checker."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'tools'))
from vector import Vector  # noqa: E402,F401
import geometry  # noqa: E402,F401
import ramp_paths  # noqa: E402,F401
