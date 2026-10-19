# File Size Limit Plugin

Claude Code plugin that keeps every file under 5,000 tokens (~20 KB), so an
agent can read and edit any file in one go.

- **After each Edit/Write**: if the file is now over the limit, Claude is told
  to split it before doing anything else (with step-by-step split instructions).
  Files that were already over at the last commit are reported, not forced.
- **Before `git commit`**: the commit is blocked while any changed or untracked
  file is over the limit.

Lockfiles, minified/generated output, snapshots and gitignored files are skipped.

Inspired by [this post from Matt Pocock](https://x.com/mattpocockuk/status/2111708560715292675).

## Install

```
/plugin marketplace add jakeam/claude-code-file-size-limit
/plugin install file-size-limit@file-size-limit
```

Or try it for one session: `git clone https://github.com/jakeam/claude-code-file-size-limit && claude --plugin-dir claude-code-file-size-limit`

## Your own ignores

Add regexes, one per line, matched against the repo-relative path (`#` lines
are comments), to either file:

- `.claude/file-size-ignore` in a repo: that repo only, and can be committed.
- `~/.claude/file-size-ignore`: every repo, just for you.

```
\.gpx$
^data/
```
