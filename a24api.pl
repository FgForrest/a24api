#!/usr/bin/perl
use Getopt::Long qw(:config pass_through);
use Data::Dumper;
use SOAP::Lite; ## aptitude install libsoap-lite-perl
use JSON;
use strict;
$|=1;

############################################################################

my $CFG = {};
my $OPT = {};

############################################################################

sub fmt($$@) {
	my $indent = shift @_; $indent = 0 if ($indent !~ /^\d+$/);
	my $fmt = shift @_;

	my $out = sprintf($fmt, @_);
    while ($indent--) { $out = "    " . $out; }
    return $out;
}
sub dbg(@) {
	my $level = shift @_;
	my $fmt = shift @_;
	return if ($level > $CFG->{debug_level});
	print fmt(0, "DEBUG %s - $fmt", $level, @_);
	print "\n";
}
sub msg(@) {
	my $indent = shift @_;
	my $fmt = shift @_;
	print fmt($indent, $fmt, @_);
	print "\n";
}
sub err(@) {
	my $fmt = shift @_;
	print "\nERROR - ";
	print fmt(0, $fmt, @_);
	print "\n";
	exit 1;
}

sub jsonDecode($) {
    my ($src) = @_;
    my $js; eval { $js = decode_json($src); }; err("JSON parsing problem: %s\n%s", $@, $src) if ($@);
    return $js;
}

sub parseCfg($) {
    my ($fn) = @_;
    my $s = "";
    err("Configuration file not found: %s", $fn) if (!-f $fn);
    foreach my $l (split /[\r\n]+/, `cat "$fn"`) {
        next if ($l =~ /^\s*\/\//);  ## skip JS comment lines
        next if ($l =~ /^\s*#/);  ## skip SHELL comment lines
        $s .= "$l\n";
        # print "L: $l\n";
    }
    return jsonDecode($s);
}

############################################################################

sub apiCallRaw($$$) {
	my ($method, $variant, $params) = @_;
	$variant = $method if ($variant eq "");

	my $xml = "./xml/${variant}.xml"; err("XML file not found: %s", $xml) if (! -f $xml);
	my $rq = `cat "$xml"`;
	foreach my $k (sort keys %{$params}) { $rq =~ s/__PARAM__${k}__/$params->{$k}/ge; }

	dbg(1, "API CALL - %s / %s", $method, $variant);
	dbg(2, "REQUEST - %s", $rq);
	my $rs = `curl -s -b "$OPT->{cookie_file}" -c "$OPT->{cookie_file}" -X POST -H "Content-Type: text/xml" -H "SOAPAction: \"$method\"" -d '$rq' $CFG->{api_url}`;

	my $soap;
	eval { $soap = SOAP::Deserializer->new->deserialize($rs); };
	err("SOAP XML deserialization failed - %s", $@) if ($@);

	$rs =~ s/>/>\n/g;
	dbg(4, "RESPONSE - %s", $rs);
	my $data = $soap->dataof("//Envelope/Body/${method}Response/${method}Return/");

	err("SOAP key not found: %s", "_value") if (! $data->{"_value"});
	err("SOAP key not found: %s", "_value") if (! $data->{"_value"});
	err("SOAP array doesn't contain exactly 1 value: %s", "_value") if (scalar @{$data->{"_value"}} != 1);

	dbg(3, "value array - %s", Dumper($data->{"_value"}));

	my $val = @{$data->{"_value"}}[0];
	if (scalar @{$val->{errors}} > 0) {
		msg(0, "API response errors:");
		foreach my $err (@{$val->{errors}}) {
			msg(1, "API ERROR '%s' - %s: %s", $err->{errorCode}, $err->{description}, $err->{value});
		}
		err("API response errors detected");
	}
	dbg(2, "response data - %s", Dumper($val->{"data"}));
	return $val->{"data"};
}

sub apiCall($$$) {
	my ($method, $variant, $params) = @_;

	my $mt = (stat($OPT->{cookie_file}))[9];
	my $now = time();
	if ($mt eq "" or $mt + $CFG->{api_session_timeout_sec} < $now) {
		apiCallRaw("login", "login", { username => $CFG->{api_username}, password => $CFG->{api_password} });
	}
	return apiCallRaw($method, $variant, $params);
}

############################################################################

my $DNS_REC_TYPES = "(A|AAAA|CNAME|NS|TXT|SOA|MX)";

sub getDnsRecords($$$$) {
	my ($domain, $type, $ren, $rev) = @_;
	$ren = ".*" if ($ren eq "");
	$rev = ".*" if ($rev eq "");

	err("Invalid type - expected %s", $DNS_REC_TYPES) if ($type ne "" and $type !~ /^$DNS_REC_TYPES$/);

	dbg(1, "getDnsRecords - domain: %s, type: %s, filter name: %s, filter value: %s", $domain, $type, $ren, $rev);
	foreach my $r (sort { $a->{name} cmp $b->{name} } @{apiCall("getDnsRecords", "", { domain => $domain })}) {
		dbg(2, "DNS record - %s", Dumper($r));
		next if ($type ne "" and $type ne $r->{"type"}); ## filter type
		next if ($r->{"name"} !~ /$ren/i); ## filter name

		my $filt = 0;
		foreach my $v (@{$r->{value}}) {
			if ($v =~ /$rev/i) { $filt = 1; last; } ## filter value
		}
		next if (! $filt);
		msg(0, "%-30s %8s %-30s %6s %-5s %s", $domain, $r->{"id"}, $r->{"name"}, $r->{"ttl"}, $r->{"type"}, join(" ", @{$r->{"value"}}));
	}
}

sub updateDnsRecord($$$$$$$) { ## or create if (id eq "")
	my ($domain, $id, $name, $type, $value, $value2, $ttl) = @_;
	err("Invalid type - expected %s", $DNS_REC_TYPES) if ($type !~ /^$DNS_REC_TYPES$/);

	my $method = ($id ne "") ? "updateDnsRecord" : "addDnsRecord";
	my $record = "DnsRecordSimple";

	my $variable = "";  my $vartype = "soapenc:string";
	my $variable2 = ""; my $vartype2 = "";
	
	if    ("A" eq $type) { $variable = "ip"; }
	elsif ("AAAA" eq $type) { $variable = "ip"; }
	elsif ("CNAME" eq $type) { $variable = "alias"; }
	elsif ("TXT" eq $type) { $variable = "text"; }
	elsif ("MX" eq $type) {  $record = "DnsRecordMX"; $variable = "mailserver"; $variable2 = "priority"; $vartype2 = "xsd:int"; }
	else { err("updateDnsRecord - type not implemented: %s", $type); }

	$record = (($id ne "") ? "update" : "create") . $record;

	apiCall($method, $record, {
		domain => $domain,
		id => $id,
		name => $name,
		ttl => $ttl,
		type => $type,
		variable  => $variable,  value  => $value,  vartype  => $vartype,
		variable2 => $variable2, value2 => $value2, vartype2 => $vartype2,
	});
}

sub deleteDnsRecord($$) {
	my ($domain, $id) = @_;

	apiCall("deleteDnsRecord", "", {
		domain => $domain,
		id => $id,
	});
}

############################################################################

sub help() {
	print <<_EOF;
Usage: $0 [options] <service> <function> [parameters]

Options:
    -c <variant> Use alternative cfg. file a24api-cfg-<variant>.json
                 If omitted, cfg. file a24api-cfg-default.json is used.
Services:
	dns - DNS record management
		dns list <domain> [-t <type>] [-fn <name regex filter>] [-fv <value regex filter>]
		dns delete <domain> <record id>
		
		A, AAAA, CNAME, TXT
			dns create <domain> <name> <ttl> <type> <value>
			dns update <domain> <record id> <name> <ttl> <type> <value>
		MX
			dns create <domain> <name> <ttl> <type> <priority> <value>
			dns update <domain> <record id> <name> <ttl> <type> <priority> <value>

_EOF
}

sub srvDns() {
	my ($FN) = shift @ARGV; err("Invalid function: %s", $FN) if ($FN !~ /^(list|create|update|delete)$/);
	my ($D) = shift @ARGV; err("Invalid domain: %s", $D) if ($D =~ /^[\r\n\s]*$/);

	if ("list" eq "$FN") {
		my ($T, $FN, $FV);
		GetOptions("t=s" => \$T, "fn=s" => \$FN, "fv=s" => \$FV);
		err("Invalid command line options: %s", join(" ", @ARGV)) if (@ARGV);
		getDnsRecords($D, $T, $FN, $FV);
	}
	elsif ("$FN" =~ /^(update|create)$/) {
		my $ID = "";
		my $VAL2 = "";

		if ($FN eq "update") { $ID = shift @ARGV; err("Invalid id: %s", $ID) if ($ID !~ /^\d+$/); }
		my $NAME = shift @ARGV; err("Invalid name: %s", $NAME) if ($NAME =~ /^[\r\n\s]*$/);
		my $TTL = shift @ARGV; err("Invalid ttl: %s", $TTL) if ($TTL !~ /^\d+$/);
		my $TYPE = shift @ARGV; ## checked elsewhere
		if ($TYPE eq "MX") { $VAL2 = shift @ARGV; err("Invalid priority: %s", $VAL2) if ($VAL2 !~ /^\d+$/); }
		my $VAL = shift @ARGV; err("Invalid value: %s", $VAL) if ($VAL =~ /^[\r\n\s]*$/);

		err("Extra command line options: %s", join(" ", @ARGV)) if (@ARGV);
		updateDnsRecord($D, $ID, $NAME, $TYPE, $VAL, $VAL2, $TTL);
	}
	elsif ("delete" eq "$FN") {
		my $ID = shift @ARGV; err("Invalid id: %s", $ID) if ($ID !~ /^\d+$/);
		err("Invalid command line options: %s", join(" ", @ARGV)) if (@ARGV);
		deleteDnsRecord($D, $ID);
	}
	else {
		err("Invalid function: %s", $FN);
	}
}


sub main() {
	my ($SRV) = shift @ARGV;
	if ("dns" eq "$SRV") {
		srvDns();
	} else {
		help(); err("Invalid service: %s", $SRV);
	}
}

############################################################################

my $CFG_VARIANT="default";

while ($ARGV[0] =~ /^-.*$/) {
    my $o = shift(@ARGV);
    if ($o eq "-c") {
        $CFG_VARIANT = shift(@ARGV);
    } else {
        err("Unsupported option: %s", $o);
    }
}

my $WD=`dirname $0`; chomp($WD); chdir($WD) or err("Can't change directory to: $WD");
my $WD=`pwd`; chomp($WD); chdir($WD) or err("Can't change directory to: $WD");

$OPT->{cookie_file} = "$WD/cookie-$CFG_VARIANT.tmp";
$CFG = parseCfg("$WD/a24api-cfg-$CFG_VARIANT.json");
main();

exit(0);
