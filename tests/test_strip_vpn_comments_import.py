import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib import strip_vpn_comments


def test_module_imports_and_can_rewrite_file(tmp_path: Path) -> None:
    src = tmp_path / "links.txt"
    src.write_text("vless://uuid@1.1.1.1:443?type=tcp#old\n", encoding="utf-8")

    written = strip_vpn_comments.process_file(str(src), output_path=None, add_comment=False)

    assert written == 1
    assert src.read_text(encoding="utf-8").strip() == "vless://uuid@1.1.1.1:443?type=tcp"
