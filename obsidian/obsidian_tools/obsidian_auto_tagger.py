"""Apply automatic tag rules to Obsidian markdown files."""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set

import re

from .tag_utils import (
    default_config_path,
    ensure_frontmatter,
    find_markdown_files,
    get_frontmatter_tags,
    load_config,
    parse_frontmatter,
    resolve_config_path,
    set_frontmatter_tags,
    setup_logging,
    write_markdown,
)


@dataclass
class AutoTagRule:
    pattern: re.Pattern[str]
    template: str
    raw_pattern: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=default_config_path(),
        help="Path to the configuration YAML file",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write updated tags back to disk",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview the changes without writing to disk",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    return parser.parse_args()


def load_rules(config: Dict[str, object]) -> List[AutoTagRule]:
    raw_rules = config.get("auto_tags", [])
    rules: List[AutoTagRule] = []
    if not isinstance(raw_rules, list):
        return rules
    for entry in raw_rules:
        if not isinstance(entry, dict):
            continue
        pattern = entry.get("pattern")
        template = entry.get("tag_format")
        if not isinstance(pattern, str) or not isinstance(template, str):
            continue
        try:
            compiled = re.compile(pattern)
        except re.error:
            continue
        rules.append(AutoTagRule(compiled, template, pattern))
    return rules


def render_tag(rule: AutoTagRule, match: re.Match[str]) -> Optional[str]:
    groups = {key: value for key, value in match.groupdict().items() if value is not None}
    groups.setdefault("match", match.group(0))
    try:
        return rule.template.format(**groups)
    except KeyError:
        return None


def collect_tags(body: str, rules: Sequence[AutoTagRule]) -> Set[str]:
    collected: Set[str] = set()
    for rule in rules:
        for match in rule.pattern.finditer(body):
            tag = render_tag(rule, match)
            if tag:
                collected.add(tag)
    return collected


def apply_new_tags(existing: Sequence[str], additions: Sequence[str]) -> List[str]:
    ordered: List[str] = list(existing)
    for tag in additions:
        if tag not in ordered:
            ordered.append(tag)
    return ordered


def main() -> int:
    args = parse_args()
    logger = setup_logging(verbose=args.verbose)
    config_path = resolve_config_path(args.config)
    logger.debug("Using configuration from %s", config_path)
    config = load_config(config_path)
    rules = load_rules(config)

    if not rules:
        logger.info("No auto-tag rules configured. Nothing to do.")
        return 0

    vault_path = Path(config.get("obsidian_vault_path", "~")).expanduser()
    apply_changes = args.apply and not args.dry_run
    total_updates = 0

    for path in find_markdown_files(vault_path):
        content = path.read_text(encoding="utf-8")
        frontmatter, body, _ = parse_frontmatter(content)
        frontmatter = ensure_frontmatter(frontmatter)
        existing_tags = get_frontmatter_tags(frontmatter)
        additions = sorted(collect_tags(body, rules))
        new_tags = [tag for tag in additions if tag not in existing_tags]
        if not new_tags:
            continue
        total_updates += 1
        logger.info("%s -> %s", path, ", ".join(new_tags))
        if apply_changes:
            updated = apply_new_tags(existing_tags, new_tags)
            set_frontmatter_tags(frontmatter, updated)
            write_markdown(path, frontmatter, body)

    if apply_changes:
        logger.info("Applied tag updates to %s files", total_updates)
    else:
        logger.info(
            "Dry-run complete; %s files would be updated", total_updates
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
