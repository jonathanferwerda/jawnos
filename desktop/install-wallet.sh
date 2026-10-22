#!/bin/sh
# Install Sparrow Wallet and the USB rules a hardware wallet needs.
#
#   ./desktop/install-wallet.sh              # Sparrow + Ledger/Trezor rules
#   ./desktop/install-wallet.sh --sparrow-only
#   ./desktop/install-wallet.sh --rules-only
#   ./desktop/install-wallet.sh --dry-run    # print, change nothing
#
# Arch/Manjaro uses the AUR (sparrow-wallet + ledger-udev). Debian/Ubuntu and
# Fedora fetch the release package from GitHub. Anything else gets the official
# tarball under ~/.local/opt/sparrow. A release asset's SHA-256 is checked
# against the published manifest before it is installed.
#
# Non-fatal by design: when a step cannot run it prints the exact commands to
# finish by hand, so a desktop install never fails because of the wallet.
set -eu

WITH_SPARROW=1
WITH_RULES=1
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--sparrow-only) WITH_RULES=0 ;;
		--rules-only) WITH_SPARROW=0 ;;
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
		*) echo "install-wallet.sh: unknown option $arg" >&2; exit 2 ;;
	esac
done

say() { printf '%s\n' "$*"; }
note() { [ "$DRY_RUN" -eq 1 ] || say "$*"; }

try() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '  would run: %s\n' "$*"
		return 0
	fi
	"$@"
}

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO=sudo
else
	SUDO=""
fi

os_id=$( . /etc/os-release 2>/dev/null || true; printf '%s%s' "${ID:-}" "${ID_LIKE:-}" )
machine=$(uname -m)
case "$machine" in
	x86_64|amd64) arch=x86_64; deb_arch=amd64 ;;
	aarch64|arm64) arch=aarch64; deb_arch=arm64 ;;
	*) arch="" ; deb_arch="" ;;
esac

# --- release helpers --------------------------------------------------------
api="https://api.github.com/repos/sparrowwallet/sparrow/releases/latest"
latest=""
release_url() {
	[ -n "$latest" ] || return 1
	curl -fsSL --max-time 30 "$api" 2>/dev/null \
		| grep -o '"browser_download_url": *"[^"]*"' \
		| sed 's/.*"\(https[^"]*\)"/\1/' \
		| grep -E "$1" \
		| head -n 1
}

verify_asset() {
	file=$1
	name=$2
	[ -n "$latest" ] || return 0
	manifest="https://github.com/sparrowwallet/sparrow/releases/download/$latest/sparrow-$latest-manifest.txt"
	want=$(curl -fsSL --max-time 30 "$manifest" 2>/dev/null | awk -v n="$name" '$2 == "*" n { print $1 }' | head -n 1 || true)
	[ -n "$want" ] || { say "  no checksum in the manifest; skipping verification"; return 0; }
	if command -v sha256sum >/dev/null 2>&1; then
		got=$(sha256sum "$file" | awk '{ print $1 }')
	else
		got=$(shasum -a 256 "$file" | awk '{ print $1 }')
	fi
	if [ "$got" = "$want" ]; then
		say "  sha256 ok"
		return 0
	fi
	say "  sha256 MISMATCH for $name (expected $want, got $got)"
	return 1
}

# --- Sparrow ---------------------------------------------------------------
if [ "$WITH_SPARROW" -eq 1 ]; then
	if command -v sparrow >/dev/null 2>&1; then
		say "Sparrow: already installed ($(command -v sparrow))"
	elif [ -z "$arch" ]; then
		say "Sparrow: no prebuilt package for $(uname -m); download it from https://sparrowwallet.com/"
	else
		case "$os_id" in
			*arch*|*manjaro*)
				if command -v yay >/dev/null 2>&1; then
					say "Sparrow: installing the AUR package sparrow-wallet"
					if try yay -S --needed --noconfirm sparrow-wallet; then
						note "Sparrow: installed"
					else
						say "Sparrow: the AUR install did not finish; run: yay -S sparrow-wallet"
					fi
				elif command -v paru >/dev/null 2>&1; then
					say "Sparrow: installing the AUR package sparrow-wallet"
					if try paru -S --needed --noconfirm sparrow-wallet; then
						note "Sparrow: installed"
					else
						say "Sparrow: the AUR install did not finish; run: paru -S sparrow-wallet"
					fi
				elif command -v pamac >/dev/null 2>&1; then
					say "Sparrow: building the AUR package sparrow-wallet"
					if try pamac build --no-confirm sparrow-wallet; then
						note "Sparrow: installed"
					else
						say "Sparrow: the build did not finish; run: pamac build sparrow-wallet"
					fi
				else
					say "Sparrow: no AUR helper found. Install it with:"
					say "  yay -S sparrow-wallet ledger-udev"
				fi
				;;
			*debian*|*ubuntu*)
				latest=$(curl -fsSL --max-time 30 "$api" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)
				url=$(release_url "_${deb_arch}\\.deb\$" || true)
				if [ -z "$url" ]; then
					say "Sparrow: no .deb found for $deb_arch; download it from https://sparrowwallet.com/"
				else
					tmp=$(mktemp -d "${TMPDIR:-/tmp}/jawnos-sparrow.XXXXXX")
					file="$tmp/$(basename "$url")"
					say "Sparrow: downloading $(basename "$url")"
					if try curl -fL --max-time 300 -o "$file" "$url" && verify_asset "$file" "$(basename "$url")"; then
						if [ "$(id -u)" -eq 0 ]; then
							try apt-get install -y "$file" && note "Sparrow: installed"
						elif [ -n "$SUDO" ]; then
							try $SUDO apt-get install -y "$file" && note "Sparrow: installed"
						else
							say "Sparrow: no sudo; install it with: sudo apt-get install -y $file"
						fi
					else
						say "Sparrow: download or checksum failed; nothing installed"
					fi
					rm -rf "$tmp"
				fi
				;;
			*fedora*|*rhel*)
				latest=$(curl -fsSL --max-time 30 "$api" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)
				url=$(release_url "${arch}\\.rpm\$" || true)
				if [ -z "$url" ]; then
					say "Sparrow: no .rpm found for $arch; download it from https://sparrowwallet.com/"
				else
					tmp=$(mktemp -d "${TMPDIR:-/tmp}/jawnos-sparrow.XXXXXX")
					file="$tmp/$(basename "$url")"
					say "Sparrow: downloading $(basename "$url")"
					if try curl -fL --max-time 300 -o "$file" "$url" && verify_asset "$file" "$(basename "$url")"; then
						if [ "$(id -u)" -eq 0 ]; then
							try dnf install -y "$file" && note "Sparrow: installed"
						elif [ -n "$SUDO" ]; then
							try $SUDO dnf install -y "$file" && note "Sparrow: installed"
						else
							say "Sparrow: no sudo; install it with: sudo dnf install -y $file"
						fi
					else
						say "Sparrow: download or checksum failed; nothing installed"
					fi
					rm -rf "$tmp"
				fi
				;;
			*)
				latest=$(curl -fsSL --max-time 30 "$api" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)
				url=$(release_url "${arch}\\.tar\\.gz\$" || true)
				if [ -z "$url" ]; then
					say "Sparrow: no tarball found for $arch; download it from https://sparrowwallet.com/"
				else
					tmp=$(mktemp -d "${TMPDIR:-/tmp}/jawnos-sparrow.XXXXXX")
					file="$tmp/$(basename "$url")"
					prefix="$HOME/.local/opt/sparrow"
					say "Sparrow: downloading $(basename "$url")"
					if try curl -fL --max-time 300 -o "$file" "$url" && verify_asset "$file" "$(basename "$url")"; then
						try mkdir -p "$prefix"
						try tar xzf "$file" -C "$prefix" --strip-components=1
						launcher=$(find "$prefix" -maxdepth 3 -type f \( -name Sparrow -o -name sparrow \) | head -n 1 || true)
						if [ -n "$launcher" ]; then
							mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
							ln -sf "$launcher" "$HOME/.local/bin/sparrow"
							icon=$(find "$prefix" -maxdepth 4 -type f -iname '*.png' | head -n 1 || true)
							{
								echo '[Desktop Entry]'
								echo 'Type=Application'
								echo 'Name=Sparrow'
								echo "Exec=$launcher"
								[ -n "$icon" ] && echo "Icon=$icon"
								echo 'Terminal=false'
								echo 'Categories=Office;Finance;'
							} > "$HOME/.local/share/applications/sparrow.desktop"
							note "Sparrow: installed to $prefix"
						else
							say "Sparrow: extracted, but no launcher was found under $prefix"
						fi
					else
						say "Sparrow: download or checksum failed; nothing installed"
					fi
					rm -rf "$tmp"
				fi
				;;
		esac
	fi
fi

# --- USB rules -------------------------------------------------------------
# Ledger uses 2c97 for every model. Trezor One/Model T use 534c; the Safe
# family also exposes 1209:53c0. uaccess hands the device to the seat's user,
# which is enough for Sparrow (and for Ledger Live).
if [ "$WITH_RULES" -eq 1 ]; then
	rule=/etc/udev/rules.d/20-hw-wallet.rules
	body='SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="534c", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="53c0", MODE="0660", TAG+="uaccess"'
	if [ -r "$rule" ] && [ "$(cat "$rule" 2>/dev/null)" = "$body" ]; then
		say "USB rules: already installed ($rule)"
	else
		tmp_rule=$(mktemp "${TMPDIR:-/tmp}/jawnos-wallet-rules.XXXXXX")
		printf '%s\n' "$body" > "$tmp_rule"
			if [ "$(id -u)" -eq 0 ]; then
			mkdir -p /etc/udev/rules.d
			if try install -m 0644 "$tmp_rule" "$rule"; then
				note "USB rules: installed $rule"
				try udevadm control --reload-rules || true
				try udevadm trigger --subsystem-match=usb || true
			fi
		elif [ -n "$SUDO" ]; then
			if try $SUDO install -m 0644 "$tmp_rule" "$rule"; then
				note "USB rules: installed $rule"
				try $SUDO udevadm control --reload-rules || true
				try $SUDO udevadm trigger --subsystem-match=usb || true
			else
				say "USB rules: could not install; run these as root:"
				say "  install -m 0644 $tmp_rule $rule"
				say "  udevadm control --reload-rules && udevadm trigger --subsystem-match=usb"
			fi
		else
			say "USB rules: no sudo available; save this as $rule:"
			cat "$tmp_rule"
		fi
		rm -f "$tmp_rule"
	fi
fi

say ""
say "Next: open Sparrow, connect and unlock the wallet, and open its Bitcoin app."
say "Then File -> New Wallet -> Single Signature -> Native Segwit (BIP84) ->"
say "Connected Hardware Wallet -> Scan -> Create Wallet."
say "Settings -> Wallet -> Show xpub; paste the zpub into JawnOS under"
say "Configure -> App -> Account xpub. Replug the device after the USB rules."
