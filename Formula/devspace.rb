class Devspace < Formula
  desc "CLI helps develop/deploy/debug apps with Docker and k8s"
  homepage "https://devspace.sh/"
  url "https://github.com/loft-sh/devspace.git",
      tag:      "v6.2.5",
      revision: "f26b041dece7f11b247cb323a264e726aef1f2c6"
  license "Apache-2.0"

  depends_on "go" => :build
  depends_on "kubernetes-cli"

  conflicts_with "homebrew/core/devspace"

  bottle do
    root_url "https://github.com/Fullscript/homebrew-tools/releases/download/bottles"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "531d808cc7c6bbc48db2a8df12fadc1560c6078bbf3c6e2676a7bdef6c11cfc3"
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
