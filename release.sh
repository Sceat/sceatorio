#!/bin/sh
VERSION=$1
FILE="info.json"

echo "releasing sceatorio:$VERSION
"
echo ">> cleaning up.."
rm $FILE

echo ">> generating $FILE"
/bin/cat <<EOM >$FILE
{
    "name": "Sceatorio",
    "version": "$VERSION",
    "title": "Sceatorio",
    "author": "Sceat",
    "contact": "@Sceat_",
    "homepage": "",
    "factorio_version": "0.18",
    "dependencies": ["base >= 0.18"],
    "description": "# Sceatorio\nA multiplayer pve/pvp factorio mod\n>  factorio v0.18.5\n## Features\n- When joining the game you get your own force and your own spawn with starting resources (remake of oarc)\n- Death messages, Researchs and chat is shared across teams\n- PvP is enabled, that prevent griefing and stealing and allow turrets to kill other players\n- When a player is offline, his buildings can't be destroyed, and enemies will stop targeting his base\n- When a player is online, everyone can see him and his position (it's friendly after all, go solo if you don't want too see anyone)\n- Real time player list\n## Todo\n- Protect electricity\n## Build mod\n"
}
EOM

echo ">> pushing $FILE"
git add .
git commit -m "preparing $FILE for sceatorio:$VERSION release"
git push
echo ">> pushing tags"
git tag $VERSION
git push --tags