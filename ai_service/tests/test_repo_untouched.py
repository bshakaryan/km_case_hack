import re
import subprocess
from pathlib import Path


def test_only_allowed_backend_and_frontend_files_are_staged():
    root = Path(__file__).resolve().parents[2]
    document = (root / "ai_service/ALLOWED_CHANGES.md").read_text(encoding="utf-8")
    allowed = set(re.findall(r"^- `(backend|frontend)/([^`]+)`$", document, flags=re.MULTILINE))
    allowed_paths = {f"{directory}/{name}" for directory, name in allowed}
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--", "backend", "frontend"],
        cwd=root, text=True, capture_output=True, check=True,
    )
    staged = {line.replace("\\", "/") for line in result.stdout.splitlines() if line}
    assert staged <= allowed_paths, f"В индекс попали неразрешённые файлы: {sorted(staged - allowed_paths)}"
