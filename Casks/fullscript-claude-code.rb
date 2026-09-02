# frozen_string_literal: true

require "json"

class FullscriptClaudeCode
  USER_SETTINGS_FILE = File.expand_path("~/.claude/settings.json").freeze
  RX_BIN = "/opt/fullscript/bin/rx"

  # Sentinel marking a key to be removed during the deep merge.
  REMOVE = Object.new.freeze

  # Model tiers that have default NAME / MODEL / DESCRIPTION env vars.
  MODEL_TIERS = %w[FABLE OPUS SONNET HAIKU].freeze

  # Prefix of model ids that are compatible with our gateway. A user value
  # starting with this is respected; anything else (unset, or an old
  # inference-profile style id) is replaced with our default.
  GATEWAY_MODEL_PREFIX = "global.anthropic"

  DEFAULT_SETTINGS = {
    "awsAuthRefresh"     => REMOVE,
    "apiKeyHelper"       => "#{RX_BIN} gateway login",
    "env"                => {
      "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"         => "Fable 5.1",
      "ANTHROPIC_DEFAULT_FABLE_MODEL"              => "global.anthropic.claude-fable-5-1",
      "ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION"  => "(Cloudflare gateway)",
      "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"          => "Opus 5",
      "ANTHROPIC_DEFAULT_OPUS_MODEL"               => "global.anthropic.claude-opus-5",
      "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION"   => "(Cloudflare gateway)",
      "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"        => "Sonnet 5",
      "ANTHROPIC_DEFAULT_SONNET_MODEL"             => "global.anthropic.claude-sonnet-5",
      "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION" => "(Cloudflare gateway)",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"         => "Haiku 4.5",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL"              => "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION"  => "(Cloudflare gateway)",
      "AWS_REGION"                                 => REMOVE,
      "CLAUDE_CODE_USE_BEDROCK"                    => "1",
      "CLAUDE_CODE_SKIP_BEDROCK_AUTH"              => "1",
      "ANTHROPIC_BEDROCK_BASE_URL"                 => "https://dev-ai-gateway.fullscript.cloud/p/bedrock/aws-bedrock/bedrock-runtime/us-east-1",
      "CLAUDE_CODE_MAX_OUTPUT_TOKENS"              => "16384",
      "MAX_THINKING_TOKENS"                        => "10000",
    }.freeze,
    "permissions"        => {
      "allow" => [
        "Bash(git status:*)",
        "Bash(git diff:*)",
        "Bash(git log:*)",
        "Bash(git show:*)",
        "Bash(git branch:*)",
        "Bash(git remote -v:*)",
        "Bash(git remote show:*)",
        "Bash(git remote get-url:*)",
        "Bash(git fetch:*)",
        "Bash(git ls-files:*)",
        "Bash(git rev-parse:*)",
        "Bash(git describe:*)",
        "Bash(git config --get:*)",
        "Bash(git config --list:*)",
        "Bash(cd:*)",
        "Bash(ls:*)",
        "Bash(pwd)",
        "Bash(which:*)",
        "Bash(echo:*)",
        "Bash(cat:*)",
        "Bash(head:*)",
        "Bash(tail:*)",
        "Bash(wc:*)",
        "Bash(grep:*)",
        "Bash(rg:*)",
        "Bash(find:*)",
        "Bash(tree:*)",
        "Bash(command:*)",
        "Bash(file:*)",
        "Bash(stat:*)",
      ].freeze,
    }.freeze,
  }.freeze

  def initialize(ohai)
    @ohai = ohai
  end

  def ohai(message)
    @ohai.call(message)
  end

  def install
    check_rx_installed
    install_user_settings
  end

  private

  def check_rx_installed
    return if File.executable?(RX_BIN)

    raise <<~ERROR
      rx CLI not found at #{RX_BIN}

      Please install rx first by following the instructions at:
      https://engineering-docs.fullscript.cloud/Onboarding/setting_up_your_development_environment/#installing-rx
    ERROR
  end

  def install_user_settings
    FileUtils.mkdir_p(File.dirname(USER_SETTINGS_FILE))

    existing_settings = read_settings_file
    new_settings = deep_merge(existing_settings, effective_defaults(existing_settings))

    if new_settings == existing_settings
      ohai "#{USER_SETTINGS_FILE} already up to date"
      return
    end

    File.write(USER_SETTINGS_FILE, JSON.pretty_generate(new_settings))
    ohai "Updated #{USER_SETTINGS_FILE}"
  end

  # Returns a copy of DEFAULT_SETTINGS with the NAME / MODEL / DESCRIPTION env
  # vars dropped for any tier whose existing model is already gateway
  # compatible, so we respect the user's choice. For tiers that are unset or
  # use an old inference-profile style id, our defaults are kept (setting a
  # default or converting the old value), which also updates the name and
  # description to match.
  def effective_defaults(existing_settings)
    existing_env = existing_settings["env"]
    existing_env = {} unless existing_env.is_a?(Hash)

    env_defaults = DEFAULT_SETTINGS["env"].dup

    MODEL_TIERS.each do |tier|
      current_model = existing_env["ANTHROPIC_DEFAULT_#{tier}_MODEL"]
      next unless current_model.is_a?(String) && current_model.start_with?(GATEWAY_MODEL_PREFIX)

      env_defaults.reject! { |key, _| key.start_with?("ANTHROPIC_DEFAULT_#{tier}_MODEL") }
    end

    DEFAULT_SETTINGS.merge("env" => env_defaults)
  end

  def read_settings_file
    JSON.parse(File.read(USER_SETTINGS_FILE))
  rescue Errno::ENOENT
    {}
  rescue JSON::ParserError => e
    raise "Cannot update #{USER_SETTINGS_FILE}: file contains invalid JSON (#{e.message}). Please fix or remove it and try again."
  end

  # Deep merges +defaults+ into +base+, returning a new hash. Nested hashes
  # are merged recursively, arrays are unioned, and any value equal to the
  # REMOVE sentinel deletes the corresponding key.
  def deep_merge(base, defaults)
    result = base.dup

    defaults.each do |key, default_value|
      if default_value.equal?(REMOVE)
        result.delete(key)
        next
      end

      base_value = result[key]
      result[key] = if default_value.is_a?(Hash)
        deep_merge(base_value.is_a?(Hash) ? base_value : {}, default_value)
      elsif base_value.is_a?(Array) && default_value.is_a?(Array)
        base_value | default_value
      else
        default_value
      end
    end

    result
  end
end

cask "fullscript-claude-code" do
  version "2.1.0"
  sha256 :no_check

  url "file:///dev/null"
  name "Fullscript Claude Code Setup"
  desc "Claude Code with Cloudflare gateway configuration"
  homepage "https://www.anthropic.com/claude-code"

  preflight do
    FullscriptClaudeCode.new(method(:ohai)).install
  end

  caveats <<~EOS
    Fullscript Claude Code has been configured with the Cloudflare gateway!

    To get started, run:
      claude

    Configuration file created:
    - #{FullscriptClaudeCode::USER_SETTINGS_FILE} (user settings)
  EOS
end
