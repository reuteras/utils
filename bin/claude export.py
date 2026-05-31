#!/usr/bin/env python3
"""
claude_export.py — Export Claude.ai conversations to Markdown.

Usage:
    python3 claude_export.py conversations.json          # list all conversations
    python3 claude_export.py conversations.json 2        # export by index
    python3 claude_export.py conversations.json "Mounjaro"  # export by name search
    python3 claude_export.py conversations.json --all    # export all conversations
    python3 claude_export.py conversations.json 2 -o ~/notes/mounjaro.md  # custom path
"""

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path


# ── Parsing ────────────────────────────────────────────────────────────────────

def load_export(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        for key in ("conversations", "chats", "data"):
            if key in data and isinstance(data[key], list):
                return data[key]
    if isinstance(data, list):
        return data
    raise ValueError("Unexpected JSON structure — expected a list of conversations.")


def get_text_block(message: dict) -> tuple[str, list[dict]]:
    """Return (text, citations) from the main text content block of a message."""
    for block in message.get("content", []):
        if block.get("type") == "text" and block.get("text", "").strip():
            return block["text"].strip(), block.get("citations", [])
    text = message.get("text", "").strip()
    return text, message.get("citations", [])


def extract_search_links(messages: list[dict]) -> dict[str, str]:
    """Collect URL → title pairs from all web_search tool_result blocks."""
    links: dict[str, str] = {}
    for msg in messages:
        for block in msg.get("content", []):
            if block.get("type") == "tool_result" and block.get("name") == "web_search":
                for item in block.get("content", []):
                    if item.get("type") == "knowledge":
                        url = item.get("url", "").strip()
                        title = re.sub(r"\s+", " ", item.get("title", url)).strip()
                        if url:
                            links[url] = title
    return links


def clean_text(text: str) -> str:
    """Strip artefacts from the Claude export format."""
    text = re.sub(
        r"```\nThis block is not supported on your current device yet\.\n```\n*",
        "",
        text,
    )
    return text.strip()


# ── Citation injection ─────────────────────────────────────────────────────────

def apply_citations(text: str, citations: list[dict]) -> str:
    """
    Insert inline markdown links using the start_index/end_index offsets
    stored in each citation entry.

    The export format stores citations as:
        {"start_index": N, "end_index": N,
         "details": {"type": "web_search_citation", "url": "https://..."}}

    We sort descending by start_index so that inserting from the end of the
    string doesn't shift the indices of earlier spans.
    """
    if not citations:
        return text

    # Deduplicate: same span + same URL → keep one
    seen: set[tuple[int, int, str]] = set()
    unique: list[dict] = []
    for cit in citations:
        url = cit.get("details", {}).get("url", "")
        s, e = cit.get("start_index", -1), cit.get("end_index", -1)
        if not url or s < 0 or e <= s:
            continue
        key = (s, e, url)
        if key not in seen:
            seen.add(key)
            unique.append(cit)

    # Apply from the end so earlier indices stay valid
    for cit in sorted(unique, key=lambda c: c["start_index"], reverse=True):
        url = cit["details"]["url"]
        s, e = cit["start_index"], cit["end_index"]
        if e > len(text):
            continue
        span = text[s:e]
        # Avoid double-linking (span already contains a markdown link)
        if "](" in span:
            continue
        text = text[:s] + f"[{span}]({url})" + text[e:]

    return text


# ── Formatting ─────────────────────────────────────────────────────────────────

def format_date(iso: str) -> str:
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except Exception:
        return iso[:10]


def conversation_to_markdown(chat: dict) -> str:
    title = chat.get("name") or "Untitled"
    created = format_date(chat.get("created_at", ""))
    messages = chat.get("chat_messages", [])
    links = extract_search_links(messages)

    lines: list[str] = []
    # H2 so the document can be pasted under an existing H1
    lines.append(f"## {title}")
    lines.append(f"\n*Exported from Claude.ai — {created}*\n")
    lines.append("---\n")

    for msg in messages:
        sender = msg.get("sender", "")
        raw_text, citations = get_text_block(msg)
        text = clean_text(raw_text)
        if not text:
            continue

        if sender == "assistant" and citations:
            text = apply_citations(text, citations)

        # Downshift headings inside message body by one level
        # (### → ####, ## → ###) so they sit below the H3 speaker headers
        if sender == "assistant":
            text = re.sub(r"^(#{1,5}) ", lambda m: "#" + m.group(0), text, flags=re.MULTILINE)

        if sender == "human":
            lines.append(f"### 🧑 User\n\n{text}\n")
        elif sender == "assistant":
            lines.append(f"### 🤖 Claude\n\n{text}\n")

    if links:
        lines.append("---\n\n### 🔗 Referenced Links\n")
        for url, link_title in links.items():
            lines.append(f"- [{link_title}]({url})")

    return "\n".join(lines)


# ── Listing ────────────────────────────────────────────────────────────────────

def list_conversations(chats: list[dict]) -> None:
    if not chats:
        print("No conversations found in export file.")
        return

    print(f"\n{'#':>4}  {'Date':<12}  {'Messages':>8}  Title")
    print("─" * 72)
    for i, chat in enumerate(chats):
        name = chat.get("name") or "(untitled)"
        date = format_date(chat.get("created_at", ""))
        msgs = [
            m for m in chat.get("chat_messages", [])
            if clean_text(get_text_block(m)[0])
        ]
        print(f"{i:>4}  {date:<12}  {len(msgs):>8}  {name}")
    print()


# ── Export ─────────────────────────────────────────────────────────────────────

def find_chat(chats: list[dict], selector: str) -> tuple[int, dict]:
    """Return (index, chat) by numeric index or case-insensitive name search."""
    if selector.isdigit():
        idx = int(selector)
        if idx >= len(chats):
            print(f"Error: index {idx} out of range (0–{len(chats) - 1}).")
            sys.exit(1)
        return idx, chats[idx]

    needle = selector.lower()
    matches = [
        (i, c) for i, c in enumerate(chats)
        if needle in (c.get("name") or "").lower()
    ]
    if not matches:
        print(f"No conversation found matching '{selector}'.")
        sys.exit(1)
    if len(matches) > 1:
        print(f"Multiple matches for '{selector}':")
        for i, c in matches:
            print(f"  [{i}] {c.get('name')}")
        print("Use the numeric index to be specific.")
        sys.exit(1)
    return matches[0]


def export_chat(chat: dict, output_path: Path) -> None:
    md = conversation_to_markdown(chat)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(md, encoding="utf-8")
    print(f"✓ Exported → {output_path}")


def safe_filename(name: str) -> str:
    name = re.sub(r"[^\w\s-]", "", name).strip()
    name = re.sub(r"\s+", "_", name)
    return name[:80] or "untitled"


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export Claude.ai conversations from a JSON export to Markdown.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("file", type=Path, help="Path to the Claude.ai JSON export file")
    parser.add_argument(
        "selector",
        nargs="?",
        help="Conversation index (0-based) or name search string",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        help="Output file path (default: ./<safe_title>.md)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Export all conversations (use -o to set output directory)",
    )
    args = parser.parse_args()

    if not args.file.exists():
        print(f"Error: file not found: {args.file}")
        sys.exit(1)

    chats = load_export(args.file)

    if not args.selector and not args.all:
        list_conversations(chats)
        return

    if args.all:
        out_dir = args.output or Path(".")
        out_dir.mkdir(parents=True, exist_ok=True)
        for i, chat in enumerate(chats):
            name = chat.get("name") or f"conversation_{i}"
            filename = f"{i:03d}_{safe_filename(name)}.md"
            export_chat(chat, out_dir / filename)
        print(f"\nExported {len(chats)} conversations to {out_dir}/")
        return

    idx, chat = find_chat(chats, args.selector)
    name = chat.get("name") or f"conversation_{idx}"
    out_path = args.output or Path(f"{safe_filename(name)}.md")
    export_chat(chat, out_path)


if __name__ == "__main__":
    main()
