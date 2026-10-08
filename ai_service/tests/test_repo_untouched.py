import subprocess
from pathlib import Path


def test_transfer_changes_only_allowed_paths():
    root = Path(__file__).resolve().parents[2]
    allowed = {line.removeprefix("- `").removesuffix("`")
               for line in (root / "ai_service" / "ALLOWED_CHANGES.md").read_text(encoding="utf-8").splitlines()
               if line.startswith("- `")}
    assert "ai_service/" in allowed
    result = subprocess.run(
        ["git", "diff", "--name-only", "HEAD", "--", "."],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
    )
    unexpected = [path for path in result.stdout.splitlines()
                  if path not in allowed and not any(path.startswith(prefix) for prefix in allowed if prefix.endswith("/"))]
    assert not unexpected, f"Unexpected paths in transfer: {unexpected}"
