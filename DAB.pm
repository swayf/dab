package PVE::DAB;

use strict;
use warnings;
use IO::File;
use File::Path;
use File::Basename;
use IO::Select;
use IPC::Open2;
use IPC::Open3;
use POSIX qw (LONG_MAX);

# fixme: lock container ?

my $dablibdir = "/usr/lib/dab";
my $devicetar = "$dablibdir/devices.tar.gz";
my $default_env = "$dablibdir/scripts/defenv";
my $fake_init = "$dablibdir/scripts/init.pl";
my $script_ssh_init = "$dablibdir/scripts/ssh_gen_host_keys";
my $script_mysql_randompw = "$dablibdir/scripts/mysql_randompw";
my $script_init_urandom = "$dablibdir/scripts/init_urandom";

my $postfix_main_cf = <<EOD;
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = no

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost = 
mynetworks = 127.0.0.0/8
inet_interfaces = loopback-only
recipient_delimiter = +

EOD

# produce apt compatible filenames (/var/lib/apt/lists)
sub __url_to_filename {
    my $url = shift;

    $url =~ s|^\S+://||;
    $url =~ s|_|%5f|g;
    $url =~ s|/|_|g;

    return $url;
}

sub download {
    my ($self, $url, $path) = @_;

    $self->logmsg ("download: $url\n");
    my $tmpfn = "$path.tmp$$";
    eval {
	$self->run_command ("wget -q '$url'  -O '$tmpfn'"); 
    };

    my $err = $@;
    if ($err) {
	unlink $tmpfn;
	die $err;
    }

    rename ($tmpfn, $path);
}

sub write_file {
    my ($data, $file, $perm) = @_;

    die "no filename" if !$file;

    unlink $file;

    my $fh = IO::File->new ($file, O_WRONLY | O_CREAT, $perm) ||
	die "unable to open file '$file'";

    print $fh $data;

    $fh->close;
}

sub read_file {
    my ($file) = @_;

    die "no filename" if !$file;

    my $fh = IO::File->new ($file) ||
	die "unable to open file '$file'";

    local $/; # slurp mode
    
    my $data = <$fh>;

    $fh->close;

    return $data;
}

sub read_config {
    my ($filename) = @_;

    my $res = {};

    my $fh = IO::File->new ("<$filename") || return $res;
    my $rec = '';

    while (defined (my $line = <$fh>)) {
	next if $line =~ m/^\#/;
	next if $line =~ m/^\s*$/;
	$rec .= $line;
    };

    close ($fh);

    chomp $rec;
    $rec .= "\n";

    while ($rec) {
	if ($rec =~ s/^Description:\s*([^\n]*)(\n\s+.*)*$//si) {
	    $res->{headline} = $1;
	    chomp $res->{headline};
	    my $long = $2;
	    $long =~ s/^\s+/ /;
	    $res->{description} = $long;
	    chomp $res->{description};	    
	} elsif ($rec =~ s/^([^:]+):\s*(.*\S)\s*\n//) {
	    my ($key, $value) = (lc ($1), $2);
	    if ($key eq 'source' || $key eq 'mirror') {
		push @{$res->{$key}}, $value;
	    } else {
		die "duplicate key '$key'\n" if defined ($res->{$key});
		$res->{$key} = $value;
	    }
	} else {
	    die "unable to parse config file: $rec";
	}
    }

    die "unable to parse config file" if $rec;

    return $res;
}

sub run_command {
    my ($self, $cmd, $input, $getoutput) = @_;

    my $reader = IO::File->new();
    my $writer = IO::File->new();
    my $error  = IO::File->new();

    my $orig_pid = $$;

    my $cmdstr = ref ($cmd) eq 'ARRAY' ? join (' ', @$cmd) : $cmd;

    my $pid;
    eval {
	if (ref ($cmd) eq 'ARRAY') {
	    $pid = open3 ($writer, $reader, $error, @$cmd) || die $!;
	} else {
	    $pid = open3 ($writer, $reader, $error, $cmdstr) || die $!;
	}
    };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	$self->logmsg ("ERROR: command '$cmdstr' failed - fork failed\n");
	POSIX::_exit (1); 
	kill ('KILL', $$); 
    }

    die $err if $err;

    print $writer $input if defined $input;
    close $writer;

    my $select = new IO::Select;
    $select->add ($reader);
    $select->add ($error);

    my $res = '';
    my $logfd = $self->{logfd};

    while ($select->count) {
	my @handles = $select->can_read ();

	foreach my $h (@handles) {
	    my $buf = '';
	    my $count = sysread ($h, $buf, 4096);
	    if (!defined ($count)) {
		waitpid ($pid, 0);
		die "command '$cmdstr' failed: $!";
	    }
	    $select->remove ($h) if !$count;

	    print $logfd $buf;

	    $res .= $buf if $getoutput;
	}
    }

    waitpid ($pid, 0);
    my $ec = ($? >> 8);

    die "command '$cmdstr' failed with exit code $ec\n" if $ec;

    return $res;
}

sub logmsg {
    my $self = shift;
    print STDERR @_;
    $self->writelog (@_);
}

sub writelog {
    my $self = shift;
    my $fd = $self->{logfd};
    print $fd @_;
}

sub __sample_config {
    my ($self, $mem) = @_;

    my $max = LONG_MAX;
    my $nolimit = "\"$max:$max\"";

    my $defaults = {
	128 => {},
	256 => {},
	512 => {},
	1024 => {},
	2048 => {},
    };

    die "unknown memory size" if !defined ($defaults->{$mem});

    my $data = '';

    $data .= "# DAB default config for ${mem}MB RAM\n\n";

    $data .= "ONBOOT=\"no\"\n";

    $data .= "\n# Primary parameters\n";
    $data .= "NUMPROC=\"1024:1024\"\n";
    $data .= "NUMTCPSOCK=$nolimit\n";
    $data .= "NUMOTHERSOCK=$nolimit\n";

    my $vmguarpages = int ($mem*1024/4);
    $data .= "VMGUARPAGES=\"$vmguarpages:$max\"\n";

    $data .= "\n# Secondary parameters\n";

    $data .= "KMEMSIZE=$nolimit\n";

    my $privmax = int ($vmguarpages*1.1);
    $privmax = $vmguarpages + 12500 if ($privmax-$vmguarpages) > 12500;
    $data .= "OOMGUARPAGES=\"$vmguarpages:$max\"\n";
    $data .= "PRIVVMPAGES=\"$vmguarpages:$privmax\"\n";

    $data .= "TCPSNDBUF=$nolimit\n";
    $data .= "TCPRCVBUF=$nolimit\n";
    $data .= "OTHERSOCKBUF=$nolimit\n";
    $data .= "DGRAMRCVBUF=$nolimit\n";

    $data .= "\n# Auxiliary parameters\n";
    $data .= "NUMFILE=$nolimit\n";
    $data .= "NUMFLOCK=$nolimit\n";
    $data .= "NUMPTY=\"255:255\"\n";
    $data .= "NUMSIGINFO=\"1024:1024\"\n";
    $data .= "DCACHESIZE=$nolimit\n";
    $data .= "LOCKEDPAGES=$nolimit\n";
    $data .= "SHMPAGES=$nolimit\n";
    $data .= "NUMIPTENT=$nolimit\n";
    $data .= "PHYSPAGES=\"0:$max\"\n";

    $data .= "\n# Disk quota parameters\n";
    $data .= "DISK_QUOTA=\"no\"\n";
    $data .= "DISKSPACE=$nolimit\n";
    $data .= "DISKINODES=$nolimit\n";
    $data .= "QUOTATIME=\"0\"\n";
    $data .= "QUOTAUGIDLIMIT=\"0\"\n";

    $data .= "\n# CPU fair sheduler parameter\n";
    $data .= "CPUUNITS=\"1000\"\n\n";

    $data .= "\n# Template parameter\n";
    $data .= "OSTEMPLATE=\"$self->{targetname}\"\n";
    $data .= "HOSTNAME=\"localhost\"\n";
    
    return $data;
}

sub __allocate_ve {
    my ($self) = @_;

    my $cid;
    if (my $fd = IO::File->new (".veid")) {
	$cid = <$fd>;
	chomp $cid;
	close ($fd);
    }

    my $cfgdir = "/etc/vz/conf";

    if ($cid) {
	$self->{veid} = $cid;
	$self->{veconffile} = "$cfgdir/$cid.conf";
	return $cid;
    }

    my $cdata = $self->__sample_config (1024);

    my $veid;
    my $startid = 90000;
    for (my $id = $startid; $id < ($startid + 100); $id++) {

	my $tmpfn = "$cfgdir/$id.conf.tmp$$";
	my $target = "$cfgdir/$id.conf";

	next if -f $target;

	my $fh = IO::File->new ($target, O_WRONLY | O_CREAT | O_EXCL, 0644);

	next if !$fh;

	print $fh $cdata;
	close ($fh);
	$veid = $id;
	last;
    }

    die "unable to allocate VE\n" if !$veid;

    my $fd = IO::File->new (">.veid") ||
	die "unable to write '.veid'\n";
    print $fd "$veid\n";
    close ($fd);

    $self->logmsg ("allocated VE $veid\n");

    $self->{veid} = $veid;
    $self->{veconffile} = "$cfgdir/$veid.conf";

    return $veid;
}

sub new {
    my ($class, $config) = @_;

    $class = ref ($class) || $class;

    my $self = {};

    $config = read_config ('dab.conf') if !$config;

    $self->{config} = $config;

    bless $self, $class;

    $self->{logfile} = "logfile";
    $self->{logfd} = IO::File->new (">>$self->{logfile}") ||
	die "unable to open log file";

    my $arch = $config->{architecture};
    die "no 'architecture' specified\n" if !$arch;

    die "unsupported architecture '$arch'\n" 
	if $arch !~ m/^(i386|amd64)$/;

    my $suite = $config->{suite} || die "no 'suite' specified\n";
    if ($suite eq 'wheezy') {
         $config->{ostype} = "debian-7.0";
    } elsif ($suite eq 'squeeze') {
	$config->{ostype} = "debian-6.0";
    } elsif ($suite eq 'lenny') { 
	$config->{ostype} = "debian-5.0";
    } elsif ($suite eq 'etch') { 
	$config->{ostype} = "debian-4.0";
    } elsif ($suite eq 'hardy') { 
	$config->{ostype} = "ubuntu-8.04";
    } elsif ($suite eq 'intrepid') { 
	$config->{ostype} = "ubuntu-8.10";
    } elsif ($suite eq 'jaunty') { 
	$config->{ostype} = "ubuntu-9.04";
    } else {
	die "unsupported debian suite '$suite'\n";
    }

    my $name = $config->{name} || die "no 'name' specified\n";

    $name =~ m/^[a-z][0-9a-z\-\*\.]+$/ || 
	die "illegal characters in name '$name'\n";

    my $version = $config->{version};
    die "no 'version' specified\n" if !$version;
    die "no 'section' specified\n" if !$config->{section};
    die "no 'description' specified\n" if !$config->{headline};
    die "no 'maintainer' specified\n" if !$config->{maintainer};

    if ($name =~ m/^$config->{ostype}/) {
	$self->{targetname} = "${name}_${version}_$config->{architecture}";
    } else {
	$self->{targetname} = "$config->{ostype}-${name}_" .
	    "${version}_$config->{architecture}";
    }

    if (!$config->{source}) {
	if ($suite eq 'etch' || $suite eq 'lenny' || $suite eq 'squeeze' || $suite eq 'wheezy' ) {
	    push @{$config->{source}}, "http://ftp.debian.org/debian SUITE main contrib";
	    push @{$config->{source}}, "http://ftp.debian.org/debian SUITE-updates main contrib"
		if ($suite eq 'squeeze' || $suite eq 'wheezy');
	    push @{$config->{source}}, "http://security.debian.org SUITE/updates main contrib";
	} elsif ($suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	    my $comp = "main restricted universe multiverse";
	    push @{$config->{source}}, "http://archive.ubuntu.com/ubuntu SUITE $comp"; 
	    push @{$config->{source}}, "http://archive.ubuntu.com/ubuntu SUITE-updates $comp"; 
	    push @{$config->{source}}, "http://archive.ubuntu.com/ubuntu SUITE-security $comp";
	}
    }

    my $sources = undef;

    foreach my $s (@{$config->{source}}) {
	if ($s =~ m@^\s*((http|ftp)://\S+)\s+(\S+)((\s+(\S+))+)$@) {
	    my ($url, $su, $components) = ($1, $3, $4);
	    $su =~ s/SUITE/$suite/;
	    $components =~ s/^\s+//; 
	    $components =~ s/\s+$//; 
	    my $ca;
	    foreach my $co (split (/\s+/, $components)) {
		push @$ca, $co;
	    }
	    $ca = ['main'] if !$ca;

	    push @$sources, {
		source => $url,
		comp => $ca,
		suite => $su,
	    };
	} else {
	    die "syntax error in source spezification '$s'\n";
	}
    }

    foreach my $m (@{$config->{mirror}}) {
	if ($m =~ m@^\s*((http|ftp)://\S+)\s*=>\s*((http|ftp)://\S+)\s*$@) {
	    my ($ms, $md) = ($1, $3);
	    my $found;
	    foreach my $ss (@$sources) {
		if ($ss->{source} eq $ms) {
		    $found = 1;
		    $ss->{mirror} = $md;
		    last;
		}
	    }
	    die "unusable mirror $ms\n" if !$found;
	} else {
	    die "syntax error in mirror spezification '$m'\n";
	}
    }

    $self->{sources} = $sources;

    $self->{infodir} = "info";

    $self->__allocate_ve ();

    $self->{cachedir} = ($config->{cachedir} || 'cache')  . "/$suite";;

    my $incl = [qw (less ssh openssh-server logrotate)];

    my $excl = [qw (modutils reiserfsprogs ppp pppconfig pppoe
		    pppoeconf nfs-common mtools ntp)];

    # ubuntu has too many dependencies on udev, so
    # we cannot exclude it (instead we disable udevd)
    if ($suite eq 'hardy') {
	push @$excl, qw(kbd);
	push @$excl, qw(apparmor apparmor-utils ntfs-3g
			friendly-recovery);
    } elsif($suite eq 'intrepid' || $suite eq 'jaunty') {
	push @$excl, qw(apparmor apparmor-utils libapparmor1 libapparmor-perl 
			libntfs-3g28 ntfs-3g friendly-recovery);
    } else {
	push @$excl, qw(udev module-init-tools pciutils hdparm 
			memtest86+ parted);
    }

    $self->{incl} = $incl;
    $self->{excl} = $excl;

    return $self;
}

sub initialize {
    my ($self) = @_;

    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    rmtree $infodir;
    mkpath $infodir;

    # truncate log
    my $logfd = $self->{logfd} = IO::File->new (">$self->{logfile}") ||
	die "unable to open log file";

    foreach my $ss (@{$self->{sources}}) {
	my $src = $ss->{mirror} || $ss->{source};
	my $path = "dists/$ss->{suite}/Release";
	my $url = "$src/$path";
	my $target = __url_to_filename ("$ss->{source}/$path");
	eval {
	    $self->download ($url, "$infodir/$target");
	    $self->download ("$url.gpg", "$infodir/$target.gpg");
	    # fixme: impl. verify (needs --keyring option)
	};
	if (my $err = $@) { 
	    print $logfd $@; 
	    warn "Release info ignored\n";
	};
	foreach my $comp (@{$ss->{comp}}) {
	    $path = "dists/$ss->{suite}/$comp/binary-$arch/Packages.gz";
	    $target = "$infodir/" . __url_to_filename ("$ss->{source}/$path");
	    my $pkgsrc = "$src/$path";
	    $self->download ($pkgsrc, $target);
	    $self->run_command ("gzip -d '$target'");
	}
    }
}

sub write_config {
    my ($self, $filename, $size) = @_;

    my $config = $self->{config};

    my $data = '';

    $data .= "Name: $config->{name}\n";
    $data .= "Version: $config->{version}\n";
    $data .= "Type: openvz\n";
    $data .= "OS: $config->{ostype}\n";
    $data .= "Section: $config->{section}\n";
    $data .= "Maintainer: $config->{maintainer}\n";
    $data .= "Architecture: $config->{architecture}\n";
    $data .= "Installed-Size: $size\n";

    # optional
    $data .= "Infopage: $config->{infopage}\n" if $config->{infopage};
    $data .= "ManageUrl: $config->{manageurl}\n" if $config->{manageurl};
    $data .= "Certified: $config->{certified}\n" if $config->{certified};

    # description
    $data .= "Description: $config->{headline}\n";
    $data .= "$config->{description}\n" if $config->{description};

    write_file ($data, $filename, 0644);
}

sub finalize {
    my ($self, $opts) = @_;

    my $suite = $self->{config}->{suite};
    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    my $instpkgs = $self->read_installed ();
    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $rootdir = $self->vz_root_dir();

    my $vestat = $self->ve_status();
    die "ve not running - unable to finalize\n" if !$vestat->{running};

    # cleanup mysqld
    if (-f "$rootdir/etc/init.d/mysql") {
	$self->ve_command ("/etc/init.d/mysql stop");
    }

    if (!($opts->{keepmycnf} || (-f "$rootdir/etc/init.d/mysql_randompw"))) {
	unlink "$rootdir/root/.my.cnf";
    }

    if ($suite eq 'etch') {
	# enable apache2 startup
	if ($instpkgs->{apache2}) {
	    write_file ("NO_START=0\n", "$rootdir/etc/default/apache2");
	} else {
	    unlink "$rootdir/etc/default/apache2";
	}
    }
    $self->logmsg ("cleanup package status\n");
    # prevent auto selection of all standard, required or important 
    # packages which are not installed
    foreach my $pkg (keys %$pkginfo) {
	my $pri = $pkginfo->{$pkg}->{priority};
	if ($pri && ($pri eq 'required' || $pri eq 'important' 
		     || $pri eq 'standard')) {
	    if (!$instpkgs->{$pkg}) {
		$self->ve_dpkg_set_selection ($pkg, 'purge');
	    }
	}
    }

    $self->ve_command ("apt-get clean");

    $self->logmsg ("update available package list\n");

    $self->ve_command ("dpkg --clear-avail");
    foreach my $ss (@{$self->{sources}}) {
	my $relsrc = __url_to_filename ("$ss->{source}/dists/$ss->{suite}/Release");
	if (-f "$infodir/$relsrc" && -f "$infodir/$relsrc.gpg") {
	    $self->run_command ("cp '$infodir/$relsrc' '$rootdir/var/lib/apt/lists/$relsrc'");
	    $self->run_command ("cp '$infodir/$relsrc.gpg' '$rootdir/var/lib/apt/lists/$relsrc.gpg'");
	}
	foreach my $comp (@{$ss->{comp}}) {
	    my $src = __url_to_filename ("$ss->{source}/dists/$ss->{suite}/" .
					 "$comp/binary-$arch/Packages");
	    my $target = "/var/lib/apt/lists/$src";
	    $self->run_command ("cp '$infodir/$src' '$rootdir/$target'");
	    $self->ve_command ("dpkg --merge-avail '$target'");
	}
    }

    # set dselect default method
    write_file ("apt apt\n", "$rootdir/var/lib/dpkg/cmethopt"); 

    $self->ve_divert_remove ("/usr/sbin/policy-rc.d");

    $self->ve_divert_remove ("/sbin/start-stop-daemon"); 

    $self->ve_divert_remove ("/sbin/init"); 

    # finally stop the VE
    $self->run_command ("vzctl stop $veid --fast");
    $rootdir = $self->vz_priv_dir();

    unlink "$rootdir/sbin/defenv";

    unlink <$rootdir/root/dead.letter*>;

    unlink "$rootdir/var/log/init.log";

    unlink "$rootdir/aquota.group";

    unlink "$rootdir/aquota.user";

    write_file ("", "$rootdir/var/log/syslog");

    $self->logmsg ("detecting final size: ");

    my $sizestr = $self->run_command ("du -sm $rootdir", undef, 1);
    my $size;
    if ($sizestr =~ m/^(\d+)\s+\Q$rootdir\E$/) {
	$size = $1;
    } else {
	die "unable to detect size\n";
    }
    $self->logmsg ("$size MB\n");

    $self->write_config ("$rootdir/etc/appliance.info", $size);

    $self->logmsg ("creating final appliance archive\n");

    my $target = "$self->{targetname}.tar";
    unlink $target;
    unlink "$target.gz";

    $self->run_command ("tar cpf $target --numeric-owner -C '$rootdir' ./etc/appliance.info");
    $self->run_command ("tar rpf $target --numeric-owner -C '$rootdir' --exclude ./etc/appliance.info .");
    $self->run_command ("gzip $target");
}

sub read_installed {
    my ($self) = @_;

    my $rootdir = $self->vz_priv_dir();

    my $pkgfilelist = "$rootdir/var/lib/dpkg/status";
    local $/ = '';
    open (PKGLST, "<$pkgfilelist") ||
	die "unable to open '$pkgfilelist'";

    my $pkglist = {};

    while (my $rec = <PKGLST>) {
	chomp $rec;
	$rec =~ s/\n\s+/ /g;
	$rec .= "\n";
	my $res = {};

	while ($rec =~ s/^([^:]+):\s+(.*)\s*\n//) {
	    $res->{lc $1} = $2;
	}

	my $pkg = $res->{'package'};
	if (my $status = $res->{status}) {
	    my @sa = split (/\s+/, $status);
	    my $stat = $sa[0];
	    if ($stat && ($stat ne 'purge')) {
		$pkglist->{$pkg} = $res;
	    }
	}
    }

    close (PKGLST);    

    return $pkglist;
}

sub vz_root_dir {
    my ($self) = @_;

    my $veid = $self->{veid};

    return "/var/lib/vz/root/$veid";
}

sub vz_priv_dir {
    my ($self) = @_;

    my $veid = $self->{veid};

    return "/var/lib/vz/private/$veid";
}

sub ve_status {
    my ($self) = @_;

    my $veid = $self->{veid};
    
    my $res = $self->run_command ("vzctl status $veid", undef, 1);
    chomp $res;

    if ($res =~ m/^CTID\s+$veid\s+(exist|deleted)\s+(mounted|unmounted)\s+(running|down)$/) {
	return {
	    exist => $1 eq 'exist',
	    mounted => $2 eq 'mounted',
	    running => $3 eq 'running',
	};
    } else {
	die "unable to parse ve status";
    }
}

sub ve_command {
    my ($self, $cmd, $input) = @_;

    my $veid = $self->{veid};

    if (ref ($cmd) eq 'ARRAY') {
	unshift @$cmd, 'vzctl', 'exec2',  $veid, 'defenv';
	$self->run_command ($cmd, $input);	
    } else {
	$self->run_command ("vzctl exec2 $veid defenv $cmd", $input);
    }
}

# like ve_command, but pipes stdin correctly
sub ve_exec {
    my ($self, @cmd) = @_;

    my $veid = $self->{veid};

    my $reader;
    my $pid = open2($reader, "<&STDIN", 'vzctl', 'exec2', $veid, 
		    'defenv', @cmd) || die "unable to exec command";
    
    while (defined (my $line = <$reader>)) {
	$self->logmsg ($line);
    }

    waitpid ($pid, 0);
    my $rc = $? >> 8;

    die "ve_exec failed - status $rc\n" if $rc != 0;
}

sub ve_divert_add {
    my ($self, $filename) = @_;

    $self->ve_command ("dpkg-divert --add --divert '$filename.distrib' " .
		       "--rename '$filename'");
}
sub ve_divert_remove {
    my ($self, $filename) = @_;

    my $rootdir = $self->vz_root_dir();

    unlink "$rootdir/$filename";
    $self->ve_command ("dpkg-divert --remove --rename '$filename'");
}

sub ve_debconfig_set {
    my ($self, $dcdata) = @_;

    my $rootdir = $self->vz_root_dir();
    my $cfgfile = "/tmp/debconf.txt";
    write_file ($dcdata, "$rootdir/$cfgfile");
    $self->ve_command ("debconf-set-selections $cfgfile"); 
    unlink "$rootdir/$cfgfile";    
}

sub ve_dpkg_set_selection {
    my ($self, $pkg, $status) = @_;

    $self->ve_command ("dpkg --set-selections", "$pkg $status");
}

sub ve_dpkg {
    my ($self, $cmd, @pkglist) = @_;

    return if !scalar (@pkglist);

    my $pkginfo = $self->pkginfo();

    my $rootdir = $self->vz_root_dir();
    my $cachedir = $self->{cachedir};

    my @files;

    foreach my $pkg (@pkglist) {
	my $filename = $self->getpkgfile ($pkg);
	$self->run_command ("cp '$cachedir/$filename' '$rootdir/$filename'");
	push @files, "/$filename";
	$self->logmsg ("$cmd: $pkg\n");
    }

    my $fl = join (' ', @files);

    if ($cmd eq 'install') {
	$self->ve_command ("dpkg --force-depends --force-confold --install $fl");
    } elsif ($cmd eq 'unpack') {
	$self->ve_command ("dpkg --force-depends --unpack $fl");
    } else {
	die "internal error";
    }

    foreach my $fn (@files) { unlink "$rootdir$fn"; }
}

sub ve_destroy {
    my ($self) = @_;

    my $veid = $self->{veid}; # fixme

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
	$self->run_command ("vzctl stop $veid --fast");
    } elsif ($vestat->{mounted}) {
	$self->run_command ("vzctl umount $veid");
    }
    if ($vestat->{exist}) {
	$self->run_command ("vzctl destroy $veid");
    } else {
	unlink $self->{veconffile};
    }
}

sub ve_init {
    my ($self) = @_;

    my $root = $self->vz_root_dir();
    my $priv = $self->vz_priv_dir();

    my $veid = $self->{veid}; # fixme

    $self->logmsg ("initialize VE $veid\n");

    while (1) {
	my $vestat = $self->ve_status();
	if ($vestat->{running}) {
	    $self->run_command ("vzctl stop $veid --fast");
	} elsif ($vestat->{mounted}) {
	    $self->run_command ("vzctl umount $veid");
	} else {
	    last;
	}
	sleep (1);
    }

    rmtree $root;
    rmtree $priv;
    mkpath $root;
    mkpath $priv;

    $self->run_command ("vzctl mount $veid");
}

sub __deb_version_cmp {
    my ($cur, $op, $new) = @_;

    if (system("dpkg", "--compare-versions", $cur, $op, $new) == 0) {
	return 1;
    }

    return 0;
}

sub __parse_packages {
    my ($pkginfo, $filename, $src) = @_;

    local $/ = '';
    open (PKGLST, "<$filename") ||
	die "unable to open '$filename'";

    while (my $rec = <PKGLST>) {
	$rec =~ s/\n\s+/ /g;
	chomp $rec;
	$rec .= "\n";

	my $res = {};

	while ($rec =~ s/^([^:]+):\s+(.*)\s*\n//) {
	    $res->{lc $1} = $2;
	}

	my $pkg = $res->{'package'};
	if ($pkg && $res->{'filename'}) {
	    my $cur;
	    if (my $info = $pkginfo->{$pkg}) {
		$cur = $info->{version};
	    }
	    my $new = $res->{version};
	    if (!$cur || __deb_version_cmp ($cur, 'lt', $new)) {
		if ($src) {
		    $res->{url} = "$src/$res->{'filename'}";
		} else {
		    die "no url for package '$pkg'" if !$res->{url};
		}
		$pkginfo->{$pkg} = $res;
	    }
	}
    }

    close (PKGLST);    
}

sub pkginfo {
    my ($self) = @_;

    return $self->{pkginfo} if $self->{pkginfo};

    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    my $availfn = "$infodir/available";

    my $pkginfo = {};
    my $pkgcount = 0;

    # reading 'available' is faster, because it only contains latest version
    # (no need to do slow version compares)
    if (-f $availfn) {
	    __parse_packages ($pkginfo, $availfn);
	    $self->{pkginfo} = $pkginfo;
	    return $pkginfo;
    }

    $self->logmsg ("generating available package list\n");

    foreach my $ss (@{$self->{sources}}) {
	foreach my $comp (@{$ss->{comp}}) {
	    my $url = "$ss->{source}/dists/$ss->{suite}/$comp/binary-$arch/Packages";
	    my $pkgfilelist = "$infodir/" . __url_to_filename ($url);

	    my $src = $ss->{mirror} || $ss->{source};

	    __parse_packages ($pkginfo, $pkgfilelist, $src);
	}
    }

    if (my $dep = $self->{config}->{depends}) {
	foreach my $d (split (/,/, $dep)) {
	    if ($d =~ m/^\s*(\S+)\s*(\((\S+)\s+(\S+)\)\s*)?$/) {
		my ($pkg, $op, $rver) = ($1, $3, $4);
		$self->logmsg ("checking dependencies: $d\n");
		my $info = $pkginfo->{$pkg};
		die "package '$pkg' not available\n" if !$info;
		if ($op) {
		    my $cver = $info->{version};
		    if (!__deb_version_cmp ($cver, $op, $rver)) {
			die "detected wrong version '$cver'\n";
		    }
		}
	    } else {
		die "syntax error in depends field";
	    }
	}
    }

    $self->{pkginfo} = $pkginfo;

    my $tmpfn = "$availfn.tmp$$";
    my $fd = IO::File->new (">$tmpfn");
    foreach my $pkg (sort keys %$pkginfo) {
	my $info = $pkginfo->{$pkg};
	print $fd "package: $pkg\n";
	foreach my $k (sort keys %$info) {
	    next if $k eq 'description';
	    next if $k eq 'package';
	    my $v = $info->{$k};
	    print $fd "$k: $v\n" if $v;	    
	}
	print $fd "description: $info->{description}\n" if $info->{description};	    
	print $fd "\n";
    }
    close ($fd);

    rename ($tmpfn, $availfn);

    return $pkginfo;
}

sub __record_provides {
    my ($pkginfo, $closure, $list, $skipself) = @_;

    foreach my $pname (@$list) {
	my $info = $pkginfo->{$pname};
	# fixme: if someone install packages directly using dpkg, there
	# is no entry in 'available', only in 'status'. In that case, we
	# should extract info from $instpkgs
	if (!$info) {
	    warn "hint: ignoring provides for '$pname' - package not in 'available' list.\n";
	    next;
	}
	if (my $prov = $info->{provides}) {
	    my @pl = split (',', $prov);
	    foreach my $p (@pl) {
		$p =~ m/\s*(\S+)/;
		if (!($skipself && (grep { $1 eq $_ } @$list))) {
		    $closure->{$1} = 1;
		}
	    }
	}
	$closure->{$pname} = 1 if !$skipself;
    }
}

sub closure {
    my ($self, $closure, $list) = @_;

    my $pkginfo = $self->pkginfo();

    # first, record provided packages
    __record_provides ($pkginfo, $closure, $list, 1);

    my $pkgs = {};

    # then resolve dependencies
    foreach my $pname (@$list) {
	__closure_single ($pkginfo, $closure, $pkgs, $pname, $self->{excl});
    }

    return [ keys %$pkgs ];
}

sub __closure_single {
    my ($pkginfo, $closure, $pkgs, $pname, $excl) = @_;

    $pname =~ s/^\s+//;
    $pname =~ s/\s+$//;

    return if $closure->{$pname};

    my $info = $pkginfo->{$pname} || die "no such package '$pname'";

    my $dep = $info->{depends};
    my $predep = $info->{'pre-depends'};

    my $size = $info->{size};
    my $url = $info->{url};

    $url || die "$pname: no url for package '$pname'";
    
    $pkgs->{$pname} = 1;

    __record_provides ($pkginfo, $closure, [$pname]) if $info->{provides};

    $closure->{$pname} = 1;
 
    #print "$url\n";

    my @l;

    push  @l, split (/,/, $predep) if $predep;
    push  @l, split (/,/, $dep) if $dep;

  DEPEND: foreach my $p (@l) {
      my @l1 = split (/\|/, $p);
      foreach my $p1 (@l1) {
	  if ($p1 =~ m/^\s*(\S+).*/) {
	      #printf (STDERR "$pname: $p --> $1\n");
	      if ($closure->{$1}) {
		  next DEPEND; # dependency already met
	      }
	  }
      }
      # search for non-excluded alternative
      my $found;
      foreach my $p1 (@l1) {
	  if ($p1 =~ m/^\s*(\S+).*/) {
	      next if grep { $1 eq $_ } @$excl;
	      $found = $1;
	      last;
	  }
      }
      die "package '$pname' depends on exclusion '$p'\n" if !$found;

      #printf (STDERR "$pname: $p --> $found\n");
	  
      __closure_single ($pkginfo, $closure, $pkgs, $found, $excl);
  }
}

sub cache_packages {
    my ($self, $pkglist) = @_;

    foreach my $pkg (@$pkglist) {
	$self->getpkgfile ($pkg);
    }
}

sub getpkgfile {
    my ($self, $pkg) = @_;

    my $pkginfo = $self->pkginfo();
    my $info = $pkginfo->{$pkg} || die "no such package '$pkg'";
    my $cachedir = $self->{cachedir};

    my $url = $info->{url};

    my $filename;
    if ($url =~ m|/([^/]+.deb)$|) {
	$filename = $1;
    } else {
	die "internal error";
    }

    return $filename if -f "$cachedir/$filename";

    mkpath $cachedir;

    $self->download ($url, "$cachedir/$filename");

    return $filename;
}

sub install_init_script {
    my ($self, $script, $runlevel, $prio) = @_;

    my $suite = $self->{config}->{suite};
    my $rootdir = $self->vz_root_dir();

    my $base = basename ($script);
    my $target = "$rootdir/etc/init.d/$base";

    $self->run_command ("install -m 0755 '$script' '$target'");
    if ($suite eq 'etch' || $suite eq 'lenny') {
	$self->ve_command ("update-rc.d $base start $prio $runlevel .");
    } else {
	$self->ve_command ("insserv $base");
    }

    return $target;
}

sub bootstrap {
    my ($self, $opts) = @_;

    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $suite = $self->{config}->{suite};

    my $important = [ @{$self->{incl}} ];
    my $required;
    my $standard;

    my $mta = $opts->{exim} ? 'exim' : 'postfix';

    if ($mta eq 'postfix') {
	push @$important, "postfix";
    }

    foreach my $p (keys %$pkginfo) {
	next if grep { $p eq $_ } @{$self->{excl}};
	my $pri = $pkginfo->{$p}->{priority};
	next if !$pri;
	next if $mta ne 'exim' && $p =~ m/exim/; 
	next if $p =~ m/(selinux|semanage|policycoreutils)/;

	push @$required, $p  if $pri eq 'required';
	push @$important, $p if $pri eq 'important';
	push @$standard, $p if $pri eq 'standard' && !$opts->{minimal};
    }

    my $closure = {};
    $required = $self->closure ($closure, $required);
    $important = $self->closure ($closure, $important);

    if (!$opts->{minimal}) {
	push @$standard, 'xbase-clients';
	$standard = $self->closure ($closure, $standard);
    }

    # test if we have all 'ubuntu-minimal' and 'ubuntu-standard' packages
    # except those explicitly excluded
    if ($suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	my $mdeps = $pkginfo->{'ubuntu-minimal'}->{depends};
	foreach my $d (split (/,/, $mdeps)) {
	    if ($d =~ m/^\s*(\S+)$/) {
		my $pkg = $1;
		next if $closure->{$pkg};
		next if grep { $pkg eq $_ } @{$self->{excl}};
		die "missing ubuntu-minimal package '$pkg'\n";
	    }
	}
	if (!$opts->{minimal}) {
	    $mdeps = $pkginfo->{'ubuntu-standard'}->{depends};
	    foreach my $d (split (/,/, $mdeps)) {
		if ($d =~ m/^\s*(\S+)$/) {
		    my $pkg = $1;
		    next if $closure->{$pkg};
		    next if grep { $pkg eq $_ } @{$self->{excl}};
		    die "missing ubuntu-standard package '$pkg'\n";
		}
	    }
	}
    }

    # download/cache all files first
    $self->cache_packages ($required);
    $self->cache_packages ($important);
    $self->cache_packages ($standard);
 
    my $rootdir = $self->vz_priv_dir();

    # extract required packages first
    $self->logmsg ("create basic environment\n");
    foreach my $p (@$required) {
	my $filename = $self->getpkgfile ($p);
	$self->run_command ("ar -p '$self->{cachedir}/$filename' data.tar.gz | zcat | tar -C '$rootdir' -xf -");
    }

    # fake dpkg status
    my $data = "Package: dpkg\n" .
	"Version: $pkginfo->{dpkg}->{version}\n" .
	"Status: install ok installed\n";

    write_file ($data, "$rootdir/var/lib/dpkg/status");
    write_file ("", "$rootdir/var/lib/dpkg/info/dpkg.list");
    write_file ("", "$rootdir/var/lib/dpkg/available");

    $data = '';
    foreach my $ss (@{$self->{sources}}) {
	my $url = $ss->{source};
	my $comp = join (' ', @{$ss->{comp}});
	$data .= "deb $url $ss->{suite} $comp\n\n";
    }

    write_file ($data, "$rootdir/etc/apt/sources.list");

    $data = "# UNCONFIGURED FSTAB FOR BASE SYSTEM\n";
    write_file ($data, "$rootdir/etc/fstab", 0644);

    write_file ("localhost\n", "$rootdir/etc/hostname", 0644);

    # avoid warnings about non-existent resolv.conf
    write_file ("", "$rootdir/etc/resolv.conf", 0644);

    $data = "auto lo\niface lo inet loopback\n";
    write_file ($data, "$rootdir/etc/network/interfaces", 0644);

    # setup devices
    $self->run_command ("tar xzf '$devicetar' -C '$rootdir'");

    # avoid warnings about missing default locale
    write_file ("LANG=\"C\"\n", "$rootdir/etc/default/locale", 0644);

    # fake init
    rename ("$rootdir/sbin/init", "$rootdir/sbin/init.org");
    $self->run_command ("cp '$fake_init' '$rootdir/sbin/init'");

    $self->run_command ("cp '$default_env' '$rootdir/sbin/defenv'");

    $self->run_command ("vzctl start $veid");    
    $rootdir = $self->vz_root_dir(); 

    $self->logmsg ("initialize ld cache\n");
    $self->ve_command ("/sbin/ldconfig");
    $self->run_command ("ln -sf mawk '$rootdir/usr/bin/awk'");

    $self->logmsg ("installing packages\n");

    $self->ve_dpkg ('install', 'base-files', 'base-passwd');

    $self->ve_dpkg ('install', 'dpkg');

    $self->run_command ("ln -sf /usr/share/zoneinfo/UTC '$rootdir/etc/localtime'");
    
    $self->run_command ("ln -sf bash '$rootdir/bin/sh'");

    $self->ve_dpkg ('install', 'libc6');
    $self->ve_dpkg ('install', 'perl-base');

    unlink "$rootdir/usr/bin/awk";

    $self->ve_dpkg ('install', 'mawk');
    $self->ve_dpkg ('install', 'debconf');
    
    # unpack required packages
    foreach my $p (@$required) {
	$self->ve_dpkg ('unpack', $p);
    }

    rename ("$rootdir/sbin/init.org", "$rootdir/sbin/init");
    $self->ve_divert_add ("/sbin/init");
    $self->run_command ("cp '$fake_init' '$rootdir/sbin/init'");

    # disable service activation
    $self->ve_divert_add ("/usr/sbin/policy-rc.d");
    $data = "#!/bin/sh\nexit 101\n";
    write_file ($data, "$rootdir/usr/sbin/policy-rc.d", 755);

    # disable start-stop-daemon
    $self->ve_divert_add ("/sbin/start-stop-daemon");
    $data = <<EOD;
#!/bin/sh
echo
echo \"Warning: Fake start-stop-daemon called, doing nothing\"
EOD
    write_file ($data, "$rootdir/sbin/start-stop-daemon", 0755);

    # disable udevd
    $self->ve_divert_add ("/sbin/udevd");

    if ($suite eq 'etch') {
	# disable apache2 startup
	write_file ("NO_START=1\n", "$rootdir/etc/default/apache2");
    }

    $self->logmsg ("configure required packages\n");
    $self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");

    # set postfix defaults
    if ($mta eq 'postfix') {
	$data = "postfix postfix/main_mailer_type select Local only\n";
	$self->ve_debconfig_set ($data);

	$data = "postmaster: root\nwebmaster: root\n";
	write_file ($data, "$rootdir/etc/aliases");
    }

    if ($suite eq 'jaunty') {
	# jaunty does not create /var/run/network, so network startup fails.
	# so we do not use tmpfs for /var/run and /var/lock
	$self->run_command ("sed -e 's/RAMRUN=yes/RAMRUN=no/' -e 's/RAMLOCK=yes/RAMLOCK=no/'  -i $rootdir/etc/default/rcS");
	# and create the directory here
	$self->run_command ("mkdir $rootdir/var/run/network");
    }

    # unpack base packages
    foreach my $p (@$important) {
	$self->ve_dpkg ('unpack', $p);
    }

    # start loopback
    $self->ve_command ("ifconfig lo up");

    $self->logmsg ("configure important packages\n");
    $self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");

    if (-d "$rootdir/etc/event.d") {
	unlink <$rootdir/etc/event.d/tty*>;
    }

    if (-f "$rootdir/etc/inittab") {
	$self->run_command ("sed -i -e '/getty\\s38400\\stty[23456]/d' '$rootdir/etc/inittab'");
    }

    # Link /etc/mtab to /proc/mounts, so df and friends will work:
    unlink "$rootdir/etc/mtab";
    $self->ve_command ("ln -s /proc/mounts /etc/mtab");

    # reset password
    $self->ve_command ("usermod -L root");

    # regenerate sshd host keys
    $self->install_init_script ($script_ssh_init, 2, 14);

    if ($mta eq 'postfix') {
	$data = "postfix postfix/main_mailer_type select No configuration\n";
	$self->ve_debconfig_set ($data);

	unlink "$rootdir/etc/mailname";
	write_file ($postfix_main_cf, "$rootdir/etc/postfix/main.cf");
    }

    if (!$opts->{minimal}) {
	# unpack standard packages
	foreach my $p (@$standard) {
	    $self->ve_dpkg ('unpack', $p);
	}

	$self->logmsg ("configure standard packages\n");
	$self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");
    }

    # disable HWCLOCK access
    $self->run_command ("echo 'HWCLOCKACCESS=no' >> '$rootdir/etc/default/rcS'"); 

    # disable hald
    $self->ve_divert_add ("/usr/sbin/hald");

    # disable /dev/urandom init
    $self->run_command ("install -m 0755 '$script_init_urandom' '$rootdir/etc/init.d/urandom'");

    if ($suite eq 'etch' || $suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	# avoid klogd start
	$self->ve_divert_add ("/sbin/klogd");
    }

    # remove unnecessays sysctl entries to avoid warnings
    my $cmd = 'sed';
    $cmd .= ' -e \'s/^\(kernel\.printk.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(kernel\.maps_protect.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(fs\.inotify\.max_user_watches.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(vm\.mmap_min_addr.*\)/#\1/\'';
    $cmd .= " -i '$rootdir/etc/sysctl.conf'";
    $self->run_command ($cmd);

    my $bindv6only = "$rootdir/etc/sysctl.d/bindv6only.conf";
    if (-f $bindv6only) {
	$cmd = 'sed';
	$cmd .= ' -e \'s/^\(net\.ipv6\.bindv6only.*\)/#\1/\'';	
	$cmd .= " -i '$bindv6only'";
	$self->run_command ($cmd);
    }

    if ($suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	# disable tty init (console-setup)
	my $cmd = 'sed';
	$cmd .= ' -e \'s/^\(ACTIVE_CONSOLES=.*\)/ACTIVE_CONSOLES=/\'';
	$cmd .= " -i '$rootdir/etc/default/console-setup'";
	$self->run_command ($cmd);
    }

    if ($suite eq 'intrepid') {
	# remove sysctl setup (avoid warnings at startup)
	my $filelist = "$rootdir/etc/sysctl.d/10-console-messages.conf";
	$filelist .= " $rootdir/etc/sysctl.d/10-process-security.conf";
	$filelist .= " $rootdir/etc/sysctl.d/10-network-security.conf";
	$self->run_command ("rm $filelist");
    }
    if ($suite eq 'jaunty') {
	# remove sysctl setup (avoid warnings at startup)
	my $filelist = "$rootdir/etc/sysctl.d/10-console-messages.conf";
	$filelist .= " $rootdir/etc/sysctl.d/10-network-security.conf";
	$self->run_command ("rm $filelist");
    }
}

sub enter {
    my ($self) = @_;

    my $veid = $self->{veid};

    my $vestat = $self->ve_status();

    if (!$vestat->{exist}) {
	$self->logmsg ("Please create the appliance first (bootstrap)");
	return;
    }

    if (!$vestat->{running}) {
	$self->run_command ("vzctl start $veid");
    }

    system ("vzctl enter $veid");
}

sub ve_mysql_command {
    my ($self, $sql, $password) = @_;

    #my $bootstrap = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables " .
    #"--skip-bdb  --skip-innodb --skip-ndbcluster";

    $self->ve_command ("mysql", $sql);
}

sub ve_mysql_bootstrap {
    my ($self, $sql, $password) = @_;

    my $cmd;

    my $suite = $self->{config}->{suite};
 
    if ($suite eq 'squeeze' || $suite eq 'wheezy' ) {
	$cmd = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables";

    } else {
	$cmd = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables " .
	    "--skip-bdb  --skip-innodb --skip-ndbcluster";
    }

    $self->ve_command ($cmd, $sql);
}

sub compute_required {
    my ($self, $pkglist) = @_;

    my $pkginfo = $self->pkginfo();
    my $instpkgs = $self->read_installed ();

    my $closure = {};
    __record_provides ($pkginfo, $closure, [keys %$instpkgs]);

    return $self->closure ($closure, $pkglist);
}

sub task_postgres {
    my ($self, $opts) = @_;

    my @supp = ('7.4', '8.1');
    my $pgversion = '8.1';

    my $suite = $self->{config}->{suite};

    if ($suite eq 'lenny' || $suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	@supp = ('8.3');
	$pgversion = '8.3';
    } elsif ($suite eq 'squeeze') {
	@supp = ('8.4');
	$pgversion = '8.4';
    } elsif ($suite eq 'wheezy') {
        @supp = ('9.1');
        $pgversion = '9.1';
    }

    $pgversion = $opts->{version} if $opts->{version};

    die "unsupported postgres version '$pgversion'\n" 
	if !grep { $pgversion eq $_; } @supp;

    my $rootdir = $self->vz_root_dir();

    my $required = $self->compute_required (["postgresql-$pgversion"]);

    $self->cache_packages ($required);
 
    $self->ve_dpkg ('install', @$required);

    my $iscript = "postgresql-$pgversion";
    if ($suite eq 'squeeze' || $suite eq 'wheezy') {
      $iscript = 'postgresql';
    }

    $self->ve_command ("/etc/init.d/$iscript start") if $opts->{start};
}

sub task_mysql {
    my ($self, $opts) = @_;

    my $password = $opts->{password};
    my $rootdir = $self->vz_root_dir();

    my $suite = $self->{config}->{suite};
    
    my $ver = '5.0';
    if ($suite eq 'squeeze') {
      $ver = '5.1';
    } elsif ($suite eq 'wheezy') {
      $ver = '5.5';
    }

    my $required = $self->compute_required (['mysql-common', "mysql-server-$ver"]);

    $self->cache_packages ($required);
 
    $self->ve_dpkg ('install', @$required);

    # fix security (see /usr/bin/mysql_secure_installation)
    my $sql = "DELETE FROM mysql.user WHERE User='';\n" .
	"DELETE FROM mysql.user WHERE User='root' AND Host!='localhost';\n" .
	"FLUSH PRIVILEGES;\n";
    $self->ve_mysql_bootstrap ($sql);

    if ($password) {

	my $rpw = $password eq 'random' ? 'admin' : $password;

	my $sql = "USE mysql;\n" .
	    "UPDATE user SET password=PASSWORD(\"$rpw\") WHERE user='root';\n" .
	    "FLUSH PRIVILEGES;\n";
	$self->ve_mysql_bootstrap ($sql);

	write_file ("[client]\nuser=root\npassword=\"$rpw\"\n", "$rootdir/root/.my.cnf", 0600);
	if ($password eq 'random') {
	    $self->install_init_script ($script_mysql_randompw, 2, 20);
	}
    }

    $self->ve_command ("/etc/init.d/mysql start") if $opts->{start};
}

sub task_php {
    my ($self, $opts) = @_;

    my $memlimit = $opts->{memlimit};
    my $rootdir = $self->vz_root_dir();

    my $required = $self->compute_required ([qw (php5 php5-cli libapache2-mod-php5 php5-gd)]);

    $self->cache_packages ($required);

    $self->ve_dpkg ('install', @$required);

    if ($memlimit) {
	$self->run_command ("sed -e 's/^\\s*memory_limit\\s*=.*;/memory_limit = ${memlimit}M;/' -i $rootdir/etc/php5/apache2/php.ini");
    }
}

sub install {
    my ($self, $pkglist, $unpack) = @_;

    my $required = $self->compute_required ($pkglist);
    
    $self->cache_packages ($required);

    $self->ve_dpkg ($unpack ? 'unpack' : 'install', @$required);
}

sub cleanup {
    my ($self, $distclean) = @_;

    unlink $self->{logfile};
    unlink "$self->{targetname}.tar";
    unlink "$self->{targetname}.tar.gz";

    $self->ve_destroy ();
    unlink ".veid";

    rmtree $self->{cachedir} if $distclean && !$self->{config}->{cachedir};

    rmtree $self->{infodir};

}

1;
