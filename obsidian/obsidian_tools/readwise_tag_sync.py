"""Synchronize Readwise tags with Obsidian files using fuzzy matching."""
from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import requests
from rapidfuzz import fuzz, process

from .tag_utils import (
    default_config_path,
    ensure_frontmatter,
    find_markdown_files,
    find_tags_in_text,
    get_env_token,
    get_frontmatter_tags,
    load_config,
    parse_frontmatter,
    replace_tag_in_text,
    resolve_config_path,
    set_frontmatter_tags,
    setup_logging,
    similarity_threshold,
    write_markdown,
)


@dataclass
class Proposal:
    path: Path
    location: str
    original: str
    suggested: str
    score: float


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
        help="Apply the proposed tag changes to the vault",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview the proposed changes without writing to disk",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    return parser.parse_args()


def fetch_readwise_tags(token: str) -> List[str]:
    url = "https://readwise.io/api/v2/tags/"
    headers = {"Authorization": f"Token {token}"}
    tags: List[str] = []
    while url:
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        payload = response.json()
        tags.extend(
            item["name"]
            for item in payload.get("results", [])
            if isinstance(item, dict) and "name" in item
        )
        url = payload.get("next")
    return sorted(set(tags))


def best_match(tag: str, candidates: Sequence[str]) -> Optional[Tuple[str, float]]:
    if not candidates:
        return None
    result = process.extractOne(tag, candidates, scorer=fuzz.ratio)
    if result is None:
        return None
    match, score, _ = result
    return match, float(score)


def build_proposals(
    path: Path,
    frontmatter_tags: Sequence[str],
    body_tags: Sequence[str],
    readwise_tags: Sequence[str],
    threshold: int,
) -> Tuple[List[Proposal], Dict[str, str], Dict[str, str]]:
    proposals: List[Proposal] = []
    frontmatter_updates: Dict[str, str] = {}
    body_updates: Dict[str, str] = {}

    seen_frontmatter = set()
    for tag in frontmatter_tags:
        if tag in seen_frontmatter:
            continue
        seen_frontmatter.add(tag)
        suggestion = best_match(tag, readwise_tags)
        if suggestion is None:
            continue
        candidate, score = suggestion
        if candidate == tag or score < threshold:
            continue
        proposals.append(Proposal(path, "frontmatter", tag, candidate, score))
        frontmatter_updates[tag] = candidate

    seen_body = set()
    for tag in body_tags:
        if tag in seen_body:
            continue
        seen_body.add(tag)
        suggestion = best_match(tag, readwise_tags)
        if suggestion is None:
            continue
        candidate, score = suggestion
        if candidate == tag or score < threshold:
            continue
        proposals.append(Proposal(path, "body", tag, candidate, score))
        body_updates[tag] = candidate

    return proposals, frontmatter_updates, body_updates


def apply_updates(
    path: Path,
    content_body: str,
    frontmatter_tags: Sequence[str],
    frontmatter_updates: Dict[str, str],
    body_updates: Dict[str, str],
) -> Tuple[Sequence[str], str]:
    updated_tags = [frontmatter_updates.get(tag, tag) for tag in frontmatter_tags]
    # Preserve ordering while removing duplicates
    seen = set()
    deduped_tags = []
    for tag in updated_tags:
        if tag not in seen:
            deduped_tags.append(tag)
            seen.add(tag)
    updated_body = content_body
    for original, replacement in body_updates.items():
        updated_body = replace_tag_in_text(updated_body, original, replacement)
    return deduped_tags, updated_body


def write_proposals(csv_path: Path, proposals: Sequence[Proposal]) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["file", "location", "original_tag", "suggested_tag", "score"])
        for proposal in proposals:
            writer.writerow(
                [
                    str(proposal.path),
                    proposal.location,
                    proposal.original,
                    proposal.suggested,
                    f"{proposal.score:.2f}",
                ]
            )


def main() -> int:
    args = parse_args()
    logger = setup_logging(verbose=args.verbose)
    config_path = resolve_config_path(args.config)
    logger.debug("Using configuration from %s", config_path)
    config = load_config(config_path)

    vault_path = Path(config.get("obsidian_vault_path", "~")).expanduser()
    env_var = str(config.get("readwise_token_env", "READWISE_TOKEN"))
    token = get_env_token(config)
    if not token:
        logger.error(
            "Readwise token not found in environment variable %s", env_var
        )
        return 1

    logger.info("Fetching tags from Readwise…")
    try:
        readwise_tags = fetch_readwise_tags(token)
    except requests.HTTPError as exc:
        if exc.response is not None and exc.response.status_code == 401:
            logger.error(
                "Failed to fetch tags: unauthorized. Verify that the %s environment "
                "variable contains a valid Readwise API token.",
                env_var,
            )
        else:
            logger.error("Failed to fetch tags: %s", exc)
        if exc.response is not None and exc.response.text:
            logger.debug("Readwise response: %s", exc.response.text)
        return 1

    threshold = similarity_threshold(config)
    logger.info("Using similarity threshold %s", threshold)

    proposals: List[Proposal] = []
    csv_path = config_path.parent / "tag_proposal.csv"
    apply_changes = args.apply and not args.dry_run

    for path in find_markdown_files(vault_path):
        content = path.read_text(encoding="utf-8")
        frontmatter, body, _ = parse_frontmatter(content)
        frontmatter = ensure_frontmatter(frontmatter)
        frontmatter_tags = get_frontmatter_tags(frontmatter)
        body_tags = sorted(find_tags_in_text(body))

        file_proposals, frontmatter_updates, body_updates = build_proposals(
            path,
            frontmatter_tags,
            body_tags,
            readwise_tags,
            threshold,
        )
        if not file_proposals:
            continue
        proposals.extend(file_proposals)

        if apply_changes:
            updated_tags, updated_body = apply_updates(
                path,
                body,
                frontmatter_tags,
                frontmatter_updates,
                body_updates,
            )
            set_frontmatter_tags(frontmatter, updated_tags)
            write_markdown(path, frontmatter, updated_body)
            logger.info("Updated %s", path)

    write_proposals(csv_path, proposals)
    if proposals:
        logger.info("Wrote proposal preview to %s", csv_path)
    else:
        logger.info("No tag updates proposed. %s contains only headers.", csv_path)

    if apply_changes:
        logger.info("Apply mode completed")
    else:
        logger.info("Dry-run complete; no files were modified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
