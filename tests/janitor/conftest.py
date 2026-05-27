"""Make the janitor source importable from the test without packaging it."""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
JANITOR_SRC = REPO_ROOT / "platform" / "janitor" / "src"
sys.path.insert(0, str(JANITOR_SRC))
