#!/bin/sh
FOLDER="SceatMulti_${1}"
mkdir $FOLDER
cp -r locale src control.lua info.json $FOLDER/
zip -r $FOLDER.zip $FOLDER
rm -rf $FOLDER