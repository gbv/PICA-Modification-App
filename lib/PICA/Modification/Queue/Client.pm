package PICA::Modification::Queue::Client;
#ABSTRACT: REST client

# TODO: IMPLEMENT

use strict;
use warnings;
use v5.10;

use parent 'PICA::Modification::Queue';

use LWP::UserAgent;
use HTTP::Headers;
use Log::Contextual qw(:log :dlog), 
	-default_logger => Log::Contextual::WarnLogger->new({ env_prefix => 'PICA_QUEUE' });
use JSON;

use PICA::Modification::Request;

# TODO: use Plack::Client

our $JSON = JSON->new;

sub new {
	my ($class,%options) = @_;
	my $self = bless { }, $class;

	$self->{api} = $options{api};
	$self->{api} =~ s{/$}{};

	$self->{ua} = LWP::UserAgent->new(
		default_headers => HTTP::Headers->new(
			Accept => 'application/json'
		)
	);
	
	$self;
}

sub get {
	my ($self, $id) = @_;

	my $url = $self->{api} . "/$id.json";
	my $res = $self->{ua}->get($url);

	log_trace { "GET $url" };
	my $data = eval { $JSON->decode($res->content); } // return;

	return PICA::Modification::Request->new(%$data);  
}

sub insert {
    my ($self, $edit) = @_;

	my $data = $edit->attributes;

	my $url  = $self->{api};
	my $json = $JSON->encode( $data );
	my $res  = $self->request( POST $url, Content => $json ) // return;

	my $id = $res->header('Location') // return;
	return unless $id =~ s/^$url//;

	return $id;
}

sub remove {
	my ($self, $id) = @_;

	my $url = $self->{api} . "/$id";
	my $res = $self->request(DELETE $url) or return;

	return $id;
}

sub list {
	my ($self, %options) = @_;
	
	my $url = $self->{api};
	# TODO: add query parameters
	my $res = $self->{ua}->get($url);

	log_trace { "GET $url" };
	my $data = eval { $JSON->decode($res->content); } // return;

	...;
}

sub request {
	my ($self, $request) = @_;

	log_debug { $request->method . " " . $request->uri };
	my $res = $self->{ua}->request( $request, Accept => 'application/json' );

	if (! $res->is_success ) {
		log_warn { "HTTP request failed: ".$request->method." ".$request->uri };
		return;
	}

	return $res;
}

sub json_request {
	my ($self, $request) = @_;
	my $res = $self->request($request) || return '';

	return unless $self->header('Content-Type') =~ qr{^application/json};

	if ($self->content) {
		JSON->decode( $self->content );
	} else {
		return '';
	}
}

1;
