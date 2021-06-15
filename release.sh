#!/bin/sh
VERSION=$1
FILE=info.json

echo "
releasing sceatorio:$VERSION
"
echo "
>> cleaning up..
"
rm $FILE

echo "
>> generating $FILE
"
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

echo "
>> pushing $FILE
"
git add .
git commit -m "sceatorio:$VERSION release"
git push
echo "
>> pushing tags
"
git tag $VERSION
git push --tags