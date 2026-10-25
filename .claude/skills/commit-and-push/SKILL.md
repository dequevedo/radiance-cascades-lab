---
name: commit-and-push
description: How to commit changes to this repository and push them to GitHub (dequevedo/radiance-cascades-lab, public). Use whenever a change here is ready to be committed, or when Daniel asks to commit, push or publish the lab.
---

# Commit and push

The repository is **public** on GitHub: `https://github.com/dequevedo/radiance-cascades-lab`, branch `main` only.
Everything pushed is visible to anyone.

## Before the commit

1. **Check that it still runs.** Import check (no output = fine):
   `godot --headless --path . --editor --quit`
   Then run the harness flags the change touches (`--uitest` for the panel, `--buildtest` for the scene, `--mattest` for
   materials, `--bench` for performance; see `src/main.gd`). Never commit something that was not run.
2. **Look at what goes in:** `git status --short` and `git diff`. Nothing from `out/` (screenshots, logs), no local paths,
   no personal data, no secrets.
3. **README rules** (when the README or its images change):
   - it shows what the lab does **now**: never "before / after" images of a bug that was fixed (that goes in
     `docs/DEVLOG.md`);
   - short: a few lines per section, no repository layout, no long explanations;
   - every image in `docs/readme/` is used by the README; delete the ones that are not.
4. **Write the step in `docs/DEVLOG.md`** when the change is a real step (what broke, how it was measured, what changed).

## The commit

- Stage **explicit paths**, never `git add -A` or `git add .`:
  `git add src/foo.gd docs/DEVLOG.md`
- Message in **English**: a short first line saying what changed, then why, then the trailer.
- Author and committer are Daniel, with his GitHub no-reply address:

```sh
GIT_AUTHOR_NAME="Daniel Quevedo" GIT_AUTHOR_EMAIL="22284377+dequevedo@users.noreply.github.com" \
GIT_COMMITTER_NAME="Daniel Quevedo" GIT_COMMITTER_EMAIL="22284377+dequevedo@users.noreply.github.com" \
git commit -F - <<'EOF'
Short line: what changed

Why it changed, in a few lines.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
```

- One step ready and tested = one commit. No `--amend`, no rewriting history, no force push.

## The push

- **Only when Daniel asks** ("faz o push", "publica"). Committing does not mean pushing.
- `git push origin main`, then check it landed: `git log --oneline -1 origin/main`.
- Tell Daniel which commits went up (`git log --oneline <old>..<new>`).
