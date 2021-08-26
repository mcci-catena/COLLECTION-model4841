#!/bin/bash

##############################################################################
#
# Name: build-with-cli.sh
#
# Function:
#   Build the model4841 firmware using the arduino-cli.
#
# Copyright:
#   See LICENSE.md in this collection.
#
# Author:
#   Terry Moore, MCCI Corporation   August 2021
#
##############################################################################

#
# to set up to use this:
#
#  1. Install arduino-cli from github using:
#
#       curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
#
#  2. If Ubuntu, use a 64-bit system, set up the 64-bit compiler, and then set up the 32-bit cross compile:
#
#       sudo dpkg --add-architecture i386
#       sudo apt install libc6-i386
#

##############################################################################
#   The code
##############################################################################

# exit if any errors encountered
set -e
PNAME="$(basename "$0")"
PDIR="$(dirname "$0")"
PROOT="$(realpath "$PDIR")"

#---- project settings -----
KEYFILE_DEFAULT="$(realpath "$PDIR/../keys/model4841-codesign.pem")"
readonly KEYFILE_DEFAULT

readonly ARDUINO_FQBN="mcci:stm32:mcci_catena_4630"

ARDUINO_OPTIONS="$(echo '
                    xserial=usbhwserial
                    sysclk=hsi16m
                    opt=osstd
                    lorawan_region=us915
                    lorawan_network=ttn
                    lorawan_subband=sb1
                    upload_method=STLink
                    boot=trusted
                    ' | xargs echo)"
readonly ARDUINO_OPTIONS

readonly ARDUINO_SOURCE=sketches/model4841-production-lorawan/model4841-production-lorawan.ino

readonly BOOTLOADER_NAME=McciBootloader_46xx

#---- common code ----
readonly PROOT
BSP_MCCI=$HOME/.arduino15/packages/mcci
BSP_CORE=$BSP_MCCI/hardware/stm32/
LOCAL_BSP_CORE="$PROOT/extra/Arduino_Core_STM32"
OUTPUT_ROOT="$PROOT/build"
OUTPUT="${OUTPUT_ROOT}/ide"
BSP_CORE_DIR=

function _help {
    less <<.
Build ${ARDUINO_SOURCE} using the arduino-cli tool.

Options:
    --clean does a clean prior to building.

    --verbose causes more info to be displayed.

    --test makes this a test-signing build (no use of private key)

    --key={file} gives the path to the public/private key files.
        The default is ${KEYFILE_DEFAULT}. The public file is
        found by changing "*.pem" to "*.pub.pem".

    --help prints this message.

    --script-debug prints more script debug info.
.
}

typeset -i OPTTESTSIGN=0
typeset -i OPTVERBOSE=0
typeset -i OPTCLEAN=0
typeset -i OPTDEBUG=0

OPTKEYFILE="${KEYFILE_DEFAULT}"

# make sure everything is clean
for opt in "$@"; do
    case "$opt" in
    "--clean" )
        rm -rf "$OUTPUT_ROOT"
        OPTCLEAN=1
        ;;
    "--verbose" )
        OPTVERBOSE=$((OPTVERBOSE + 1))
        if [[ $OPTVERBOSE -gt 1 ]]; then
            ARDUINO_CLI_FLAGS="${ARDUINO_CLI_FLAGS}${ARDUINO_CLI_FLAGS+ }-v"
        fi
        ;;
    "--script-debug" )
        OPTDEBUG=1
        ;;
    "--test" )
        OPTTESTSIGN=1
        ;;
    "--key="* )
        OPTKEYFILE="${opt#--key=}"
        ;;
    "--help" )
        _help
        exit 0
        ;;
    *)
        echo "not recognized: $opt -- use '--help' for help."
        exit 1
        ;;
    esac
done

if [[ ! -d "${OUTPUT}" ]]; then
    # the IDE hammers the specified directory; and we need other things here...
    # so make it a subdir of build.
    mkdir -p "${OUTPUT}"
fi

function _verbose {
    if [[ $OPTVERBOSE -ne 0 ]]; then
        echo "$@"
    fi
}

if [[ -d ~/Arduino/libraries ]]; then
    printf "%s\n" "Error: you have a ~/Arduino/libraries directory." \
                  "Please remove or hide it to use this script."
    exit 1
fi

#---- confirm that the BSP is well formed
function _count {
    echo $#
}

if [[ $(_count "$BSP_CORE"*) -gt 1 ]]; then
    echo "BSP not well-formed. Directory must have only one entry: ${BSP_CORE}"
    exit 1
fi
for i in "$BSP_CORE"* ; do
    if [[ ! -d "$i" ]]; then
        echo "BSP not well-formed; no version entry: ${BSP_CORE}"
        exit 1
    fi
    BSP_CORE_DIR="$i"
    break
done

#---- extract the version from the BSP
LOCAL_BSP_VERSION=$(awk '/^version=/ { printf("%s\n", substr($0,9)); exit(0) }' "${LOCAL_BSP_CORE}"/platform.txt)

if [[ "$LOCAL_BSP_VERSION" = "" ]]; then
    echo "local BSP malformed, check $LOCAL_BSP_CORE/platform.txt"
    exit 1
fi

# set up links to IDE
if [[ ! -d "$BSP_CORE" ]]; then
    echo "Not installed: $BSP_CORE"
    exit 1
fi

function _cleanup {
    [[ -f "$PRIVATE_KEY_UNLOCKED" ]] && shred -u "$PRIVATE_KEY_UNLOCKED"
    if [[ -h "$BSP_CORE/$LOCAL_BSP_VERSION" ]]; then
        _verbose "$PNAME: remove symbolic link"
        rm "$BSP_CORE/$LOCAL_BSP_VERSION"
    fi
    if [[ "$SAVE_BSP_CORE" != "" ]] && [[ -d "$SAVE_BSP_CORE" ]]; then
        _verbose "$PNAME: restore BSP"
        mv "$SAVE_BSP_CORE" "$BSP_CORE"/"$SAVE_BSP_VER"
    fi
    rm -f "$LOCAL_BSP_CORE"/platform.local.txt
}

function _errcleanup {
    _verbose "$PNAME: Build error: remove output files"
    rm -f "$OUTPUT"/*.elf "$OUTPUT"/*.bin "$OUTPUT"/*.hex "$OUTPUT"/*.dfu
}

trap '_cleanup' EXIT
trap '_errcleanup' ERR

# set up BSP
OLD_BSP_CORE="${BSP_CORE_DIR}"
if [[ ! -h "$OLD_BSP_CORE" ]] && [[ -d "$OLD_BSP_CORE" ]]; then
    _verbose "save and overlay BSP"
    SAVE_BSP_VER="$(basename "$OLD_BSP_CORE")"
    SAVE_BSP_CORE="$(dirname "$BSP_CORE")"/stm32-"$SAVE_BSP_VER"
    _verbose mv "$OLD_BSP_CORE" "$SAVE_BSP_CORE"
    mv "$OLD_BSP_CORE" "$SAVE_BSP_CORE"
    _verbose ln -s "$LOCAL_BSP_CORE" "$BSP_CORE"/"$LOCAL_BSP_VERSION"
    ln -s "$LOCAL_BSP_CORE" "$BSP_CORE"/"$LOCAL_BSP_VERSION"
    [[ $OPTDEBUG -ne 0 ]] && { printf "%s\n" "$BSP_CORE" ; ls -l "$BSP_CORE" ; }
elif [[ -h "$OLD_BSP_CORE" ]] ; then
    _verbose "replace existing BSP link"
    rm "$OLD_BSP_CORE"
    ln -s "$LOCAL_BSP_CORE"/"$LOCAL_BSP_VERSION" "$BSP_CORE"/
else
    _verbose "link BSP core"
    ln -s "$LOCAL_BSP_CORE"/"$LOCAL_BSP_VERSION" "$BSP_CORE"/
fi

# check tools
BSP_CROSS_COMPILE="$(printf "%s" "$BSP_MCCI"/tools/arm-none-eabi-gcc/*)"/bin/arm-none-eabi-
if [[ ! -x "$BSP_CROSS_COMPILE"gcc ]]; then
    echo "Toolchain not found: $BSP_CROSS_COMPILE"
    exit 1
fi

# set up private key
if [[ $OPTTESTSIGN -eq 0 ]]; then
    if [[ ! -r "${OPTKEYFILE}" ]]; then
        echo "Can't find project key file: ${OPTKEYFILE} -- did you do git clone --recursive?"
        exit 1
    fi
    PRIVATE_KEY_LOCKED="$(realpath "${OPTKEYFILE}")"
    PRIVATE_KEY_UNLOCKED_DIR="${OUTPUT_ROOT}/key.d"
    if [[ ! -d "${PRIVATE_KEY_UNLOCKED_DIR}" ]]; then
        _verbose make key directory "${PRIVATE_KEY_UNLOCKED_DIR}"
        mkdir "${PRIVATE_KEY_UNLOCKED_DIR}"
    fi
    PRIVATE_KEY_UNLOCKED="$(realpath "${PRIVATE_KEY_UNLOCKED_DIR}"/"$(basename "${PRIVATE_KEY_LOCKED/%.pem/.tmp.pem}")")"
    chmod 700 "${PRIVATE_KEY_UNLOCKED_DIR}"
    _verbose "Unlocking private key:"
    rm -f "${PRIVATE_KEY_UNLOCKED}"                     # remove old
    touch "${PRIVATE_KEY_UNLOCKED}"                     # create new
    chmod 600 "${PRIVATE_KEY_UNLOCKED}"                 # fix permissions
    cat "$PRIVATE_KEY_LOCKED" >"$PRIVATE_KEY_UNLOCKED"  # copy encrypted key (preserving permissions)
    ssh-keygen -p -N '' -f "$PRIVATE_KEY_UNLOCKED"      # decrypt key (ssh-keygen is careful with permissions)

    # set up Arduino IDE to use the key
    printf "%s\n" mccibootloader_keys.path="$(dirname "$PRIVATE_KEY_UNLOCKED")" mccibootloader_keys.test="$(basename "$PRIVATE_KEY_UNLOCKED")" > "$LOCAL_BSP_CORE"/platform.local.txt

    # set input key path for signing bootloader
    KEYFILE="${PRIVATE_KEY_UNLOCKED}"
else
    _verbose "** using test key **"
    rm -rf "$LOCAL_BSP_CORE"/platform.local.txt

    # set input key pay for signing bootloader
    KEYFILE="$(realpath extra/bootloader/tools/mccibootloader_image/test/mcci-test.pem)"
fi

# do a build
_verbose "Building sketch"

# we want ARDUINO_CLI_FLAGS to be parsed...
# shellcheck disable=2086 
_verbose arduino-cli compile $ARDUINO_CLI_FLAGS \
    -b "${ARDUINO_FQBN}":"${ARDUINO_OPTIONS//[[:space:]]/,}" \
    --build-path "$OUTPUT" \
    --libraries libraries \
    "${ARDUINO_SOURCE}"

# shellcheck disable=2086 
arduino-cli compile $ARDUINO_CLI_FLAGS \
    -b "${ARDUINO_FQBN}":"${ARDUINO_OPTIONS//[[:space:]]/,}" \
    --build-path "$OUTPUT" \
    --libraries libraries \
    "${ARDUINO_SOURCE}"

# build & sign the bootloader
_verbose "Building mccibootloader_image"

if [[ $OPTCLEAN -ne 0 ]]; then
    make -C extra/bootloader/tools/mccibootloader_image clean
fi
make -C extra/bootloader/tools/mccibootloader_image all

_verbose "Building and signing bootloader"
MCCIBOOTLOADER_IMAGE_FLAGS_ARG=
if [[ $OPTVERBOSE -ne 0 ]]; then
    MCCIBOOTLOADER_IMAGE_FLAGS_ARG="MCCIBOOTLOADER_IMAGE_FLAGS=-v"
fi
if [[ $OPTCLEAN -ne 0 ]]; then
    CROSS_COMPILE="${BSP_CROSS_COMPILE}" make -C extra/bootloader clean MCCI_BOOTLOADER_KEYFILE="$KEYFILE" ${MCCIBOOTLOADER_IMAGE_FLAGS_ARG}
fi
CROSS_COMPILE="${BSP_CROSS_COMPILE}" make -C extra/bootloader all MCCI_BOOTLOADER_KEYFILE="$KEYFILE" ${MCCIBOOTLOADER_IMAGE_FLAGS_ARG}

# copy bootloader images to output dir
_verbose "Save bootloader"
cp -p extra/bootloader/build/arm-none-eabi/release/${BOOTLOADER_NAME}.* "$OUTPUT"

# combine hex images to simplify download
_verbose "Combine bootloader and app"

# all lines but the last, then append the main app
ARDUINO_SOURCE_BASE="$(basename ${ARDUINO_SOURCE} .ino)"
head -n-1 "$OUTPUT"/${BOOTLOADER_NAME}.hex | cat - "$OUTPUT"/"${ARDUINO_SOURCE_BASE}".ino.hex > "$OUTPUT"/"${ARDUINO_SOURCE_BASE}"-bootloader.hex

# make a packed DFU variant
_verbose "Make a packed DFU variant"
pip3 install IntelHex
python3 extra/dfu-util/dfuse-pack.py -i "$OUTPUT"/${BOOTLOADER_NAME}.hex -i "$OUTPUT"/"${ARDUINO_SOURCE_BASE}".ino.hex -D 0x040e:0x00a1 "$OUTPUT"/"${ARDUINO_SOURCE_BASE}"-bootloader.dfu

# all done
_verbose "done"
exit 0
