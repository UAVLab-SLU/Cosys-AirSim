#!/bin/bash
# =============================================================================
# AirSim Linux Build Script
# =============================================================================
# This script:
# 1. Checks for the correct clang version (18.1.0-rockylinux8)
# 2. Downloads and sets up the toolchain if not found
# 3. Builds AirSim Linux libraries with the correct compiler
# 4. Copies libraries to the correct locations
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REQUIRED_CLANG_VERSION="14.0.0"
REQUIRED_TOOLCHAIN="clang-14-ubuntu22.04"
TOOLCHAIN_DIR="/usr"
BUILD_TYPE="Release"

echo -e "${BLUE}=============================================================================${NC}"
echo -e "${BLUE}AirSim Linux Build Script${NC}"
echo -e "${BLUE}=============================================================================${NC}"
echo

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check clang version
check_clang_version() {
    if command_exists clang; then
        local version=$(clang --version | head -n1 | grep -oP '\d+\.\d+\.\d+' | head -n1)
        if [[ "$version" == "$REQUIRED_CLANG_VERSION" ]]; then
            return 0
        fi
    fi
    return 1
}

# Function to check existing dependencies
check_existing_dependencies() {
    print_status "Checking existing dependencies..."
    
    local deps_ok=true
    
    # Check for rpclib
    if [[ ! -d "external/rpclib/rpclib-2.3.1" ]]; then
        print_warning "rpclib-2.3.1 not found, will download..."
        deps_ok=false
    else
        print_status "✓ rpclib-2.3.1 found"
    fi
    
    # Check for Eigen
    if [[ ! -d "AirLib/deps/eigen3/Eigen" ]]; then
        print_warning "Eigen library not found, will download..."
        deps_ok=false
    else
        print_status "✓ Eigen library found"
    fi
    
    if [[ "$deps_ok" == false ]]; then
        print_status "Downloading missing dependencies..."
        download_dependencies
    fi
}

# Function to download dependencies
download_dependencies() {
    # Download rpclib if not exists
    if [[ ! -d "external/rpclib/rpclib-2.3.1" ]]; then
        print_status "Downloading rpclib-2.3.1..."
        mkdir -p external/rpclib
        wget -O /tmp/v2.3.1.zip https://github.com/WouterJansen/rpclib/archive/refs/tags/v2.3.1.zip
        unzip -q /tmp/v2.3.1.zip -d external/rpclib
        rm /tmp/v2.3.1.zip
    fi
    
    # Download Eigen if not exists
    if [[ ! -d "AirLib/deps/eigen3/Eigen" ]]; then
        print_status "Downloading Eigen library..."
        mkdir -p AirLib/deps/eigen3
        wget -O /tmp/eigen3.zip https://github.com/WouterJansen/eigen/archive/refs/tags/3.4.1r.zip
        unzip -q /tmp/eigen3.zip -d /tmp/
        mv /tmp/eigen*/Eigen AirLib/deps/eigen3/
        rm -rf /tmp/eigen* /tmp/eigen3.zip
    fi
}

# Function to install system dependencies
install_dependencies() {
    print_status "Checking system dependencies..."
    
    # Check if we can run sudo commands
    if ! sudo -n true 2>/dev/null; then
        print_warning "Cannot run sudo commands. Checking if dependencies are already installed..."
        
        # Check for essential tools
        local missing_deps=()
        command -v cmake >/dev/null 2>&1 || missing_deps+=("cmake")
        command -v wget >/dev/null 2>&1 || missing_deps+=("wget")
        command -v xz >/dev/null 2>&1 || missing_deps+=("xz-utils")
        
        if [ ${#missing_deps[@]} -gt 0 ]; then
            print_error "Missing dependencies: ${missing_deps[*]}"
            print_error "Please install them manually:"
            echo "  sudo apt update"
            echo "  sudo apt install -y ${missing_deps[*]}"
            return 1
        fi
        
        print_status "Essential dependencies found ✓"
        return 0
    fi
    
    sudo apt update
    sudo apt install -y \
        build-essential \
        cmake \
        git \
        wget \
        xz-utils \
        libeigen3-dev \
        libboost-all-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        python3 \
        python3-pip \
        clang-18 \
        clang++-18 \
        llvm-18
    
    print_status "Dependencies installed successfully!"
}

# Function to setup LLVM toolchain
setup_llvm_toolchain() {
    print_status "Setting up Clang $REQUIRED_CLANG_VERSION toolchain..."
    
    # Check if clang-14 is available
    if command -v clang-14 >/dev/null 2>&1; then
        print_status "Clang 14 found in system ✓"
        export CC="clang-14"
        export CXX="clang++-14"
        export AR="/usr/bin/llvm-ar-14"
        return 0
    else
        print_error "Clang 14 not found. Please install it manually:"
        echo "  sudo apt update"
        echo "  sudo apt install -y clang-14 clang++-14 llvm-14"
        return 1
    fi
}

# Function to verify toolchain
verify_toolchain() {
    print_status "Verifying toolchain..."
    
    if command -v clang-14 >/dev/null 2>&1; then
        local version=$(clang-14 --version | head -n1 | grep -oP '\d+\.\d+\.\d+' | head -n1)
        if [[ "$version" == *"14"* ]]; then
            print_status "Toolchain verified: clang-14 $version"
            return 0
        fi
    fi
    
    print_error "Toolchain verification failed!"
    return 1
}

# Function to setup build environment
setup_build_environment() {
    print_status "Setting up build environment..."
    
    # Check if we have clang-14, otherwise use system compilers
    if command -v clang-14 >/dev/null 2>&1; then
        export CC="clang-14"
        export CXX="clang++-14"
        export AR="/usr/bin/llvm-ar-14"
        print_status "Using Clang 14 compiler"
    else
        # Use system GCC (which we know works)
        export CC="gcc"
        export CXX="g++"
        export AR="ar"
        print_status "Using system GCC compiler"
    fi
    
    # Set build directory (like original build.sh)
    build_dir="build_release"
    
    # Clean up any existing cmake cache files
    if [[ -f "./cmake/CMakeCache.txt" ]]; then
        rm "./cmake/CMakeCache.txt"
    fi
    if [[ -d "./cmake/CMakeFiles" ]]; then
        rm -rf "./cmake/CMakeFiles"
    fi
    
    # Create build directory
    if [[ ! -d $build_dir ]]; then
        mkdir -p $build_dir
    fi
    
    print_status "Build environment ready!"
}

# Function to build AirSim
build_airsim() {
    print_status "Building AirSim..."
    
    # Use the same approach as original build.sh
    local build_dir="build_release"
    local folder_name="Release"
    
    # Create output directory structure (needed for CMake)
    # CMake expects output directories to be relative to the project root, not build directory
    mkdir -p output/lib
    mkdir -p output/bin
    
    # Configure with CMake (like original build.sh)
    print_status "Configuring with CMake..."
    pushd $build_dir >/dev/null
    
    cmake ../cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        || (popd && rm -r $build_dir && exit 1)
    
    popd >/dev/null
    
    # Build (like original build.sh)
    print_status "Building AirSim libraries..."
    pushd $build_dir >/dev/null
    make -j$(nproc)
    popd >/dev/null
    
    print_status "AirSim build completed successfully!"
}

# Function to copy libraries
copy_libraries() {
    print_status "Copying built libraries..."
    
    # Use the same approach as original build.sh
    local build_dir="build_release"
    local folder_name="Release"
    local RPC_VERSION_FOLDER="rpclib-2.3.1"
    
    # Create lib directories (like original build.sh)
    mkdir -p AirLib/lib/x64/$folder_name
    mkdir -p AirLib/deps/rpclib/lib
    mkdir -p AirLib/deps/MavLinkCom/lib
    
    # Copy libraries (like original build.sh)
    if [[ -f "$build_dir/output/lib/libAirLib.a" ]]; then
        cp $build_dir/output/lib/libAirLib.a AirLib/lib/
        print_status "Copied libAirLib.a"
    else
        print_warning "libAirLib.a not found in build output"
    fi
    
    if [[ -f "$build_dir/output/lib/libMavLinkCom.a" ]]; then
        cp $build_dir/output/lib/libMavLinkCom.a AirLib/deps/MavLinkCom/lib/
        print_status "Copied libMavLinkCom.a"
    else
        print_warning "libMavLinkCom.a not found in build output"
    fi
    
    if [[ -f "$build_dir/output/lib/librpc.a" ]]; then
        cp $build_dir/output/lib/librpc.a AirLib/deps/rpclib/lib/librpc.a
        print_status "Copied librpc.a"
    else
        print_warning "librpc.a not found in build output"
    fi
    
    # Update AirLib/lib, AirLib/deps, Plugins folders with new binaries (like original build.sh)
    if [[ -d "$build_dir/output/lib" ]]; then
        rsync -a --delete $build_dir/output/lib/ AirLib/lib/x64/$folder_name
        print_status "Updated AirLib/lib/x64/$folder_name"
    fi
    
    if [[ -d "external/rpclib/$RPC_VERSION_FOLDER/include" ]]; then
        rsync -a --delete external/rpclib/$RPC_VERSION_FOLDER/include AirLib/deps/rpclib
        print_status "Updated rpclib headers"
    fi
    
    if [[ -d "MavLinkCom/include" ]]; then
        rsync -a --delete MavLinkCom/include AirLib/deps/MavLinkCom
        print_status "Updated MavLinkCom headers"
    fi
    
    # Copy AirLib to Unreal plugin (like original build.sh)
    if [[ -d "Unreal/Plugins/AirSim/Source" ]]; then
        rsync -a --delete AirLib Unreal/Plugins/AirSim/Source/
        rm -rf Unreal/Plugins/AirSim/Source/AirLib/src
        print_status "Updated Unreal plugin"
    fi
    
    print_status "Libraries copied successfully!"
}

# Function to verify build
verify_build() {
    print_status "Verifying build..."
    
    local success=true
    
    # Check if libraries exist and are valid
    if [[ -f "AirLib/lib/libAirLib.a" ]]; then
        local size=$(stat -c%s "AirLib/lib/libAirLib.a")
        if [[ $size -gt 1000 ]]; then
            print_status "✓ libAirLib.a ($size bytes)"
        else
            print_error "✗ libAirLib.a is too small or invalid"
            success=false
        fi
    else
        print_error "✗ libAirLib.a not found"
        success=false
    fi
    
    if [[ -f "AirLib/deps/MavLinkCom/lib/libMavLinkCom.a" ]]; then
        local size=$(stat -c%s "AirLib/deps/MavLinkCom/lib/libMavLinkCom.a")
        if [[ $size -gt 1000 ]]; then
            print_status "✓ libMavLinkCom.a ($size bytes)"
        else
            print_error "✗ libMavLinkCom.a is too small or invalid"
            success=false
        fi
    else
        print_error "✗ libMavLinkCom.a not found"
        success=false
    fi
    
    if [[ -f "AirLib/deps/rpclib/lib/librpc.a" ]]; then
        local size=$(stat -c%s "AirLib/deps/rpclib/lib/librpc.a")
        if [[ $size -gt 1000 ]]; then
            print_status "✓ librpc.a ($size bytes)"
        else
            print_error "✗ librpc.a is too small or invalid"
            success=false
        fi
    else
        print_error "✗ librpc.a not found"
        success=false
    fi
    
    if [[ "$success" == true ]]; then
        print_status "Build verification successful!"
        return 0
    else
        print_error "Build verification failed!"
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BLUE}[1/7]${NC} Checking system and dependencies..."
    
    # Check if we're in the right directory
    if [[ ! -f "build.sh" ]]; then
        print_error "This script must be run from the AirSim root directory!"
        print_error "Please navigate to your Cosys-AirSim directory and run this script."
        exit 1
    fi
    
    # Check existing dependencies first
    check_existing_dependencies
    
    # Install system dependencies
    install_dependencies
    
    echo -e "${BLUE}[2/7]${NC} Setting up Clang $REQUIRED_CLANG_VERSION toolchain..."
    
    # Try to set up Clang 18
    if setup_llvm_toolchain; then
        print_status "Clang $REQUIRED_CLANG_VERSION toolchain ready!"
    else
        print_warning "Clang $REQUIRED_CLANG_VERSION not available, will use system GCC"
    fi
    
    echo -e "${BLUE}[3/7]${NC} Setting up build environment..."
    setup_build_environment
    
    echo -e "${BLUE}[4/7]${NC} Building AirSim..."
    build_airsim
    
    echo -e "${BLUE}[5/7]${NC} Copying libraries..."
    copy_libraries
    
    echo -e "${BLUE}[6/7]${NC} Verifying build..."
    if verify_build; then
        echo
        echo -e "${GREEN}=============================================================================${NC}"
        echo -e "${GREEN}BUILD SUCCESSFUL!${NC}"
        echo -e "${GREEN}=============================================================================${NC}"
        echo
        print_status "AirSim Linux libraries have been built successfully!"
        print_status "The following libraries are ready:"
        echo "  - AirLib/lib/libAirLib.a"
        echo "  - AirLib/deps/MavLinkCom/lib/libMavLinkCom.a"
        echo "  - AirLib/deps/rpclib/lib/librpc.a"
        echo
        print_status "Libraries have been copied to the correct locations for Unreal Engine integration."
        echo
    else
        echo
        echo -e "${RED}=============================================================================${NC}"
        echo -e "${RED}BUILD FAILED!${NC}"
        echo -e "${RED}=============================================================================${NC}"
        echo
        print_error "Please check the error messages above and try again."
        exit 1
    fi
}

# Run main function
main "$@"
