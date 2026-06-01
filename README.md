# git-tools

A small collection of personal `git` subcommands.

Today it generates a git commit message — or a branch name — from your staged
changes using Apple's on-device foundation model. No network, no API keys:
everything runs locally through the Apple Intelligence model.

Two git subcommands read `git diff --staged` and print to stdout:

```
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

## Setup

See [docs/SETUP.md](docs/SETUP.md) for full build and runtime setup. In short:

- **Runtime:** macOS 26 (Tahoe)+ on Apple silicon with Apple Intelligence enabled.
  No Xcode required to run.
- **Build:** full Xcode is required (the `@Generable` macro plugin ships only with
  Xcode, not the Command Line Tools), then `swift build -c release` and symlink
  both binaries onto your `PATH` as `git-commit-message` and `git-branch-name`.

git discovers any `git-<name>` executable on `PATH` as a subcommand, so the tools
are invoked as `git commit-message` and `git branch-name`.

## Usage

```sh
git add <files>

git commit-message                     # print a commit message to stdout
git commit-message | git commit -F -   # commit with it directly

git branch-name                        # print a type/kebab-summary branch name
git switch -c "$(git branch-name)"     # create the branch with it

git commit-message --dry-run           # show the execution plan, then exit
git commit-message --help
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

## Behavior on errors

- **No staged changes** — exits non-zero and asks you to `git add` first; it never
  stages files for you.
- **Apple Intelligence unavailable** — exits non-zero with the reason (not enabled,
  still downloading, or unsupported device). Errors go to stderr, so stdout stays
  clean for piping.
