#!/bin/bash
#
# SessionStart hook: pin the git commit identity for this repository.
#
# Why this exists
# ---------------
# Claude Code's hosted (remote) environment defaults `git config user.email`
# to `noreply@anthropic.com`. GitHub resolves that address to the real account
# @claude, so every commit made from a session gets attributed to @claude and
# the account shows up in this repository's Contributors list.
#
# This hook forces the repository-local identity back to the repo owner on
# every session start, so no session can silently reintroduce the problem.
#
# Signing
# -------
# The hosted environment enables SSH commit signing with a key registered to
# Anthropic's identity. Keeping it on while the committer email is the repo
# owner's produces a RED "Unverified" badge on GitHub, which is worse than no
# badge at all, so signing is disabled here. The trade-off is deliberate:
# clean attribution over a verification badge. Commits signed locally on the
# owner's own machine are unaffected.
#
# Disabling signing also makes the harness' own stop-hook signature check
# (which is gated on `commit.gpgsign == true`) skip, so sessions stop being
# told to reset the author back to Claude.
#
set -euo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}"

git config user.name  "Larry Hsu"
git config user.email "hantsunghsu@gmail.com"
git config commit.gpgsign false

echo "[session-start] git identity: $(git config user.name) <$(git config user.email)>, signing off"
