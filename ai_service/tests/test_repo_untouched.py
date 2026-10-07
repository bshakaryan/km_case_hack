import subprocess
from pathlib import Path


def test_existing_repository_files_are_untouched():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        ["git", "diff", "--name-only", "HEAD", "--", ".", ":!ai_service"],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
    )
    assert not result.stdout.strip(), f"Files outside ai_service are modified:\n{result.stdout}"
