class Sops < Formula
  desc "Editor of encrypted files"
  homepage "https://github.com/mozilla/sops"
  url "https://github.com/mozilla/sops/archive/v3.7.3.tar.gz"
  sha256 "0e563f0c01c011ba52dd38602ac3ab0d4378f01edfa83063a00102587410ac38"
  license "MPL-2.0"
  head "https://github.com/mozilla/sops.git", branch: "master"

  bottle do
    root_url "https://github.com/Fullscript/homebrew-tools/releases/download/bottles"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "edadfb5e554fabf348be101e39cc32dbf3a9bf831ebeb27da340bd2d375765c3"
    sha256 cellar: :any_skip_relocation, ventura: "fcda5c3b48a043db32e49b84b29081e0904879ef54dae2b206e13ba9813306a5"
  end

  depends_on "go" => :build
  conflicts_with "homebrew/core/sops"

  def install
    system "go", "build", "-o", bin/"sops", "go.mozilla.org/sops/v3/cmd/sops"
    pkgshare.install "example.yaml"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/sops --version")

    assert_match "Recovery failed because no master key was able to decrypt the file.",
      shell_output("#{bin}/sops #{pkgshare}/example.yaml 2>&1", 128)
  end
end
