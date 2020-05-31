#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Data::Dumper;$Data::Dumper::Indent=1;
use Data::Dump ( qw| dd pp| );
use Carp;
use Getopt::Long;
use Perl::Download::FTP;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;

=head1 USAGE

    perl get-rc-tarball.pl \
        --host=ftp.cpan.org \
        --hostdir=/pub/CPAN/src/5.0 \
        --compression=gz \
        --type=dev_or_rc \
        --dev_cycle=29 \
        --downloads_dir=$DOWNLOADS_DIR \
        --email_to='"James E Keenan" <jkeenan@pobox.com>' \
        --email_from='"James E Keenan" <jkeenan@pobox.com>' \
        --email_subject='Status of Perl 5 RC release' \
        --verbose

=cut

my $date = qx/date/;
chomp $date;
say sprintf("%-52s%s" => ("Date:", $date));
say "Running $0";

my ($host, $hostdir, $verbose, $compression, $type, $dev_cycle, $downloads_dir) = ('') x 6;
my ($email_from, $email_to, $email_subject) = (undef) x 3;
GetOptions(
    "host=s"            => \$host,
    "hostdir=s"         => \$hostdir,
    "compression=s"     => \$compression,
    "type=s"            => \$type,
    "dev_cycle=i"       => \$dev_cycle,
    "downloads_dir=s"   => \$downloads_dir,
    "email_from=s"      => \$email_from,
    "email_to=s"        => \$email_to,
    "email_subject=s"   => \$email_subject,
    "verbose"           => \$verbose,
) or croak "Unable to get options";
croak "Unable to locate downloads_dir" unless (-d $downloads_dir);

say "host:                  $host"          if $verbose;
say "hostdir:               $hostdir"       if $verbose;
say "compression:           $compression"   if $verbose;
say "type:                  $type"          if $verbose;
say "dev_cycle:             $dev_cycle"     if $verbose;

my ($minor_version, $rc_version);
$minor_version = $dev_cycle;
$rc_version = $minor_version + 1;

my $pdfobj = Perl::Download::FTP->new( {
    host        => $host,
    dir         => $hostdir,
    verbose     => $verbose,
    Passive     => 1,
} );
#dd($pdfobj);
croak "Unable to create object" unless defined $pdfobj;

my @all_releases = $pdfobj->ls();

my @releases = grep { m/perl-5\.($minor_version|$rc_version)/ }
    $pdfobj->list_releases( {
        type            => $type,
        compression     => $compression,
   } ) or croak "Wrong " . $pdfobj->{ftp}->message;
if ($verbose) {
    say "We can see these dev_or_rc versions on server";
    dd(\@releases);
}
my $latest_on_server = $releases[0];
say "latest_on_server:      $latest_on_server" if $verbose;

my $email_body;

if ($latest_on_server =~ m/RC/) {
    say "Downloading RC release $latest_on_server" if $verbose;

    my $specific_release = $pdfobj->get_specific_release( {
        release         => $latest_on_server,
        path            => $downloads_dir,
    } );
    say "Downloaded: $specific_release" if $verbose;
    $email_body = "We have downloaded $latest_on_server to $specific_release";
    email_notify( {
        email_to            => $email_to,
        email_from          => $email_from,
        email_subject       => $email_subject,
        latest_on_server    => $latest_on_server,
        email_body          => $email_body,
    } );
}
else {
    say "Most recent release in dev_cycle $dev_cycle, $latest_on_server, is not an RC release" if $verbose;
    $email_body = "Most recent release in dev_cycle $dev_cycle, $latest_on_server, is not an RC release";
    email_notify( {
        email_to            => $email_to,
        email_from          => $email_from,
        email_subject       => $email_subject,
        latest_on_server    => $latest_on_server,
        email_body          => $email_body,
    } );
}

say "Finished!" if $verbose;
exit 0;

sub email_notify {
    my $args = shift;
    croak "email_notify() takes hash reference" unless ref($args) eq 'HASH';
    my $email = Email::Simple->create(
      header => [
        To      => $args->{email_to},
        From    => $args->{email_from},,
        Subject => join(' ' => ($args->{email_subject}, $args->{latest_on_server})),
      ],
      body => $args->{email_body},
    );

    local $@;
    eval { sendmail($email); };
    if ($@) { say "Problem in sending email: <$@>"; exit 1; }
    else { return 1 };
}

