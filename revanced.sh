#!/bin/bash
UserAgent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36"

req() {
    wget -U "$UserAgent" -nv -O "$1" "$2"
}

basename() {
    sed 's/.*\///' | sed 's/\.[^.]*$//'
}

download_resources() {
    local revancedApiUrl="https://releases.revanced.app/tools"
    local response=$(req - 2>/dev/null "$revancedApiUrl")

    local assetUrls=$(echo "$response" | jq -r '.tools[] | select(.name | test("revanced-(patches|cli).*jar$|revanced-integrations.*apk$")) | .browser_download_url, .name')

    while read -r downloadUrl && read -r assetName; do
        req "$assetName" "$downloadUrl" 
    done <<< "$assetUrls"
}

download_youtube_apk() {
    json=$(req - "https://api.revanced.app/v2/patches/latest")
    version=$(echo $json | jq -r '.. | objects | select(.name == "com.google.android.youtube" and .versions != null) | .versions[-2]' | uniq)
    url="https://www.apkmirror.com/apk/google-inc/youtube/youtube-${version//./-}-release"
    url=$(req - "$url" | pup -p --charset utf-8 ':parent-of(:parent-of(span:contains("APK")))' | pup -p --charset utf-8 'a.accent_color attr{href}')
    url=$(req - "https://www.apkmirror.com$url" | pup -p --charset utf-8 'a.downloadButton attr{href}')
    url=$(req - "https://www.apkmirror.com$url" | pup -p --charset utf-8 'a[data-google-vignette="false"][rel="nofollow"] attr{href}')
    url="https://www.apkmirror.com${url}" 
    req youtube-v$version.apk "$url"
}

apply_patches() {    
    # Read patches from file
    mapfile -t lines < ./etc/patches.txt

    # Process patches
    for line in "${lines[@]}"; do
        if [[ -n "$line" && ( ${line:0:1} == "+" || ${line:0:1} == "-" ) ]]; then
            patch_name=$(sed -e 's/^[+|-] *//;s/ *$//' <<< "$line") 
            [[ ${line:0:1} == "+" ]] && includePatches+=("--include" "$patch_name")
            [[ ${line:0:1} == "-" ]] && excludePatches+=("--exclude" "$patch_name")
        fi
    done
    
    # Apply patches using Revanced tools
    java -jar revanced-cli*.jar patch \
        --merge revanced-integrations*.apk \
        --patch-bundle revanced-patches*.jar \
        "${excludePatches[@]}" "${includePatches[@]}" \
        --out "patched-youtube-v$version.apk" \
        "youtube-v$version.apk"
}

sign_patched_apk() {    
    # Sign the patched APK
    apksigner=$(find $ANDROID_SDK_ROOT/build-tools -name apksigner -type f | sort -r | head -n 1)
    $apksigner sign --verbose \
        --ks ./etc/public.jks \
        --ks-key-alias public \
        --ks-pass pass:public \
        --key-pass pass:public \
        --in "patched-youtube-v$version.apk" \
        --out "youtube-revanced-v$version.apk"
}

create_github_release() {
    local tagName=$(date +"%d-%m-%Y")
    local patchFilePath=$(find . -type f -name "revanced-patches*.jar")
    local apkFilePath=$(find . -type f -name "youtube-revanced*.apk")
    local patchFileName=$(echo "$patchFilePath" | basename)
    local apkFileName=$(echo "$apkFilePath" | basename).apk

    # Only release with APK file
    if [ ! -f "$apkFilePath" ]; then
        exit
    fi

    # Check if the release with the same tag already exists
    local existingRelease=$(wget -qO- --header="Authorization: token $accessToken" "https://api.github.com/repos/$repoOwner/$repoName/releases/tags/$tagName")

    if [ -n "$existingRelease" ]; then
        local existingReleaseId=$(echo "$existingRelease" | jq -r ".id")

        # If the release exists, delete it
        wget -q --method=DELETE --header="Authorization: token $accessToken" "https://api.github.com/repos/$repoOwner/$repoName/releases/$existingReleaseId" -O /dev/null
    fi

    # Create a new release
    local releaseData='{
        "tag_name": "'"$tagName"'",
        "target_commitish": "main",
        "name": "Release '"$tagName"'",
        "body": "'"$patchFileName"'"
    }'
    local newRelease=$(wget -qO- --post-data="$releaseData" --header="Authorization: token $accessToken" --header="Content-Type: application/json" "https://api.github.com/repos/$repoOwner/$repoName/releases")
    local releaseId=$(echo "$newRelease" | jq -r ".id")

    # Upload APK file
    local uploadUrlApk="https://uploads.github.com/repos/$repoOwner/$repoName/releases/$releaseId/assets?name=$apkFileName"
    wget -q --header="Authorization: token $accessToken" --header="Content-Type: application/zip" --post-file="$apkFilePath" -O /dev/null "$uploadUrlApk"
}

check_release_body() {
    # Compare body content with downloaded patch file name
    if [ "$scriptRepoBody" != "$downloadedPatchFileName" ]; then
        return 0
    else
        return 1
    fi
}

# Main script 
accessToken=$GITHUB_TOKEN
repoName=$GITHUB_REPOSITORY_NAME
repoOwner=$GITHUB_REPOSITORY_OWNER

# Perform download_repository_assets
download_resources

# Get the body content of the script repository release
scriptRepoLatestRelease=$(wget -nv -O- 2>/dev/null "https://api.github.com/repos/$repoOwner/$repoName/releases/latest" --header="Authorization: token $accessToken" || true)
scriptRepoBody=$(echo "$scriptRepoLatestRelease" | jq -r '.body')

# Get the downloaded patch file name
downloadedPatchFileName=$(ls -1 revanced-patches*.jar | basename)

# Patch if no release
if [ -z "$scriptRepoBody" ]; then
    download_youtube_apk
    apply_patches
    sign_patched_apk 
    create_github_release 
    exit 0
fi

# Check if the body content matches the downloaded patch file name
if check_release_body ; then
    download_youtube_apk
    apply_patches
    sign_patched_apk
    create_github_release
else
    echo -e "\e[91mSkipping because patched\e[0m"
fi
