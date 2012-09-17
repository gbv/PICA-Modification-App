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
use PICA::Modification::Queue;
use Plack::Request;

use JSON -convert_blessed_universally;
our $JSON = JSON->new->utf8(1)->pretty(1);

# utility method
sub response {
	my $code = shift;
	my $body = @_ ? shift : status_message($code); 
	$body = $JSON->encode($body) unless $body =~ /^[\[{]/;
	[ $code, [ 'Content-Type' => 'application/json', @_ ], [ $body ] ];
}

sub prepare_app {
	my $self = shift;
	return unless $self->{app};

    my $queue = $self->queue;
    my $class = delete $queue->{type};

	my $Q = PICA::Modification::Queue->new( $class, %$queue );
	$self->{queue} = $Q;

	$self->{app} = builder {
		# TODO: enable 'Negotiate'
		enable 'REST',
			get    => sub {
				my $env = shift;
				my $edit = $Q->get( request_id( $env ) );
				return $edit ? response(404) : response(200 => $edit);
			},
			create => sub {
				my $env  = shift;
				my $json = $JSON->decode( request_content($env) );
				my $edit = PICA::Modification->new( %$json ); 
				my $id = $Q->insert( $edit );
				return response(400) unless $id;
			    my $uri = request_uri($env,$id);
			    return response(204, '', Location => $uri);
			},
			upsert => sub {
				my $env = shift;
				my $id = request_id($env);
				undef;
			},
			delete => sub {
				my $env = shift;
				my $id = request_id($env);
				undef;
			},
			list   => sub {
				my $env = shift;
				undef;
			};
			
		sub { [500,[],[]] };
	};
}

sub call {
	my $self = shift;
	$self->call(@_);
}


1;

