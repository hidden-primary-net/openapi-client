package OpenAPI::Client;
use Mojo::Base -base;

use Carp ();
use JSON::Validator::OpenAPI::Mojolicious;
use Mojo::JSON 'encode_json';
use Mojo::UserAgent;
use Mojo::Util;

use constant DEBUG => $ENV{MOJO_OPENAPI_DEBUG} || 0;

our $VERSION = '0.01';

my $BASE = __PACKAGE__;

has base_url => sub {
  my $self   = shift;
  my $schema = $self->_validator->schema;

  return Mojo::URL->new->host($schema->get('/host'))->path($schema->get('/basePath'))
    ->scheme($schema->get('/schemes')->[0] || 'http');
};

has ua => sub { Mojo::UserAgent->new };

sub local_app {
  my ($self, $app) = @_;
  my $ua = $self->ua;

  $ua->ioloop(Mojo::IOLoop->singleton);
  $ua->server->app($app);
  $self->base_url->host($ua->server->url->host);
  $self->base_url->port($ua->server->url->port);

  return $self;
}

sub new {
  my ($class, $url) = (shift, shift);
  my $attrs = @_ == 1 ? shift : {@_};
  my $validator = JSON::Validator::OpenAPI::Mojolicious->new;

  $class = $class->_url_to_class($url);
  _generate_class($class, $validator->load_and_validate_schema($url, $attrs)) unless $class->isa($BASE);

  my $self = bless $attrs, $class;
  $self->ua->transactor->name('Mojo-OpenAPI (Perl)');

  return $self;
}

sub _generate_class {
  my ($class, $validator) = @_;
  my $paths = $validator->schema->get('/paths') || {};

  eval <<"HERE" or Carp::confess("package $class: $@");
package $class;
use Mojo::Base '$BASE';
1;
HERE

  Mojo::Util::monkey_patch($class, _validator => sub {$validator});

  for my $path (keys %$paths) {
    for my $http_method (keys %{$paths->{$path}}) {
      my $op_spec = $paths->{$path}{$http_method};
      my $method  = $op_spec->{operationId} or next;
      my $code    = _generate_method(lc $http_method, $path, $op_spec);

      $method =~ s![^\w]!_!g;
      warn "[$class] Add method $class\::$method()\n" if DEBUG;
      Mojo::Util::monkey_patch($class, $method => $code);
    }
  }
}

sub _generate_method {
  my ($http_method, $path, $op_spec) = @_;
  my @path_spec = grep {length} split '/', $path;

  return sub {
    my $cb   = ref $_[-1] eq 'CODE' ? pop : undef;
    my $self = shift;
    my $tx   = $self->_generate_tx($http_method, \@path_spec, $op_spec, @_);

    if ($tx->error) {
      return $tx unless $cb;
      Mojo::IOLoop->next_tick(sub { $self->$cb($tx) });
      return $self;
    }

    return $self->ua->start($tx) unless $cb;
    return $self->tap(
      sub {
        $self->ua->start($tx, sub { $self->$cb($_[1]) });
      }
    );
  };
}

sub _generate_tx {
  my ($self, $http_method, $path_spec, $op_spec, $params) = @_;
  my $v   = $self->_validator;
  my $url = $self->base_url->clone;
  my (%headers, %req, @body, @errors);

  push @{$url->path}, map { local $_ = $_; s,\{(\w+)\},{$params->{$1}//''},ge; $_ } @$path_spec;

  for my $p (@{$op_spec->{parameters} || []}) {
    my ($in, $name, $type) = @$p{qw(in name type)};
    my $val = $params->{$name};
    my @e = (defined $val or $p->{required})
      ? $v->validate({$name => $val},
      {type => 'object', required => $p->{required} ? [$name] : [], properties => {$name => $p}})
      : ();

    if (@e) {
      warn "[OpenAPI] Invalid '$name' in '$in': @e\n" if DEBUG;
      push @errors, @e;
      next;
    }
    if (!defined $val) {
      next;
    }

    $url->query->param($name => $val) if $in eq 'query';
    $headers{$name} = $val if $in eq 'header';
    $req{form}{$name} = $val if $in eq 'formData';
    @body = (ref $val ? encode_json $val : $val) if $in eq 'body';
  }

  # Valid input
  warn "[OpenAPI] Input validation for '$url': @{@errors ? \@errors : ['Success']}\n" if DEBUG;
  return $self->ua->build_tx($http_method, $url, \%headers, %req, @body) unless @errors;

  # Invalid input
  my $tx = Mojo::Transaction::HTTP->new;
  $tx->req->url($url);
  $tx->res->headers->content_type('application/json');
  $tx->res->body(encode_json {errors => \@errors});
  $tx->res->code(400)->message($tx->res->default_message);
  $tx->res->error({message => 'Invalid input', code => 400});
  return $tx;
}

sub _url_to_class {
  my ($self, $package) = @_;

  $package =~ s!^\w+?://!!;
  $package =~ s!\W!_!g;
  $package = Mojo::Util::md5_sum($package) if length $package > 110;    # 110 is a bit random, but it cannot be too long

  return sprintf '%s::%s', __PACKAGE__, $package;
}

1;

=encoding utf8

=head1 NAME

OpenAPI::Client - A client for talking to an Open API powered server

=head1 DESCRIPTION

L<OpenAPI::Client> is a class for generating classes that can talk to an Open
API server. This is done by generating a custom class, based on a Open API
specification, with methods that transform parameters into a HTTP request.

The generated class will perform input validation, so invalid data won't be
sent to the server.

Not that this implementation is currently EXPERIMENTAL! Feedback is
appreciated.

=head1 SYNOPSIS

=head2 Open API specification

The input C<url> given to L</new> need to point to a valid OpenAPI document, in
either JSON or YAML format. Example:

  ---
  swagger: 2.0
  host: api.example.com
  basePath: /api
  schemes: [ "http" ]
  paths:
    /foo:
      get:
        operationId: listPets
        parameters:
        - name: limit
          in: query
          type: integer
        responses:
          200: { ... }

C<host>, C<basePath> and the first item in C<schemes> will be used to construct
L</base_url>. This can be altered at any time, if you need to send data to a
custom URL.

=head2 Client

The OpenAPI API specification will be used to generate a sub-class of
L<OpenAPI::Client> where the "operationId", inside of each path definition, is
used to generate methods:

  use OpenAPI::Client;
  $client = OpenAPI::Client->new("file:///path/to/api.json");

  # Blocking
  $tx = $client->listPets;

  # Non-blocking
  $client = $client->listPets(sub { my ($client, $tx) = @_; });

  # With parameters
  $tx = $client->listPets({limit => 10});

=head2 Customization

If you want to request a different server than what is specified in
the Open API document:

  $client->base_url->host("other.server.com");

=head1 ATTRIBUTES

=head2 base_url

  $base_url = $self->base_url;

Returns a L<Mojo::URL> object with the base URL to the API. The default value
comes from C<schemes>, C<basePath> and C<host> in the Open API specification.

=head2 ua

  $ua = $self->ua;

Returns a L<Mojo::UserAgent> object which is used to execute requests.

=head1 METHODS

=head2 local_app

  $client = $client->local_app(Mojolicious->new);

This method will modify L</ua> to run requests against the L<Mojolicious> or
L<Mojolicious::Lite> application given as argument. (Useful for testing)

=head2 new

  $client = OpenAPI::Client->new($specification, %attrs);
  $client = OpenAPI::Client->new($specification, \%attrs);

Returns an object of a generated class, with methods generated from the Open
API specification located at C<$specification>. See L<JSON::Validator/schema>
for valid versions of C<$specification>.

Note that the class is cached by perl, so loading a new specification from the
same URL will not generate a new class.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2017, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut