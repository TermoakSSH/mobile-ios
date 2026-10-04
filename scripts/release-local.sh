#!/usr/bin/env bash
# Builds and publishes the iOS app without GitHub Actions, with the version in
# project.yml (MARKETING_VERSION), as the ios-vX.Y.Z release: an unsigned .ipa
# that users sign with their own certificate.
#
#   scripts/release-local.sh status
#   scripts/release-local.sh version ios [X.Y.Z]
#   scripts/release-local.sh build ios
#   scripts/release-local.sh publish ios
#
# version also increments CURRENT_PROJECT_VERSION (the build number).
#
# build runs scripts/build-ipa.sh (Mac only): the engine comes from the core/
# submodule (core/scripts/build-ios.sh) and the .ipa goes to dist/ios/.
#
# publish creates the <component>-vX.Y.Z release with the contents of
# dist/<component>/, using the GitHub API (curl, no `gh`). It is created as a
# draft and published once all files are uploaded. If the release already
# exists, the files are added to it.
# The release can be created empty on any machine (without a build) and the
# .ipa added later from the Mac (build ios and publish ios again).
#
# Variables:
#   GITHUB_TOKEN  GitHub token (publish and download). If unset, it is read
#                 from ~/.config/termoak/github-token. Fine-grained, with access to
#                 the TermoakSSH repositories, Contents: Read and write (and
#                 Actions: Read for download)
#   REPO          owner/repository (default: TermoakSSH/mobile-ios)
#   COMMIT        commit to tag (default: HEAD)
#   VERSION       version for download and publish (default: the manifest's)
#
# Compatible with macOS's bash 3.2.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

COMPONENTS="ios"

# --- components ---------------------------------------------------------------

manifest_of() { # component
  case "$1" in
    ios) echo project.yml ;;
    *) die "unknown component: ${1:-} (ios)" ;;
  esac
}

title_of() { echo iOS; }

# What the app is built from (for `status`): core is the submodule.
paths_of() { echo "Termoak UITests project.yml scripts/build-ipa.sh core"; }

version_of() { # component
  local v
  v="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' project.yml | head -1)"
  [[ -n "$v" ]] || die "project.yml has no MARKETING_VERSION: \"X.Y.Z\" line"
  echo "$v"
}

# A component's latest published tag.
last_tag_of() { git tag -l "$1-v*" --sort=-v:refname | head -1; }

# Component and version from the command line. In build, `version` and `tag`
# always come from the manifest; in download and publish they can be changed
# with VERSION (e.g. for binaries from an earlier release.yml run).
select_component() { # component command
  component="${1:-}"
  [[ -n "$component" ]] || die "missing component: ios"
  manifest_of "$component" >/dev/null
  version="$(version_of "$component")"
  if [[ -n "${VERSION:-}" && "$2" != build ]]; then
    version="${VERSION#v}"
  fi
  tag="$component-v$version"
  dist="$root/dist/$component"
}

# --- status and version -------------------------------------------------------

cmd_status() {
  git fetch -q --tags origin 2>/dev/null || true
  printf '%-9s %-9s %-16s %s\n' component version 'latest tag' 'commits since'
  local c v last n note
  for c in $COMPONENTS; do
    v="$(version_of "$c")"
    last="$(last_tag_of "$c")"
    note=""
    if [[ -z "$last" ]]; then
      last="-"
      n="$(git rev-list --count HEAD)"
    else
      # shellcheck disable=SC2046
      n="$(git rev-list --count "$last..HEAD" -- $(paths_of "$c"))"
    fi
    if [[ "$n" != 0 ]] && git rev-parse -q --verify "refs/tags/$c-v$v" >/dev/null; then
      note="  (v$v already published: bump the version before publishing)"
    fi
    printf '%-9s %-9s %-16s %s%s\n' "$c" "$v" "$last" "$n" "$note"
  done
}

cmd_version() { # component [X.Y.Z]
  select_component "${1:-}" version
  local new="${2:-}" file
  if [[ -z "$new" ]]; then
    echo "$version"
    return
  fi
  new="${new#v}"
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "\"$new\" is not an X.Y.Z version"
  [[ "$new" != "$version" ]] || die "$component is already at $new"
  file="$(manifest_of "$component")"
  # CURRENT_PROJECT_VERSION (the build number) goes up with every version.
  awk -v v="$new" '
    /^ *MARKETING_VERSION:/ { sub(/".*"/, "\"" v "\"") }
    /^ *CURRENT_PROJECT_VERSION:/ { match($0, /"[0-9]+"/); n = substr($0, RSTART + 1, RLENGTH - 2) + 1; sub(/"[0-9]+"/, "\"" n "\"") }
    { print }' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  say "$component: $version → $new ($file)"
}

# --- build --------------------------------------------------------------------

cmd_build() { # ios
  select_component "${1:-}" build
  rm -rf "$dist"
  scripts/build-ipa.sh
  echo "$tag" >"$dist/.version"
  say "Done: $tag in dist/ios/"
  ls -l "$dist"
}

# --- GitHub API (curl) --------------------------------------------------------

github_setup() {
  command -v curl >/dev/null || die "curl is missing"
  command -v python3 >/dev/null || die "python3 is missing (needed to read GitHub's JSON responses)"
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/termoak/github-token"
  github_token="${GITHUB_TOKEN:-}"
  if [[ -z "$github_token" && -f "$file" ]]; then
    github_token="$(tr -d '[:space:]' <"$file")"
  fi
  [[ -n "$github_token" ]] ||
    die "the GitHub token is missing: GITHUB_TOKEN or $file (fine-grained, Contents: Read and write)"
  # This repository; REPO=owner/repository publishes somewhere else (a fork).
  repo="${REPO:-TermoakSSH/mobile-ios}"
  [[ "$repo" == */* ]] || die "cannot tell which repository this is: set REPO=owner/repository"
}

# Calls the API. Leaves the response in api_body and the HTTP status in api_status.
github() { # method path-or-url [curl arguments...]
  local method="$1" url="$2" out
  shift 2
  [[ "$url" == https://* ]] || url="https://api.github.com$url"
  # -L: GitHub redirects downloads to its storage (curl does not forward the
  # token to another domain).
  out="$(curl -sS -L -X "$method" -w '\n%{http_code}' \
    -H "Authorization: Bearer $github_token" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@" "$url")" || die "could not connect to GitHub"
  api_status="${out##*$'\n'}"
  api_body="${out%$'\n'*}"
}
# Like github(), but stops if GitHub answers with an error.
github_ok() { # what-we-were-doing method path [curl arguments...]
  local what="$1"
  shift
  github "$@"
  if [[ "$api_status" != 2* ]]; then
    printf '%s\n' "$api_body" >&2
    die "GitHub answered $api_status when trying to $what"
  fi
}
# Python expression over the JSON response (in `d`).
json() {
  printf '%s' "$api_body" | python3 -c "import json, sys; d = json.load(sys.stdin); v = $1; print('' if v is None else v)"
}
# JSON object from key value pairs. `draft` is a boolean; everything else is
# a string (make_latest too: the API expects "true" or "false").
json_object() {
  python3 -c '
import json, sys
a = sys.argv[1:]
print(json.dumps({k: (v == "true") if k == "draft" else v for k, v in zip(a[::2], a[1::2])}))' "$@"
}

# --- publish ------------------------------------------------------------------

cmd_publish() { # component
  select_component "${1:-}" publish
  local commit existing=0 file files=() prev latest id asset_id
  [[ -z "${2:-}" ]] || die "unknown option: $2"
  local empty=0
  if [[ "$(cat "$dist/.version" 2>/dev/null)" != "$tag" ]]; then
    [[ "$component" == ios ]] ||
      die "dist/$component/ does not hold $tag: run scripts/release-local.sh build $component first"
    empty=1
  fi
  github_setup

  github GET "/repos/$repo/releases/tags/$tag"
  if [[ "$api_status" == 200 ]]; then
    existing=1
    id="$(json 'd["id"]')"
    say "Release $tag already exists: adding the files"
  elif [[ "$api_status" != 404 ]]; then
    printf '%s\n' "$api_body" >&2
    die "GitHub answered $api_status when looking up release $tag (does the token have access to the repository?)"
  else
    commit="${COMMIT:-$(git rev-parse HEAD)}"
    git fetch -q --tags origin 2>/dev/null || true
    [[ -n "$(git branch -r --contains "$commit" 2>/dev/null)" ]] ||
      die "commit $commit is not on GitHub: push it first (git push)"
  fi


  # latest.json goes last: it never points to a file that is not there yet.
  if [[ $empty == 0 ]]; then
    for file in "$dist"/*; do
      [[ -f "$file" && "$(basename "$file")" != latest.json ]] && files+=("$file")
    done
    [[ -f "$dist/latest.json" ]] && files+=("$dist/latest.json")
    [[ ${#files[@]} -gt 0 ]] || die "nothing to publish in dist/$component/"
  else
    [[ $existing == 0 ]] || die "release $tag already exists: build the .ipa on a Mac (build ios) to add it"
    say "No .ipa: release $tag is created empty"
  fi

  if [[ $existing == 0 ]]; then
    # An earlier attempt that failed halfway leaves a draft: reuse it.
    github_ok "look for drafts" GET "/repos/$repo/releases?per_page=100"
    id="$(json "next((r['id'] for r in d if r['draft'] and r['tag_name'] == '$tag'), None)")"
  fi
  if [[ $existing == 0 && -n "$id" ]]; then
    say "Found a draft of $tag from an earlier attempt: completing it"
  elif [[ $existing == 0 ]]; then
    # Notes since the previous version of this same component.
    prev="$(last_tag_of "$component")"
    if [[ -n "$prev" && "$prev" != "$tag" ]]; then
      github_ok "generate the notes" POST "/repos/$repo/releases/generate-notes" \
        -d "$(json_object tag_name "$tag" target_commitish "$commit" previous_tag_name "$prev")"
    else
      github_ok "generate the notes" POST "/repos/$repo/releases/generate-notes" \
        -d "$(json_object tag_name "$tag" target_commitish "$commit")"
    fi
    say "Creating release $tag in $repo ($commit) as a draft"
    github_ok "create the release" POST "/repos/$repo/releases" \
      -d "$(json_object tag_name "$tag" target_commitish "$commit" \
        name "$(title_of "$component") $version" body "$(json 'd["body"]')" draft true)"
    id="$(json 'd["id"]')"
  fi

  for file in ${files[@]+"${files[@]}"}; do
    # If one with that name already exists (existing release), it is replaced.
    github_ok "read the release" GET "/repos/$repo/releases/$id"
    asset_id="$(json "next((a['id'] for a in d['assets'] if a['name'] == '$(basename "$file")'), None)")"
    if [[ -n "$asset_id" ]]; then
      github_ok "delete $(basename "$file")" DELETE "/repos/$repo/releases/assets/$asset_id"
    fi
    echo "  uploading $(basename "$file")"
    github_ok "upload $(basename "$file")" POST \
      "https://uploads.github.com/repos/$repo/releases/$id/assets?name=$(basename "$file")" \
      -H "Content-Type: application/octet-stream" --data-binary "@$file"
  done

  if [[ $existing == 0 ]]; then
    latest=true
    github_ok "publish the release" PATCH "/repos/$repo/releases/$id" \
      -d "$(json_object draft false make_latest "$latest")"
  fi
  say "Published $tag: https://github.com/$repo/releases/tag/$tag"
}

# With exit in every branch bash does not read this file again: it can be
# edited (or git pulled) while it builds.
case "${1:-}" in
  status) cmd_status; exit ;;
  version) shift; cmd_version "$@"; exit ;;
  build) shift; cmd_build "$@"; exit ;;
  publish) shift; cmd_publish "$@"; exit ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 1 ;;
esac
