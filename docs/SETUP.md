# Setup

This tool has two distinct environments:

- **Build environment** — the machine that compiles the binary. Needs full Xcode.
- **Runtime environment** — the machine that runs `git commit-message`. Needs only
  macOS with Apple Intelligence enabled; no Xcode, no Command Line Tools.

They can be the same machine. The sections below are independent — set up only
what each machine needs.

---

## Build environment

The machine where you run `swift build`.

### Requirements

| Component | Version / detail | Why |
| --- | --- | --- |
| macOS | 26 (Tahoe) or later | `FoundationModels` SDK target is `macosx26.0` |
| Chip | Apple silicon | Apple Intelligence is Apple-silicon only |
| **Xcode** | Full Xcode (not just Command Line Tools) | The `@Generable` macro is expanded by the `FoundationModelsMacros` compiler plugin, which ships **only with full Xcode** |
| Swift | 6.0+ toolchain (bundled with Xcode) | Builds the package |

> **Why Command Line Tools are not enough.** The on-device model, sessions, and
> `respond(...)` all work under Command Line Tools. But the `@Generable` /
> `@Guide` macros require the `FoundationModelsMacros` plugin, which is absent
> from `/Library/Developer/CommandLineTools`. Without it the build fails with
> `external macro implementation type 'FoundationModelsMacros.GenerableMacro'
> could not be found`. The plugin is bundled inside `Xcode.app`.

### 1. Install Xcode

Install **Xcode** from the App Store, or download it from
<https://developer.apple.com/download/applications/>.

### 2. Point the toolchain at Xcode

Command Line Tools may be the active developer directory. Switch it to Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app
```

Verify:

```sh
xcode-select -p
# -> /Applications/Xcode.app/Contents/Developer

xcodebuild -version
# -> Xcode 26.x

swift --version
# -> Apple Swift version 6.x ... Target: arm64-apple-macosx26.0
```

If `xcode-select -p` still prints `/Library/Developer/CommandLineTools`, the
switch did not take effect — re-run step 2.

### 3. Build

```sh
swift build -c release
```

The products are three small native binaries at `.build/release/git-commit-message`,
`.build/release/git-branch-name`, and `.build/release/git-branch-clean`. The model
is not bundled — it is the system on-device model, linked dynamically. The macro
is fully expanded at compile time, so the binaries have no build-time dependency
baked in: they run on any compliant runtime machine without Xcode. `git-branch-clean`
links no model at all and runs anywhere git does.

### 4. Install on PATH

git discovers any `git-<name>` executable on `PATH` as a subcommand, so the
binaries are callable as `git commit-message`, `git branch-name`, and
`git branch-clean`.

```sh
mkdir -p ~/.local/bin
ln -sf "$(pwd)/.build/release/git-commit-message" ~/.local/bin/git-commit-message
ln -sf "$(pwd)/.build/release/git-branch-name" ~/.local/bin/git-branch-name
ln -sf "$(pwd)/.build/release/git-branch-clean" ~/.local/bin/git-branch-clean

# Ensure ~/.local/bin is on PATH (add to ~/.zshrc if missing)
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc ;; esac
```

Symlinks mean a later `swift build -c release` updates the installed commands in
place — no reinstall needed.

---

## Runtime environment

The machine where you run `git commit-message`. Needs **neither Xcode nor
Command Line Tools** — only the OS and an enabled model.

### Requirements

| Component | Version / detail |
| --- | --- |
| macOS | 26 (Tahoe) or later on Apple silicon |
| Apple Intelligence | Enabled, with the on-device model downloaded |
| git | Any recent version |
| The binary | Built per the build section, on `PATH` as `git-commit-message` |

### Enable Apple Intelligence

1. Open **System Settings** > **Apple Intelligence & Siri**.
2. Turn on **Apple Intelligence**. Sign in with your Apple Account if prompted.
3. Wait for the on-device model to finish downloading (several GB; progress is
   shown in the same pane).

### Verify

```sh
git add -A
git commit-message --dry-run   # prints the model prompt; works even before enabling AI
git commit-message             # prints a commit message once AI is enabled
```

`--dry-run` never calls the model, so use it to confirm the binary and git
plumbing work before Apple Intelligence finishes setting up.

### Troubleshooting

The tool checks model availability before generating and exits non-zero with a
reason on stderr:

| Message | Cause | Fix |
| --- | --- | --- |
| `Apple Intelligence is not enabled...` | `appleIntelligenceNotEnabled` | Enable it in System Settings (above) |
| `the on-device model is not ready yet...` | `modelNotReady` | The model is still downloading; wait and retry |
| `this device does not support Apple Intelligence` | `deviceNotEligible` | Unsupported hardware/region; cannot run here |
| `no staged changes...` | Nothing staged | `git add` your changes first |

Errors are written to stderr and stdout is left empty, so a failed run does not
pollute a `git commit-message | git commit -F -` pipeline.
