#!/bin/bash
set -euo pipefail

OPENSSL_TARGET="${OPENSSL_TARGET:-linux-x86_64}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
LIBRETLS_VERSION="${LIBRETLS_VERSION:-3.8.1}"
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
ECL_VERSION="${ECL_VERSION:-26.5.5}"
SBCL_VERSION="${SBCL_VERSION:-2.6.0}"
STATIC_PREFIX="${STATIC_PREFIX:-/opt/static}"

case $(uname -m) in
    x86_64) ARCH="x86-64" ;;
    arm64|aarch64) ARCH="arm64";;
    *) ARCH=$(uname -m) ;;
esac

export PATH="/opt/rh/devtoolset-10/root/usr/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/rh/devtoolset-10/root/usr/lib64:/opt/rh/devtoolset-10/root/usr/lib:${LD_LIBRARY_PATH:-}"

if [ -f /etc/yum.repos.d/CentOS-Base.repo ]; then
  sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' \
    /etc/yum.repos.d/CentOS-Base.repo
fi

yum -y install \
  perl \
  perl-IPC-Cmd \
  perl-Time-Piece \
  make \
  pkgconfig \
  autoconf \
  automake \
  libtool \
  m4 \
  git \
  wget \
  curl \
  which
yum clean all

mkdir -p /usr/src "${STATIC_PREFIX}"
cd /usr/src

echo "=== Building OpenSSL ${OPENSSL_VERSION} (target: ${OPENSSL_TARGET}) ==="
curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o openssl.tar.gz
tar xf openssl.tar.gz
cd "openssl-${OPENSSL_VERSION}"
./Configure "${OPENSSL_TARGET}" no-shared no-tests \
  --prefix="${STATIC_PREFIX}" \
  --openssldir="${STATIC_PREFIX}/ssl" \
  --libdir=lib
make -j"$(nproc)"
make install_sw install_ssldirs
cd /usr/src && rm -rf "openssl-${OPENSSL_VERSION}" openssl.tar.gz

export PKG_CONFIG_PATH="${STATIC_PREFIX}/lib/pkgconfig:${STATIC_PREFIX}/lib64/pkgconfig"
export CPATH="${STATIC_PREFIX}/include"
export LIBRARY_PATH="${STATIC_PREFIX}/lib:${STATIC_PREFIX}/lib64"

echo "=== Verifying OpenSSL symbol visibility ==="
for sym in OpenSSL_version_num SSL_CTX_new EVP_sha256; do
  match=$(nm "${STATIC_PREFIX}/lib/libcrypto.a" "${STATIC_PREFIX}/lib/libssl.a" 2>/dev/null | grep " T ${sym}\$" || true)
  if [ -z "$match" ]; then
    echo "FATAL: symbol ${sym} is missing or not globally visible in the static OpenSSL build" >&2
    exit 1
  fi
  echo "OK: ${sym} -> ${match}"
done

echo "=== Building zstd ${ZSTD_VERSION} ==="
cd /usr/src
curl -fsSL "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" -o zstd.tar.gz
tar xf zstd.tar.gz
cd "zstd-${ZSTD_VERSION}"
make -j"$(nproc)" BUILD_SHARED=0 BUILD_STATIC=1
make install PREFIX="${STATIC_PREFIX}" BUILD_SHARED=0 BUILD_STATIC=1
cd /usr/src && rm -rf "zstd-${ZSTD_VERSION}" zstd.tar.gz

echo "=== Building LibreTLS ${LIBRETLS_VERSION} ==="
curl -fsSL "https://causal.agency/libretls/libretls-${LIBRETLS_VERSION}.tar.gz" -o libretls.tar.gz
tar xf libretls.tar.gz
cd "libretls-${LIBRETLS_VERSION}"
PKG_CONFIG="pkg-config --static" ./configure \
  --prefix="${STATIC_PREFIX}" \
  --disable-shared \
  --enable-static
make -j"$(nproc)"
make install
cd /usr/src && rm -rf "libretls-${LIBRETLS_VERSION}" libretls.tar.gz

echo "=== Building ECL ${ECL_VERSION} ==="
curl -fsSL "https://common-lisp.net/project/ecl/static/files/release/ecl-$ECL_VERSION.tgz" -o ecl.tar.gz
tar xf ecl.tar.gz
cd "ecl-${ECL_VERSION}"
PKG_CONFIG="pkg-config --static" ./configure \
  --prefix="${STATIC_PREFIX}" \
  --disable-shared
make -j"$(nproc)"
make install
ln -s "${STATIC_PREFIX}/bin/ecl" "/usr/local/bin/ecl"
cd /usr/src && rm -rf "ecl-${ECL_VERSION}" ecl.tar.gz

export LD_LIBRARY_PATH="${STATIC_PREFIX}/lib:${STATIC_PREFIX}/lib64"

echo "=== Building SBCL ${SBCL_VERSION} ==="
SBCL_HOST_DIR="sbcl-1.4.2-${ARCH}-linux"
curl -fsSL https://prdownloads.sourceforge.net/sbcl/${SBCL_HOST_DIR}-binary.tar.bz2 -o sbcl-host.tar.gz
SBCL_HOST_DIR="${PWD}/${SBCL_HOST_DIR}"
tar xf sbcl-host.tar.gz
git clone --depth 1 --branch sbcl-${SBCL_VERSION} https://github.com/sbcl/sbcl sbcl-${SBCL_VERSION}
cd "sbcl-${SBCL_VERSION}"
bash make.sh --xc-host="${SBCL_HOST_DIR}/run-sbcl.sh" --fancy
bash install.sh
cd /usr/src && rm -rf sbcl*

echo "--- installed static libs ---"
ls -la "${STATIC_PREFIX}/lib"
echo "--- glibc in this image ---"
ldd --version | head -n1 || true
