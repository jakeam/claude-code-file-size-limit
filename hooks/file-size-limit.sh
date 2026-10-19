#!/usr/bin/env bash
# Rejects files over MAX_TOKENS (tokens ~= bytes / 4) so files stay small
# enough for an agent to read and edit in one go. Run by this plugin's hooks
# (hooks/hooks.json), which pass the tool call's JSON on stdin:
#   after-edit     after each Edit/Write: checks the edited file
#   before-commit  before each Bash command: if it contains "git commit",
#                  checks every changed and untracked file
# Exit 2 sends the message to the model (and blocks the commit); any other
# failure is shown to the user without blocking.
# shortcut: only Edit/Write are checked on save; files written through Bash are
# only caught at commit, other tools and hand edits never, and "git commit" is a
# text match, so `git -C dir commit` slips by.
# shortcut: the JSON is read with grep/sed so nothing needs installing; a file
# path containing " or \ is skipped on save, use jq if that ever matters.
set -euo pipefail

MAX_TOKENS=5000
# Files no agent writes by hand: lockfiles, recorded data, generated output.
IGNORE='(^|/)(Cargo\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$|(^|/)(go\.sum|Package\.resolved)$|\.(lock|min\.js|min\.css|map|snap|svg|ipynb)$|(^|/)(generated|gen|dist|target|node_modules|__snapshots__)/'

cd "${CLAUDE_PROJECT_DIR:-.}"
# Extra regexes, one per line (# for comments): ~/.claude/file-size-ignore for
# every repo, .claude/file-size-ignore for this one.
for list in ~/.claude/file-size-ignore .claude/file-size-ignore; do
  [[ -f $list ]] || continue
  while IFS= read -r re; do [[ -n $re && $re != \#* ]] && IGNORE+="|$re"; done < "$list"
done
files=()
case ${1-} in
  after-edit)
    f=$(sed -n 's/.*"file_path" *: *"\([^"]*\)".*/\1/p')
    [[ $f == "$PWD"/* ]] || exit 0  # outside the project
    files=("${f#"$PWD"/}")
    ;;
  before-commit)
    grep -q 'git commit' || exit 0
    # Runs before the commit command, so in `git add -A && git commit` nothing
    # is staged yet: check every changed and untracked file, not just staged.
    # No commits yet: compare against the empty tree.
    base=$(git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null)
    while IFS= read -r -d '' f; do files+=("$f"); done < <(
      git diff "$base" --relative --name-only -z --diff-filter=ACMR
      git ls-files -z --others --exclude-standard)
    ;;
  *) echo "usage: $0 after-edit|before-commit  (hook JSON on stdin)" >&2; exit 1 ;;
esac
(( ${#files[@]} )) || exit 0

over=() was_over=()
for f in "${files[@]}"; do
  [[ -f $f && ! $f =~ $IGNORE ]] || continue
  git check-ignore -q -- "$f" && continue  # never committed
  grep -Iq . "$f" || continue  # binary or empty
  tokens=$(( $(wc -c < "$f") / 4 ))
  (( tokens > MAX_TOKENS )) || continue
  # After an edit, a file that was already over at the last commit is not this
  # edit's fault: report it rather than derail a small task into a split.
  committed=$(git cat-file -s "HEAD:./$f" 2>/dev/null || echo 0)
  if [[ $1 == after-edit ]] && (( committed / 4 > MAX_TOKENS )); then
    was_over+=("  $f: ~$tokens tokens")
  else
    over+=("  $f: ~$tokens tokens")
  fi
done

if (( ${#over[@]} == 0 )); then
  (( ${#was_over[@]} == 0 )) && exit 0
  cat >&2 <<EOF
These files were already over $MAX_TOKENS tokens before this edit:
$(printf '%s\n' "${was_over[@]}")

Don't split them as part of this task unless the task is about them. Tell
the user they are over the limit; committing changes to them will be blocked
until they are split.
EOF
  exit 2
fi

cat >&2 <<EOF
These files are over $MAX_TOKENS tokens ($(( MAX_TOKENS * 4 )) bytes):
$(printf '%s\n' "${over[@]}")

Split each one now, before any other work. Do not trim comments or squash
code to fit. If a listed file is generated or data, don't split it or edit
this check: tell the user, so a regex for it can be added as a line in
.claude/file-size-ignore (this repo) or ~/.claude/file-size-ignore (all repos).

1. Find the seams: group the file's items (types, impls, systems, functions,
   sections) by what they are about. Each group becomes one new file, named
   for that one thing, ideally under half the limit so it has room to grow.
2. Move code, don't rewrite it. Keep names, signatures, doc comments and
   behaviour identical; the split should be a pure move.
3. Keep the original file as the entry point: its public interface and the
   wiring that ties the pieces together stay; the groups move into sibling
   files or a directory named after it, pulled in with the language's own
   module mechanism (Rust mod, JS/TS import/export, Python package, shader
   or C includes). Widen visibility only as far as the siblings need.
4. Copy this repo's conventions: if a file has already been split this
   way, follow its layout, naming and visibility.
5. Docs: keep the overview and links in the original file; move each long
   section into its own file and link to it.
6. Run the project's build, tests and linters. If you were committing,
   stage every new and changed file (git add) and commit again.
EOF
exit 2
