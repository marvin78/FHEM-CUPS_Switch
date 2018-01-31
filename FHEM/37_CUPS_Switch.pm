# $Id: 98_CUPS_Switch.pm  $

package main;

use strict;
use warnings;
use Blocking;

#######################
# Global variables
my $version = "1.0.1";

my %gets = (
  "version:noArg"     => "",
); 


sub CUPS_Switch_Initialize($) { 
	my ($hash) = @_;

  $hash->{DefFn}      = "CUPS_Switch_Define";
  $hash->{NotifyFn}   = "CUPS_Switch_Notify";
  $hash->{UndefFn}    = "CUPS_Switch_Undefine";
  $hash->{GetFn}    	= "CUPS_Switch_Get";
	$hash->{AttrFn}     = "CUPS_Switch_Attr";
	
  $hash->{AttrList}   = "disable:1,0 ".		
												"do_not_notify:1,0 ".
												"pollInterval ".
												"switchOffTime ".
											  $readingFnAttributes;
	
	return undef;
} 

sub CUPS_Switch_Define($$) {
  my ($hash, $def) = @_;
	my $now = time();
	my $name = $hash->{NAME}; 
	
	my @a = split( "[ \t][ \t]*", $def );
	
	if ( int(@a) < 4 ) {
    my $msg =
"Wrong syntax: define <name> CUPS_Switch <CUPS-Printer-Name> <Switch-Device>[:<onCmd>:<offCmd>] [<host> <port>]";
    Log3 $name, 4, $msg;
    return $msg;
  }
	
	my @devTemp = split(":", $a[3]);
	my $onCmd = $devTemp[1] ? $devTemp[1] : "on";
	my $offCmd = $devTemp[2] ? $devTemp[2] : "off";
			
	$hash->{"CUPS"} = $a[2];
	$hash->{"DEVICE"} = $devTemp[0];
	$hash->{"HOST"} = $a[4] ? $a[4] : "localhost";
	$hash->{"PORT"} = $a[5] ? $a[5] : "631";
	$hash->{"ONCMD"} = $onCmd;
	$hash->{"OFFCMD"} = $offCmd;
	
	$hash->{VERSION}=$version;
	$hash->{NOTIFYDEV}  = "global";
	
	delete $hash->{TIMEOUT} if ($hash->{TIMEOUT});
	delete $hash->{TIMEOUTOFF} if ($hash->{TIMEOUTOFF});
	
	$hash->{"POLLINTERVAL"} = AttrVal($name,"pollInterval","-") ne "-" ? AttrVal($name,"pollInterval","30") : 30;
	$hash->{"SWITCHOFFTIME"} = AttrVal($name,"switchOffTime","-") ne "-" ? AttrVal($name,"switchOffTime","30") : 600;
	
	
	readingsSingleUpdate($hash,"state","active",1) if (AttrVal($name,"disable",0) != 1);
	readingsSingleUpdate($hash,"state","disabled",1) if (AttrVal($name,"disable",0) == 1);
	
	readingsSingleUpdate($hash, "job", 0, 1);
	
	delete $hash->{helper}{RUNNING_PID} if(defined($hash->{helper}{RUNNING_PID}));
	
	if ($init_done) {
		RemoveInternalTimer($hash);
		InternalTimer(gettimeofday()+2, "CUPS_Switch_StartGetSpool", $hash, 0);
	}
	
	delete $hash->{JOBS};
	$hash->{helper}{automatic}=0;
	
	
	return undef;
}

sub CUPS_Switch_Undefine($$) {
  my ($hash, $arg) = @_;
	
  RemoveInternalTimer($hash);
	
  return undef;
}

sub CUPS_Switch_Attr($@) {
  my ($cmd, $name, $attrName, $attrVal) = @_;
	
  my $orig = $attrVal;
	
	my $hash = $defs{$name};
	
	if ( $attrName eq "disable" ) {

		if ( $cmd eq "set" && $attrVal == 1 ) {
			if ($hash->{READINGS}{state}{VAL} ne "disabled") {
				readingsSingleUpdate($hash,"state","disabled",1);
				RemoveInternalTimer($hash);
				delete $hash->{helper}{RUNNING_PID} if(defined($hash->{helper}{RUNNING_PID}));
				delete $hash->{helper}{RUNNING_PID2} if(defined($hash->{helper}{RUNNING_PID2}));
			}
		}
		elsif ( $cmd eq "del" || $attrVal == 0 ) {
			if ($hash->{READINGS}{state}{VAL} ne "active") {
				readingsSingleUpdate($hash,"state","active",1);
				
				RemoveInternalTimer($hash,"CUPS_Switch_StartGetSpool");
				InternalTimer(gettimeofday()+2, "CUPS_Switch_StartGetSpool", $hash, 0);
				delete $hash->{helper}{RUNNING_PID} if(defined($hash->{helper}{RUNNING_PID}));
				delete $hash->{helper}{RUNNING_PID2} if(defined($hash->{helper}{RUNNING_PID2}));
			}
		}
	}
	
	if ( $attrName eq "pollInterval") {
		return "$name: pollInterval has to be a number (seconds)" if ($attrVal!~ /\d+/);
		if ( $cmd eq "set" ) {
			$hash->{"POLLINTERVAL"} = $attrVal;
		}
		else {
			$hash->{"POLLINTERVAL"} = 30;
		}
		
	}
	
	if ( $attrName eq "switchOffTime" ) {
		return "$name: switchOffTime has to be a number (seconds)" if ($attrVal!~ /\d+/);
		if ( $cmd eq "set" ) {
			$hash->{"SWITCHOFFTIME"} = $attrVal;
		}
		else {
			$hash->{"SWITCHOFFTIME"} = 600;
		}
		
	}
	
	
	return;
}

sub CUPS_Switch_Notify ($$) {
	my ($hash,$dev) = @_;

  return if($dev->{NAME} ne "global");
	
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
	InternalTimer(gettimeofday()+2, "CUPS_Switch_StartGetSpool", $hash, 0);

  return undef;

}

sub CUPS_Switch_Get($@) {
  my ($hash, $name, $cmd, @args) = @_;
  my $ret = undef;
  
  if ( $cmd eq "version") {
  	$hash->{VERSION} = $version;
    return "Version: ".$version;
  }
  else {
    $ret ="$name get with unknown argument $cmd, choose one of " . join(" ", sort keys %gets);
  }
 
  return $ret;
}

sub CUPS_Switch_StartGetSpool ($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	unless(exists($hash->{helper}{RUNNING_PID})) {
	
		$hash->{helper}{RUNNING_PID} = BlockingCall("CUPS_Switch_DoGetSpool", $name."|".$hash->{CUPS}, "CUPS_Switch_ProcessGetSpool", 60, "CUPS_Switch_ProcessAbortedGetSpool", $hash);
		
		 if(!$hash->{helper}{RUNNING_PID}) {
      delete($hash->{helper}{RUNNING_PID});
              
      my $seconds = $hash->{"POLLINTERVAL"};
              
      Log3 $hash->{NAME}, 4, "CUPS_Switch ($name) - fork failed, rescheduling next check in $seconds seconds";
              
      RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
      InternalTimer(gettimeofday()+$seconds, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
    }
        
    return undef;
	}		
	else {
		Log3 $hash->{NAME}, 4, "CUPS_Switch ($name) - another check is currently running. skipping check";
        
    my $seconds = 30;
        
      Log3 $hash->{NAME}, 4, "CUPS_Switch ($name) - rescheduling next check in $seconds seconds";
        
      RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
      InternalTimer(gettimeofday()+$seconds, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
        
      return "another check is currently running";
    }
}

sub CUPS_Switch_DoGetSpool ($) {
	my ($string) = @_;
	my ($name, $device) = split("\\|", $string);
	
	my $hash = $defs{$name};
	
	my $retcode;
  my $return;
  my $temp;
	
	Log3 $name, 4, "CUPS_Switch ($name) - DoGetSpool with $device, host ".$hash->{HOST}." and port ".$hash->{PORT};
	Log3 $name, 5, "CUPS_Switch ($name) - send lpstat -h $hash->{HOST}:$hash->{PORT} -o $device";
	
	$temp = qx(lpstat -h $hash->{HOST}:$hash->{PORT} -o $device);
	
	if ($temp =~ /$device/) {
		Log3 $name, 5, "CUPS_Switch ($name) - DoGetSpool: ".$temp;
		return "$name|$device|present";
	}
	else {
		Log3 $name, 4, "CUPS_Switch ($name) - DoGetSpool: Printer not found or no answer. ".$temp;
		return "$name|$device|absent";
	}
	
}

sub CUPS_Switch_ProcessGetSpool ($) {
	my ($string) = @_;
	
	my @a = split("\\|",$string);
  my $hash = $defs{$a[0]}; 
  
	my $val = $a[2];
	
  my $name = $hash->{NAME};
		
	delete($hash->{helper}{RUNNING_PID});
	
	my $device = $hash->{DEVICE};
	my $devState=ReadingsVal($device,"state","off");
	my $onCmd = $hash->{ONCMD};
		
	if($a[2] eq "present") {
		if ($hash->{READINGS}{job}{VAL} != 1) {
			$hash->{JOBS}++ if ($devState ne $onCmd || $hash->{JOBS});
			$hash->{helper}{setDevice}="on";
			readingsSingleUpdate($hash, "job", 1, 1);
			CUPS_Switch_SetDevice($hash) unless(AttrVal($name,"disable",0) == 1);
		}
  }
	else {
		if ($hash->{READINGS}{job}{VAL} != 0) {
			readingsSingleUpdate($hash, "job", 0, 1);
			$hash->{helper}{setDevice}="off";
			CUPS_Switch_SetDevice($hash) unless(AttrVal($name,"disable",0) == 1);
		}
		
		if (!$hash->{helper}{init} || $hash->{helper}{init}!=1) {
			readingsSingleUpdate($hash, "job", 0, 1);
			$hash->{helper}{init}=1;
		}
	}
	
	my $seconds=$hash->{"POLLINTERVAL"};
	
	Log3 $hash->{NAME}, 4, "CUPS_Switch ($name) - ProcessGetSpool";
	
	RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
  InternalTimer(gettimeofday()+$seconds, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
}

sub CUPS_Switch_SetDevice($) {
	my ($hash) = @_;
	
	my $name = $hash->{NAME};
	
	our $nHash;
	$nHash->{hash}=$hash;
	$nHash->{name}=$name;
	$nHash->{setOff}="true";
		
	my $set = $hash->{helper}{setDevice};
	my $device = $hash->{DEVICE};
	
	my $timeoutOff = $hash->{"SWITCHOFFTIME"};
	
	if ($hash->{READINGS}{job}{VAL} == 1 && $set eq "on" && AttrVal($name,"disable",0) != 1) {
		
		my $auto = 1;
		
		my $onCmd = $hash->{ONCMD};
		
		my $devState=ReadingsVal($device,"state","off");
				
		$auto = 0 if ($devState eq $onCmd && !$hash->{JOBS});		
		
		$hash->{helper}{automatic}=$auto;
		
		fhem("set $device:FILTER=STATE!=$onCmd $onCmd");
		
		Log3 $name, 4, "CUPS_Switch ($name) - set $device $onCmd"; 
	}
	if ($hash->{READINGS}{job}{VAL} == 0 && $set eq "off" && AttrVal($name,"disable",0) != 1 && $hash->{helper}{automatic}==1) {
	
	
		$hash->{OFF_TIMER_START} = FmtDateTime( gettimeofday() );
		
		RemoveInternalTimer($nHash, "CUPS_Switch_SetDeviceOff");
	
		InternalTimer(gettimeofday()+$timeoutOff, "CUPS_Switch_SetDeviceOff", $nHash, 0);
		
		Log3 $name, 4, "CUPS_Switch ($name) - off timer startet"; 
		
	}

	return undef;
}

sub CUPS_Switch_SetDeviceOff ($) {
	my ($nHash) = @_;

	my $hash = $nHash->{hash};
	
	my $set = $hash->{helper}{setDevice};
	my $device = $hash->{DEVICE};
	
	my $name = $hash->{NAME};
	
	my $offCmd = $hash->{OFFCMD};
	
	if ($hash->{READINGS}{job}{VAL} == 0 && $set eq "off" && AttrVal($name,"disable",0) != 1 && $hash->{helper}{automatic}==1) {
		fhem("set $device:FILTER=STATE!=$offCmd $offCmd");
		delete $hash->{JOBS};
		
		Log3 $name, 4, "CUPS_Switch ($name) - set $device $offCmd"; 
	}
	
	delete $hash->{OFF_TIMER_START};
	
	return undef;
}

sub CUPS_Switch_ProcessAbortedGetSpool ($) {
	my ($hash) = @_;
  my $name = $hash->{NAME};
	
	delete($hash->{helper}{RUNNING_PID});
  RemoveInternalTimer($hash);
	
	
	if(defined($hash->{helper}{RETRY_COUNT})) {
    if($hash->{helper}{RETRY_COUNT} >= 3) {
      Log3 $hash->{NAME}, 2, "CUPS_Switch ($name) - device could not be checked after ".$hash->{helper}{RETRY_COUNT}." ".($hash->{helper}{RETRY_COUNT} > 1 ? "retries" : "retry"). " (resuming normal operation)" if($hash->{helper}{RETRY_COUNT} == 3);
      
			RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
			InternalTimer(gettimeofday()+10, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
      $hash->{helper}{RETRY_COUNT}++;
    }
    else {
      Log3 $hash->{NAME}, 2, "CUPS_Switch ($name) - device could not be checked after ".$hash->{helper}{RETRY_COUNT}." ".($hash->{helper}{RETRY_COUNT} > 1 ? "retries" : "retry")." (retrying in 10 seconds)";
       
			 RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
			 InternalTimer(gettimeofday()+10, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
       $hash->{helper}{RETRY_COUNT}++;
    }

  }
  else {
    $hash->{helper}{RETRY_COUNT} = 1;
		
		RemoveInternalTimer($hash, "CUPS_Switch_StartGetSpool");
    InternalTimer(gettimeofday()+10, "CUPS_Switch_StartGetSpool", $hash, 0) unless(AttrVal($name,"disable",0) == 1);
    Log 2, "CUPS_Switch ($name) - device could not be checked (retrying in 10 seconds)"
  }
}

1;

=pod
=begin html

<a name="CUPS_Switch"></a>
<h3>CUPS_Switch</h3>
<ul>
  Defines a device to check for jobs for a printer in CUPS job list. The Module switches a device on and off (eg. a socket) to process the print job.<br />
	CUPS has to be installed on your FHEM-Server.<br /><br />
	
	<a name="CUPS_Switch_Define"></a>
  <b>Define</b><br />
  <ul>
    <code>define &lt;name&gt; CUPS_Switch &lt;CUPS-Printer-Name&gt; &lt;Switch-Device&gt;[:&lt;onCmd&gt;:&lt;offCmd&gt;] [&lt;host&gt; &lt;port&gt;]</code><br />
    <br />
		<b>CUPS-Printer-Name:</b> The correct name of the printer in CUPS. Name may not contain spaces.<br />
		<b>Switch-Device:</b> The device to switch on and off if a new job is detected<br />
		<b>onCmd:</b> The command to set &lt;Switch-Device&gt; on (optional - default is 'on')<br />
		<b>offCmd:</b> The command to set &lt;Switch-Device&gt; off (optional - default is 'off')<br />
		<b>host:</b> IP or localhost (optional)
		<b>port:</b> Port used by CUPS (optional - default is 631)
    <br /><br />

    Example:
    <ul>
      <code>define cupsPrinter CUPS_Switch PrinterHP Steckdose_Drucker:an:aus PrinterServer 631</code><br />
    </ul>
  </ul><br />
		
	<a name="CUPS_Switch_Attributes"></a>
  <b>Attributes</b><br />
  <ul>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li><br />
		<li><a href="#do_not_notify">do_not_notify</a></li><br />
    <li><a name="#disable">disable</a></li><br />
		<li><a name="pollInterval">pollInterval</a></li>
		check Job-Status every x seconds. Default is 30.<br /><br />
		<li><a name="switchOffTime">switchOffTime</a></li>
		switch Switch-Device off after x seconds. Default is 600.<br />
		<!--<li><a name="switchScript">switchScript</a></li>
		a script to start after switching the Switch-Device on<br />
		<li><a name="switchScriptTimeout">switchScriptTimout</a></li>
		start the script after x seconds<br />-->
	</ul><br />
	
	<a name="CUPS_Switch_Readings"></a>
  <b>Readings</b><br />
  <ul>
		<li>job<br />
      1 if at least one job is found, 0 if no job is found</li><br />
		<li>state<br />
      the state of the FHEM CUPS_Switch device (active/disabled).</li><br />
  </ul><br />
</ul>

=end html
=cut