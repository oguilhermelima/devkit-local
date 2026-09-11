# Template rendered by scripts/release.sh; do not audit this file directly.
class Megabrain < Formula
  desc "Tooling for Git worktrees, agent orchestration, and device testing"
  homepage "https://github.com/oguilhermelima/megabrain"
  url "https://github.com/oguilhermelima/megabrain/releases/download/v0.2.0/megabrain-0.2.0.tar.gz"
  sha256 "4c0efecadc7e77c4b2fe3d68c0a6f62e921ce762b249a369cb737c19e605a96d"
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
