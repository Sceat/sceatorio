#!/bin/sh
VERSION="0.18.7"
FOLDER="SceatMulti_${VERSION}"

mkdir $FOLDER
cp -r locale src control.lua info.json $FOLDER/
zip -r $FOLDER.zip $FOLDER
rm -rf $FOLDER