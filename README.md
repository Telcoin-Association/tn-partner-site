# run.telcoin.network

This repo publishes the four partner PDFs of tn-node-deployment (`docs/partner`) at <https://run.telcoin.network>, with a landing page and short links.
The PDFs are not stored here.
Each build reads them from `main` of [Telcoin-Association/tn-node-deployment](https://github.com/Telcoin-Association/tn-node-deployment), checks them and deploys the result to GitHub Pages.

## Links

All paths are under `https://run.telcoin.network`.
The landing page `/` lists the four documents in this order:

| Document | PDF | Short link |
|---|---|---|
| Testnet node requirements | `/testnet-node-requirements.pdf` | `/testnet` |
| Mainnet node requirements | `/mainnet-node-requirements.pdf` | `/mainnet` |
| MNO node guide | `/mno-node-guide.pdf` | `/guide` |
| Technical specification | `/technical-specification.pdf` | `/spec` |

A short link is a page that forwards to its PDF.
File names carry no version, so every link serves the revision published last.
The version and date are printed on page 1 of each PDF and on the landing page.

## Publish

After a change to a partner PDF merges in tn-node-deployment, run the Publish workflow on `main` of this repo, from the Actions tab or with:

```sh
gh workflow run publish.yml --repo Telcoin-Association/tn-partner-site --ref main
```

A push to `main` of this repo also publishes.
A manual run on another branch builds and checks the site but does not deploy it.

Publishing is manual for two reasons.
A workflow in one repo cannot start one in another without a token, and none is set up (see [Automatic publishing later](#automatic-publishing-later)).
A schedule does not work either: GitHub switches a scheduled workflow off after 60 days without activity in the repo, and this repo rarely changes.

## Check that the site is current

The site is current when `source_tree` in its `source.txt` equals the tree hash of `docs/partner` on tn-node-deployment `main`:

```sh
curl -fsS https://run.telcoin.network/source.txt | grep '^source_tree:'
git fetch origin && git rev-parse origin/main:docs/partner   # in a tn-node-deployment checkout
```

Compare the tree, not the commit: a merge that changes nothing under `docs/partner` moves `main` but leaves the served files as they are.
GitHub Pages may serve a cached copy for a few minutes after a deploy.

`source.txt` holds five fields, a blank line, and one `sha256sum` line per PDF in landing order:

| Field | Value |
|---|---|
| `source_repo` | `https://github.com/Telcoin-Association/tn-node-deployment` |
| `source_commit` | the tn-node-deployment commit the build read |
| `source_tree` | the git tree hash of `docs/partner` at that commit |
| `site_commit` | the commit of this repo that ran the build, or `unknown` when it did not run from a git checkout |
| `built_at` | build time in UTC, as `YYYY-MM-DDTHH:MM:SSZ` |

To check a PDF someone downloaded or was sent, put it under its published file name in a directory with `source.txt` and run `sha256sum -c` on the hash lines:

```sh
curl -fsSO https://run.telcoin.network/source.txt
grep -E '^[0-9a-f]{64}  ' source.txt | sha256sum -c --ignore-missing
```

Each PDF present prints `OK`; `--ignore-missing` skips the ones that are not there.

## What the build checks

`build-site.sh` runs these gates on every document before anything is uploaded:

| Gate | Check |
|---|---|
| 0 | `docs/partner` exists in a git checkout, has no modified, deleted or untracked file, and every file the site copies is tracked, so `source_tree` describes exactly what is served |
| 1 | each document has its `.md`, `metadata.yaml` and `.pdf`, and the shared assets (fonts, logo) exist |
| 2 | each PDF is non-empty, starts with `%PDF-` and ends with `%%EOF` |
| 3 | `version` is `X.Y` or `X.Y.Z`, `date` is an English month name and a four-digit year, and the `.md` has exactly one non-empty `# ` heading outside code fences |
| 4 | page 1 of the PDF has the line `Version <version> · <date>`, which catches a PDF not rebuilt after a metadata change |
| 5 | no PDF contains "Confidential and Proprietary", in any case |
| 6 | the built tree holds exactly the expected files, and no HTML, CSS or text file in it contains a leftover `@@` placeholder |

Any failure stops the run before upload, so the live site keeps the previous version.
Each failure prints `error: gate <n>: ...` with the document it concerns.
Gates 0 to 5 are reported together for all four documents; a check that an earlier failure makes meaningless for a document is skipped (a truncated PDF is not searched for text).
Gate 6 runs once they pass.
The script exits 0 when the site is built, 1 when a gate failed, and 2 on a usage or environment error such as a missing tool.
Failures of gates 1 to 5 are fixed in tn-node-deployment and then published with a new run; gate 6 points at `build-site.sh` or `site/` in this repo.

## Build locally

The script needs `git`, `pdftotext` (from poppler-utils), `sha256sum` and `awk`.

```sh
git clone https://github.com/Telcoin-Association/tn-node-deployment src
bash build-site.sh src _site
python3 -m http.server --directory _site
```

Then open <http://localhost:8000>.
The output directory must not exist or must be empty.
The script never deletes it, so remove `_site` before a rebuild; a failed run does not create or fill it.
It reads `src` as data and never writes to it.
To preview a docs branch, check it out in `src` first; uncommitted changes under `docs/partner` fail gate 0.

## Add or rename a document

The documents are listed in the table at the top of `build-site.sh`, in landing order, with the expected output file list (gate 6) beside it.
Change both.
Each entry names a directory under `docs/partner` in tn-node-deployment and a short alias.
The directory name is also the file stem: the directory holds `<stem>.md`, `metadata.yaml` and `<stem>.pdf`.
Merge a new document in tn-node-deployment first, or the run here fails gate 1.

Short links are part of what partners have been sent, so an alias is never renamed or removed once shared.
Renaming a document changes its PDF URL and the old one returns 404; keep the alias, which then forwards to the new file.

## Automatic publishing later

The workflow also runs on a `repository_dispatch` event of type `partner-docs-updated`, so a job in tn-node-deployment could publish after each merge to `docs/partner`.
That job needs a credential that can write to this repo: a GitHub App installation token, or a fine-grained token with "Contents: read and write" on this repo only.
None is set up.
The call it would make, with that credential in `GH_TOKEN`:

```sh
gh api repos/Telcoin-Association/tn-partner-site/dispatches -f event_type=partner-docs-updated
```

## One-time setup

This was done once and is kept for the record and for a rebuild of the site.

1. Org settings, Pages, Verified domains: `telcoin.network` is verified.
   This blocks a takeover of the subdomain if the site is ever unpublished.
2. Repo settings, Pages, Source: GitHub Actions.
3. Repo settings, Environments, `github-pages`: deployment branches limited to `main`.
4. Recommended: a ruleset on `main` that requires a pull request.
5. Push to `main` or run the workflow.
   The first deploy goes to <https://telcoin-association.github.io/tn-partner-site/>.
   Check the site there before setting the domain, because that URL redirects once a custom domain is set.
   The 404 page uses root-absolute links, so it only looks right on the custom domain.
6. Repo settings, Pages, Custom domain: `run.telcoin.network`.
   At the DNS host (Vercel), add the record `run` CNAME `telcoin-association.github.io`.
   The explicit record is required: `telcoin.network` has a wildcard record that would otherwise send the name to Vercel.
   Do these two back to back.
7. Wait for "DNS check successful" and the certificate, then tick "Enforce HTTPS".

## Checks after a deploy

```sh
# telcoin-association.github.io.
dig +short CNAME run.telcoin.network

# Each PDF: status 200, content-type: application/pdf, and no content-disposition line.
for f in testnet-node-requirements mainnet-node-requirements mno-node-guide technical-specification; do
  echo "== $f"
  curl -sSI "https://run.telcoin.network/$f.pdf" | grep -iE '^(HTTP|content-type|content-disposition)'
done

# Each alias forwards to its PDF, e.g. "testnet: url=../testnet-node-requirements.pdf".
for a in testnet mainnet guide spec; do
  printf '%s: ' "$a"
  curl -fsSL "https://run.telcoin.network/$a/" | grep -o 'url=[^"]*'
done

# 404, and a browser shows this site's 404 page rather than GitHub's.
curl -sS -o /dev/null -w '%{http_code}\n' https://run.telcoin.network/no-such-page

# 301 with "location: https://run.telcoin.network/".
curl -sSI http://run.telcoin.network/ | grep -iE '^(HTTP|location)'
```

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

The Geist font files served under `assets/fonts/` are under the SIL Open Font License.
Their license texts are served beside them, as `assets/fonts/LICENSE.txt` and `assets/fonts/OFL.txt`.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
