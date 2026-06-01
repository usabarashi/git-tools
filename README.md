# git-tools

A small collection of personal `git` subcommands.

Two of the subcommands generate a git commit message — or a branch name — from
your staged changes using Apple's on-device foundation model. No network, no API
keys: everything runs locally through the Apple Intelligence model. They read
`git diff --staged` and print to stdout:

```sh
$ git add .
$ git commit-message
feat(diff): truncate large patches to fit the on-device context window

$ git branch-name
feat/truncate-large-patches
```

`git commit-message` prints a single
[Conventional Commits](https://www.conventionalcommits.org/) message;
`git branch-name` reshapes the same result into a `type/kebab-summary` branch
name.

A third subcommand, `git branch-clean`, is pure git plumbing (no model): it
deletes local branches already integrated into the default branch, including
**squash-merged** ones that `git branch --merged` misses.

```sh
$ git branch-clean
Branches already integrated into origin/main:

  feat/add-retry-logic  abc1234  patch already on origin/main (squash-merged)

Recover any branch with: git branch <name> <sha>

Delete these 1 local branch(es) with `git branch -D`? [y/N]
```

A fourth subcommand, `git secret-check`, is an **advisory** on-device AI pass
over the staged diff: it asks the model whether any added lines look like real
secrets (API keys, tokens, passwords, private keys, credentials) and reports
them with the value masked. It complements — does not replace — a deterministic
scanner like [gitleaks](https://github.com/gitleaks/gitleaks); a clean result
does not prove the diff is secret-free.

```sh
$ git add .
$ git secret-check
Possible secrets in staged changes (advisory):

  config/app.env — API key [high] sk-9…[redacted]
      assigned to a production-looking variable on an added line
```

## Setup

See [docs/SETUP.md](docs/SETUP.md) for full build and runtime setup. In short:

- **Runtime:** macOS 26 (Tahoe)+ on Apple silicon with Apple Intelligence enabled.
  No Xcode required to run.
- **Build:** full Xcode is required (the `@Generable` macro plugin ships only with
  Xcode, not the Command Line Tools), then `swift build -c release` and symlink
  the binaries onto your `PATH`. `git-branch-clean` uses no model and needs
  neither Xcode nor Apple Intelligence at runtime.

git discovers any `git-<name>` executable on `PATH` as a subcommand, so the tools
are invoked as `git commit-message`, `git branch-name`, `git branch-clean`, and
`git secret-check`.

## Usage

```sh
git add <files>

git commit-message                     # print a commit message to stdout
git commit-message | git commit -F -   # commit with it directly

git branch-name                        # print a type/kebab-summary branch name
git switch -c "$(git branch-name)"     # create the branch with it

git commit-message --dry-run           # show the execution plan, then exit
git commit-message --help

git branch-clean                       # delete merged/squash-merged local branches
git branch-clean --dry-run             # list candidates only, delete nothing
git branch-clean --yes --no-fetch      # skip the prompt and the fetch (scripts)

git secret-check                       # advisory AI scan of staged changes for secrets
git secret-check --dry-run             # list files that would be scanned, no model
git secret-check --fail-on medium      # exit non-zero on medium+ confidence findings
```

`--dry-run` works even before Apple Intelligence is enabled, which is handy for
inspecting how a diff is routed and parsed.

## How it works

- Small, focused diffs are summarized in a single model call.
- Larger diffs are handled with map-reduce so no model call ever exceeds the
  model's small context window: each file is summarized from its own untruncated
  diff (MAP), then the summaries are grouped by file category and synthesized
  into one message (REDUCE). This keeps the model from inventing changes for
  content it cannot see.
- For larger diffs the commit type, scope, and body grouping are decided
  deterministically in code (from file paths and categories) rather than by the
  model; small diffs are model-authored and then mechanically normalized.
- `git branch-name` runs the same pipeline and formats `type` + `subject` into a
  git-ref-safe `type/kebab-summary` slug.
- Output is always English. Generation uses a low temperature; re-run for a
  fresh take. Progress for large diffs is reported on stderr, leaving stdout
  clean for piping.
- `git branch-clean` judges each local branch against the remote default branch
  (`origin/HEAD`, refreshed by a `git fetch --prune` first). A branch is a
  candidate when it is an ancestor of the default branch (a normal merge), has no
  net diff from the merge-base, or — the squash case — its aggregate diff already
  exists upstream as an equivalent patch (a synthetic `commit-tree` compared with
  `git cherry`). This detects *content* equivalence, not provenance, so it always
  prompts, shows the reason and recoverable SHA, and protects the current,
  default, `main`/`master`/`develop`, and `release/*` branches.
- `git secret-check` scans the staged diff per file and never truncates: each
  file's added lines are sent to the model whole, and a file too large for the
  context window is split into overlapping windows so cross-line context (e.g. a
  user/password pair) survives. The diff is treated as untrusted data, obvious
  placeholders are ignored, and the secret value is masked locally — the model is
  never trusted to echo it. Exit is `0` when clean, `1` on findings at or above
  `--fail-on` (default `high`), and `2` when a file could not be fully scanned or
  the model is unavailable, so a clean result is never overstated.

## Behavior on errors

- **No staged changes** — exits non-zero and asks you to `git add` first; it never
  stages files for you.
- **Apple Intelligence unavailable** — exits non-zero with the reason (not enabled,
  still downloading, or unsupported device). Errors go to stderr, so stdout stays
  clean for piping.
