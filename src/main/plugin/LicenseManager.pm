# Copyright (c) 2014, ickStream GmbH
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of ickStream nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL LOGITECH, INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package Plugins::IckStreamPlugin::LicenseManager;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5;
use File::Slurp;
use File::Spec::Functions qw(:ALL);
use URI::Escape qw( uri_escape_utf8 );

my $log = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $initializedPlayers = {};
my $initializedPlayerDaemon = undef;
my $PUBLISHER = 'AC9BFD85-26F6-4A97-BEB1-2DE43835A2F0';

sub getApplicationId {
	my $player = shift;
	my $cbSuccess = shift;
	my $cbFailure = shift;

	if($player) {
		my $playerConfiguration = $prefs->client($player)->get('playerConfiguration') || {};
		if(defined($playerConfiguration->{'applicationId'})) {
			&{$cbSuccess}(Crypt::Tea::decrypt($playerConfiguration->{'applicationId'},$serverPrefs->get('server_uuid')));
			return;
		}
	}elsif(defined($prefs->get('applicationId'))) {
		my $applicationId = Crypt::Tea::decrypt($prefs->get('applicationId'),$serverPrefs->get('server_uuid'));
		&{$cbSuccess}($applicationId);
		return;
	}
	
	_getLicenseMD5($player, 
		sub {
			my $md5 = shift;
			addLicenseIfConfirmed($player,$md5);
			
			if(isLicenseConfirmed($player, $md5)) {
				_retrieveApplicationId($player,$md5,
					sub {
						my $applicationId = shift;
						&{$cbSuccess}($applicationId);
					},
					sub {
						my $error = shift;
						&{$cbFailure}("Failed to retrieve application identity for "._getDeviceName($player).":\n".$error);
					});
			}else {
				&{$cbFailure}("License for "._getDeviceName($player)." has not been confirmed yet, please goto settings page an confirm it");
			}
		},
		sub {
			my $error = shift;
			if(defined($cbFailure)) {
				&{$cbFailure}($error);
			}
		});
}

sub getLicense {
	my $player = shift;
	my $cbSuccess = shift;
	my $cbFailure = shift;

	_readLicense($player,
		sub {
			my $md5 = shift;
			my $licenseText = shift;
			addLicenseIfConfirmed($player,$md5);
			&{$cbSuccess}($md5, $licenseText);
		},
		sub {
			my $error = shift;
			if(defined($cbFailure)) {
				&{$cbFailure}($error);
			}
		});
			
}

sub showLicense {
   my ($client, $params, $callback, $httpClient, $response) = @_;
    getLicense($client,
    	sub {
    		my $md5 = shift;
    		my $licenseText = shift;
    		
    		$params->{'licenseText'} = $licenseText; 
		    my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/showlicense.html', $params);
			&{$callback}($client,$params,$output,$httpClient,$response);
    	},
    	sub {
    		$params->{'licenseText'} = "Failed to retrieve license";
		    my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/showlicense.html', $params);
			&{$callback}($client,$params,$output,$httpClient,$response);
    	});
    return undef;
}

sub confirmLicense {
	my $player = shift;
	my $md5 = shift;
	
	if(!defined($prefs->get('confirmedLicenses'))) {
		$prefs->set('confirmedLicenses',{});
	}
	my $confirmedLicenses = $prefs->get('confirmedLicenses');	
	$confirmedLicenses->{_getDeviceModel($player)} = $md5;
}

sub _retrieveApplicationId {
	my $player = shift;
	my $confirmedLicenseMD5 = shift;
	my $cbSuccess = shift;
	my $cbFailure = shift;
	
	my $kernelInfo = "Unknown OS";
	if(Slim::Utils::OSDetect::isLinux()) {
		$kernelInfo = `uname -a`;
	}elsif(Slim::Utils::OSDetect::isMac()) {
		$kernelInfo = `uname -a`;
	}elsif(Slim::Utils::OSDetect::isWindows()) {
		$kernelInfo = "Windows";
	}
	
	my $httpParams = { timeout => 35 };
	$log->debug("Getting application identity for "._getDeviceName($player)." using confirmed license with MD5: ".$confirmedLicenseMD5."\nEnvironment: \n".$kernelInfo);
	my $macAddress = undef;
	my $uuid = $serverPrefs->get('server_uuid');
	my $deviceModel = _getDeviceModel($player);
	if($player) {
		$uuid = $player->uuid();
		$macAddress = $player->macaddress();
	}
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $jsonResponse = from_json($http->content);
			if(defined($jsonResponse->{'applicationId'})) {
				if($player) {
					my $playerConfiguration = $prefs->client($player)->get('playerConfiguration') || {};
					$playerConfiguration->{'applicationId'} = Crypt::Tea::encrypt($jsonResponse->{'applicationId'},$serverPrefs->get('server_uuid'));
					$prefs->client($player)->set('playerConfiguration',$playerConfiguration);
				}else {
					$prefs->set('applicationId',Crypt::Tea::encrypt($jsonResponse->{'applicationId'},$serverPrefs->get('server_uuid')));
				}
				&{$cbSuccess}($jsonResponse->{'applicationId'});
				return;
			}
			if(defined($cbFailure)) {
				&{$cbFailure}("Invalid response when getting application identity");
			}
		},
		sub {
			my $http = shift;
			my $error = shift;
			if(defined($cbFailure)) {
				&{$cbFailure}("Failed to retrieve application identity: $error");
			}
		},
		$httpParams
		)->post(_getBaseUrl().'/getapplication','Content-Type' => 'application/x-www-form-urlencoded',
			'publisherId='.$PUBLISHER.
			'&confirmedLicenseMD5='.$confirmedLicenseMD5.
			'&deviceModel='.uri_escape_utf8($deviceModel).
			(defined($macAddress)?'&deviceMAC='.uri_escape_utf8($macAddress):"").
			(defined($uuid)?'&deviceUUID='.uri_escape_utf8($uuid):"").
			'&environment='.uri_escape_utf8($kernelInfo)
			);
}

sub addLicenseIfConfirmed {
	my $player = shift;
	my $md5 = shift;
	
	my $confirmedLicenses = $prefs->get('confirmedLicenses') || {};	
	foreach my $confirmedLicense (values %$confirmedLicenses) {
		if($md5 eq $confirmedLicense) {
			$confirmedLicenses->{_getDeviceModel($player)} = $md5;
			last;
		}
	}
}

sub isLicenseConfirmed {
	my $player = shift;

	my $confirmedLicenses = $prefs->get('confirmedLicenses') || {};	
	return $confirmedLicenses->{_getDeviceModel($player)};
}

sub _getDeviceModel {
	my $player = shift;
	my $deviceModel = "lms";
	if($player) {
		$deviceModel = $player->model();
	}
	return $deviceModel;
}

sub _getDeviceName {
	my $player = shift;
	my $deviceName = "Logitech Media Server";
	if($player) {
		$deviceName = $player->name();
	}
	return $deviceName;
}

sub _getLicenseMD5 {
	my $player = shift;
	my $cbSuccess = shift;
	my $cbFailure = shift;

	my $confirmedLicenses = $prefs->get('confirmedLicenses') || {};	
	if(defined($confirmedLicenses->{_getDeviceModel($player)})) {
		&{$cbSuccess}($confirmedLicenses->{_getDeviceModel($player)});
		return;
	}

	_readLicense($player,
		sub {
			my $md5 = shift;
			my $licenseText = shift;
			&{$cbSuccess}($md5);
		},
		sub {
			my $error = shift;
			if(defined($cbFailure)) {
				&{$cbFailure}($error);
			}
		});
			
}

sub _readLicense {
	my $player = shift;
	my $cbSuccess = shift;
	my $cbFailure = shift;
	
	my $licenseDir = catdir(Slim::Utils::OSDetect::dirsFor('prefs'), 'plugin', 'ickstream', 'licenses');
	my $licenseFile = catfile($licenseDir,"license_"._getDeviceModel($player).".txt");
	if(-e $licenseFile) {
		my $licenseText = eval { read_file($licenseFile) };
		if(defined($licenseText)) {
			my $md5 = Digest::MD5::md5_hex($licenseText);
			if(defined($md5)) {
				&{$cbSuccess}($md5,$licenseText);
				return;
			}
		}
	}

	my $httpParams = { timeout => 35 };
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $jsonResponse = from_json($http->content);
			if(defined($jsonResponse->{'md5'})) {
				my $prefsDir = Slim::Utils::OSDetect::dirsFor('prefs');
				my $pluginConfigurationDir = catdir(Slim::Utils::OSDetect::dirsFor('prefs'), 'plugin', 'ickstream');
				mkdir($pluginConfigurationDir);
				mkdir($licenseDir);
				my $fh;
				open($fh,"> $licenseFile") or do {
                    $log->warn("Unable to save retrieved license file to: $licenseFile");
                };
                print $fh $jsonResponse->{'licenseText'};
                close $fh;
				&{$cbSuccess}($jsonResponse->{'md5'},$jsonResponse->{'licenseText'});
				return;
			}
			&{$cbFailure}("Invalid response when retrieving license");
		},
		sub {
			&{$cbFailure}("Failed to retrieve license");
		},
		$httpParams
		)->get(_getBaseUrl().'/getlicense?publisherId='.$PUBLISHER.'&deviceModel='._getDeviceModel($player),'Content-Type' => 'application/json');
}

sub _getBaseUrl {
	my $licenseBaseUrl = 'https://api.ickstream.com/ickstream-cloud-application-publisher';
	if(defined($prefs->get('licenseBaseUrl'))) {
		$licenseBaseUrl = $prefs->get('licenseBaseUrl') || $licenseBaseUrl;
	}
	return $licenseBaseUrl;
}

1;
