package PICA::Modification::Server;
#ABSTRACT: ...

use strict;
use warnings;
use v5.10;

use parent 'Plack::Component';

use Plack::Builder;
use Plack::Middleware::REST::Util;
use HTTP::Status qw(status_message);
use Plack::Util::Accessor qw(queue);
use PICA::Modification;
use PICA::Modification::Queue;
use Plack::Request;

use JSON -convert_blessed_universally;
our $JSON = JSON->new->utf8(1)->pretty(1);

# utility method to construct PSGI response in JSON
sub response {
	my $code = shift;
	my $body = @_ ? shift : (status_message($code) // ''); 
	if ($body !~ /^[\[{]/) {
		if ($code eq 204 and $body eq '') { # No Content
			return [ 204, [ @_ ], [ ] ];
		} else {
			$body = { "message" => $body } unless ref $body;
			$body = $JSON->encode($body);
		}
	}
	$body =~ s/\n$//m;
	[ $code, [ 'Content-Type' => 'application/json', @_ ], [ $body ] ];
}

sub prepare_app {
	my $self = shift;
	return if $self->{app};

    my $queue = $self->queue;
    my $class = delete $queue->{type};

	my $Q = PICA::Modification::Queue->new( $class, %$queue );
	$self->{queue} = $Q;

	$self->{app} = builder {
		# TODO: enable 'Negotiate'
		enable 'REST',
			get    => sub {
				my $mod = $Q->get( request_id( shift ) );
				return ( $mod
					? response(200, $mod)
					: response(404, "modification request not found")
				);
			},
			create => sub {
				my $env  = shift;

				# parse and validate
				my ($json,$type) = request_content($env);
				return response(400,'expected request with application/json')
					if $type ne 'application/json';
				$json = eval { $JSON->decode( $json ); };
				return response(400,'failed to parse JSON') if @_;

				my $mod = PICA::Modification->new( %$json ); 

				my $id = $Q->request( $mod );
				return response(400) unless $id;
			    my $uri = request_uri($env,$id);
			    return response(204, '', Location => $uri);
			},
			upsert => sub {
				my $env = shift;
				my $id = request_id($env);
				my $mod = $Q->get($id);
				return response(404) unless $mod;

				## parse and validate
				my ($json,$type) = request_content($env);
				return response(400,'expected request with application/json')
					if $type ne 'application/json';
				$json = eval { $JSON->decode( $json ); };
				return response(400,'failed to parse JSON') if @_;
				$mod = PICA::Modification->new( %$json ); 

				$id = $Q->update( $id => $mod );
				return response(400) unless $id;
			    my $uri = request_uri($env,$id);
			    return response(204, '', Location => $uri);
			},
			delete => sub {
				my $env = shift;
				my $id = request_id($env);
				my $ok = $Q->delete($id);
				return defined $ok ? response(200,"deleted") : response(404);
			},
			list   => sub {
				my $env = shift;
				my $req = Plack::Request->new($env);
				my $list = $Q->list( %{ $req->parameters->as_hashref } );
				# TODO: add Link: headers
				my $r = response( 200, $list );
				return $r;
			};
		sub { [500,[],[]] };
	};
}

sub call {
	my $self = shift;
	$self->{app}->(@_);
}

1;
