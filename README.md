# git-commit-message

Generate a git commit message from your staged changes using Apple's on-device
foundation model. No network, no API keys — everything runs locally through the
Apple Intelligence model.

It reads `git diff --staged` and prints a single
[Conventional Commits](https://www.conventionalcommits.org/) message to stdout.

```
$ git add .
$ git commit-message
feat(diff): truncate large patches to fit the on-device context window
```

## Setup

See [docs/SETUP.md](docs/SETUP.md) for full build and runtime setup. In short:

- **Runtime:** macOS 26 (Tahoe)+ on Apple silicon with Apple Intelligence enabled.
  No Xcode required to run.
- **Build:** full Xcode is required (the `@Generable` macro plugin ships only with
  Xcode, not the Command Line Tools), then `swift build -c release` and symlink
  the binary onto your `PATH` as `git-commit-message`.

git discovers any `git-<name>` executable on `PATH` as a subcommand, so the tool
is invoked as `git commit-message`.

## Usage

```sh
git add <files>
git commit-message                 # print a message to stdout
git commit-message | git commit -F -   # commit with it directly
git commit-message --dry-run       # show the prompt sent to the model, then exit
git commit-message --help
```

`--dry-run` works even before Apple Intelligence is enabled, which is handy for
inspecting what the model receives.

## How it works

- The staged diff is sent to the model as a `--stat` header plus the patch body.
  Large diffs are trimmed to fit the model's ~4k-token context window: structural
  lines (file and hunk headers) are always kept, and changed lines fill the
  remaining budget. If a diff still overflows, the tool retries with the file
  list only.
- The model returns a structured `CommitMessage` (`type` / `scope` / `subject` /
  `body`) via guided generation, which is rendered to Conventional Commits text.
- Output is always English. Generation uses a low temperature for stable results;
  re-run to get a fresh take.

## Behavior on errors

- **No staged changes** — exits non-zero and asks you to `git add` first; it never
  stages files for you.
- **Apple Intelligence unavailable** — exits non-zero with the reason (not enabled,
  still downloading, or unsupported device). Errors go to stderr, so stdout stays
  clean for piping.
