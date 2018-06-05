# t/001-filter-vagrant-up.t
use 5.14.0;
use warnings;
use Test::More;
use NYPM::Filter::Vagrant::Up qw( filter_vagrant_up );
use Carp;
use File::Copy;
use File::Slurper qw( read_lines );
use File::Spec::Functions qw( catdir catfile );
use File::Temp qw( tempdir );
use IO::Zlib;


{   # bad arguments
    
    {
        local $@ = undef;
        eval { filter_vagrant_up( [ 'foo', 'bar' ] ); };
        like($@, qr/filter_vagrant_up\(\) takes hashref/,
            "Got expected error message for non-hashref argument");
    }

    {
        local $@ = undef;
        my $bad_key = 'foo';
        eval { filter_vagrant_up( { 'foo', 'bar' } ); };
        like($@, qr/Incorrect elements in hashref passed to filter_vagrant_up\(\): $bad_key/,
            "Got expected error message for bad element in hashref");
    }

    {
        local $@ = undef;
        eval { filter_vagrant_up( { } ); };
        like($@, qr/Hashref passed to filter_vagrant_up\(\) lacks 'vagrant_log' element/,
            "Got expected error message for absence of 'vagrant_log' element in hashref");
    }

    {
        local $@ = undef;
        my $phony_log = 'foo';
        eval { filter_vagrant_up( { vagrant_log => $phony_log } ); };
        like($@, qr/Could not locate '$phony_log'/,
            "Got expected error message for non-existent vagrant log '$phony_log'");
    }

    {
        local $@ = undef;
        my $phony_dir = 'foo';
        my $tdir = tempdir( CLEANUP => 1 );
        my $test_log = setup_input($tdir);
        eval { filter_vagrant_up( {
            vagrant_log => $test_log,
            output_dir => $phony_dir,
        } ); };
        like($@, qr/Could not locate output directory '$phony_dir'/,
            "Got expected error message for non-existent output directory '$phony_dir'");
    }
}

{
    my $tdir = tempdir( CLEANUP => 1 );
    my $test_log = setup_input($tdir);
    my @lines_in = read_lines($test_log);
    my $count_in = scalar(@lines_in);
    my $expected_lines_in = 5963;
    my $expected_filtered = 3632;
    my $expected_lines_out = $expected_lines_in - $expected_filtered;
    is ($count_in, $expected_lines_in, "Got $expected_lines_in lines in $test_log");

    my $output_file = filter_vagrant_up( {
        vagrant_log     => $test_log,
        output_dir      => $tdir,
    } );
    ok(-f $output_file, "Located '$output_file'");
    like($output_file, qr/\.gz$/, "$output_file has '.gz' extension");
    my $FH = IO::Zlib->new($output_file, "rb");
    croak "Call to IO::Zlib->new did not return defined object"
        unless defined $FH;
    my @lines_out = $FH->getlines();
    $FH->close() or croak "Unable to close $output_file after reading";
    is (scalar @lines_out, $expected_lines_out,
        "Got expected line count in $output_file");
}

##### SUBROUTINES #####

sub setup_input {
    my $tdir = shift;
    my $dummy_log = 'vagrant-up-provision.log';
    my $fdummy_log = catfile( 't', $dummy_log );
    ok(-f $fdummy_log, "Located '$fdummy_log' for testing");
    my $test_log = catfile ( $tdir, $dummy_log );
    copy $fdummy_log => $test_log
        or croak "Unable to copy '$fdummy_log' for testing";
    return $test_log;
}

done_testing;
