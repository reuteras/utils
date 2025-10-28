# Obsidian Tools

## Overview
The **Obsidian Tools** suite provides automation for keeping Obsidian vault tags aligned with Readwise and enriching your notes with automatically generated tags. It contains two CLI utilities:

- **`readwise-tag-sync`**: Fetches tags from the Readwise API, compares them against tags found in your Obsidian vault, and proposes safe updates based on fuzzy similarity.
- **`obsidian-auto-tagger`**: Scans markdown notes for configurable regex matches and adds tags to the YAML frontmatter without modifying files unless explicitly approved.

Both scripts are designed with a dry-run first approach so you can preview every change before applying it.

## Quickstart
```bash
cd obsidian
uv run readwise-tag-sync --dry-run
```

The first invocation of `uv run` will automatically create an isolated
environment based on `pyproject.toml` and install the declared
dependencies. Subsequent runs reuse that environment, so there is no
need to manage a virtual environment manually.

## Configuration
Copy `config.yaml-default` to `config.yaml` (or point the tools at your own
file with `--config`) and adjust the values to suit your environment. The
default template is:

```yaml
obsidian_vault_path: "~/vault"
readwise_token_env: "READWISE_TOKEN"
similarity_threshold: 80

auto_tags:
  - pattern: "CVE-(\\d{4}-\\d+)"
    tag_format: "CVE/{match}"
```

Set the Readwise API token in your shell (or preferred secret manager):

```bash
export READWISE_TOKEN="<your-readwise-token>"
```

If you see `401 Unauthorized` errors when running `readwise-tag-sync`,
double-check that the `READWISE_TOKEN` variable (or the custom name defined in
your config file) is exported in the shell where you invoke `uv run`.

## CLI Usage
Preview changes (default behavior):

```bash
uv run readwise-tag-sync --dry-run
uv run obsidian-auto-tagger --dry-run
```

Apply the proposed changes after reviewing the previews:

```bash
uv run readwise-tag-sync --apply
uv run obsidian-auto-tagger --apply
```

Both commands support an optional `--config` flag if your configuration file lives elsewhere.

## Safety Guarantees
- Dry-run is the default mode for every tool.
- Files are only modified when `--apply` is explicitly provided.
- YAML frontmatter is parsed and written using `ruamel.yaml` to preserve ordering, comments, and formatting.
- Detailed logs and preview CSVs are generated so you can audit changes before writing anything to disk.

## Next Steps
After installation, try running `readwise-tag-sync --dry-run` to generate `tag_proposal.csv` and inspect the suggested mappings. Once you're confident, re-run with `--apply` to commit the changes.
