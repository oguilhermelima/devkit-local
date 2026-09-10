# Template rendered by scripts/release.sh; do not audit this file directly.
class Megabrain < Formula
  desc "Tooling for Git worktrees, agent orchestration, and device testing"
  homepage "https://github.com/oguilhermelima/megabrain"
  url "https://github.com/oguilhermelima/megabrain/releases/download/v0.1.0/megabrain-0.1.0.tar.gz"
  sha256 "9ad1b72cc59c837d6bf0129c3281a7c91b3431f26b245b39a00f9b9cb8677045"
  license "MIT"

  depends_on "jq"

  def install
    libexec.install Dir["*"]
    libexec.install ".agents", ".claude-plugin", ".codex-plugin", ".megabrain"
    bin.install_symlink libexec/"megabrain"
    bin.install_symlink libexec/"mb"
  end

  def caveats
    <<~EOS
      Homebrew installs the megabrain CLI. Run `megabrain install` for machine setup.
      The megabrain skill is kept in sync by megabrain itself.
    EOS
  end

  test do
    assert_match(/^megabrain [0-9]+\.[0-9]+\.[0-9]+$/, shell_output("#{bin}/megabrain version"))
  end
end
