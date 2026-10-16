import json
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIELDS = (
    "id",
    "name",
    "version",
    "plugin_api",
    "author",
    "license",
    "icon",
    "description",
    "tags",
    "dependencies",
    "deprecated",
)


def main():
    entries = []
    for manifest in sorted(ROOT.glob("*/plugin.toml")):
        data = tomllib.loads(manifest.read_text(encoding="utf-8"))
        entries.append({key: data[key] for key in FIELDS if key in data})

    blocks = [
        "[[plugin]]\n"
        + "\n".join(
            f"{key} = {json.dumps(value, ensure_ascii=False)}"
            for key, value in entry.items()
        )
        for entry in entries
    ]
    catalog = "# Generated from plugin manifests; do not edit.\n"
    if blocks:
        catalog += "\n" + "\n\n".join(blocks) + "\n"
    assert tomllib.loads(catalog).get("plugin", []) == entries
    (ROOT / "catalog.toml").write_text(catalog, encoding="utf-8")


if __name__ == "__main__":
    main()
