use Test::More;
use Test::Exception;
use strict;
use v5.10;

use Plack::Test;
use PICA::Modification::Server;
use HTTP::Request::Common;
use Data::Dumper;

my $server = PICA::Modification::Server->new();

test_psgi $server, sub {
	my $cb = shift;
	my $res = $cb->(GET '/', Accept => 'application/json');
	is $res->content, '[]', 'empty list';

	$res = $cb->(GET '/1', Accept => 'application/json');
	is $res->code, 404, 'non-existing request';

	$res = $cb->(POST '/', Accept => 'application/json', Content => '', 'Content-Type' => 'application/json' );
	is $res->code, 400, 'bad requested';

	my $mod = '{"id":"foo:ppn:123","del":"098A"}';
	$res = $cb->(POST '/', Accept => 'application/json', Content => $mod, 'Content-Type' => 'application/json' );
	is $res->code, 204, 'requested new modification';

	my $loc = $res->header('Location');
	is $loc, 'http://localhost/1', 'modification has Location URI';
};

done_testing;
