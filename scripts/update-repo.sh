#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/update-repo.sh - assemble, prune and sign the OT-OS APT repository
#
# Called by .github/workflows/publish.yml. Produces a complete static site in
# ${OUT} that GitHub Pages serves as-is.
#
# Design (OT-OS decisions Q11/Q12, 2026-10-25):
#   * The PUBLISHED repository is the source of truth. No .deb is ever stored
#     in git: every run downloads the live repo, verifies its InRelease
#     against our key, merges the incoming packages, prunes, re-signs and
#     deploys the whole site again.
#   * Published files are IMMUTABLE. If an incoming file has the same pool
#     path as a published one but different bytes, the run fails: clients
#     would otherwise get "Hash Sum mismatch". Fix: bump the version.
#   * Retention: per suite, the ${KEEP} newest versions of every binary
#     package (per architecture) plus the source packages they were built
#     from (GPL source availability, Q6).
#   * Acquire-By-Hash: index files are also served under by-hash/SHA{256,512}/,
#     and the previous generation's indices are kept there. GitHub Pages'
#     CDN caches files for minutes; a client holding a stale InRelease still
#     finds matching indices instead of failing with a hash mismatch.
#
# Layout:
#   dists/<suite>/{InRelease,Release,Release.gpg}
#   dists/<suite>/main/binary-amd64/Packages{,.gz,.xz}   (arch all included)
#   dists/<suite>/main/source/Sources{,.gz,.xz}
#   pool/main/<prefix>/<source>/<files>                    (shared by suites)
#
# Environment (all required unless marked optional):
#   SITE_URL             published base URL, with trailing slash
#   OUT                  output directory (created, must not exist or be empty)
#   KEYRING_ASC          armored public key (keys/ot-os-archive-keyring.asc)
#   ARCHIVE_FPR          expected primary key fingerprint
#   SIGNING_SUBKEY_FPR   subkey that signs (already imported into GNUPGHOME)
#   PASSPHRASE_FILE      file holding the subkey passphrase
#   INCOMING             (optional) directory with the ot-os-packages artefact
#   TARGET_SUITE         (with INCOMING) noble | noble-nightly
#   ALLOW_BOOTSTRAP      (optional) 1 = allow publishing when NO suite exists
#                        yet. Guards against wiping the repo when the site is
#                        unreachable or misconfigured.
#   KEEP                 (optional, default 3) versions kept per package
# -----------------------------------------------------------------------------
set -Eeuo pipefail

log() { printf '\033[1;36m[ot-os-apt]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ot-os-apt] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUITES=(noble noble-nightly)
: "${SITE_URL:?}" "${OUT:?}" "${KEYRING_ASC:?}" "${ARCHIVE_FPR:?}"
: "${SIGNING_SUBKEY_FPR:?}" "${PASSPHRASE_FILE:?}"
INCOMING="${INCOMING:-}"
TARGET_SUITE="${TARGET_SUITE:-}"
ALLOW_BOOTSTRAP="${ALLOW_BOOTSTRAP:-0}"
KEEP="${KEEP:-3}"

[[ "${SITE_URL}" == */ ]] || SITE_URL="${SITE_URL}/"
if [[ -n "${INCOMING}" ]]; then
	[[ " ${SUITES[*]} " == *" ${TARGET_SUITE} "* ]] || die "TARGET_SUITE '${TARGET_SUITE}' is not one of: ${SUITES[*]}"
fi
[[ ! -e "${OUT}" || -z "$(ls -A "${OUT}")" ]] || die "OUT=${OUT} is not empty"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STORE="${WORK}/store"          # every pool file we know of, by pool path
mkdir -p "${STORE}" "${OUT}"

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# add_by_hash <file> <index dir>: copy to <dir>/by-hash/SHA{256,512}/<hash>.
add_by_hash() {
	local algo h
	for algo in SHA256 SHA512; do
		h="$("${algo,,}sum" "$1" | cut -d' ' -f1)"
		mkdir -p "$2/by-hash/${algo}"
		[[ -e "$2/by-hash/${algo}/${h}" ]] || cp "$1" "$2/by-hash/${algo}/${h}"
	done
}

# --- 0. Our key ------------------------------------------------------------------
# gpgv needs a binary keyring. The fingerprint check makes sure a modified
# keys/ file cannot make this script trust (or publish) a different key.
fprs="$(gpg --batch --with-colons --show-keys "${KEYRING_ASC}" | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}')"
[[ "${fprs}" == "${ARCHIVE_FPR}" ]] || die "${KEYRING_ASC} holds '${fprs}', expected ${ARCHIVE_FPR}"
gpg --batch --dearmor < "${KEYRING_ASC}" > "${WORK}/keyring.gpg"

# --- helpers ----------------------------------------------------------------------
# Debian pool layout: pool/main/<first letter, or libX for lib*>/<source>/
pool_dir() {
	local src="$1" prefix="${1:0:1}"
	[[ "${src}" == lib?* ]] && prefix="${src:0:4}"
	echo "pool/main/${prefix}/${src}"
}

# fetch <url> <dest> <sha256>: download and verify.
fetch() {
	curl -fsS --retry 3 -o "$2" "$1" || die "download failed: $1"
	[[ "$(sha256 "$2")" == "$3" ]] || die "sha256 mismatch: $1"
}

# store_add <file> <pool path>: put a file into the store, enforcing immutability.
store_add() {
	local src="$1" path="$2" dst="${STORE}/$2"
	if [[ -e "${dst}" ]]; then
		[[ "$(sha256 "${src}")" == "$(sha256 "${dst}")" ]] \
			|| die "IMMUTABLE: ${path} is already published with different content - bump the version"
		return 0
	fi
	install -D -m 0644 "${src}" "${dst}"
}

# --- 1. Current state of the published repository ---------------------------------
existing=0
for suite in "${SUITES[@]}"; do
	: > "${WORK}/members.${suite}"
	code="$(curl -sS --retry 3 -o "${WORK}/${suite}.InRelease" -w '%{http_code}' "${SITE_URL}dists/${suite}/InRelease")" \
		|| die "cannot reach ${SITE_URL} (refusing to continue: it would publish an empty repo)"
	case "${code}" in
		200) ;;
		404) log "${suite}: not published yet"; continue ;;
		*)   die "${SITE_URL}dists/${suite}/InRelease returned HTTP ${code}" ;;
	esac
	existing=$((existing + 1))

	gpgv --keyring "${WORK}/keyring.gpg" --output "${WORK}/${suite}.Release" "${WORK}/${suite}.InRelease" \
		|| die "${suite}: InRelease signature does NOT verify against ${ARCHIVE_FPR}"

	# .xz is parsed below; .gz is only kept for the by-hash history (clients
	# configured for gzip indexes, e.g. Docker's ubuntu image).
	for idx in main/binary-amd64/Packages.xz main/source/Sources.xz \
	           main/binary-amd64/Packages.gz main/source/Sources.gz; do
		sha="$(awk -v f="${idx}" '/^SHA256:/ {s=1; next} /^[^ ]/ {s=0} s && $3 == f {print $1}' "${WORK}/${suite}.Release")"
		[[ -n "${sha}" ]] || die "${suite}: ${idx} missing from Release"
		mkdir -p "${WORK}/prev/${suite}/$(dirname "${idx}")"
		fetch "${SITE_URL}dists/${suite}/${idx}" "${WORK}/prev/${suite}/${idx}" "${sha}"
	done

	# Packages: one "sha path" line per binary package.
	xz -dc "${WORK}/prev/${suite}/main/binary-amd64/Packages.xz" | awk 'BEGIN {RS=""; FS="\n"} {
		f = ""; s = ""
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^Filename: /) f = substr($i, 11)
			if ($i ~ /^SHA256: /)   s = substr($i, 9)
		}
		if (f != "") print s, f
	}' > "${WORK}/${suite}.files"
	# Sources: one "sha path" line per file of every source package.
	xz -dc "${WORK}/prev/${suite}/main/source/Sources.xz" | awk 'BEGIN {RS=""; FS="\n"} {
		d = ""; n = 0; c = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^Directory: /) { d = substr($i, 12); c = 0; continue }
			if ($i ~ /^Checksums-Sha256:/) { c = 1; continue }
			if (c && $i ~ /^ /) { split($i, a, " "); n++; sh[n] = a[1]; nm[n] = a[3]; continue }
			c = 0
		}
		for (j = 1; j <= n; j++) print sh[j], d "/" nm[j]
	}' >> "${WORK}/${suite}.files"

	while read -r sha path; do
		[[ "${path}" == pool/* && "${path}" != *..* ]] || die "${suite}: suspicious path in index: ${path}"
		if [[ ! -e "${STORE}/${path}" ]]; then
			mkdir -p "$(dirname "${STORE}/${path}")"
			fetch "${SITE_URL}${path}" "${STORE}/${path}" "${sha}"
		fi
		echo "${path}" >> "${WORK}/members.${suite}"
	done < "${WORK}/${suite}.files"
	log "${suite}: $(wc -l < "${WORK}/members.${suite}") published file(s) fetched and verified"
done

if ((existing == 0)) && [[ "${ALLOW_BOOTSTRAP}" != "1" ]]; then
	die "no suite exists at ${SITE_URL}. First deploy? Re-run with ALLOW_BOOTSTRAP=1 (workflow input 'bootstrap')."
fi

# --- 2. Incoming packages -------------------------------------------------------------
if [[ -n "${INCOMING}" ]]; then
	[[ -f "${INCOMING}/SHA256SUMS" ]] || die "${INCOMING}/SHA256SUMS missing (not an ot-os-packages artefact?)"
	(cd "${INCOMING}" && sha256sum --strict --quiet -c SHA256SUMS) || die "incoming SHA256SUMS do not verify"
	log "incoming -> ${TARGET_SUITE}"

	for deb in "${INCOMING}"/*.deb; do
		[[ -e "${deb}" ]] || continue
		pkg="$(dpkg-deb -f "${deb}" Package)"
		src="$(dpkg-deb -f "${deb}" Source)"; src="${src%% *}"; src="${src:-${pkg}}"
		path="$(pool_dir "${src}")/$(basename "${deb}")"
		store_add "${deb}" "${path}"
		echo "${path}" >> "${WORK}/members.${TARGET_SUITE}"
		log "  + ${path}"
	done
	for dsc in "${INCOMING}"/*.dsc; do
		[[ -e "${dsc}" ]] || continue
		src="$(awk '/^Source:/ {print $2; exit}' "${dsc}")"
		dir="$(pool_dir "${src}")"
		store_add "${dsc}" "${dir}/$(basename "${dsc}")"
		echo "${dir}/$(basename "${dsc}")" >> "${WORK}/members.${TARGET_SUITE}"
		while read -r f; do
			[[ -f "${INCOMING}/${f}" ]] || die "${dsc} references missing file ${f}"
			store_add "${INCOMING}/${f}" "${dir}/${f}"
			echo "${dir}/${f}" >> "${WORK}/members.${TARGET_SUITE}"
		done < <(awk '/^Checksums-Sha256:/ {c=1; next} /^[^ ]/ {c=0} c && NF {print $3}' "${dsc}")
		log "  + ${dir}/$(basename "${dsc}") (source)"
	done
fi

# --- 3. Retention ---------------------------------------------------------------------
# Debian version order (epochs, ~) is not what sort -V does, so versions are
# ordered with dpkg --compare-versions (insertion sort; lists are tiny).
prune_suite() {
	local suite="$1" members="${WORK}/members.$1" p f key
	sort -u -o "${members}" "${members}"
	: > "${WORK}/table"
	while read -r p; do
		[[ "${p}" == *.deb ]] || continue
		f="${STORE}/${p}"
		printf '%s/%s\t%s\t%s\n' "$(dpkg-deb -f "${f}" Package)" "$(dpkg-deb -f "${f}" Architecture)" \
			"$(dpkg-deb -f "${f}" Version)" "${p}" >> "${WORK}/table"
	done < "${members}"

	: > "${WORK}/keep"
	: > "${WORK}/keep-src"
	while read -r key; do
		local sorted=() row v i
		while IFS=$'\t' read -r _ v p; do
			row="${v}"$'\t'"${p}"
			sorted+=("${row}")
			i=$((${#sorted[@]} - 1))
			while ((i > 0)) && dpkg --compare-versions "${sorted[i-1]%%$'\t'*}" lt "${v}"; do
				sorted[i]="${sorted[i-1]}"; i=$((i - 1))
			done
			sorted[i]="${row}"
		done < <(awk -F'\t' -v k="${key}" '$1 == k' "${WORK}/table")
		for row in "${sorted[@]:0:${KEEP}}"; do
			p="${row#*$'\t'}"
			echo "${p}" >> "${WORK}/keep"
			# The source this binary was built from: "Source: name (version)",
			# "Source: name", or absent (= package name and version).
			local s sv
			s="$(dpkg-deb -f "${STORE}/${p}" Source)"
			sv="$(sed -n 's/.*(\(.*\)).*/\1/p' <<< "${s}")"
			s="${s%% *}"
			[[ -n "${s}" ]] || s="$(dpkg-deb -f "${STORE}/${p}" Package)"
			[[ -n "${sv}" ]] || sv="$(dpkg-deb -f "${STORE}/${p}" Version)"
			echo "${s} ${sv}" >> "${WORK}/keep-src"
		done
		for row in "${sorted[@]:${KEEP}}"; do
			log "${suite}: pruned ${row#*$'\t'}"
		done
	done < <(cut -f1 "${WORK}/table" | sort -u)

	# Keep a source package (the .dsc and its files) iff a kept binary needs it.
	local dsc s sv dir
	while read -r dsc; do
		s="$(awk '/^Source:/ {print $2; exit}' "${STORE}/${dsc}")"
		sv="$(awk '/^Version:/ {print $2; exit}' "${STORE}/${dsc}")"
		if grep -qxF "${s} ${sv}" "${WORK}/keep-src"; then
			dir="$(dirname "${dsc}")"
			echo "${dsc}" >> "${WORK}/keep"
			awk '/^Checksums-Sha256:/ {c=1; next} /^[^ ]/ {c=0} c && NF {print $3}' "${STORE}/${dsc}" \
				| sed "s|^|${dir}/|" >> "${WORK}/keep"
		else
			log "${suite}: pruned source ${dsc}"
		fi
	done < <(grep '\.dsc$' "${members}" || true)

	sort -u "${WORK}/keep" > "${members}"
}

for suite in "${SUITES[@]}"; do
	prune_suite "${suite}"
done

# --- 4. Site assembly ----------------------------------------------------------------
# Hard links where possible (same filesystem), copies otherwise.
link() { install -d "$(dirname "$2")"; cp -l "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

for suite in "${SUITES[@]}"; do
	tree="${WORK}/tree/${suite}"
	mkdir -p "${tree}/pool"
	while read -r p; do
		link "${STORE}/${p}" "${OUT}/${p}"
		link "${STORE}/${p}" "${tree}/${p}"
	done < "${WORK}/members.${suite}"

	d="${OUT}/dists/${suite}"
	mkdir -p "${d}/main/binary-amd64" "${d}/main/source"
	# Run inside the per-suite tree so Filename:/Directory: are "pool/...",
	# i.e. relative to the site root, and only this suite's files are listed.
	# We use no override files, so the "has no ... override entry" notices
	# are expected noise; anything else apt-ftparchive says stays visible.
	(cd "${tree}" && apt-ftparchive packages pool) > "${d}/main/binary-amd64/Packages" \
		2> >(grep -v 'override entry' >&2)
	(cd "${tree}" && apt-ftparchive sources pool)  > "${d}/main/source/Sources" \
		2> >(grep -v 'override entry' >&2)
	for f in "${d}/main/binary-amd64/Packages" "${d}/main/source/Sources"; do
		gzip -9n -k "${f}"
		xz -9 -k "${f}"
	done

	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin="OT-OS" \
		-o APT::FTPArchive::Release::Label="OT-OS" \
		-o APT::FTPArchive::Release::Suite="${suite}" \
		-o APT::FTPArchive::Release::Codename="${suite}" \
		-o APT::FTPArchive::Release::Architectures="amd64" \
		-o APT::FTPArchive::Release::Components="main" \
		-o APT::FTPArchive::Release::Description="OT-OS packages for Ubuntu 24.04 LTS (${suite})" \
		release "${d}" > "${WORK}/Release"
	# Acquire-By-Hash (see header). Added after generation so the by-hash
	# copies themselves are not listed in Release.
	sed -i '/^Components:/a Acquire-By-Hash: yes' "${WORK}/Release"
	mv "${WORK}/Release" "${d}/Release"

	# apt fetches by-hash with the STRONGEST hash in Release (SHA512), so
	# both SHA256 and SHA512 copies are provided.
	for f in "${d}"/main/*/Packages* "${d}"/main/*/Sources*; do
		add_by_hash "${f}" "$(dirname "${f}")"
	done
	# Previous generation's indices (only when this suite was published).
	for f in "${WORK}/prev/${suite}"/main/*/*.{xz,gz}; do
		[[ -e "${f}" ]] || continue
		rel="${f#"${WORK}/prev/${suite}/"}"
		add_by_hash "${f}" "${d}/$(dirname "${rel}")"
	done

	# --- 5. Signing -------------------------------------------------------------------
	# "!" forces exactly this subkey. The CI keyring holds no primary secret key.
	gpg_sign=(gpg --batch --yes --pinentry-mode loopback --passphrase-file "${PASSPHRASE_FILE}"
		--local-user "${SIGNING_SUBKEY_FPR}!" --digest-algo SHA512)
	"${gpg_sign[@]}" --clearsign --output "${d}/InRelease" "${d}/Release"
	"${gpg_sign[@]}" --armor --detach-sign --output "${d}/Release.gpg" "${d}/Release"
	gpgv --keyring "${WORK}/keyring.gpg" "${d}/InRelease" 2>/dev/null \
		|| die "${suite}: fresh InRelease does not verify with the published key"
	gpgv --keyring "${WORK}/keyring.gpg" "${d}/Release.gpg" "${d}/Release" 2>/dev/null \
		|| die "${suite}: fresh Release.gpg does not verify with the published key"

	log "${suite}: $(grep -c '^Package:' "${d}/main/binary-amd64/Packages" || true) binary package(s), signed"
	awk '/^Package:/ {p=$2} /^Version:/ {print "    " p " " $2}' "${d}/main/binary-amd64/Packages"
done

# --- 6. Static extras -------------------------------------------------------------
install -m 0644 "${KEYRING_ASC}" "${OUT}/ot-os-archive-keyring.asc"
install -m 0644 "${WORK}/keyring.gpg" "${OUT}/ot-os-archive-keyring.gpg"
touch "${OUT}/.nojekyll"
fpr_spaced="$(sed -E 's/(.{4})/\1 /g; s/ $//' <<< "${ARCHIVE_FPR}")"
cat > "${OUT}/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OT-OS APT repository</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}pre{background:#f3f3f3;padding:.75rem;overflow-x:auto}</style>
</head><body>
<h1>OT-OS APT repository</h1>
<p>Packages for OT-OS (Ubuntu 24.04 LTS, amd64). OT-OS installations already have this repository
(package <code>ot-os-archive-keyring</code>). Manual setup on Ubuntu 24.04:</p>
<pre>sudo curl -fsSL -o /usr/share/keyrings/ot-os-archive-keyring.gpg ${SITE_URL}ot-os-archive-keyring.gpg
gpg --show-keys /usr/share/keyrings/ot-os-archive-keyring.gpg   # must show ${fpr_spaced}
printf 'Types: deb\nURIs: ${SITE_URL}\nSuites: noble\nComponents: main\nSigned-By: /usr/share/keyrings/ot-os-archive-keyring.gpg\n' \\
  | sudo tee /etc/apt/sources.list.d/ot-os.sources
sudo apt update &amp;&amp; sudo apt install ot-os-archive-keyring</pre>
<p>Suites: <code>noble</code> (releases), <code>noble-nightly</code> (every commit; versions sort below the matching release).
Source packages are published alongside the binaries in <code>pool/</code>.</p>
<p>Signing key: <code>${fpr_spaced}</code></p>
</body></html>
EOF

size_mb="$(du -sm "${OUT}" | cut -f1)"
log "site: ${size_mb} MB"
# GitHub Pages limits a site to 1 GB; stop well before that.
((size_mb < 900)) || die "site is ${size_mb} MB - over the 900 MB safety limit (GitHub Pages: 1 GB)"
