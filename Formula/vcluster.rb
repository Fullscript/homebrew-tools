class Vcluster < Formula
  desc "Creates fully functional virtual k8s cluster inside host k8s cluster's namespace"
  homepage "https://www.vcluster.com"
  url "https://github.com/loft-sh/vcluster.git",
      tag:      "v0.14.2",
      revision: "0dac15bff8ee6b4048b1f2c44a97eb95820d3ec2"
  license "Apache-2.0"

  depends_on "go" => :build
  depends_on "helm"
  depends_on "kubernetes-cli"

  conflicts_with "homebrew/core/vcluster"

  bottle do
    root_url "https://github.com/Fullscript/homebrew-tools/releases/download/bottles"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "72468f665b007d39c6d040ecfb44c2c500dc0b249f8dee8e51ace1fb1aad3f91"
    sha256 cellar: :any_skip_relocation, ventura: "5ae199dba373d25b2b3d0420af2ea5884b9df33f1f8175719d2ef46d4009df97"
  end

  def install
    ldflags = %W[
      -s -w
      -X main.commitHash=#{Utils.git_head}
      -X main.buildDate=#{time.iso8601}
      -X main.version=#{version}
    ]
    system "go", "generate", "./..."
    system "go", "build", "-mod", "vendor", *std_go_args(ldflags: ldflags), "./cmd/vclusterctl/main.go"
  end

  test do
    help_output = "vcluster root command"
    assert_match help_output, shell_output("#{bin}/vcluster --help")

    create_output = "there is an error loading your current kube config " \
                    "(invalid configuration: no configuration has been provided, " \
                    "try setting KUBERNETES_MASTER environment variable), " \
                    "please make sure you have access to a kubernetes cluster and the command " \
                    "`kubectl get namespaces` is working"
    assert_match create_output, shell_output("#{bin}/vcluster create vcluster -n vcluster --create-namespace", 1)
  end
end
