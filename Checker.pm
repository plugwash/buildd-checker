# buildd-check: package processor for buildd
# This file goes in /usr/share/perl5/Buildd/
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Buildd::Checker;

use strict;
use warnings;

use Buildd qw(lock_file unlock_file exitstatus);
use Buildd::Conf qw();
use Buildd::Base;
use Sbuild qw(binNMU_version $devnull);
use Sbuild::ChrootRoot;
use Buildd::Client;
use Cwd;
use File::Basename;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Buildd::Base);

    @EXPORT = qw();
}


sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Checker Lock', undef);

    $self->open_log();

    return $self;
}


sub run {
    my $self = shift;

    $self->set('Checker Lock',
               lock_file("$main::HOME/buildd-checker", 1));

    if (!$self->get('Checker Lock')) {
        $self->log("exiting; another buildd-checker is still running");
        return 1;
    }

    chdir($self->get_conf('HOME'));

    #print STDERR "about to read whitelist\n";
    open my $fh, '<', "checkerwhitelist" or die "failed to open whitelist file";
    my %whitelist; 
    while (my $line = readline $fh) {
        chomp($line);
        next if $line =~ /^\s*\z/; # skip blank lines;
        next if $line =~ /^\s*#/; # skip comment lines;
        $whitelist{$line} = 1;
    }
    $self->set('whitelist',\%whitelist);
    #print STDERR "whitelist read complete\n";
    $self->process_build('build');

    return 0;
}


sub process_build() {
    my $self = shift;
    my $bdir = shift;

    chdir( "$main::HOME/$bdir" ) || return;

    # Get the list of .changes files in the build directory.
    lock_file( "$main::HOME/$bdir" );
    my( $f, @before, @tested, @failed, @dirty );
    foreach $f (<*.changes>) {
        push( @before, $f );
    }
    unlock_file( "$main::HOME/$bdir" );

    # Check if nothing to do.
    if (!@before) {
        $self->log("Nothing to do for $bdir\n");
        return;
    }

    $self->log(scalar(@before), " jobs to test in $bdir:\n");
    foreach $f (@before) {
        $self->log("    " . $f . "\n");
    }

    # Test each changes file in the /build directory.
    foreach $f (@before) {
        if ( -f $f ) {
	    if ($self->test_changes($f)) {
                push(@tested, $f);
            } else {
	        push(@failed, $f);
		push(@dirty, $f);
	    }
        }
    }

    $self->log(scalar(@tested), " jobs to upload in $bdir:\n");
    foreach $f (@tested) {
        $self->log("    " . $f . "\n");
    }

    # Prepare each tested file for upload that passed in the build directory.
    foreach $f (@tested) {
        if ( -f $f ) {
	    if (!$self->prepare_for_upload($f)) {
	        push(@failed, $f);
	    }
        }
    }

    # Move each dirty file to the dirty directory.
    foreach $f (@dirty) {
        if ( -f $f ) {
	    $self->dump_to_dirty($f);
        }
    }

    if (@failed) {
        $self->log(scalar(@failed), " jobs failed to be processed in $bdir:\n");
        foreach $f (@failed) {
            $self->log("    " . $f . "\n");
        }
    } else {
        $self->log("All jobs processed successfully.\n");
    }
    $self->write_stats("tested", scalar(@before) - scalar(@failed));
}


sub test_changes ($$) {
    my $self = shift;
    my $f = shift;

    $self->log("Testing: " . $f . "\n");

    # Flag that indicates the packages are v7clean.
    my $v7clean = 1;

    my( @files, @md5, @debs, $d, $p, $t );

    if (!open( F, "<$f" )) {
        $self->log("Cannot open $f: $!\n");
        return 0;
    }
    my $changes;
    { local($/); undef $/; $changes = <F>; }
    close( F );
    $changes =~ s/\n+$/\n/;

    # Get the source and version.
    if ($changes !~ /^Source:\s*(\S+)(?:\s+\(\S+\))?\s*$/m) {
        $self->log("$f doesn't have a Source: field\n");
        return 0;
    }
    my $source = $1;
    if ($changes !~ /^Version:\s*(\S+)\s*$/m) {
        $self->log("$f doesn't have a Version: field\n");
        return 0;
    }
    my $version = $1;
    my $pkg = "${source}_$version";

    # Get the files.
    $changes =~ /^Files:\s*\n((^[       ]+.*\n)*)/m;
    foreach (split( "\n", $1 )) {
        push( @md5, (split( /\s+/, $_ ))[1] );
        push( @files, (split( /\s+/, $_ ))[5] );
    }
    if (!@files) { # probably not a valid changes
        $self->log("$f doesn't have a valid File: field\n");
        return 0;
    }

    # We are only interested in the .deb & .udeb files.
    foreach $p (@files) {
        if ($p =~ /.u?deb$/) {
            push(@debs, $p);
        }
    }

    # Check if nothing to do.
    if (!@debs) {
        $self->log("No packages to process for $f\n");
        return 1;
    }

    # Create a temp directory to unpack the packages.
    ($t = $f) =~ s/\.changes$/\.check/;
    if (system "mkdir " . $self->get_conf('HOME') . "/build/$t") { 
        $self->log("Cannot create temp directory build/$t\n");
        return 0;
    }

    # Test each package within the temp directory.
    foreach $d (@debs) {
    	if (!$self->test_package($t, $d)) {
	    $v7clean = 0;
            $self->log("ARMv7 WARNING: $d\n");
	}
    }
     
    # Remove the temp directory.
    if (system "rm -rf " . $self->get_conf('HOME') . "/build/$t") { 
        $self->log("Cannot remove temp directory build/$t\n");
        return 0;
    }

    return $v7clean;
}


sub test_package ($$) {
    my $self = shift;
    my $tmpdir = shift;
    my $deb = shift;

    # Flag that indicates the package is v7clean.
    my $v7clean = 1;

    # Unpack the archive into the temp directory.
    my $savedir = cwd;
    chdir $self->get_conf('HOME') . "/build/$tmpdir";
    if (system "ar x " . $self->get_conf('HOME') . "/build/$deb") { 
        $self->log("Cannot extract debian archive build/$deb\n");
        chdir $savedir;
        return 0;
    }
    chdir $savedir;

    # Create a data directory.
    if (system "mkdir " . $self->get_conf('HOME') . "/build/$tmpdir/data") { 
        $self->log("Cannot create temp data directory build/$tmpdir/data\n");
        return 0;
    }

    # Handle extracting the tar archive.
    if ( -f $self->get_conf('HOME') . "/build/$tmpdir/data.tar.gz" ) {
        system "tar xzf " . $self->get_conf('HOME') . "/build/$tmpdir/data.tar.gz " .
            "-C " . $self->get_conf('HOME') . "/build/$tmpdir/data";
    } elsif ( -f $self->get_conf('HOME') . "/build/$tmpdir/data.tar.bz2" ) {
        system "tar xjf " . $self->get_conf('HOME') . "/build/$tmpdir/data.tar.bz2 " .
            "-C " . $self->get_conf('HOME') . "/build/$tmpdir/data";
    } elsif ( -f $self->get_conf('HOME') . "/build/$tmpdir/data.tar.xz" ) {
        system "tar xJf " . $self->get_conf('HOME') . "/build/$tmpdir/data.tar.xz " .
            "-C " . $self->get_conf('HOME') . "/build/$tmpdir/data";
    } else {
        $self->log("Unrecognized compression formation for data file.\n");
        return 0;
    }

    # Use find and file to get the type for each file in the scan.
    my $dirscan;
    # Create a list of all files to be tested.
    if (!open( F, "find " . $self->get_conf('HOME') . "/build/$tmpdir/data" . 
            " -exec file {} \\; |" )) {
        $self->log("Cannot open find command: $!\n");
        return 0;
    }
    { local($/); undef $/; $dirscan = <F>; }
    close(F);

    # Parse the dirscan data. 
    my ( @files, @info );
    foreach (split("\n", $dirscan)) {
        push(@files, (split(/:/, $_))[0]);
        push(@info, (split(/:/, $_))[1]);
    }

    # Loop over each line.
    for (my $c = 0; $c < @files && $v7clean; $c++) {
	# Look for lines that are executable binaries.
        if ($info[$c] =~ /ELF|ar archive/) {
             # Now test the file. 
             my $fileinpackage = substr($files[$c],length($self->get_conf('HOME') . "/build/$tmpdir/data"));
             if (!$self->test_file($files[$c],$fileinpackage)) {
                 $v7clean = 0;
             }
        }
    }

    # Clean up all package files in the temp directory.
    if (system "rm -rf " . $self->get_conf('HOME') . "/build/$tmpdir/*") { 
        $self->log("Cannot clean directory build/$tmpdir\n");
        return 0;
    }

    return $v7clean;
}


sub test_file ($$) {
    my $self = shift;
    my $file = shift;
    my $fileinpackage = shift;

    my $filescan;
    # Call readelf on the file to be tested.
    if (!open( F, "readelf -A " . $file . " |" )) {
        $self->log("Cannot open readelf command: $!\n");
        return 0;
    }
    { local($/); undef $/; $filescan = <F>; }
    close(F);
    my $whitelist = $self->get('whitelist');
    # Look for the "Tag_CPU_arch: v7" string.
    if ($filescan =~ /Tag_CPU_arch:\s+v7/) {
        if ($whitelist->{$fileinpackage}) {
            $self->log("found dirty file ".$fileinpackage." but ignoring due to whitelist");
        } elsif (index($fileinpackage,"/usr/lib/debug/.build-id/")==0) {
            $self->log("found dirty file ".$fileinpackage." but ignoring because path begins with /usr/lib/debug/.build_id/");
        } else {
            $self->log("found dirty file ".$fileinpackage);
            return 0;
        }
    }

    return 1;
}


sub prepare_for_upload ($$) {
    my $self = shift;
    my $f = shift;

    $self->log("Processing: " . $f . "\n");

    my( @files, @md5, @missing, @md5fail, $i );

    if (!open( F, "<$f" )) {
        $self->log("Cannot open $f: $!\n");
	return 0;
    }
    my $changes;
    { local($/); undef $/; $changes = <F>; }
    close( F );
    $changes =~ s/\n+$/\n/;

    # Get the source and version.
    if ($changes !~ /^Source:\s*(\S+)(?:\s+\(\S+\))?\s*$/m) {
        $self->log("$f doesn't have a Source: field\n");
	return 0;
    }
    my $source = $1;
    if ($changes !~ /^Version:\s*(\S+)\s*$/m) {
        $self->log("$f doesn't have a Version: field\n");
	return 0;
    }
    my $version = $1;
    my $pkg = "${source}_$version";

    # Get the distributions.
    if ($changes !~ /^Distribution:\s*(.*)\s*$/m) {
        $self->log("$f doesn't have a Distribution: field\n");
	return 0;
    }
    my @to_dists = split( /\s+/, $1 );

    # Get the files.
    $changes =~ /^Files:\s*\n((^[ 	]+.*\n)*)/m;
    foreach (split( "\n", $1 )) {
	push( @md5, (split( /\s+/, $_ ))[1] );
	push( @files, (split( /\s+/, $_ ))[5] );
    }
    if (!@files) { # probably not a valid changes
        $self->log("$f doesn't have a valid File: field\n");
	return 0;
    }

    # Get the architecture.
    my $changes_filename_arch = $self->get_conf('ARCH');
    if ($changes =~ /^Architecture:\s*(.+)/m) {
	my @arches = grep { $_ ne "all" } split /\s+/, $1;
	if (@arches > 1) {
	    $changes_filename_arch = "multi";
	} else {
	    $changes_filename_arch = $arches[0];
	}
    }

    my @wrong_dists = ();
    foreach my $d (@to_dists) {
	push( @wrong_dists, $d )
	    if !$self->check_state(
			$pkg, 
			$self->get_dist_config_by_name($d),
		   	qw(Building Built Install-Wait Reupload-Wait Build-Attempted));
    }
    if (@wrong_dists) {
        $self->log("STATE WARNING: Package $pkg has target distributions\n" .
		   "which it isn't registered as Building. Please fix this\n" .
                   "by either modifying the Distribution: header or taking\n" .
                   "the package in those distributions, too.\n");
	return 0;
    }

    for( $i = 0; $i < @files; ++$i ) {
	if (! -f $self->get_conf('HOME') . "/build/$files[$i]") {
	    push( @missing, $files[$i] ) ;
	}
	else {
	    my $home = $self->get_conf('HOME');
	    chomp( my $sum = `md5sum $home/build/$files[$i]` );
	    push( @md5fail, $files[$i] ) if (split(/\s+/,$sum))[0] ne $md5[$i];
	}
    }
    if (@missing) {
        $self->log("While trying to move the built package $pkg to upload,\n".
		   "the following files mentioned in the .changes were not found:\n".
		   "@missing\n");
	return 0;
    }
    if (@md5fail) {
        $self->log("While trying to move the built package $pkg to upload,\n".
		   "the following files had bad md5 checksums:\n".
		   "@md5fail\n");
	return 0;
    }

    my @upload_dirs = $self->get_upload_queue_dirs ( $changes );

    my $pkg_noep = $pkg;
    $pkg_noep =~ s/_\d*:/_/;
    my $changes_name = $pkg_noep . "_" . $changes_filename_arch . ".changes";
    
    for my $upload_dir (@upload_dirs) {
    if (! -d $upload_dir &&!mkdir( $upload_dir, 0750 )) {
	$self->log("Cannot create directory $upload_dir\n");
	return 0;
    }
    }

    my $errs = 0;
    for my $upload_dir (@upload_dirs) {
	lock_file( $upload_dir );
	foreach (@files) {
	    if (system "cp " . $self->get_conf('HOME') . "/build/$_ $upload_dir/$_") {
		$self->log("Cannot copy $_ to $upload_dir/\n");
		++$errs;
	    }
	}

	open( F, ">$upload_dir/$changes_name" );
	print F $changes;
	close( F );
	unlock_file( $upload_dir );
	$self->log("Moved $pkg to ", basename($upload_dir), "\n");
    }

    foreach (@files) {
	if (system "rm " . $self->get_conf('HOME') . "/build/$_") {
	    $self->log("Cannot remove build/$_\n");
	    ++$errs;
	}
    }

    if ($errs) {
        $self->log("Could not move all files to upload dir.");
	return 0;
    }

    unlink( $self->get_conf('HOME') . "/build/$changes_name" )
	or $self->log("Cannot remove " . $self->get_conf('HOME') . "/$changes_name: $!\n");

    return 1;
}


sub dump_to_dirty ($$) {
    my $self = shift;
    my $f = shift;

    $self->log("Dumping to Dirty : " . $f . "\n");

    my( @files, @md5, @missing, @md5fail, $i );

    if (!open( F, "<$f" )) {
        $self->log("Cannot open $f: $!\n");
        return 0;
    }
    my $changes;
    { local($/); undef $/; $changes = <F>; }
    close( F );
    $changes =~ s/\n+$/\n/;

    # Get the source and version.
    if ($changes !~ /^Source:\s*(\S+)(?:\s+\(\S+\))?\s*$/m) {
        $self->log("$f doesn't have a Source: field\n");
        return 0;
    }
    my $source = $1;
    if ($changes !~ /^Version:\s*(\S+)\s*$/m) {
        $self->log("$f doesn't have a Version: field\n");
        return 0;
    }
    my $version = $1;
    my $pkg = "${source}_$version";

    # Get the files.
    $changes =~ /^Files:\s*\n((^[       ]+.*\n)*)/m;
    foreach (split( "\n", $1 )) {
        push( @md5, (split( /\s+/, $_ ))[1] );
        push( @files, (split( /\s+/, $_ ))[5] );
    }
    if (!@files) { # probably not a valid changes
        $self->log("$f doesn't have a valid File: field\n");
        return 0;
    }

    my $dirty_dir = $self->get_conf('HOME') . "/dirty";
    if (! -d $dirty_dir &&!mkdir( $dirty_dir, 0750 )) {
        $self->log("Cannot create directory $dirty_dir\n");
        return 0;
    }

    my $errs = 0;
    lock_file( $dirty_dir );
    foreach (@files) {
        if (system "cp " . $self->get_conf('HOME') . "/build/$_ $dirty_dir/$_") {
            $self->log("Cannot copy $_ to $dirty_dir/\n");
            ++$errs;
        }
    }
    if (system "cp " . $self->get_conf('HOME') . "/build/$f $dirty_dir/$f") {
        $self->log("Cannot copy $f to $dirty_dir/\n");
        ++$errs;
    }
    unlock_file( $dirty_dir );
    $self->log("Moved $pkg to ", basename($dirty_dir), "\n");

    foreach (@files) {
        if (system "rm " . $self->get_conf('HOME') . "/build/$_") {
            $self->log("Cannot remove build/$_\n");
            ++$errs;
        }
    }

    if ($errs) {
        $self->log("Could not move all files to dirty dir.");
        return 0;
    }

    unlink( $self->get_conf('HOME') . "/build/$f" )
        or $self->log("Cannot remove " . $self->get_conf('HOME') . "/$f: $!\n");

    return 1;
}


sub check_state ($@) {
    my $self = shift;
    my $retval = $self->check_state_internal(@_);
    # check if we should retry the call
    if ($retval == -1) {
        my $interval = int(rand(120));
        $self->log("Retrying --info in $interval seconds...\n");
        # 0..120s of sleep ought to be enough for retrying;
        sleep $interval;
        $retval = $self->check_state_internal(@_);
        # remap the -1 retry code to failure
        if ($retval == -1) {
            return 0;
        } else {
            return $retval;
        }
    }
    return $retval;
}


sub check_state_internal ($$@) {
    my $self = shift;
    my $pkgv = shift;
    my $dist_config = shift;
    my @wanted_states = @_;
    my $dist_name = $dist_config->get('DIST_NAME');

    # Package may be passed in with a version.
    $pkgv =~ /^([^_]+)_(.+)/;
    my ($pkg, $vers) = ($1, $2);

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('--info', "--dist=$dist_name", $pkg);
    if (!$pipe) {
        $self->log("Couldn't start wanna-build --info: $!\n");
        # let check_state() retry if needed
        return -1;
    }

    my ($av, $as, $ab, $an);
    while(<$pipe>) {
        $av = $1 if /^\s*Version\s*:\s*(\S+)/;
        $as = $1 if /^\s*State\s*:\s*(\S+)/;
        $ab = $1 if /^\s*Builder\s*:\s*(\S+)/;
        $an = $1 if /^\s*Binary-NMU-Version\s*:\s*(\d+)/;
    }
    close($pipe);

    if ($?) {
        my $t = "wanna-build --info failed with status ".exitstatus($?)."\n";
        $self->log($t);
        return 0;
    }

    $av = binNMU_version($av,$an,undef) if (defined $an);
    if ($av ne $vers) {
        # $self->log("$pkgv($dist_name) check_state(@wanted_states): " .
        #            "version $av registered as $as\n");
        return 0;
    }
    if (!Buildd::isin($as, @wanted_states)) {
        # $self->log("$pkgv($dist_name) check_state(@wanted_states): " .
        #            "state is $as\n");
        return 0;
    }
    if ($as eq "Building" && $ab ne $dist_config->get('WANNA_BUILD_DB_USER')) {
        #$self->log("$pkgv($dist_name) check_state(@wanted_states): " .
        #           "is building by $ab\n");
        return 0;
    }
    return 1;
}


sub get_upload_queue_dirs ($) {
    my $self = shift;
    my $changes = shift;

    my %upload_dirs;
    $changes =~ /^Distribution:\s*(.*)\s*$/m;
    my @dists = split( /\s+/, $1 );
    for my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	my $upload_dir = $self->get_conf('HOME') . '/' . $dist_config->get('DUPLOAD_LOCAL_QUEUE_DIR');

	if (grep { $dist_config->get('DIST_NAME') eq $_ } @dists) {
	    $upload_dirs{$upload_dir} = 1;
        }
    }
    return keys %upload_dirs;
}

1;
