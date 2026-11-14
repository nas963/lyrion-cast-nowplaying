package Plugins::CastNowPlaying::MDNS;

# Minimal mDNS for _googlecast._tcp: build the PTR query and parse responses.
# Pure Perl, no LMS dependencies (tested in tests/).

use strict;
use warnings;
use Socket qw(inet_ntoa);

use constant SERVICE => '_googlecast._tcp.local';

sub query_packet {
	my $q = pack('n6', 0, 0, 1, 0, 0, 0);
	$q .= join('', map { chr(length $_) . $_ } split /\./, SERVICE) . "\0";
	$q .= pack('nn', 12, 1);    # PTR, IN (QM: answers come by multicast)
	return $q;
}

sub _name {
	my ($buf, $off) = @_;
	my (@labels, $end);
	my $jumped = 0;
	for (1 .. 128) {
		die "bad name\n" if $off >= length $buf;
		my $len = ord(substr($buf, $off, 1));
		if (($len & 0xC0) == 0xC0) {
			my $ptr = unpack('n', substr($buf, $off, 2)) & 0x3FFF;
			$end = $off + 2 unless $jumped;
			$jumped = 1;
			$off = $ptr;
			next;
		}
		if ($len == 0) { $end = $off + 1 unless $jumped; last }
		push @labels, substr($buf, $off + 1, $len);
		$off += 1 + $len;
	}
	return (join('.', @labels), $end);
}

# parse($packet, $source_ip) -> list of { id, name, model, ca, ip, port }
# Only answers that carry a Cast TXT record (with id=) produce a device.
sub parse {
	my ($buf, $srcip) = @_;
	my @dev;
	eval {
		my (undef, $flags, $qd, $an, $ns, $ar) = unpack('n6', $buf);
		return unless $flags & 0x8000;    # responses only
		my $off = 12;
		for (1 .. $qd) { (undef, $off) = _name($buf, $off); $off += 4 }
		my (%txt, %srv, %addr);
		for (1 .. $an + $ns + $ar) {
			my $name;
			($name, $off) = _name($buf, $off);
			my ($type, undef, undef, $rdlen) = unpack('nnNn', substr($buf, $off, 10));
			$off += 10;
			my $rd = substr($buf, $off, $rdlen);
			if ($type == 16) {
				my %kv;
				my $p = 0;
				while ($p < length $rd) {
					my $l = ord(substr($rd, $p, 1));
					my ($k, $v) = split /=/, substr($rd, $p + 1, $l), 2;
					$kv{lc $k} = $v if defined $k && length $k;
					$p += 1 + $l;
				}
				$txt{lc $name} = \%kv;
			}
			elsif ($type == 33 && $rdlen >= 7) {
				my ($target) = _name($buf, $off + 6);
				$srv{lc $name} = { port => unpack('n', substr($rd, 4, 2)), target => lc $target };
			}
			elsif ($type == 1 && $rdlen == 4) {
				$addr{lc $name} = inet_ntoa($rd);
			}
			$off += $rdlen;
		}
		for my $inst (keys %txt) {
			next unless $inst =~ /\Q._googlecast._tcp.local\E$/i;
			my $t = $txt{$inst};
			next unless $t->{id};
			my $s = $srv{$inst} || {};
			push @dev, {
				id    => $t->{id},
				name  => $t->{fn} // $t->{id},
				model => $t->{md} // '',
				ca    => $t->{ca} // 0,
				ip    => ($s->{target} && $addr{ $s->{target} }) || $srcip,
				port  => $s->{port} || 8009,
			};
		}
		1;
	};
	return @dev;
}

# Cast capability bit 0 = video out (has a screen)
sub has_display { my $ca = shift // 0; return ($ca =~ /^\d+$/ && ($ca & 1)) ? 1 : 0 }

1;
