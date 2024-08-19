class Vcluster < Formula
  desc "Creates fully functional virtual k8s cluster inside host k8s cluster's namespace"
  homepage "https://www.vcluster.com"
  url "https://github.com/loft-sh/vcluster.git",
      tag:      "v0.19.7",
      revision: "75c742cf1bbca367394ee04e3ee9f9664ae0bc56"
  license "Apache-2.0"
  head "https://github.com/loft-sh/vcluster.git", branch: "main"

  depends_on "go" => :build
  depends_on "helm"
  depends_on "kubernetes-cli"

  conflicts_with "homebrew/core/vcluster"

  bottle do
    root_url "https://github.com/Fullscript/homebrew-tools/releases/download/bottles"
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "63b9771c605e21ddcad311ebf5f56d1232b729f64cd83a19e926c5e76a3c2883"
  end

  def install
    ldflags = %W[
      -s -w
      -X main.commitHash=#{Utils.git_head}
      -X main.buildDate=#{time.iso8601}
      -X main.version=#{version}
    ]
    system "go", "generate", "./..."
    system "go", "build", "-mod", "vendor", *std_go_args(ldflags:), "./cmd/vclusterctl/main.go"
    generate_completions_from_executable(bin/"vcluster", "completion")
  end

  test do
    help_output = "vcluster root command"
    assert_match help_output, shell_output("#{bin}/vcluster --help")

    create_output = "there is an error loading your current kube config " \
                    "(invalid configuration: no configuration has been provided, " \
                    "try setting KUBERNETES_MASTER environment variable), " \
                    "please make sure you have access to a kubernetes cluster and the command " \
                    "`kubectl get namespaces` is working"
    assert_match create_output, shell_output("#{bin}/vcluster create vcluster -n vcluster --create-namespace 2>&1", 1)
  end
end
