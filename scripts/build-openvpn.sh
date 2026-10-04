#!/usr/bin/env bash
# Builds an AWS-Client-VPN-compatible openvpn (2.6.12 + AWS SAML patch),
# with OpenSSL linked statically so the binary only depends on system libs.
#
# Sources, each pinned by SHA-256:
#   openvpn   official release tarball from swupdate.openvpn.org
#   AWS patch https://github.com/aws-vpn-client/aws-vpn-client (successor of the archived
#             samm-git/aws-vpn-client), file openvpn-v2.6.12-aws.patch at a fixed commit
#   our fix   vendor/openvpn-aws-size-macros.patch, applied on top
#
# OPENVPN_TARBALL and AWS_PATCH_FILE can point at already downloaded copies (the Homebrew formula
# does this; its build has no network). OPENSSL_PREFIX overrides `brew --prefix openssl@3`.
set -euo pipefail

VERSION=2.6.12
SHA256=1c610fddeb686e34f1367c347e027e418e07523a10f4d8ce4a2c2af2f61a1929
AWS_PATCH_COMMIT=d61ec721f002d6b4e6ec912c772313c1d4bb0ad6
AWS_PATCH_SHA256=561f0887a7043452cff55f3140539f18c7a63e914343047c98f82a121f356457
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/openvpn"
OUT="$ROOT/Resources/openvpn"
SSL="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

TARBALL="openvpn-$VERSION.tar.gz"
[ -n "${OPENVPN_TARBALL:-}" ] && cp "$OPENVPN_TARBALL" "$TARBALL"
if [ ! -f "$TARBALL" ]; then
  curl -fL -o "$TARBALL" "https://swupdate.openvpn.org/community/releases/$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

AWS_PATCH="openvpn-v$VERSION-aws.patch"
[ -n "${AWS_PATCH_FILE:-}" ] && cp "$AWS_PATCH_FILE" "$AWS_PATCH"
if [ ! -f "$AWS_PATCH" ]; then
  curl -fL -o "$AWS_PATCH" \
    "https://raw.githubusercontent.com/aws-vpn-client/aws-vpn-client/$AWS_PATCH_COMMIT/$AWS_PATCH"
fi
echo "$AWS_PATCH_SHA256  $AWS_PATCH" | shasum -a 256 -c -

rm -rf "openvpn-$VERSION"
tar xzf "$TARBALL"
cd "openvpn-$VERSION"
patch -p1 < "$WORK/$AWS_PATCH"
patch -p1 < "$ROOT/vendor/openvpn-aws-size-macros.patch"

./configure \
  --disable-debug --disable-dependency-tracking \
  --disable-lzo --disable-lz4 --disable-plugins --disable-plugin-auth-pam \
  --disable-plugin-down-root --disable-pkcs11 --disable-management \
  --with-crypto-library=openssl \
  OPENSSL_CFLAGS="-I$SSL/include" \
  OPENSSL_LIBS="$SSL/lib/libssl.a $SSL/lib/libcrypto.a" \
  MACOSX_DEPLOYMENT_TARGET=14.0

make -j"$(sysctl -n hw.ncpu)"
cp src/openvpn/openvpn "$OUT"
strip "$OUT"
echo "Built $OUT"
otool -L "$OUT"
