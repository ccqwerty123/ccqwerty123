#!/bin/bash
#
# A robust, automated installer script for alek76-2/VanitySearch.
#
# This script is designed to be run via a pipe, e.g.:
# curl -sSL [URL] | bash
#
# Features:
# - Automatic dependency checking (git, build-essential, libssl-dev).
# - Intelligent detection of NVIDIA drivers and CUDA Toolkit.
# - Automatic detection of GPU Compute Capability (ccap).
# - In-place configuration of the Makefile.
# - Retry logic for network operations.
# - Colored, verbose output for better user experience.
# - Fails safely with clear instructions if requirements are not met.
#

# --- Configuration ---
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
REQUIRED_CMDS=("git" "g++" "make")
REQUIRED_HEADERS=("/usr/include/openssl/ssl.h")
MAX_RETRIES=3

# --- Shell Safety and Color Definitions ---
set -o errexit  # Exit immediately if a command exits with a non-zero status.
set -o nounset  # Treat unset variables as an error when substituting.
set -o pipefail # Return value of a pipeline is the value of the last command to exit with a non-zero status.

# Colors
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Logging Functions ---
log_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $1"
}
log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} ${C_BOLD}$1${C_RESET}"
}
log_warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"
}
log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
    exit 1
}

# --- Core Functions ---

# Function to check for required system commands and libraries.
check_dependencies() {
    log_info "Checking for required system dependencies..."
    
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Command '$cmd' not found. Please install it. On Debian/Ubuntu, try: sudo apt install build-essential git"
        fi
    done

    for header in "${REQUIRED_HEADERS[@]}"; do
        if [ ! -f "$header" ]; then
            log_error "Header file '$header' not found. Please install the OpenSSL development library. On Debian/Ubuntu, try: sudo apt install libssl-dev"
        fi
    done
    
    log_success "All basic dependencies are installed."
}

# Function to check for NVIDIA driver and CUDA toolkit, and detect properties.
check_nvidia_cuda() {
    log_info "Checking for NVIDIA GPU environment..."

    if ! command -v nvidia-smi &>/dev/null; then
        log_error "NVIDIA driver not found. 'nvidia-smi' command failed. Please install the appropriate NVIDIA drivers for your GPU and restart."
    fi
    log_success "NVIDIA driver detected."

    if ! command -v nvcc &>/dev/null; then
        log_error "NVIDIA CUDA Toolkit not found. 'nvcc' command failed. Please install the CUDA Toolkit from the NVIDIA website."
    fi
    local cuda_version
    cuda_version=$(nvcc --version | grep "release" | sed 's/.*release \([^,]*\).*/\1/')
    log_success "NVIDIA CUDA Toolkit detected (Version: $cuda_version)."

    # Automatically detect the compute capability
    log_info "Detecting GPU Compute Capability (ccap)..."
    local compute_cap
    compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1)
    if [ -z "$compute_cap" ]; then
        log_error "Could not determine GPU Compute Capability. Please check your 'nvidia-smi' installation."
    fi
    # Convert from "8.6" to "86" format for the Makefile
    DETECTED_CCAP=$(echo "$compute_cap" | tr -d '.')
    log_success "Detected GPU Compute Capability: $compute_cap (ccap=${DETECTED_CCAP})"
    
    # Attempt to find a suitable g++ compiler path
    if command -v g++-7 &>/dev/null; then
        DETECTED_CXXCUDA="/usr/bin/g++-7"
    elif command -v g++-8 &>/dev/null; then
        DETECTED_CXXCUDA="/usr/bin/g++-8"
    else
        DETECTED_CXXCUDA=$(command -v g++)
        log_warn "Could not find a specific older g++ version (like g++-7). Using the system default at '$DETECTED_CXXCUDA'. If compilation fails, you may need to install a CUDA-compatible g++ version."
    fi
    log_success "Selected g++ compiler: $DETECTED_CXXCUDA"

    # Assume standard CUDA path
    DETECTED_CUDA_PATH="/usr/local/cuda"
    if [ ! -d "$DETECTED_CUDA_PATH" ]; then
        log_warn "Standard CUDA path '$DETECTED_CUDA_PATH' not found. Assuming it's in the system PATH."
        # If not in standard path, nvcc must be in PATH, so we can leave the Makefile path empty and let it rely on the PATH.
        DETECTED_CUDA_PATH=""
    else
         log_success "Found CUDA installation at $DETECTED_CUDA_PATH"
    fi
}

# Function to download the source code with retries.
download_source() {
    log_info "Downloading VanitySearch source code..."
    
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "Directory '$PROJECT_DIR' already exists. It will be removed for a clean installation."
        rm -rf "$PROJECT_DIR"
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        git clone "$GITHUB_REPO" && log_success "Source code downloaded successfully." && return 0
        log_warn "Git clone failed (Attempt $i/$MAX_RETRIES). Retrying in 3 seconds..."
        sleep 3
    done
    
    log_error "Failed to clone the repository after $MAX_RETRIES attempts."
}

# Function to dynamically configure the Makefile.
configure_makefile() {
    log_info "Configuring Makefile for your system..."
    
    cd "$PROJECT_DIR"
    if [ ! -f "Makefile" ]; then
        log_error "Makefile not found in the project directory."
    fi

    # Use sed to replace the default CUDA and CXXCUDA paths with our detected ones.
    # The `|| true` prevents the script from exiting if a pattern is not found (e.g., if the user already modified it).
    sed -i "s|^CUDA       = .*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile || true
    sed -i "s|^CXXCUDA    = .*|CXXCUDA    = ${DETECTED_CXXCUDA}|" Makefile || true
    
    log_success "Makefile configured automatically."
    cd ..
}

# Function to compile the source code.
compile_source() {
    log_info "Starting compilation... This may take a few minutes."
    
    cd "$PROJECT_DIR"
    
    # Clean previous builds first
    make clean > /dev/null 2>&1 || true
    
    if make -j$(nproc) gpu=1 ccap=${DETECTED_CCAP} all; then
        log_success "Compilation finished successfully!"
    else
        log_error "Compilation failed. Please review the error messages above. Common issues include:\n  - Incompatible CUDA and g++ versions.\n  - Incorrect NVIDIA driver installation."
    fi
    
    cd ..
}

# --- Main Execution Logic ---
main() {
    # Welcome and warning message
    echo -e "${C_BOLD}--- alek76-2/VanitySearch Automated Installer ---${C_RESET}"
    log_warn "This script will attempt to compile software from source. It will NOT install system-level packages (like drivers or compilers) with root privileges."
    log_warn "Please ensure you have installed NVIDIA drivers and the CUDA Toolkit MANUALLY before running this script."
    echo "----------------------------------------------------"
    sleep 2

    # Step 1: Check system dependencies
    check_dependencies
    
    # Step 2: Check NVIDIA environment
    check_nvidia_cuda
    
    # Step 3: Download source
    download_source
    
    # Step 4: Configure Makefile
    configure_makefile
    
    # Step 5: Compile
    compile_source

    # Final success message
    echo "----------------------------------------------------"
    log_success "VanitySearch has been successfully installed!"
    log_info "The executable is located at: ${C_BOLD}$(pwd)/${PROJECT_DIR}/VanitySearch${C_RESET}"
    log_info "To run it, use a command like:"
    echo -e "  cd ${PROJECT_DIR}"
    echo -e "  ./VanitySearch -gpu 1MyPrefix"
    echo ""
    log_warn "SECURITY REMINDER: Always handle your generated private keys with extreme care. Store them offline and securely."
    echo "----------------------------------------------------"
}

# Run the main function
main
