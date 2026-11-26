# B3 in this product repository

`b3 install product` writes `.cursor/commands/*.md` and `.cursor/README.md` in this repo's `.cursor/` directory (`commands/` + `README.md` only; **skills, agents, and rules are not copied here** to avoid duplicate discovery). Use:

1. **Global Cursor install** (recommended, once per machine — links flattened `~/.cursor/skills/<name>`, commands, and agents):
   ```bash
   b3 install cursor
   # or unified dispatcher: b3 install global --action install --host cursor
   ```
   (Obtain `b3` once via `scripts/bootstrap-b3.ps1` / `scripts/bootstrap-b3.sh` or `cargo build --release`.)
2. **`B3_HOME`**: read `.b3/home` or set env `B3_HOME` to your `b3_ai-engineering` clone so `/b3-ship`, `/b3-research-ship`, and standalone commands load canonical procedures from there.

Re-run attach after upgrading B3 (refreshes unmodified B3 command pointers idempotently; pass `--force` to overwrite local edits):

```bash
b3 install product --product-root /path/to/this-repo --host cursor
```

Commit `.b3/home`, `.cursor/commands/`, and `.cursor/README.md`. Keep `.b3/ship/`, `.b3/research-ship/`, `.b3/pr-feedback/`, and `.b3/models.md` local (gitignored).
