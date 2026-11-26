# B3 in this product repository

`install-product` writes `.cursor/commands/*.md` and `.cursor/README.md` in this repo's `.cursor/` directory (`commands/` + `README.md` only; **skills, agents, and rules are not copied here** to avoid duplicate discovery). Use:

1. **Global Cursor install** (recommended, once per machine — links flattened `~/.cursor/skills/<name>`, commands, and agents):
   - PowerShell: `.\adapters\install-global.ps1 -HostName cursor`
   - Bash: `./adapters/install-global.sh --host cursor`
2. **`B3_HOME`**: read `.b3/home` or set env `B3_HOME` to your `b3_ai-engineering` clone so `/b3-ship`, `/b3-research-ship`, and standalone commands load canonical procedures from there.

Re-run attach after upgrading B3 (refreshes unmodified B3 command pointers idempotently; pass `-Force` / `--force` to overwrite local edits):

```powershell
.\adapters\install-product.ps1 -ProductRoot D:\path\to\this-repo -HostName cursor
```

```bash
./adapters/install-product.sh --product-root /path/to/this-repo --host cursor
```

Commit `.b3/home`, `.cursor/commands/`, and `.cursor/README.md`. Keep `.b3/ship/`, `.b3/research-ship/`, `.b3/pr-feedback/`, and `.b3/models.md` local (gitignored).
