#!/usr/bin/env bash
# Installs what tools/build_sdl3.sh needs on Debian and Ubuntu: CMake, Ninja, a C compiler, and the dev packages of the
# libraries SDL loads at run time (their headers only: SDL dlopens them). On other distributions, see the README.
#
#   tools/install_build_deps.sh

set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
	build-essential cmake ninja-build pkg-config \
	libwayland-dev wayland-protocols libdecor-0-dev libxkbcommon-dev \
	libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxtst-dev \
	libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev \
	libasound2-dev libpulse-dev libpipewire-0.3-dev \
	libudev-dev libusb-1.0-0-dev libdbus-1-dev libibus-1.0-dev
