#!/bin/zsh
# Publishes a new Papiro version on GitHub. Usage: ./release.sh 1.0.1 qeydler.txt
#   - sets the version in Info.plist (and raises the build number), commits that locally;
#   - builds, makes Papiro.dmg (for people: drag Papiro to Applications), Papiro.zip and Papiro.zip.sha256
#     (for the updater inside Papiro);
#   - puts the current code on GitHub as one new commit on top of GitHub's main (the local history stays here;
#     the author is GitHub's noreply address);
#   - creates the release vX.Y with the notes from the file; Papiro on every Mac offers it from then on.
set -e
cd "$(dirname "$0")"
REPO=azadaydinli/Papiro
V=$1
NOTES=$2
[[ -n $V && -f $NOTES ]] || { echo "İstifadə: ./release.sh 1.0.1 qeydler.txt"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Əvvəlcə dəyişiklikləri commit edin."; exit 1; }
gh release view "v$V" -R $REPO >/dev/null 2>&1 && { echo "v$V artıq var."; exit 1; }

# version
plutil -replace CFBundleShortVersionString -string "$V" Info.plist
BUILD=$(( $(plutil -extract CFBundleVersion raw Info.plist) + 1 ))
plutil -replace CFBundleVersion -string "$BUILD" Info.plist
git commit -q -m "Versiya $V" Info.plist

# build and package
./build.sh
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
ditto -c -k --keepParent build.noindex/Papiro.app "$OUT/Papiro.zip"
shasum -a 256 "$OUT/Papiro.zip" | cut -d' ' -f1 > "$OUT/Papiro.zip.sha256"
mkdir "$OUT/dmg"
ditto build.noindex/Papiro.app "$OUT/dmg/Papiro.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Papiro $V" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO "$OUT/Papiro.dmg"

# code on GitHub: this tree as one commit after GitHub's main (no force push, local history not sent)
GH_GIT=(-c credential.helper= -c "credential.helper=!gh auth git-credential")
git "${GH_GIT[@]}" fetch -q "https://github.com/$REPO.git" main
NOREPLY="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
NAME="$(gh api user --jq '.login')"
COMMIT=$(GIT_AUTHOR_NAME=$NAME GIT_AUTHOR_EMAIL=$NOREPLY GIT_COMMITTER_NAME=$NAME GIT_COMMITTER_EMAIL=$NOREPLY \
         git commit-tree "HEAD^{tree}" -p FETCH_HEAD -m "Papiro $V")
git "${GH_GIT[@]}" push -q "https://github.com/${REPO}.git" "${COMMIT}:refs/heads/main"   # braces: zsh reads "$X:r" as a modifier

# release
gh release create "v$V" "$OUT/Papiro.dmg" "$OUT/Papiro.zip" "$OUT/Papiro.zip.sha256" \
   -R $REPO --target "$COMMIT" --title "Papiro $V" --notes-file "$NOTES"
git tag "v$V"
echo "Hazırdır: https://github.com/$REPO/releases/tag/v$V"
