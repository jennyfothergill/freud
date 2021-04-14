#!/bin/bash
if [ -z $1 ]; then
    echo "A package directory must be provided as the first argument."
    exit 1
fi

# Install a modern version of CMake for compatibility with TBB 2021
# (manylinux image includes CMake 2.8)
python --version
pip --version
pip install cmake

PACKAGE_DIR=$1
#TBB_PLATFORM=$1
TBB_VERSION="2021.2.0"
#if [[ "${TBB_PLATFORM}" == "win" ]]; then
#    TBB_ZIP="oneapi-tbb-${TBB_VERSION}-${TBB_PLATFORM}.zip"
#else
#    TBB_ZIP="oneapi-tbb-${TBB_VERSION}-${TBB_PLATFORM}.tgz"
#fi
TBB_ZIP="v${TBB_VERSION}.zip"
#curl -L -O "https://github.com/oneapi-src/oneTBB/releases/download/v${TBB_VERSION}/${TBB_ZIP}"
curl -L -O "https://github.com/oneapi-src/oneTBB/archive/refs/tags/${TBB_ZIP}"
unzip -q "${TBB_ZIP}"

# Move to a hard-coded path (defined by CIBW_ENVIRONMENT)
mv "oneTBB-${TBB_VERSION}" "${PACKAGE_DIR}/tbb"
cd "${PACKAGE_DIR}/tbb"
mkdir -p build
cd build
cmake ../ -DTBB_TEST=OFF
make
cmake -DCOMPONENT=runtime -P cmake_install.cmake
cmake -DCOMPONENT=devel -P cmake_install.cmake
BUILD_DIR=$(dirname $(find . -name vars.sh))
cd "${BUILD_DIR}"
source vars.sh
echo "TBBROOT: ${TBBROOT:-"not found"}"
