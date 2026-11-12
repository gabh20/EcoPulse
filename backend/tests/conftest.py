import os
import sys
from pathlib import Path

os.environ.setdefault("JWT_SECRET", "test-secret-with-at-least-32-characters")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
