#!/bin/sh
# local_test.sh

# Set your Factorio mods directory here
FACTORIO_MODS_DIR=~/Library/Application\ Support/Factorio/mods

# Get the version from the command line argument
VERSION=$1

# Ensure version is provided
if [ -z "$VERSION" ]
then
    echo "Error: Version not provided. Usage: sh local_test.sh [version]"
    exit 1
fi

# Set file name
FILE=info.json

# Generate info.json
/bin/cat <<EOM >$FILE
{
    "name": "Sceatorio",
    "version": "$VERSION",
    "title": "Sceatorio",
    "author": "Sceat",
    "contact": "@Sceat_",
    "homepage": "",
    "factorio_version": "1.1",
    "dependencies": ["base >= 1.1.21"],
    "description": "Separated spawn for a vanilla multiplayer experience, play with your friends without worrying for grief or resources stealing while offline"
}
EOM

# Mod name with version for directory name
MOD_NAME=Sceatorio_$VERSION

# Removing previous versions from Factorio mods directory
rm -r "$FACTORIO_MODS_DIR/Sceatorio_"*

# Ensure the destination folder does not already exist
if [ -d "$FACTORIO_MODS_DIR/$MOD_NAME" ]; then
    rm -r "$FACTORIO_MODS_DIR/$MOD_NAME"
fi

# Moving/Copying the mod directory to Factorio mod directory
# Using rsync to exclude .git and shell script itself
rsync -a --exclude='.git' --exclude='local_test.sh' ./ "$FACTORIO_MODS_DIR/$MOD_NAME"

echo "Mod $MOD_NAME has been copied to $FACTORIO_MODS_DIR"
