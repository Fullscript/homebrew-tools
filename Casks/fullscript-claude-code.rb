# frozen_string_literal: true
require 'json'
require 'open3'

class FullscriptClaudeCode
  REGION = "us-east-1"
  ENV_CONFIG_FILE = "#{HOMEBREW_PREFIX}/etc/fullscript-claude-code/env.sh"
  USER_SETTINGS_FILE = File.expand_path("~/.claude/settings.json")
  RX_BIN = "/opt/fullscript/bin/rx"
  AWS_BIN = "#{HOMEBREW_PREFIX}/bin/aws"
  MIN_AWS_VERSION = "2.27.63"
  MODELS = {
    opus: {
      suffix: "opus-4-7",
      inference_profile: "global.anthropic.claude-opus-4-7",
      name: "Opus 4.7",
    },
    sonnet: {
      suffix: "sonnet-4-6",
      inference_profile: "global.anthropic.claude-sonnet-4-6",
      name: "Sonnet 4.6",
    },
    haiku: {
      suffix: "haiku-4-5",
      inference_profile: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      name: "Haiku 4.5",
    },
  }.freeze

  def initialize(ohai)
    @ohai = ohai
  end

  def ohai(message)
    @ohai.call(message)
  end

  def install
    check_rx_installed
    check_aws_version
    ensure_aws_authenticated
    cleanup_stale_inference_profiles
    create_all_inference_profiles
    install_user_settings
    remove_legacy_env_config
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

  def check_aws_version
    stdout, _, status = Open3.capture3(AWS_BIN, "--version")
    raise "Failed to get AWS CLI version" unless status.success?

    version = stdout[/aws-cli\/(\d+\.\d+\.\d+)/, 1]
    raise "Could not parse AWS CLI version from: #{stdout}" unless version

    return if Gem::Version.new(version) >= Gem::Version.new(MIN_AWS_VERSION)

    raise "AWS CLI #{MIN_AWS_VERSION}+ required, found #{version}. Run: brew upgrade awscli"
  end

  def gitlab_email
    @gitlab_email ||= begin
      stdout, stderr, status = Open3.capture3(RX_BIN, "config", "auth", "--json", "--type", "gitlab")
      raise "Failed to get GitLab config from rx: #{stderr}" unless status.success?

      data = JSON.parse(stdout)
      email = data.dig("gitlab", "email")
      raise "Could not determine GitLab email from rx config" unless email

      email
    end
  end

  def username
    @username ||= gitlab_email.split("@").first
  end

  def username_slug
    @username_slug ||= username.tr(".", "-")
  end

  def aws_authenticated?
    _, _, status = Open3.capture3(AWS_BIN, "sts", "get-caller-identity", "--query", "Account", "--output", "text")
    status.success?
  end

  def ensure_aws_authenticated
    return if aws_authenticated?

    ohai "AWS SSO authentication required"
    _, stderr, status = Open3.capture3(RX_BIN, "sso", "login")
    raise "Failed to authenticate with AWS SSO: #{stderr}" unless status.success?
  end

  def aws_account_id
    @aws_account_id ||= begin
      stdout, stderr, status = Open3.capture3(AWS_BIN, "sts", "get-caller-identity", "--query", "Account", "--output", "text")
      raise "Failed to get AWS account ID: #{stderr}" unless status.success?

      stdout.strip
    end
  end

  def inference_profile_exists?(profile_name)
    stdout, _, status = Open3.capture3(
      AWS_BIN, "bedrock", "list-inference-profiles",
      "--region", REGION,
      "--type", "APPLICATION",
      "--query", "inferenceProfileSummaries[?inferenceProfileName==`#{profile_name}`].inferenceProfileArn",
      "--output", "text"
    )
    status.success? && !stdout.strip.empty?
  end

  def create_inference_profile(suffix, model_id)
    profile_name = "#{username_slug}-#{suffix}-claude-code"

    if inference_profile_exists?(profile_name)
      ohai "Inference profile already exists: #{profile_name}"
      return
    end

    ohai "Creating inference profile: #{profile_name}"
    source_arn = "arn:aws:bedrock:#{REGION}:#{aws_account_id}:inference-profile/#{model_id}"

    _, stderr, status = Open3.capture3(
      AWS_BIN, "bedrock", "create-inference-profile",
      "--inference-profile-name", profile_name,
      "--model-source", "copyFrom=#{source_arn}",
      "--tags",
      "key=fullscript:environment,value=development",
      "key=fullscript:team,value=engineering",
      "key=fullscript:service,value=Bedrock",
      "key=fullscript:user,value=#{username}",
      "key=fullscript:tool,value=claude-code",
      "--region", REGION
    )
    raise "Failed to create inference profile #{profile_name}: #{stderr}" unless status.success?
  end

  def create_all_inference_profiles
    MODELS.each_value { |model| create_inference_profile(model[:suffix], model[:inference_profile]) }
  end

  def cleanup_stale_inference_profiles
    stdout, stderr, status = Open3.capture3(
      AWS_BIN, "bedrock", "list-inference-profiles",
      "--region", REGION,
      "--type", "APPLICATION",
      "--query", "inferenceProfileSummaries[?starts_with(inferenceProfileName, '#{username_slug}-')].[inferenceProfileName,inferenceProfileArn]",
      "--output", "text"
    )
    raise "Failed to list inference profiles: #{stderr}" unless status.success?

    expected_names = MODELS.values.map { |model| "#{username_slug}-#{model[:suffix]}-claude-code" }

    stdout.lines.each do |line|
      name, arn = line.strip.split("\t")
      next if expected_names.include?(name)

      ohai "Deleting stale inference profile: #{name}"
      _, del_stderr, del_status = Open3.capture3(
        AWS_BIN, "bedrock", "delete-inference-profile",
        "--inference-profile-identifier", arn,
        "--region", REGION
      )
      raise "Failed to delete inference profile #{name}: #{del_stderr}" unless del_status.success?
    end
  end

  def get_inference_profile_arns
    stdout, stderr, status = Open3.capture3(
      AWS_BIN, "bedrock", "list-inference-profiles",
      "--region", REGION,
      "--type", "APPLICATION",
      "--query", "inferenceProfileSummaries[?contains(inferenceProfileName, '#{username_slug}') && contains(inferenceProfileName, '-claude-code')].[inferenceProfileName,inferenceProfileArn]",
      "--output", "text"
    )
    raise "Failed to list inference profiles: #{stderr}" unless status.success?

    arns = stdout.lines.each_with_object({}) do |line, result|
      name, arn = line.strip.split("\t")
      MODELS.each do |key, model|
        result[key] = arn if name&.include?(model[:suffix])
      end
    end

    missing = MODELS.keys - arns.keys
    raise "Missing inference profiles: #{missing.join(', ')}" if missing.any?

    arns
  end

  def install_user_settings
    FileUtils.mkdir_p(File.dirname(USER_SETTINGS_FILE))

    existing_content = read_settings_file
    settings = begin
      JSON.parse(existing_content)
    rescue JSON::ParserError => e
      raise "Cannot update #{USER_SETTINGS_FILE}: file contains invalid JSON (#{e.message}). Please fix or remove it and try again."
    end

    apply_default_settings(settings, get_inference_profile_arns)
    new_content = JSON.pretty_generate(settings)

    if existing_content == new_content
      ohai "#{USER_SETTINGS_FILE} already up to date"
      return
    end

    File.write(USER_SETTINGS_FILE, new_content)
    ohai "Updated #{USER_SETTINGS_FILE}"
  end

  def remove_legacy_env_config
    return unless File.exist?(ENV_CONFIG_FILE)

    FileUtils.rm(ENV_CONFIG_FILE)
    ohai "Removed legacy env config: #{ENV_CONFIG_FILE}"
  end

  def read_settings_file
    File.read(USER_SETTINGS_FILE)
  rescue Errno::ENOENT
    "{}"
  end

  def apply_default_settings(settings, arns)
    settings["autoUpdatesChannel"] ||= "stable"
    settings["awsAuthRefresh"] = "#{RX_BIN} sso login"

    settings["env"] ||= {}
    settings["env"].merge!(default_env(arns))

    settings["permissions"] ||= {}
    settings["permissions"]["allow"] ||= []
    settings["permissions"]["allow"] |= default_permissions
  end

  def default_env(arns)
    env = MODELS.each_with_object({}) do |(key, model), result|
      prefix = "ANTHROPIC_DEFAULT_#{key.upcase}_MODEL"
      result[prefix] = arns[key]
      result["#{prefix}_NAME"] = model[:name]
      result["#{prefix}_DESCRIPTION"] = "(bedrock #{arns[key].split('/').last})"
    end
    env["CLAUDE_CODE_USE_BEDROCK"] = "1"
    env["AWS_REGION"] = REGION
    env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "16384"
    env["MAX_THINKING_TOKENS"] = "10000"
    env
  end

  def default_permissions
    [
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
    ]
  end
end

cask "fullscript-claude-code" do
  version "1.4.0"
  sha256 :no_check

  url "file:///dev/null"

  name "Fullscript Claude Code Setup"
  desc "Claude Code with Fullscript AWS Bedrock configuration"
  homepage "https://www.anthropic.com/claude-code"

  depends_on formula: "awscli"

  postflight do
    FullscriptClaudeCode.new(method(:ohai)).install
  end

  caveats <<~EOS
    Fullscript Claude Code has been configured with AWS Bedrock!

    To get started, run:
      claude

    Configuration file created:
    - #{FullscriptClaudeCode::USER_SETTINGS_FILE} (user settings)

    If you need to re-authenticate with AWS, run:
      #{FullscriptClaudeCode::RX_BIN} sso login
  EOS

  uninstall_postflight do
    FileUtils.rm(FullscriptClaudeCode::ENV_CONFIG_FILE) if File.exist?(FullscriptClaudeCode::ENV_CONFIG_FILE)
  end
end
