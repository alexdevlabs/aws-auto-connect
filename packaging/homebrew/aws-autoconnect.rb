# Homebrew formula for the alexdevlabs/homebrew-tap repo (copy it to Formula/aws-autoconnect.rb there).
# Builds from source, so the app isn't quarantined and needs no Developer ID signature.
class AwsAutoconnect < Formula
  desc "Menu bar app that keeps AWS SSO signed in and connects AWS Client VPN (SAML)"
  homepage "https://github.com/alexdevlabs/aws-auto-connect"
  url "https://github.com/alexdevlabs/aws-auto-connect/archive/refs/tags/v1.2.1.tar.gz"
  sha256 "dd0f7e2cc70c6554b6ec03a5fbea3553f9c56afca2bdf61d26a1ba0e66ada425"
  license "MIT"
  head "https://github.com/alexdevlabs/aws-auto-connect.git", branch: "main"

  depends_on "openssl@3" => :build # linked statically into the bundled openvpn
  depends_on macos: :sonoma

  # The same pinned sources scripts/build-openvpn.sh would download (the build has no network).
  resource "openvpn" do
    url "https://swupdate.openvpn.org/community/releases/openvpn-2.6.12.tar.gz"
    sha256 "1c610fddeb686e34f1367c347e027e418e07523a10f4d8ce4a2c2af2f61a1929"
  end

  resource "aws-patch" do
    url "https://raw.githubusercontent.com/aws-vpn-client/aws-vpn-client/d61ec721f002d6b4e6ec912c772313c1d4bb0ad6/openvpn-v2.6.12-aws.patch"
    sha256 "561f0887a7043452cff55f3140539f18c7a63e914343047c98f82a121f356457"
  end

  def install
    ENV["OPENVPN_TARBALL"] = resource("openvpn").cached_download.to_s
    ENV["AWS_PATCH_FILE"] = resource("aws-patch").cached_download.to_s
    ENV["OPENSSL_PREFIX"] = formula_opt_prefix("openssl@3").to_s
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/bundle.sh"
    prefix.install "build/AWS AutoConnect.app"
  end

  def caveats
    <<~EOS
      Start it once; it copies itself to /Applications (or ~/Applications) and runs from there:
        open "#{opt_prefix}/AWS AutoConnect.app"
      After `brew upgrade`, the copy updates itself the next time it starts.
      `brew uninstall` leaves that copy of AWS AutoConnect.app; delete it by hand.

      For the VPN, open the VPN tab and click "Install Helper…" (asks for your admin password once).
    EOS
  end

  test do
    assert_predicate prefix/"AWS AutoConnect.app/Contents/MacOS/AWSAutoConnect", :executable?
    assert_predicate prefix/"AWS AutoConnect.app/Contents/Resources/openvpn", :executable?
  end
end
