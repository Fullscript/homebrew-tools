# frozen_string_literal: true

cask "fullscript-claude-code" do
  version "3.0.0"
  sha256 :no_check

  url "file:///dev/null"
  name "Fullscript Claude Code Setup"
  desc "Retired: rx now manages Claude Code settings"
  homepage "https://www.anthropic.com/claude-code"

  disable! date: "2099-12-31", because: "is replaced by rx"

  stage_only true

  caveats <<~EOS
    rx now manages ~/.claude/settings.json and keeps it up to date.
    To apply the settings right away, run:
      rx claude sync-settings
  EOS
end
