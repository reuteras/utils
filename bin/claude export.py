#!/usr/bin/env python3
"""
claude_export.py — Export Claude.ai conversations to Markdown.

Usage:
    python3 claude_export.py conversations.json          # list all conversations
    python3 claude_export.py conversations.json 2        # export by index
    python3 claude_export.py conversations.json "Mounjaro"  # export by name search
    python3 claude_export.py conversations.json --all    # export all conversations
    python3 claude_export.py conversations.json 2 -o ~/notes/mounjaro.md  # custom path
    python3 claude_export.py conversations.json 2 --scripts ./scripts/   # save scripts to dir
    python3 claude_export.py conversations.json 2 --inline-scripts       # scripts inline in markdown
    python3 claude_export.py conversations.json 2 --scripts ./s/ --inline-scripts  # both
"""

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

_EXT_LANG: dict[str, str] = {
    ".py": "python", ".sh": "bash", ".bash": "bash", ".zsh": "bash",
    ".js": "javascript", ".ts": "typescript", ".jsx": "javascript", ".tsx": "typescript",
    ".go": "go", ".rs": "rust", ".rb": "ruby", ".java": "java",
    ".c": "c", ".cpp": "cpp", ".h": "c",
    ".md": "markdown", ".yaml": "yaml", ".yml": "yaml",
    ".json": "json", ".toml": "toml", ".ini": "ini",
    ".html": "html", ".css": "css", ".sql": "sql",
}


# ── Helpers ───────────────────────────────────────────────────────────────────


def ext_to_lang(path: str) -> str:
    return _EXT_LANG.get(Path(path).suffix.lower(), "")


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


# ── Script extraction ─────────────────────────────────────────────────────────

# Both heredoc orderings used by claude.ai's bash_tool:
#   cat << 'MARKER' > /path/file   and   cat > /path/file << 'MARKER'
_HEREDOC_A = re.compile(r"cat\s+<<\s+'([A-Z]+)'\s+>\s+(\S+)\n(.*?)\n\1", re.DOTALL)
_HEREDOC_B = re.compile(r"cat\s+>\s+(\S+)\s+<<\s+'([A-Z]+)'\n(.*?)\n\2", re.DOTALL)


def _scripts_from_bash(command: str) -> list[dict]:
    found = []
    for m in _HEREDOC_A.finditer(command):
        # groups: marker, path, content
        path, content = m.group(2), m.group(3)
        found.append({"filename": Path(path).name, "path": path, "content": content, "source": "bash_heredoc"})
    for m in _HEREDOC_B.finditer(command):
        # groups: path, marker, content
        path, content = m.group(1), m.group(3)
        found.append({"filename": Path(path).name, "path": path, "content": content, "source": "bash_heredoc"})
    return found


def extract_scripts(chat: dict) -> list[dict]:
    """Return list of {filename, path, content, source} from create_file and bash heredocs."""
    scripts: list[dict] = []
    seen: set[tuple[str, str]] = set()

    for msg in chat.get("chat_messages", []):
        for block in msg.get("content", []):
            if block.get("type") != "tool_use":
                continue
            name = block.get("name", "")
            inp = block.get("input", {})

            if name == "create_file":
                path = inp.get("path", "")
                content = inp.get("file_text", "")
                if path and content:
                    key = (path, content[:80])
                    if key not in seen:
                        seen.add(key)
                        scripts.append({"filename": Path(path).name, "path": path, "content": content, "source": "create_file"})

            elif name == "bash_tool":
                for entry in _scripts_from_bash(inp.get("command", "")):
                    key = (entry["path"], entry["content"][:80])
                    if key not in seen:
                        seen.add(key)
                        scripts.append(entry)

    return scripts


def format_inline_script(block: dict) -> str | None:
    """Render a create_file or bash heredoc tool_use block as a markdown fenced code block."""
    name = block.get("name", "")
    inp = block.get("input", {})

    if name == "create_file":
        path = inp.get("path", "")
        content = inp.get("file_text", "")
        if not (path and content):
            return None
        lang = ext_to_lang(path)
        return f"**`{Path(path).name}`**\n\n```{lang}\n{content}\n```"

    if name == "bash_tool":
        parts = []
        for entry in _scripts_from_bash(inp.get("command", "")):
            lang = ext_to_lang(entry["path"])
            parts.append(f"**`{entry['filename']}`**\n\n```{lang}\n{entry['content']}\n```")
        return "\n\n".join(parts) if parts else None

    return None


def save_scripts(scripts: list[dict], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    counts: dict[str, int] = {}
    for entry in scripts:
        stem = Path(entry["filename"]).stem
        suffix = Path(entry["filename"]).suffix
        count = counts.get(entry["filename"], 0)
        counts[entry["filename"]] = count + 1
        fname = entry["filename"] if count == 0 else f"{stem}_v{count + 1}{suffix}"
        dest = out_dir / fname
        dest.write_text(entry["content"], encoding="utf-8")
        print(f"  ✓ Script  → {dest}")


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


def conversation_to_markdown(chat: dict, inline_scripts: bool = False) -> str:
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

        script_parts: list[str] = []
        if inline_scripts and sender == "assistant":
            for block in msg.get("content", []):
                if block.get("type") == "tool_use":
                    rendered = format_inline_script(block)
                    if rendered:
                        script_parts.append(rendered)

        if not text and not script_parts:
            continue

        if sender == "assistant" and citations:
            text = apply_citations(text, citations)

        # Downshift headings inside message body by one level
        # (### → ####, ## → ###) so they sit below the H3 speaker headers
        if sender == "assistant" and text:
            text = re.sub(
                r"^(#{1,5}) ", lambda m: "#" + m.group(0), text, flags=re.MULTILINE
            )

        if sender == "human":
            lines.append(f"### 🧑 User\n\n{text}\n")
        elif sender == "assistant":
            body_parts = ([text] if text else []) + script_parts
            lines.append(f"### 🤖 Claude\n\n" + "\n\n".join(body_parts) + "\n")

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
            m for m in chat.get("chat_messages", []) if clean_text(get_text_block(m)[0])
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
        (i, c) for i, c in enumerate(chats) if needle in (c.get("name") or "").lower()
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


def export_chat(
    chat: dict,
    output_path: Path,
    inline_scripts: bool = False,
    scripts_dir: Path | None = None,
) -> None:
    md = conversation_to_markdown(chat, inline_scripts=inline_scripts)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(md, encoding="utf-8")
    print(f"✓ Exported → {output_path}")
    if scripts_dir is not None:
        scripts = extract_scripts(chat)
        if scripts:
            save_scripts(scripts, scripts_dir)
        else:
            print("  (no scripts found in this conversation)")


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
    parser.add_argument(
        "file", type=Path, help="Path to the Claude.ai JSON export file"
    )
    parser.add_argument(
        "selector",
        nargs="?",
        help="Conversation index (0-based) or name search string",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output file path (default: ./<safe_title>.md)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Export all conversations (use -o to set output directory)",
    )
    parser.add_argument(
        "--scripts",
        metavar="DIR",
        type=Path,
        help="Extract scripts (create_file / bash heredocs) and save them to DIR",
    )
    parser.add_argument(
        "--inline-scripts",
        action="store_true",
        help="Render scripts as fenced code blocks inline in the markdown export",
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
            slug = safe_filename(name)
            filename = f"{i:03d}_{slug}.md"
            scripts_dir = (args.scripts / slug) if args.scripts else None
            export_chat(
                chat,
                out_dir / filename,
                inline_scripts=args.inline_scripts,
                scripts_dir=scripts_dir,
            )
        print(f"\nExported {len(chats)} conversations to {out_dir}/")
        return

    idx, chat = find_chat(chats, args.selector)
    name = chat.get("name") or f"conversation_{idx}"
    out_path = args.output or Path(f"{safe_filename(name)}.md")
    export_chat(
        chat,
        out_path,
        inline_scripts=args.inline_scripts,
        scripts_dir=args.scripts,
    )


if __name__ == "__main__":
    main()
