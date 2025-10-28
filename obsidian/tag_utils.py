"""Shared utilities for Obsidian automation scripts."""
from __future__ import annotations

import logging
import os
import re
from io import StringIO
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence, Set, Tuple

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq

LOGGER_NAME = "obsidian_tools"

_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.indent(mapping=2, sequence=4, offset=2)
_yaml.default_flow_style = False

_FRONTMATTER_PATTERN = re.compile(r"^---\s*\n(.*?)\n---\s*\n?", re.DOTALL)
_TAG_PATTERN = re.compile(r"(?<![\w/])#([A-Za-z0-9_./-]+)")


def setup_logging(verbose: bool = False) -> logging.Logger:
    """Configure and return a logger for the tools."""
    logger = logging.getLogger(LOGGER_NAME)
    if not logger.handlers:
        handler = logging.StreamHandler()
        formatter = logging.Formatter("%(levelname)s: %(message)s")
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    return logger


def resolve_config_path(config_path: Path) -> Path:
    """Return the path to the config file, falling back to the default template."""
    candidate = config_path.expanduser()
    if candidate.exists():
        return candidate

    if not candidate.name.endswith("-default"):
        fallback = candidate.with_name(f"{candidate.name}-default")
        if fallback.exists():
            logger = logging.getLogger(LOGGER_NAME)
            logger.info(
                "Configuration file %s not found; using default template %s",
                candidate,
                fallback.name,
            )
            return fallback

    raise FileNotFoundError(
        f"Configuration file not found at {candidate}. Copy config.yaml-default "
        "to config.yaml and update it for your vault, or pass --config to point "
        "to a different file."
    )


def load_config(config_path: Path) -> Dict[str, object]:
    """Load the YAML configuration file."""
    resolved = resolve_config_path(config_path)
    with resolved.open("r", encoding="utf-8") as fh:
        data = _yaml.load(fh) or {}
    if not isinstance(data, dict):
        raise ValueError(f"Configuration at {config_path} must be a mapping")
    return data  # type: ignore[return-value]


def find_markdown_files(root: Path) -> Iterator[Path]:
    """Yield markdown files in the vault."""
    for path in sorted(root.expanduser().rglob("*.md")):
        if path.is_file():
            yield path


def read_markdown(path: Path) -> str:
    with path.open("r", encoding="utf-8") as fh:
        return fh.read()


def write_markdown(path: Path, frontmatter: CommentedMap, body: str) -> None:
    content = compose_markdown(frontmatter, body)
    with path.open("w", encoding="utf-8") as fh:
        fh.write(content)


def parse_frontmatter(content: str) -> Tuple[CommentedMap, str, bool]:
    match = _FRONTMATTER_PATTERN.match(content)
    if match:
        frontmatter_text = match.group(1)
        remaining = content[match.end():]
        data = _yaml.load(frontmatter_text) or CommentedMap()
        if not isinstance(data, CommentedMap):
            data = CommentedMap(data)
        return data, remaining, True
    return CommentedMap(), content, False


def compose_markdown(frontmatter: CommentedMap, body: str) -> str:
    buffer = StringIO()
    if frontmatter:
        _yaml.dump(frontmatter, buffer)
        fm_text = buffer.getvalue().strip()
        header = f"---\n{fm_text}\n---\n"
    else:
        header = ""
    body_text = body
    if header and body_text and not body_text.startswith("\n"):
        body_text = "\n" + body_text
    return f"{header}{body_text}"


def get_frontmatter_tags(frontmatter: CommentedMap) -> List[str]:
    tags = frontmatter.get("tags")
    if tags is None:
        return []
    if isinstance(tags, str):
        return [t.strip() for t in tags.split(",") if t.strip()]
    if isinstance(tags, Sequence):
        return [str(t) for t in tags]
    return []


def set_frontmatter_tags(frontmatter: CommentedMap, tags: Sequence[str]) -> None:
    existing = frontmatter.get("tags")
    if isinstance(existing, str):
        frontmatter["tags"] = ", ".join(tags)
        return
    seq = CommentedSeq()
    for tag in tags:
        seq.append(tag)
    frontmatter["tags"] = seq


def find_tags_in_text(text: str) -> Set[str]:
    return {match.group(1) for match in _TAG_PATTERN.finditer(text)}


def replace_tag_in_text(text: str, old: str, new: str) -> str:
    if old == new:
        return text
    pattern = re.compile(rf"(?<![\w/])#{re.escape(old)}(?![\w/])")
    return pattern.sub(f"#{new}", text)


def ensure_directory(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def get_env_token(config: Dict[str, object]) -> Optional[str]:
    env_var = str(config.get("readwise_token_env", "READWISE_TOKEN"))
    return os.environ.get(env_var)


def similarity_threshold(config: Dict[str, object]) -> int:
    try:
        value = int(config.get("similarity_threshold", 80))
    except (TypeError, ValueError):
        value = 80
    return max(0, min(100, value))


def ensure_frontmatter(frontmatter: CommentedMap) -> CommentedMap:
    return frontmatter or CommentedMap()

