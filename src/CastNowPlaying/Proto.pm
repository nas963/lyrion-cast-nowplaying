package Plugins::CastNowPlaying::Proto;

# Cast v2 framing: 4-byte big-endian length + protobuf CastMessage.
# Only the fields we use: 1 protocol_version, 2 source_id, 3 destination_id, 4 namespace,
# 5 payload_type (0 = STRING), 6 payload_utf8. Pure Perl, no LMS dependencies (tested in tests/).

use strict;
use warnings;

use constant NS_CONN     => 'urn:x-cast:com.google.cast.tp.connection';
use constant NS_HB       => 'urn:x-cast:com.google.cast.tp.heartbeat';
use constant NS_RECEIVER => 'urn:x-cast:com.google.cast.receiver';
use constant NS_NP       => 'urn:x-cast:lms.nowplaying';

sub _varint {
	my $n = shift;
	my $o = '';
	while ($n > 0x7F) { $o .= chr(($n & 0x7F) | 0x80); $n >>= 7 }
	return $o . chr($n);
}

sub _str {
	my ($f, $s) = @_;
	utf8::encode($s) if utf8::is_utf8($s);
	return _varint(($f << 3) | 2) . _varint(length $s) . $s;
}

sub _int { my ($f, $n) = @_; return _varint($f << 3) . _varint($n) }

# encode($source, $destination, $namespace, $payload_string) -> framed bytes
sub encode {
	my ($src, $dst, $ns, $payload) = @_;
	my $m = _int(1, 0) . _str(2, $src) . _str(3, $dst) . _str(4, $ns) . _int(5, 0) . _str(6, $payload);
	return pack('N', length $m) . $m;
}

sub _read_varint {
	my ($b, $p) = @_;
	my ($n, $s) = (0, 0);
	while (1) {
		die "truncated varint\n" if $$p >= length $b;
		my $c = ord(substr($b, $$p++, 1));
		$n |= ($c & 0x7F) << $s;
		last unless $c & 0x80;
		$s += 7;
		die "varint too long\n" if $s > 63;
	}
	return $n;
}

# decode_message($bytes) -> { src, dst, ns, data } (data is the UTF-8 payload as bytes)
sub decode_message {
	my $b = shift;
	my $p = 0;
	my %m;
	while ($p < length $b) {
		my $key = _read_varint($b, \$p);
		my ($f, $wt) = ($key >> 3, $key & 7);
		if    ($wt == 0) { $m{$f} = _read_varint($b, \$p) }
		elsif ($wt == 2) { my $l = _read_varint($b, \$p); $m{$f} = substr($b, $p, $l); $p += $l }
		elsif ($wt == 1) { $p += 8 }
		elsif ($wt == 5) { $p += 4 }
		else { die "unsupported wire type $wt\n" }
	}
	return { src => $m{2} // '', dst => $m{3} // '', ns => $m{4} // '', data => $m{6} // '' };
}

# take_messages(\$buffer) -> list of decoded messages; leaves a partial frame in the buffer
sub take_messages {
	my $buf = shift;
	my @out;
	while (length($$buf) >= 4) {
		my $l = unpack('N', $$buf);
		die "frame too large ($l)\n" if $l > 1 << 20;
		last if length($$buf) < 4 + $l;
		push @out, decode_message(substr($$buf, 4, $l));
		substr($$buf, 0, 4 + $l) = '';
	}
	return @out;
}

1;
