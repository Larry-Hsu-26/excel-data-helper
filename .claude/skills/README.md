# Vendored skills

## superpowers

Source: https://github.com/obra/superpowers
Version: 6.4.1
Commit: 5bf4e78011075bcfc0dc295f0724994cd123ee71
License: MIT (Copyright (c) 2025 Jesse Vincent) — see `LICENSE-superpowers.txt`

### Why vendored instead of installed as a plugin

Development happens in ephemeral Claude Code remote containers. A plugin
installed with `/plugin install` lives in `~/.claude/plugins/` and is destroyed
when the container is reclaimed, so every new session would start without the
workflow. Committing the skills here makes them load automatically for every
session and for every contributor, and pins the exact version in git.

### Local modifications

Cross-skill references were rewritten from the plugin-scoped form
(`superpowers:writing-plans`) to the project-skill form (`writing-plans`),
because project skills under `.claude/skills/` are addressed without a plugin
prefix. No other changes.

The upstream plugin also ships hooks and an `index.js` that auto-inject skill
reminders; those are NOT vendored. Skills here are invoked explicitly.

### Updating

    git clone --depth 1 https://github.com/obra/superpowers /tmp/superpowers
    rm -rf .claude/skills/*/  # keep README.md and LICENSE-superpowers.txt
    cp -R /tmp/superpowers/skills/. .claude/skills/
    grep -rl 'superpowers:' .claude/skills | xargs sed -i 's/superpowers://g'

Then update the version and commit hash above.
