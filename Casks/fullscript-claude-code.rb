# frozen_string_literal: true
require 'open3'

class FullscriptClaudeCode
  REGION = "us-east-1"
  SYSTEM_CLAUDE_DIR = "/Library/Application Support/ClaudeCode"
  ENV_CONFIG_FILE = "#{HOMEBREW_PREFIX}/etc/fullscript-claude-code/env.sh"
  SYSTEM_SETTINGS_FILE = "#{SYSTEM_CLAUDE_DIR}/managed-settings.json"
  RX_BIN = "/opt/fullscript/bin/rx"
  AWS_BIN = "#{HOMEBREW_PREFIX}/bin/aws"
  MIN_AWS_VERSION = "2.27.63"
  INFERENCE_PROFILES = {
    "opus-4-5" => "global.anthropic.claude-opus-4-5-20251101-v1:0",
    "sonnet-4-5" => "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
    "haiku-4-5" => "global.anthropic.claude-haiku-4-5-20251001-v1:0",
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
    create_all_inference_profiles
    install_claude_code_env_config
    install_system_settings
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
      stdout, stderr, status = Open3.capture3(RX_BIN, "config", "auth", "--type", "gitlab", "--show")
      raise "Failed to get GitLab config from rx: #{stderr}" unless status.success?

      email_line = stdout.lines.find { |l| l.include?("GitLab email:") }
      raise "Could not determine GitLab email from rx config" unless email_line

      email_line.split("GitLab email:").last.strip
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
    INFERENCE_PROFILES.each { |suffix, model_id| create_inference_profile(suffix, model_id) }
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
      INFERENCE_PROFILES.each_key do |suffix|
        result[suffix] = arn if name&.include?(suffix)
      end
    end

    missing = INFERENCE_PROFILES.keys - arns.keys
    raise "Missing inference profiles: #{missing.join(', ')}" if missing.any?

    arns
  end

  def install_claude_code_env_config
    FileUtils.mkdir_p(File.dirname(ENV_CONFIG_FILE))
    arns = get_inference_profile_arns

    File.write(ENV_CONFIG_FILE, claude_code_env_content(arns))
    ohai "Created #{ENV_CONFIG_FILE}"
  end

  def claude_code_env_content(arns)
    <<~SHELL
      # Claude Code with AWS Bedrock Configuration
      # Generated by fullscript-claude-code cask - do not edit manually

      # Enable Bedrock integration
      export CLAUDE_CODE_USE_BEDROCK=1
      export AWS_REGION=#{REGION}

      # Primary model (used by default)
      export ANTHROPIC_MODEL="#{arns["opus-4-5"]}"

      # Default model aliases (maps opus/sonnet/haiku commands to inference profiles)
      export ANTHROPIC_DEFAULT_OPUS_MODEL="#{arns["opus-4-5"]}"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="#{arns["sonnet-4-5"]}"
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="#{arns["haiku-4-5"]}"

      # Recommended output token settings for Bedrock
      export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384
      export MAX_THINKING_TOKENS=10000
    SHELL
  end

  def install_system_settings
    expected_content = JSON.pretty_generate(default_settings)

    if File.exist?(SYSTEM_SETTINGS_FILE) && File.read(SYSTEM_SETTINGS_FILE) == expected_content
      ohai "#{SYSTEM_SETTINGS_FILE} already up to date"
      return
    end

    sudo_prompt = "Password required to write #{SYSTEM_SETTINGS_FILE}: "

    unless Dir.exist?(SYSTEM_CLAUDE_DIR)
      _, stderr, status = Open3.capture3("sudo", "-p", sudo_prompt, "mkdir", "-p", SYSTEM_CLAUDE_DIR)
      raise "Failed to create #{SYSTEM_CLAUDE_DIR}: #{stderr}" unless status.success?
    end

    _, stderr, status = Open3.capture3("sudo", "-p", sudo_prompt, "tee", SYSTEM_SETTINGS_FILE, stdin_data: expected_content)
    raise "Failed to write #{SYSTEM_SETTINGS_FILE}: #{stderr}" unless status.success?

    ohai "Created #{SYSTEM_SETTINGS_FILE}"
  end

  def default_settings
    {
      "awsAuthRefresh" => "#{RX_BIN} sso login",
      "permissions" => {
        "allow" => default_permissions,
      },
    }
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
      "Bash(bun install:*)",
      "Bash(bun --version:*)",
      "Bash(npm install:*)",
      "Bash(npm run:*)",
      "Bash(npm test:*)",
      "Bash(npm list:*)",
      "Bash(npm outdated:*)",
      "Bash(npm --version:*)",
      "Bash(npx --version:*)",
      "Bash(pnpm install:*)",
      "Bash(pnpm run:*)",
      "Bash(pnpm test:*)",
      "Bash(pnpm list:*)",
      "Bash(pnpm outdated:*)",
      "Bash(pnpm --version:*)",
      "Bash(yarn)",
      "Bash(yarn install:*)",
      "Bash(yarn run:*)",
      "Bash(yarn test:*)",
      "Bash(node --version:*)",
      "Bash(node -e:*)",
      "Bash(tsc --version:*)",
      "Bash(tsc --noEmit:*)",
      "Bash(bundle install:*)",
      "Bash(uv sync:*)",
      "Bash(uv pip install:*)",
      "Bash(uv pip list:*)",
      "Bash(uv --version:*)",
      "Bash(poetry install:*)",
      "Bash(poetry show:*)",
      "Bash(poetry --version:*)",
      "Bash(gh pr view:*)",
      "Bash(gh pr list:*)",
      "Bash(gh pr diff:*)",
      "Bash(gh pr status:*)",
      "Bash(gh pr checks:*)",
      "Bash(gh issue view:*)",
      "Bash(gh issue list:*)",
      "Bash(gh issue status:*)",
      "Bash(gh repo view:*)",
      "Bash(gh repo list:*)",
      "Bash(gh run view:*)",
      "Bash(gh run list:*)",
      "Bash(gh workflow view:*)",
      "Bash(gh workflow list:*)",
      "Bash(gh api:*)",
      "Bash(glab mr view:*)",
      "Bash(glab mr list:*)",
      "Bash(glab mr diff:*)",
      "Bash(glab issue view:*)",
      "Bash(glab issue list:*)",
      "Bash(glab repo view:*)",
      "Bash(glab ci view:*)",
      "Bash(glab ci list:*)",
      "Bash(glab ci status:*)",
      "Bash(glab pipeline view:*)",
      "Bash(glab pipeline list:*)",
      "Bash(glab pipeline status:*)",
      "Bash(glab api:*)",
      "Bash(docker ps:*)",
      "Bash(docker images:*)",
      "Bash(docker logs:*)",
      "Bash(kubectl get:*)",
      "Bash(kubectl describe:*)",
      "Bash(kubectl logs:*)",
      "Bash(kubectl config view:*)",
      "Bash(kubectl config get-contexts:*)",
      "Bash(kubectl config current-context:*)",
      "Bash(kubectl config get-clusters:*)",
      "Bash(terraform --version:*)",
      "Bash(terraform fmt:*)",
      "Bash(terraform validate:*)",
      "Bash(terraform plan:*)",
      "Bash(terraform show:*)",
      "Bash(terraform state list:*)",
      "Bash(terraform state show:*)",
      "Bash(terraform output:*)",
      "Bash(terraform providers:*)",
      "Bash(terraform graph:*)",
      "Bash(mkdir:*)",
      "Bash(touch:*)",
      "Bash(cp:*)",
      "WebFetch(domain:docs.gitlab.com)",
      "WebFetch(domain:docs.github.com)",
      "WebFetch(domain:docs.anthropic.com)",
      "WebFetch(domain:developers.cloudflare.com)",
      "WebFetch(domain:guides.rubyonrails.org)",
      "WebFetch(domain:api.rubyonrails.org)",
      "WebFetch(domain:ruby-doc.org)",
      "WebFetch(domain:docs.ruby-lang.org)",
      "WebFetch(domain:docs.npmjs.com)",
      "WebFetch(domain:docs.aws.amazon.com)",
      "WebFetch(domain:kubernetes.io)",
      "WebFetch(domain:helm.sh)",
      "WebFetch(domain:developer.hashicorp.com)",
      "WebFetch(domain:go.dev)",
      "WebFetch(domain:pkg.go.dev)",
      "WebFetch(domain:bun.sh)",
      "WebFetch(domain:eslint.org)",
      "WebFetch(domain:typescriptlang.org)",
    ]
  end
end

cask "fullscript-claude-code" do
  version "1.0.0"
  sha256 :no_check

  url "file:///dev/null"

  name "Fullscript Claude Code Setup"
  desc "Claude Code with Fullscript AWS Bedrock configuration"
  homepage "https://www.anthropic.com/claude-code"

  depends_on cask: "claude-code"
  depends_on formula: "awscli"

  postflight do
    FullscriptClaudeCode.new(method(:ohai)).install
  end

  caveats <<~EOS
    Fullscript Claude Code has been configured with AWS Bedrock!

    To complete setup, add this to your shell profile (.zshrc or .bashrc):
      source "#{FullscriptClaudeCode::ENV_CONFIG_FILE}"

    Then restart your terminal or source the file, and run:
      claude

    Configuration files created:
    - #{FullscriptClaudeCode::ENV_CONFIG_FILE} (Bedrock environment variables)
    - #{FullscriptClaudeCode::SYSTEM_SETTINGS_FILE} (system-level settings)

    If you need to re-authenticate with AWS, run:
      #{FullscriptClaudeCode::RX_BIN} sso login
  EOS

  uninstall_postflight do
    FileUtils.rm(FullscriptClaudeCode::ENV_CONFIG_FILE) if File.exist?(FullscriptClaudeCode::ENV_CONFIG_FILE)

    if File.exist?(FullscriptClaudeCode::SYSTEM_SETTINGS_FILE)
      sudo_prompt = "Password required to remove #{FullscriptClaudeCode::SYSTEM_SETTINGS_FILE}: "
      Open3.capture3("sudo", "-p", sudo_prompt, "rm", FullscriptClaudeCode::SYSTEM_SETTINGS_FILE)
    end
  end
end
