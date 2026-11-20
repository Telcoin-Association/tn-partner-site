#!/usr/bin/env bash
# build-site.sh <src> <out>
#
# Builds the run.telcoin.network site from the partner PDFs committed in a
# tn-node-deployment checkout. <src> is the root of that checkout and is only
# read. Every file the build reads from it must hold exactly the bytes HEAD
# records, so the site is a function of HEAD and source.txt names that commit.
# <out> must not exist or must be an empty directory. The site is built in a
# temporary sibling of <out> and moved into place only after every check
# passed, so a failed run leaves no <out>.
#
# Exit codes: 0 built, 1 a gate failed, 2 usage or environment error.
set -euo pipefail
export LC_ALL=C
# A relative cd below must not search CDPATH.
unset CDPATH

readonly BASE_URL="https://run.telcoin.network"
readonly SOURCE_REPO="https://github.com/Telcoin-Association/tn-node-deployment"

# The documents in landing order. STEMS[i] is the directory under docs/partner
# and the file stem; ALIASES[i] is the short link.
readonly STEMS=(testnet-node-requirements mainnet-node-requirements mno-node-guide technical-specification)
readonly ALIASES=(testnet mainnet guide spec)

# Shared assets, as "<path under docs/partner/assets> <path in the site>".
readonly LOGO=logos/telcoin-network-light.svg
readonly ASSETS=(
    "fonts/geist/Geist-Regular.woff2 assets/fonts/Geist-Regular.woff2"
    "fonts/geist/Geist-SemiBold.woff2 assets/fonts/Geist-SemiBold.woff2"
    "fonts/geist/LICENSE.txt assets/fonts/LICENSE.txt"
    "fonts/geist/OFL.txt assets/fonts/OFL.txt"
    "$LOGO assets/telcoin-network.svg"
)
# Gate 1: the SHA-256 of the reviewed logo. The site serves the SVG from its own
# origin and an SVG can carry script, so only the reviewed file is published.
# After a logo change in tn-node-deployment, review the new file and put its
# sha256sum here.
readonly LOGO_SHA256=3094cdd0523665d8548737ac40e299c1ecd36670a9b002f7f30d87868fa2b528

# Gate 6: the exact file list of the built site, sorted as `LC_ALL=C sort` does.
readonly EXPECTED_FILES="404.html
assets/fonts/Geist-Regular.woff2
assets/fonts/Geist-SemiBold.woff2
assets/fonts/LICENSE.txt
assets/fonts/OFL.txt
assets/telcoin-network.svg
guide/index.html
index.html
mainnet-node-requirements.pdf
mainnet/index.html
mno-node-guide.pdf
robots.txt
source.txt
spec/index.html
style.css
technical-specification.pdf
testnet-node-requirements.pdf
testnet/index.html"

readonly VERSION_RE='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
readonly DATE_RE='^(January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{4}$'

usage() {
    printf 'usage: %s <src> <out>\n' "${0##*/}" >&2
    printf '  <src>  root of a tn-node-deployment git checkout (read only)\n' >&2
    printf '  <out>  directory to create; must not exist or be empty\n' >&2
    exit 2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

failures=0
fail() {
    printf 'error: gate %s: %s\n' "$1" "$2" >&2
    failures=$((failures + 1))
}

# ---- helpers ------------------------------------------------------------------

# meta FILE KEY: the scalar value of top-level KEY in a flat YAML file, without
# quotes or a trailing comment; nothing when KEY is absent. Same awk as _meta in
# tn-node-deployment tools/build-partner-pdf.sh.
meta() {
    awk -v k="$2" 'index($0, k ":") == 1 {
        v = substr($0, length(k) + 2); sub(/[[:space:]]+#.*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
        print v; exit }' "$1"
}

# headings FILE: the text of each "# " heading outside fenced code blocks, one
# per line. Fences are found as _fenced_lines in build-partner-pdf.sh finds them.
headings() {
    awk '
        /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
        !infence && /^# / {
            t = substr($0, 3); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); print t
        }
    ' "$1"
}

# html TEXT: TEXT escaped for HTML text and attribute values. The replacements
# are quoted because bash 5.2 expands an unquoted & in them to the matched text.
html() {
    local s=$1
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    s=${s//\"/"&quot;"}
    s=${s//\'/"&#39;"}
    printf '%s' "$s"
}

# human_size BYTES: a size for people, in decimal units (kB, MB).
human_size() {
    awk -v b="$1" 'BEGIN {
        if (b < 1000) { printf "%d bytes", b; exit }
        k = int(b / 1000 + 0.5)
        if (k < 1000) printf "%d kB", k
        else printf "%.1f MB", b / 1000000 }'
}

# git_src ARGS...: git in <src>. The script runs only rev-parse and
# hash-object --no-filters there; neither reads the index nor applies a filter,
# so nothing configured in <src> runs. No replace refs, so the objects named are
# the real ones. No transport (GIT_ALLOW_PROTOCOL=none), so a partial clone
# cannot fetch and no command configured as a remote can run. No optional locks
# and no fsmonitor hook as a second guard.
git_src() {
    GIT_ALLOW_PROTOCOL=none git -C "$src" --no-replace-objects -c core.fsmonitor=false --no-optional-locks "$@"
}

# ---- arguments and environment ----------------------------------------------------

[[ $# -eq 2 ]] || usage
src=$1
out=${2%/}
[[ -n $src && -n $out ]] || usage

for tool in git pdftotext sha256sum awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed"
done

if [[ -L $out ]]; then
    die "$out is a symbolic link; name a directory that does not exist or is empty"
elif [[ -e $out && ! -d $out ]]; then
    die "$out exists and is not a directory"
elif [[ -d $out && -n $(ls -A -- "$out") ]]; then
    die "$out is not empty; the build never overwrites or deletes it"
fi
out_parent=$(dirname -- "$out")
[[ -d $out_parent ]] || die "parent directory of $out does not exist"
out_parent=$(cd -- "$out_parent" && pwd -P) || die "cannot enter $out_parent"
# From here on <src> is absolute: awk reads a relative file operand shaped like
# v=1/... as a variable assignment.
if [[ -d $src ]]; then
    src=$(cd -- "$src" && pwd -P) || die "cannot enter $src"
    [[ $out_parent/ != "$src"/* ]] || die "$out is inside $src; the build never writes under <src>"
fi

site_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for f in index.html style.css 404.html robots.txt; do
    [[ -f $site_dir/site/$f ]] || die "missing $site_dir/site/$f"
done
for p in DOCS SOURCE; do
    n=$(awk -v p="@@${p}@@" '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "") } $0 == p { n++ } END { print n + 0 }' "$site_dir/site/index.html")
    [[ $n -eq 1 ]] || die "site/index.html must hold @@${p}@@ once, alone on a line (found $n)"
done

work=$(mktemp -d)
tmp=""
cleanup() {
    rm -rf -- "$work"
    if [[ -n $tmp ]]; then rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

# ---- gates 0-5: the source --------------------------------------------------------

partner=$src/docs/partner

# Gate 0. Without docs/partner nothing else can be checked.
if [[ ! -d $partner ]]; then
    fail 0 "$src has no docs/partner directory"
    exit 1
fi
# <src> is the top of a git checkout whose HEAD holds docs/partner as a tree
# (with the trailing slash, rev-parse accepts only a tree).
head_ok=false
if ! prefix=$(git_src rev-parse --show-prefix 2>"$work/git.err"); then
    fail 0 "$src is not a git checkout: $(head -n 1 -- "$work/git.err")"
elif [[ -n $prefix ]]; then
    fail 0 "$src is not the top of its git checkout (it is $prefix)"
elif ! source_commit=$(git_src rev-parse --verify --quiet HEAD) \
    || ! source_tree=$(git_src rev-parse --verify --quiet HEAD:docs/partner/); then
    fail 0 "$src has no commit with a docs/partner directory at HEAD"
else
    head_ok=true
fi

# committed PATH: gate 0 for one file the build reads, PATH relative to <src>.
# It is a regular file, not a symbolic link, and holds exactly the bytes of the
# blob HEAD records at PATH, so source_commit and source_tree describe what is
# served. --no-filters hashes the bytes as they are, with no filter or
# line-ending conversion from <src>. A missing file is left to gate 1.
committed() {
    local want have
    if [[ -L $src/$1 ]]; then
        fail 0 "$1 is a symbolic link; the build reads only regular files"
    elif [[ -f $src/$1 ]]; then
        if ! want=$(git_src rev-parse --verify --quiet "HEAD:$1"); then
            fail 0 "$1 is not in HEAD (untracked, ignored or not committed), so source_tree does not cover it"
        elif ! have=$(git_src hash-object --no-filters -- "$1" 2>"$work/git.err"); then
            fail 0 "cannot hash $1: $(head -n 1 -- "$work/git.err")"
        elif [[ $have != "$want" ]]; then
            fail 0 "$1 differs from the file HEAD records (changed and not committed), so source_tree does not describe it"
        fi
    fi
}

# Gate 1: shared assets, and the logo is the reviewed file. Gate 0: each asset
# is the file HEAD records.
for a in "${ASSETS[@]}"; do
    from=${a%% *}
    [[ -f $partner/assets/$from ]] || fail 1 "missing shared asset docs/partner/assets/$from"
    if $head_ok; then committed "docs/partner/assets/$from"; fi
done
if [[ -f $partner/assets/$LOGO ]]; then
    if ! sum=$(sha256sum <"$partner/assets/$LOGO"); then
        fail 1 "cannot read docs/partner/assets/$LOGO"
    elif [[ ${sum%% *} != "$LOGO_SHA256" ]]; then
        fail 1 "docs/partner/assets/$LOGO is not the reviewed logo (its SHA-256 is ${sum%% *}); review the new file, then set LOGO_SHA256 in build-site.sh to that hash"
    fi
fi

titles=()
versions=()
dates=()
for i in "${!STEMS[@]}"; do
    stem=${STEMS[i]}
    dir=$partner/$stem
    rel=docs/partner/$stem
    md=$dir/$stem.md
    yaml=$dir/metadata.yaml
    pdf=$dir/$stem.pdf

    # Gate 1: the three files. Gate 0: each is the file HEAD records.
    for f in "$md" "$yaml" "$pdf"; do
        [[ -f $f ]] || fail 1 "$stem: missing $rel/${f##*/}"
    done
    if $head_ok; then
        for f in "$stem.md" metadata.yaml "$stem.pdf"; do committed "$rel/$f"; done
    fi

    # Gate 2: a whole PDF file.
    pdf_ok=false
    if [[ -f $pdf ]]; then
        if [[ ! -s $pdf ]]; then
            fail 2 "$stem: $rel/$stem.pdf is empty"
        else
            head5=$(head -c 5 -- "$pdf" | tr '\0' '?')
            # The command substitution drops trailing newlines; one CR may remain.
            tail16=$(tail -c 16 -- "$pdf" | tr '\0' '?')
            tail16=${tail16%$'\r'}
            if [[ $head5 != "%PDF-" ]]; then
                fail 2 "$stem: $rel/$stem.pdf does not start with %PDF-"
            elif [[ $tail16 != *%%EOF ]]; then
                fail 2 "$stem: $rel/$stem.pdf does not end with %%EOF (truncated?)"
            else
                pdf_ok=true
            fi
        fi
    fi

    # Gate 3: version, date and title.
    version="" date="" meta_ok=false
    if [[ -f $yaml ]]; then
        version=$(meta "$yaml" version)
        date=$(meta "$yaml" date)
        if [[ -z $version ]]; then
            fail 3 "$stem: $rel/metadata.yaml has no version"
        elif [[ ! $version =~ $VERSION_RE ]]; then
            fail 3 "$stem: version \"$version\" in $rel/metadata.yaml is not like 1.2 or 1.2.3"
        fi
        if [[ -z $date ]]; then
            fail 3 "$stem: $rel/metadata.yaml has no date"
        elif [[ ! $date =~ $DATE_RE ]]; then
            fail 3 "$stem: date \"$date\" in $rel/metadata.yaml is not a month name and a four-digit year"
        fi
        if [[ $version =~ $VERSION_RE && $date =~ $DATE_RE ]]; then meta_ok=true; fi
    fi
    title=""
    if [[ -f $md ]]; then
        mapfile -t heads < <(headings "$md")
        if [[ ${#heads[@]} -ne 1 ]]; then
            fail 3 "$stem: $rel/$stem.md has ${#heads[@]} \"# \" headings outside code fences, expected 1"
        elif [[ -z ${heads[0]} ]]; then
            fail 3 "$stem: the \"# \" heading of $rel/$stem.md is empty"
        else
            title=${heads[0]}
        fi
    fi
    titles[i]=$title
    versions[i]=$version
    dates[i]=$date

    $pdf_ok || continue

    # Gate 4: page 1 prints the metadata's version and date. Skipped when gate 3
    # already rejected them, since the PDF cannot be expected to match.
    if $meta_ok; then
        page1=$work/$stem.page1.txt
        if ! pdftotext -q -f 1 -l 1 "$pdf" "$page1"; then
            fail 4 "$stem: pdftotext cannot read page 1 of $rel/$stem.pdf"
        else
            want="Version $version · $date"
            if ! WANT=$want awk '
                    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
                    $0 == ENVIRON["WANT"] { found = 1; exit }
                    END { exit !found }' "$page1"; then
                fail 4 "$stem: page 1 of $rel/$stem.pdf has no line \"$want\"; rebuild the PDF after a metadata change"
            fi
        fi
    fi

    # Gate 5: no confidentiality marking. Whitespace is folded first, so a marking
    # broken across lines still counts.
    text=$work/$stem.txt
    if ! pdftotext -q "$pdf" "$text"; then
        fail 5 "$stem: pdftotext cannot read $rel/$stem.pdf"
    else
        tr -s '[:space:]' ' ' <"$text" >"$text.flat"
        if grep -qiF 'confidential and proprietary' "$text.flat"; then
            hits=$(grep -oiF 'confidential and proprietary' "$text.flat" | wc -l)
            fail 5 "$stem: $rel/$stem.pdf contains \"Confidential and Proprietary\" ($((hits)) times)"
        fi
    fi
done

if [[ $failures -gt 0 ]]; then
    printf 'error: %d gate failure(s); nothing was built\n' "$failures" >&2
    exit 1
fi

# ---- build ---------------------------------------------------------------------

tmp=$(mktemp -d "$out_parent/.${out##*/}.tmp.XXXXXX")
mkdir -p "$tmp/assets/fonts"

for a in "${ASSETS[@]}"; do
    cp -- "$partner/assets/${a%% *}" "$tmp/${a#* }"
done
cp -- "$site_dir/site/style.css" "$site_dir/site/404.html" "$site_dir/site/robots.txt" "$tmp/"

pdfs=()
for i in "${!STEMS[@]}"; do
    stem=${STEMS[i]}
    alias=${ALIASES[i]}
    cp -- "$partner/$stem/$stem.pdf" "$tmp/$stem.pdf"
    pdfs+=("$stem.pdf")
    t=$(html "${titles[i]}")
    mkdir "$tmp/$alias"
    cat >"$tmp/$alias/index.html" <<EOF
<!DOCTYPE html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=../$stem.pdf">
<link rel="canonical" href="$BASE_URL/$stem.pdf">
<title>$t</title>
<link rel="stylesheet" href="../style.css">
</head>
<body>
<main class="wrap stub">
<p>Opening <a href="../$stem.pdf">$t</a> (PDF).</p>
</main>
</body>
</html>
EOF
done

# One entry per document, in table order, for @@DOCS@@.
docs_block() {
    local i stem bytes
    for i in "${!STEMS[@]}"; do
        stem=${STEMS[i]}
        bytes=$(wc -c <"$tmp/$stem.pdf")
        printf '      <li class="doc">\n'
        printf '        <a class="doc-link" href="%s.pdf">\n' "$stem"
        printf '          <span class="doc-title">%s</span>\n' "$(html "${titles[i]}")"
        printf '          <span class="doc-meta">Version %s<span class="sep"> · </span>%s<span class="sep"> · </span>PDF, %s</span>\n' \
            "$(html "${versions[i]}")" "$(html "${dates[i]}")" "$(human_size "$((bytes))")"
        printf '        </a>\n'
        printf '        <p class="doc-short">Short link: <a href="%s/">%s/%s</a></p>\n' \
            "${ALIASES[i]}" "${BASE_URL#https://}" "${ALIASES[i]}"
        printf '      </li>\n'
    done
}

# The footer provenance for @@SOURCE@@.
source_block() {
    printf '    <p>The PDFs come from <a href="%s">%s</a> at commit <a href="%s/commit/%s">%s</a>. <a href="source.txt">source.txt</a> lists their SHA-256 checksums.</p>\n' \
        "$SOURCE_REPO" "${SOURCE_REPO#https://github.com/}" "$SOURCE_REPO" "$source_commit" "${source_commit:0:7}"
}

# Fill the template line by line: a placeholder sits alone on its line, so no
# pattern substitution touches the escaped values.
while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^[[:space:]]*@@DOCS@@[[:space:]]*$ ]]; then
        docs_block
    elif [[ $line =~ ^[[:space:]]*@@SOURCE@@[[:space:]]*$ ]]; then
        source_block
    else
        printf '%s\n' "$line"
    fi
done <"$site_dir/site/index.html" >"$tmp/index.html"

site_commit=$(git -C "$site_dir" rev-parse --verify --quiet HEAD 2>/dev/null) || site_commit=unknown
{
    printf 'source_repo: %s\n' "$SOURCE_REPO"
    printf 'source_commit: %s\n' "$source_commit"
    printf 'source_tree: %s\n' "$source_tree"
    printf 'site_commit: %s\n' "$site_commit"
    printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n'
    (cd "$tmp" && sha256sum -- "${pdfs[@]}")
} >"$tmp/source.txt"

# ---- gate 6: the built tree ------------------------------------------------------

actual=$(cd "$tmp" && find . -mindepth 1 ! -type d -printf '%P\n' | sort)
if [[ $actual != "$EXPECTED_FILES" ]]; then
    fail 6 "the built tree differs from the expected file list:
$(diff <(printf '%s\n' "$EXPECTED_FILES") <(printf '%s\n' "$actual") || true)"
fi
# Placeholders can only be left in the text files; the PDFs and fonts are binary
# and hold the bytes "@@" by chance.
while IFS= read -r f; do
    fail 6 "${f#./} contains @@ (an unfilled placeholder?)"
done < <(cd "$tmp" && grep -rlF --include='*.html' --include='*.css' --include='*.txt' '@@' . || true)

if [[ $failures -gt 0 ]]; then
    printf 'error: %d gate failure(s); nothing was built\n' "$failures" >&2
    exit 1
fi

# Files readable and directories searchable by everyone, whatever the umask, so
# Pages can serve the tree.
chmod -R u=rwX,go=rX -- "$tmp" || die "cannot set the modes of the built site"

# rename(2) replaces an empty directory in one step, so <out> is never half built.
mv -T -- "$tmp" "$out" || die "cannot move the built site into $out"
tmp=""
printf 'built %s from %s at %s\n' "$out" "$SOURCE_REPO" "$source_commit"
