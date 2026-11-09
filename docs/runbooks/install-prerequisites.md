# Install prerequisites

Install the tools b-agentic expects outside this repository, on Debian/Ubuntu
Linux. Commands were checked against each project's official docs on 2026-11-09;
re-check versions before pinning. The installer never runs vendor installers, so
this is a manual step. Which tool each MCP needs is listed in
[REFERENCE.md](../../REFERENCE.md).

## Prerequisites

- Debian/Ubuntu Linux with `sudo`, `curl`, and `zsh` or `bash`.
- Read each `curl | sh` script before running it.

## Steps

1. Install the base packages. `eza` is missing from Ubuntu 22.04 and Debian 12
   default repos, so add it only if `apt-cache policy eza` shows a candidate.

   ```bash
   sudo apt install -y python3 git ripgrep fd-find jq
   sudo apt install -y eza   # only where a candidate exists
   ```

2. Install `gh` from GitHub's official apt repo. The distro `gh` package is
   discouraged upstream, and Snap is too.

   ```bash
   (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
     && sudo mkdir -p -m 755 /etc/apt/keyrings \
     && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
     && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
     && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
     && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
     && sudo apt update \
     && sudo apt install gh -y
   ```

3. Install Node through nvm. The tag below was the latest on 2026-11-09; check
   the [nvm releases](https://github.com/nvm-sh/nvm/releases) for a newer one.
   Open a new shell afterwards.

   ```bash
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.41.0/install.sh | bash
   nvm install --lts
   ```

4. Install Bun, which provides `bunx`. Open a new shell afterwards.

   ```bash
   curl -fsSL https://bun.com/install | bash
   ```

5. Install Claude Code with Anthropic's native installer. The npm route
   (`npm install -g @anthropic-ai/claude-code`, no `sudo`, Node 22 or later)
   also works.

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

6. Install RTK (Rust Token Killer, `rtk-ai/rtk`).

   ```bash
   curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh
   export PATH="$HOME/.local/bin:$PATH"
   ```

   Do not run `cargo install rtk`: that crates.io name may resolve to an
   unrelated project. From source, use
   `cargo install --git https://github.com/rtk-ai/rtk --branch master rtk`.
   `brew install rtk-ai/tap/rtk` also works.

7. Install CodeGraph (`colbymchenry/codegraph`), then index each project you
   want graph answers for. Agents never run `codegraph init`; you do.

   ```bash
   npm i -g @colbymchenry/codegraph
   cd <project> && codegraph init
   ```

8. Set the API keys in your shell environment for the MCP servers you use:
   `CONTEXT7_API_KEY`, `BRAVE_API_KEY`, `FIRECRAWL_API_KEY`. The DataGrip and
   TablePro servers also need their apps running with MCP enabled (and
   `TABLEPRO_MCP_TOKEN` for TablePro).

## Verify

Each command should print a version, and `rtk gain` should print a savings
dashboard:

```bash
python3 --version && git --version && rg --version && fdfind --version \
  && jq --version && gh --version && node --version && bunx --version \
  && claude --version && rtk --version && rtk gain && codegraph --version
scripts/mcp-doctor.sh --allow-degraded
```

`mcp-doctor.sh` reports launcher and environment-variable presence only. It does
not start servers or read secret values.

## Troubleshooting

- **`nvm`, `bun`, or `rtk` not found:** open a new shell, or add its install
  directory to `PATH` (`~/.local/bin` for `rtk`).
- **`rtk --version` works but `rtk gain` fails:** the wrong `rtk` package is
  installed. Run `cargo uninstall rtk` and reinstall with the script above.
- **`fd` not found:** Debian installs the binary as `fdfind`. Optionally run
  `mkdir -p ~/.local/bin && ln -s "$(command -v fdfind)" ~/.local/bin/fd`.
- **Do not run `rtk init -g` or `codegraph install` alongside b-agentic's
  installer.** They edit `~/.claude/settings.json`, the MCP config, and
  `CLAUDE.md` or `AGENTS.md`, which the installer already merges.
- **RTK edition:** the default build is Apache-2.0 plus BUSL-1.1. An
  Apache-2.0-only build is available with `RTK_EDITION=oss` on the install
  script. Install one edition only.
- **Unverified:** `bunx --version`, `nvm install --lts`, and the plain apt
  package names are standard usage but were not confirmed against official docs.
