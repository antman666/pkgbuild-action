#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

# Enable the multilib repository
cat << EOM >> /etc/pacman.conf
[multilib]
Include = /etc/pacman.d/mirrorlist
EOM

pacman -Syu --noconfirm --needed base-devel

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

BASEDIR="$PWD"
cd "${INPUT_PKGDIR:-.}"

# Assume that if .SRCINFO is missing then it is generated elsewhere.
# AUR checks that .SRCINFO exists so a missing file can't go unnoticed.
if [ -f .SRCINFO ] && ! sudo -u builder makepkg --printsrcinfo | diff - .SRCINFO; then
	echo "::error file=$FILE,line=$LINENO::Mismatched .SRCINFO. Update with: makepkg --printsrcinfo > .SRCINFO"
	exit 1
fi

# Optionally install dependencies from AUR
if [ -n "${INPUT_AURDEPS:-}" ]; then
	# First install yay
	pacman -S --noconfirm --needed git
	git clone https://aur.archlinux.org/yay.git /tmp/yay
	pushd /tmp/yay
	chmod -R a+rw .
	sudo -H -u builder makepkg --syncdeps --install --noconfirm
	popd

	# Extract dependencies from .SRCINFO (depends or depends_x86_64) and install
	mapfile -t PKGDEPS < \
		<(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)
	sudo -H -u builder yay --sync --noconfirm "${PKGDEPS[@]}"
fi

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086
cat << EOM > /etc/makepkg.conf
#!/hint/bash
#
# /etc/makepkg.conf
#

#########################################################################
# SOURCE ACQUISITION
#########################################################################
#
#-- The download utilities that makepkg should use to acquire sources
#  Format: 'protocol::agent'
DLAGENTS=('file::/usr/bin/curl -gqC - -o %o %u'
          'ftp::/usr/bin/curl -gqfC - --ftp-pasv --retry 5 --retry-delay 5 -o %o %u'
          'http::/usr/bin/curl -gqb "" -fLC - --retry 5 --retry-delay 5 -o %o %u'
          'https::/usr/bin/curl -gqb "" -fLC - --retry 5 --retry-delay 5 -o %o %u'
          'rsync::/usr/bin/rsync --no-motd -z %u %o'
          'scp::/usr/bin/scp -C %u %o')

# Other common tools:
# /usr/bin/snarf
# /usr/bin/lftpget -c
# /usr/bin/wget

#-- The package required by makepkg to download VCS sources
#  Format: 'protocol::package'
VCSCLIENTS=('bzr::bzr'
            'fossil::fossil'
            'git::git'
            'hg::mercurial'
            'svn::subversion')

#########################################################################
# ARCHITECTURE, COMPILE FLAGS
#########################################################################
#
CARCH="x86_64"
CHOST="x86_64-pc-linux-gnu"

#-- Compiler and Linker Flags
#CPPFLAGS=""
# CFLAGS="-march=native -mtune=native -O3 -fno-plt -fexceptions \
#         -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security \
#         -fstack-clash-protection -fcf-protection"
CFLAGS="-march=native -mtune=native -O3 -fno-plt -fomit-frame-pointer \
        -fno-math-errno -fno-trapping-math -fno-common -finline-functions \
        -fgraphite-identity"
CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"
# LDFLAGS="-Wl,-O3,--sort-common,--as-needed,-z,relro,-z,now"
LDFLAGS="-Wl,-O3,--sort-common,--as-needed,--strip-all"
#RUSTFLAGS="-C opt-level=2"
#-- Make Flags: change this for DistCC/SMP systems
MAKEFLAGS="-j40"
#-- Debugging flags
# DEBUG_CFLAGS="-g -fvar-tracking-assignments"
# DEBUG_CXXFLAGS="-g -fvar-tracking-assignments"
# DEBUG_RUSTFLAGS="-C debuginfo=2"

#########################################################################
# BUILD ENVIRONMENT
#########################################################################
#
# Makepkg defaults: BUILDENV=(!distcc !color !ccache check !sign)
#  A negated environment option will do the opposite of the comments below.
#
#-- distcc:   Use the Distributed C/C++/ObjC compiler
#-- color:    Colorize output messages
#-- ccache:   Use ccache to cache compilation
#-- check:    Run the check() function if present in the PKGBUILD
#-- sign:     Generate PGP signature file
#
BUILDENV=(!distcc color !ccache check !sign)
#
#-- If using DistCC, your MAKEFLAGS will also need modification. In addition,
#-- specify a space-delimited list of hosts running in the DistCC cluster.
#DISTCC_HOSTS=""
#
#-- Specify a directory for package building.
#BUILDDIR=/tmp/makepkg

#########################################################################
# GLOBAL PACKAGE OPTIONS
#   These are default values for the options=() settings
#########################################################################
#
# Makepkg defaults: OPTIONS=(!strip docs libtool staticlibs emptydirs !zipman !purge !debug !lto)
#  A negated option will do the opposite of the comments below.
#
#-- strip:      Strip symbols from binaries/libraries
#-- docs:       Save doc directories specified by DOC_DIRS
#-- libtool:    Leave libtool (.la) files in packages
#-- staticlibs: Leave static library (.a) files in packages
#-- emptydirs:  Leave empty directories in packages
#-- zipman:     Compress manual (man and info) pages in MAN_DIRS with gzip
#-- purge:      Remove files specified by PURGE_TARGETS
#-- debug:      Add debugging flags as specified in DEBUG_* variables
#-- lto:        Add compile flags for building with link time optimization
#
OPTIONS=(strip !docs !libtool !staticlibs emptydirs zipman purge !debug !lto)

#-- File integrity checks to use. Valid: md5, sha1, sha224, sha256, sha384, sha512, b2
INTEGRITY_CHECK=(b2)
#-- Options to be used when stripping binaries. See `man strip' for details.
STRIP_BINARIES="--strip-all"
#-- Options to be used when stripping shared libraries. See `man strip' for details.
STRIP_SHARED="--strip-unneeded"
#-- Options to be used when stripping static libraries. See `man strip' for details.
STRIP_STATIC="--strip-debug"
#-- Manual (man and info) directories to compress (if zipman is specified)
MAN_DIRS=({usr{,/local}{,/share},opt/*}/{man,info})
#-- Doc directories to remove (if !docs is specified)
DOC_DIRS=(usr/{,local/}{,share/}{doc,gtk-doc} opt/*/{doc,gtk-doc})
#-- Files to be removed from all packages (if purge is specified)
PURGE_TARGETS=(usr/{,share}/info/dir .packlist *.pod)
#-- Directory to store source code in for debug packages
DBGSRCDIR="/usr/src/debug"

#########################################################################
# PACKAGE OUTPUT
#########################################################################
#
# Default: put built package and cached source in build directory
#
#-- Destination: specify a fixed directory where all packages will be placed
#PKGDEST=/home/packages
#-- Source cache: specify a fixed directory where source files will be cached
#SRCDEST=/home/sources
#-- Source packages: specify a fixed directory where all src packages will be placed
#SRCPKGDEST=/home/srcpackages
#-- Log files: specify a fixed directory where all log files will be placed
#LOGDEST=/home/makepkglogs
#-- Packager: name/email of the person or organization building packages
#PACKAGER="John Doe <john@doe.com>"
#-- Specify a key to use for package signing
#GPGKEY=""

#########################################################################
# COMPRESSION DEFAULTS
#########################################################################
#
COMPRESSGZ=(gzip -c -f -n)
COMPRESSBZ2=(bzip2 -c -f)
COMPRESSXZ=(xz -c -z -)
COMPRESSZST=(zstd -c -z -q -)
COMPRESSLRZ=(lrzip -q)
COMPRESSLZO=(lzop -q)
COMPRESSZ=(compress -c -f)
COMPRESSLZ4=(lz4 -q)
COMPRESSLZ=(lzip -c -f)

#########################################################################
# EXTENSION DEFAULTS
#########################################################################
#
PKGEXT='.pkg.tar.zst'
SRCEXT='.src.tar.gz'

#########################################################################
# OTHER
#########################################################################
#
#-- Command used to run pacman as root, instead of trying sudo and su
#PACMAN_AUTH=()
EOM
updpkgsums
sudo -H -u builder makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u builder makepkg --packagelist )
echo "Package(s): ${PKGFILES[*]}"

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
	# makepkg reports absolute paths, must be relative for use by other actions
	RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
	# Caller arguments to makepkg may mean the pacakge is not built
	if [ -f "$PKGFILE" ]; then
		echo "::set-output name=pkgfile$i::$RELPKGFILE"
	else
		echo "Archive $RELPKGFILE not built"
	fi
	(( ++i ))
done

function prepend () {
	# Prepend the argument to each input line
	while read -r line; do
		echo "$1$line"
	done
}

function namcap_check() {
	# Run namcap checks
	# Installing namcap after building so that makepkg happens on a minimal
	# install where any missing dependencies can be caught.
	pacman -S --noconfirm --needed namcap

	NAMCAP_ARGS=()
	if [ -n "${INPUT_NAMCAPRULES:-}" ]; then
		NAMCAP_ARGS+=( "-r" "${INPUT_NAMCAPRULES}" )
	fi
	if [ -n "${INPUT_NAMCAPEXCLUDERULES:-}" ]; then
		NAMCAP_ARGS+=( "-e" "${INPUT_NAMCAPEXCLUDERULES}" )
	fi

	# For reasons that I don't understand, sudo is not resetting '$PATH'
	# As a result, namcap finds program paths in /usr/sbin instead of /usr/bin
	# which makes namcap fail to identify the packages that provide the
	# program and so it emits spurious warnings.
	# More details: https://bugs.archlinux.org/task/66430
	#
	# Work around this issue by putting bin ahead of sbin in $PATH
	export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

	namcap "${NAMCAP_ARGS[@]}" PKGBUILD \
		| prepend "::warning file=$FILE,line=$LINENO::"
	for PKGFILE in "${PKGFILES[@]}"; do
		if [ -f "$PKGFILE" ]; then
			RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
			namcap "${NAMCAP_ARGS[@]}" "$PKGFILE" \
				| prepend "::warning file=$FILE,line=$LINENO::$RELPKGFILE:"
		fi
	done
}

if [ -z "${INPUT_NAMCAPDISABLE:-}" ]; then
	namcap_check
fi
