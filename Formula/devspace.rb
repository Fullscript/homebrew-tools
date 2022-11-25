class Devspace < Formula
  desc "CLI helps develop/deploy/debug apps with Docker and k8s"
  homepage "https://devspace.sh/"
  url "https://github.com/loft-sh/devspace.git",
      tag:      "v6.1.1",
      revision: "9cd3723afbf14d488a208b0dfb301f9670a51c92"
  license "Apache-2.0"

  depends_on "go" => :build
  depends_on "kubernetes-cli"

  conflicts_with "homebrew/core/devspace"

  bottle do
    rebuild 1
    root_url "https://github.com/Fullscript/homebrew-tools/releases/tag/bottles"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "7138317c952d7bf20f53763c329f889463c089f7b2f1499d7ff45b62a20d11ea"
  end

  def install
    ldflags = %W[
      -s -w
      -X main.commitHash=#{Utils.git_head}
      -X main.version=#{version}
    ]
    system "go", "build", *std_go_args(ldflags: ldflags)
  end

  test do
    help_output = "DevSpace accelerates developing, deploying and debugging applications with Docker and Kubernetes."
    assert_match help_output, shell_output("#{bin}/devspace --help")

    init_help_output = "Initializes a new devspace project"
    assert_match init_help_output, shell_output("#{bin}/devspace init --help")
  end
end
