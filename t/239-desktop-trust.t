# tests-for: desktop/jawnos_desktop/trust.py
# covers:    The desktop trusts only this install's own certificates: the leaf
#            in server/fullchain.pem and (on a joined machine) the house CA in
#            server/house-ca.pem. A different certificate is rejected, an empty
#            or unset tree trusts nothing, every PEM block counts, and a
#            rotated file is re-read.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use JSON::PP qw(decode_json);
use RepoSource;

my $root = repo_root();

my $openssl = qx{command -v openssl 2>/dev/null};
chomp $openssl;

SKIP: {
	skip 'openssl is not installed here', 15 unless $openssl;

	my $dir = tempdir(CLEANUP => 1);
	my $tree = "$dir/tree";
	make_path("$tree/server");

	# Four independent self-signed certificates: a is the fresh-machine leaf,
	# b and c share the joined machine's CA file, d is the outsider.
	my %cert;
	for my $name (qw(a b c d)) {
		$cert{$name} = "$dir/$name.pem";
		my $key = "$dir/$name.key";
		my $cmd = join(' ', map { "'$_'" } (
			$openssl, 'req', '-x509', '-newkey', 'rsa:2048',
			'-nodes', '-quiet',
			'-keyout', $key, '-out', $cert{$name}, '-days', '2',
			'-subj', "/CN=jawnos-trust-test-$name"));
		system("$cmd >/dev/null 2>&1") == 0
			or die "openssl could not make certificate $name";
	}
	write_file("$tree/server/fullchain.pem", read_file($cert{a}));
	write_file("$tree/server/house-ca.pem",
		read_file($cert{b}) . read_file($cert{c}));

	my $py = "$dir/probe.py";
	write_file($py, <<'PY');
import hashlib
import json
import os
import ssl
import sys
import tempfile

sys.path.insert(0, sys.argv[1] + '/desktop')
from jawnos_desktop import trust

tree, a, b, c, d = sys.argv[2:7]


def der(path):
    with open(path, 'r', encoding='ascii') as fh:
        return ssl.PEM_cert_to_DER_cert(fh.read())


def digest(path):
    return hashlib.sha256(der(path)).hexdigest()


class Cert:
    def __init__(self, der_bytes):
        self._der = der_bytes

    def toDer(self):
        return self._der


class ChainError:
    """The Qt 6.4+ shape: certificateChain(), acceptCertificate()."""

    def __init__(self, der_bytes, overridable=True):
        self._cert = Cert(der_bytes)
        self._overridable = overridable
        self.accepted = False

    def isOverridable(self):
        return self._overridable

    def certificateChain(self):
        return [self._cert]

    def acceptCertificate(self):
        self.accepted = True

    def accept(self):
        self.accepted = True


class SingleError(ChainError):
    """An older binding: certificate() and accept(), no chain."""

    certificateChain = None

    def certificate(self):
        return self._cert


def decide(cls, path, overridable=True):
    error = cls(der(path), overridable)
    accepted = trust.accept_certificate(error)
    return [bool(accepted), bool(error.accepted)]


out = {}
trust.set_tree(tree)
anchors = trust.trusted_digests()
out['anchor_a'] = digest(a) in anchors
out['anchor_b'] = digest(b) in anchors
out['anchor_c'] = digest(c) in anchors
out['anchor_d'] = digest(d) in anchors
out['chain_match'] = decide(ChainError, a)
out['single_match'] = decide(SingleError, a)
out['single_multiblock'] = decide(SingleError, b)
out['foreign'] = decide(ChainError, d)
out['not_overridable'] = decide(ChainError, a, False)

# Rotation: replacing the leaf is trusted on the next read, not after a
# restart, while the CA in the other file still counts.
write_file = os.path.join(tree, 'server', 'fullchain.pem')
with open(write_file, 'w', encoding='ascii') as fh:
    fh.write(open(d, 'r', encoding='ascii').read())
after = trust.trusted_digests()
out['reread_old'] = digest(a) in after
out['reread_new'] = digest(d) in after
out['reread_ca'] = digest(b) in after

# No anchors: an empty tree and no tree at all trust nothing.
empty = tempfile.mkdtemp()
trust.set_tree(empty)
out['empty_anchors'] = len(trust.trusted_digests())
error = ChainError(der(a))
out['empty_accept'] = bool(trust.accept_certificate(error))
out['empty_accepted'] = bool(error.accepted)
trust.set_tree(None)
out['no_tree_anchors'] = len(trust.trusted_digests())

print(json.dumps(out, sort_keys=True))
PY

		my $out = qx{python3 "$py" "$root" "$tree" "$cert{a}" "$cert{b}" "$cert{c}" "$cert{d}" 2>&1};
		my ($json) = $out =~ /^(\{.*\})$/m;
		ok($json, 'the trust probe ran') or diag($out);
		my $got = $json ? decode_json($json) : {};

		ok($got->{anchor_a}, 'the fresh-machine leaf in fullchain.pem is trusted');
		ok($got->{anchor_b} && $got->{anchor_c},
			'every certificate block in house-ca.pem is trusted');
		ok(!$got->{anchor_d}, 'an unrelated certificate is not an anchor');
		is_deeply($got->{chain_match}, [JSON::PP::true, JSON::PP::true],
			'a presented chain matching the anchor is accepted');
		is_deeply($got->{single_match}, [JSON::PP::true, JSON::PP::true],
			'an older binding\'s certificate() is accepted too');
		is_deeply($got->{single_multiblock}, [JSON::PP::true, JSON::PP::true],
			'a certificate from the second block is accepted');
		is_deeply($got->{foreign}, [JSON::PP::false, JSON::PP::false],
			'a different certificate is left rejected');
		is_deeply($got->{not_overridable}, [JSON::PP::false, JSON::PP::false],
			'a non-overridable error is never accepted');
		ok(!$got->{reread_old}, 'a rotated-away leaf is no longer trusted');
		ok($got->{reread_new}, 'the new leaf is trusted on the next read');
		ok($got->{reread_ca},
			'and the untouched house CA keeps working');
		is($got->{empty_anchors}, 0, 'an empty tree trusts nothing');
		ok(!$got->{empty_accept} && !$got->{empty_accepted},
			'and a matching certificate is still rejected');
		is($got->{no_tree_anchors}, 0, 'no tree at all trusts nothing');
	}

done_testing();
