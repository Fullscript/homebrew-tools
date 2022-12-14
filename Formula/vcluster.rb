class Vcluster < Formula
  desc "Creates fully functional virtual k8s cluster inside host k8s cluster's namespace"
  homepage "https://www.vcluster.com"
  url "https://github.com/loft-sh/vcluster.git",
      tag:      "v0.12.3",
      revision: "397d9942f6f05ba7ca1dc9d507f26c8e33cd36b4"
  license "Apache-2.0"

  depends_on "go" => :build
  depends_on "helm"
  depends_on "kubernetes-cli"

  conflicts_with "homebrew/core/vcluster"

  bottle do
    root_url "https://github.com/Fullscript/homebrew-tools/releases/download/bottles"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "d9a42c632c6165da6f686f240857f62727135d05b42e5b2092e8d5e621d46b08"
    sha256 cellar: :any_skip_relocation, ventura: "32fed9a933c432269dea988b89a0900d089e5d72baa0c64f7dd67e158108ec3d"
  end

  def install
    ldflags = %W[
      -s -w
      -X main.commitHash=#{Utils.git_head}
      -X main.buildDate=#{time.iso8601}
      -X main.version=#{version}
    ]
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
